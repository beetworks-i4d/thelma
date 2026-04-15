#!/usr/bin/env ruby
# generate_short_bodies.rb — Generate body-only XMLs for 30 shorts from batch recordings.
#
# Each recording session has scripted beats (hooks/closes) recorded first,
# then organic body content. This script finds the body section in each recording,
# discovers 30-90s candidates using quality scoring, and generates one XML per short.
#
# Usage: ruby scripts/generate_short_bodies.rb --library <library-name>
#   --library  Library name (required). Resolves to libraries/<name>/library.yaml.

require 'yaml'
require 'json'
require 'shellwords'
require 'fileutils'
require 'date'

PROJECT_ROOT = ENV['BUTTERCUT_ROOT'] || File.expand_path('..', __dir__)
BUILD_SCRIPT = File.join(PROJECT_ROOT, 'scripts', 'build_structure_cut.rb')

# === Recording → Shorts mapping (client-provided) ===
RECORDING_GROUPS = [
  {
    name: 'group_1',
    videos: ['Dylan Shorts 1.MP4'],
    shorts: (1..7).to_a
  },
  {
    name: 'group_2',
    videos: ['MVI_5116.MP4', 'MVI_5118.MP4'],
    shorts: (8..15).to_a
  },
  {
    name: 'group_3',
    videos: ['MVI_5119.MP4'],
    shorts: (15..22).to_a
  },
  {
    name: 'group_4',
    videos: ['MVI_5120.MP4'],
    shorts: (23..30).to_a
  }
].freeze

# === CLI parsing ===

library_name = nil
i = 0
while i < ARGV.length
  case ARGV[i]
  when '--library'
    library_name = ARGV[i + 1]
    i += 2
  else
    abort "Unknown argument: #{ARGV[i]}\nUsage: ruby scripts/generate_short_bodies.rb --library <library-name>"
  end
end

abort "Usage: ruby scripts/generate_short_bodies.rb --library <library-name>\n  --library is required" unless library_name

# === Derive paths from library.yaml ===

LIBRARY_DIR = File.join(PROJECT_ROOT, 'libraries', library_name)
library_yaml_path = File.join(LIBRARY_DIR, 'library.yaml')
abort "Library not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

library = YAML.load_file(library_yaml_path, permitted_classes: [Date])

abort "No 'videos' in #{library_yaml_path}" unless library['videos'].is_a?(Array) && !library['videos'].empty?
abort "No 'script_parsed' in #{library_yaml_path}" unless library['script_parsed']

TRANSCRIPTS_DIR = File.join(LIBRARY_DIR, 'transcripts')
script_parsed_path = File.join(TRANSCRIPTS_DIR, library['script_parsed'])
abort "Script not found: #{script_parsed_path}" unless File.exist?(script_parsed_path)

OUTPUT_DIR = File.join(LIBRARY_DIR, 'output', 'shorts-bodies')
FileUtils.mkdir_p(OUTPUT_DIR)

# === Helpers (from branch_a_batch.rb) ===

def fmt(t)
  m = (t / 60).floor
  s = t - m * 60
  '%02d:%05.2f' % [m, s]
end

def tc(t)
  h = (t / 3600).floor
  m = ((t - h * 3600) / 60).floor
  s = t - h * 3600 - m * 60
  '%02d:%02d:%05.2f' % [h, m, s]
end

def word_overlap(script_text, transcript_text)
  return 0.0 if script_text.nil? || transcript_text.nil? || script_text.empty? || transcript_text.empty?
  words_script = script_text.downcase.gsub(/[^a-z0-9\s]/, '').split.reject { |w| w.length < 3 }
  words_transcript = transcript_text.downcase.gsub(/[^a-z0-9\s]/, '').split.reject { |w| w.length < 3 }
  return 0.0 if words_script.empty? || words_transcript.empty?
  intersection = (words_script & words_transcript).length
  intersection.to_f / words_script.length
end

def segment_quality(seg)
  text = seg['text'].to_s.strip
  return 0 if text.length < 10
  return 0 if text =~ /^(okay|ok|yeah|so|um|uh|hmm|right)[.,]?\s*$/i
  words = text.scan(/\b(\w+)\b/).flatten
  word_count = words.length
  return 0 if word_count > 0 && words.group_by { |w| w.downcase }.any? { |w, occ| occ.length >= 4 && w.length > 2 && occ.length.to_f / word_count > 0.5 }
  penalty = (text[-1] !~ /[.!?"]/ && text.length < 40) ? 0.5 : 1.0
  penalty *= 0.7 if text =~ /\b(\w{3,})\s+\1\b/i
  dur = seg['end'] - seg['start']
  dur_score = dur >= 3 && dur <= 15 ? 1.0 : (dur > 15 ? 0.7 : 0.3)
  penalty * dur_score
end

def merge_continuous_clips(segments, gap_threshold: 1.5)
  return [] if segments.empty?
  clips = []
  current_start = segments.first['start']
  current_end = segments.first['end']

  segments[1..].each do |seg|
    if seg['start'] - current_end <= gap_threshold
      current_end = seg['end']
    else
      clips << { 'video_start' => current_start, 'video_end' => current_end }
      current_start = seg['start']
      current_end = seg['end']
    end
  end
  clips << { 'video_start' => current_start, 'video_end' => current_end }
  clips
end

def load_transcript(video_basename, transcripts_dir, cache)
  return cache[video_basename] if cache[video_basename]

  base = video_basename.sub(/\.[^.]+$/, '')
  base_under = base.gsub(' ', '_')
  cleaned = Dir.glob(File.join(transcripts_dir, "#{base}_transcript_cleaned.json")).first ||
            Dir.glob(File.join(transcripts_dir, "#{base_under}_transcript_cleaned.json")).first
  raw = Dir.glob(File.join(transcripts_dir, "#{base}_transcript.json")).first ||
        Dir.glob(File.join(transcripts_dir, "#{base_under}_transcript.json")).first
  path = cleaned || raw

  unless path
    $stderr.puts "  WARNING: No transcript found for #{video_basename}"
    return nil
  end

  data = JSON.parse(File.read(path))
  cache[video_basename] = data
  data
end

# === Overlap detection ===

def detect_overlaps(groups)
  short_to_groups = {}
  groups.each do |g|
    g[:shorts].each do |num|
      short_to_groups[num] ||= []
      short_to_groups[num] << g[:name]
    end
  end
  short_to_groups.select { |_num, grps| grps.length > 1 }
end

# === Candidate scoring ===

def score_candidate(candidate_segments)
  return { quality_avg: 0.0, duration_fitness: 0.0, speech_density: 0.0, composite: 0.0 } if candidate_segments.empty?

  qualities = candidate_segments.map { |s| segment_quality(s) }
  quality_avg = qualities.sum / qualities.length.to_f

  duration = candidate_segments.last['end'] - candidate_segments.first['start']
  duration_fitness = if duration < 30 || duration > 90
    0.1
  else
    Math.exp(-((duration - 60.0) ** 2) / (2.0 * 15.0 ** 2))
  end

  total_span = candidate_segments.last['end'] - candidate_segments.first['start']
  total_speech = candidate_segments.sum { |s| s['end'] - s['start'] }
  speech_density = total_span > 0 ? (total_speech / total_span) : 0.0

  composite = quality_avg * 0.40 + duration_fitness * 0.35 + speech_density * 0.25

  {
    quality_avg: quality_avg.round(3),
    duration_fitness: duration_fitness.round(3),
    speech_density: speech_density.round(3),
    composite: composite.round(3)
  }
end

# === Body section discovery ===

def find_body_candidates(body_segments, n_candidates, gap_threshold: 2.0)
  return [] if body_segments.empty? || n_candidates <= 0

  # Step 1: Group segments by natural gaps
  raw_groups = []
  current_group = [body_segments.first]

  body_segments[1..].each do |seg|
    if seg['start'] - current_group.last['end'] > gap_threshold
      raw_groups << current_group
      current_group = [seg]
    else
      current_group << seg
    end
  end
  raw_groups << current_group

  # Step 2: Build candidates by merging adjacent small groups to reach 30-90s
  candidates = []
  i = 0
  while i < raw_groups.length
    merged = raw_groups[i].dup
    j = i + 1

    while j < raw_groups.length
      merged_duration = merged.last['end'] - merged.first['start']
      break if merged_duration >= 30
      merged.concat(raw_groups[j])
      j += 1
    end

    duration = merged.last['end'] - merged.first['start']
    if duration >= 15
      candidates << {
        segments: merged,
        duration: duration.round(2),
        score: score_candidate(merged)
      }
    end

    i = [j, i + 1].max
  end

  # Step 3: If not enough candidates, try tighter gap threshold
  if candidates.length < n_candidates && gap_threshold > 1.0
    return find_body_candidates(body_segments, n_candidates, gap_threshold: 1.0)
  end

  # Step 4: Score and rank, pick top N, re-sort chronologically
  candidates.sort_by! { |c| -c[:score][:composite] }
  selected = candidates.first(n_candidates)
  selected.sort_by! { |c| c[:segments].first['start'] }
  selected
end

# === Hook/close matching (per group, forward-only sliding window) ===

def match_hooks_closes(group_shorts, script, unified_segments)
  matches = {}

  group_shorts.each do |num|
    short_def = script['shorts'].find { |s| s['number'] == num }
    next unless short_def

    beats = short_def['beats']
    hook_beat = beats.find { |b| b['role'] == 'hook' }
    close_beat = beats.find { |b| b['role'] == 'close' }

    [['hook', hook_beat], ['close', close_beat]].each do |role, beat|
      next unless beat
      beat_text = beat['text']
      best_score = 0
      best_start = nil
      best_size = 1

      (0...unified_segments.length).each do |si|
        max_win = [8, unified_segments.length - si].min
        (1..max_win).each do |w|
          break if unified_segments[si + w - 1]['_video_path'] != unified_segments[si]['_video_path']
          break if w > 1 && unified_segments[si + w - 1]['start'] - unified_segments[si + w - 2]['end'] > 5

          window_text = unified_segments[si, w].map { |s| s['text'] }.join(' ')
          score = word_overlap(beat_text, window_text)
          if score > best_score
            best_score = score
            best_start = si
            best_size = w
          end
        end
      end

      if best_start && best_score > 0.12
        matches[num] ||= {}
        matches[num][role] = {
          idx: best_start,
          size: best_size,
          score: best_score,
          end_time: unified_segments[best_start + best_size - 1]['end']
        }
      end
    end
  end

  matches
end

# === Load data ===

$stderr.puts "Loading script and library (#{library_name})..."
script = YAML.load_file(script_parsed_path, permitted_classes: [Date])
transcript_cache = {}

# Build video lookup by basename
video_lookup = {}
library['videos'].each do |v|
  basename = File.basename(v['path'])
  video_lookup[basename] = v
end

# === PHASE 1: Detect overlaps ===

$stderr.puts "\n--- Phase 1: Detecting overlaps ---"
overlaps = detect_overlaps(RECORDING_GROUPS)
if overlaps.any?
  overlaps.each { |num, grps| $stderr.puts "  Overlap: Short #{num} claimed by #{grps.join(' and ')}" }
else
  $stderr.puts "  No overlaps detected"
end

# === PHASE 2: Per-group body discovery ===

$stderr.puts "\n--- Phase 2: Per-group body discovery ---"
group_results = {}

RECORDING_GROUPS.each do |group|
  $stderr.puts "\n=== #{group[:name]}: #{group[:videos].join(' + ')} → shorts #{group[:shorts].first}-#{group[:shorts].last} ==="

  # 2a. Build group timeline
  unified = []
  group[:videos].each do |vname|
    v = video_lookup[vname]
    unless v
      $stderr.puts "  WARNING: Video #{vname} not found in library.yaml — skipping"
      next
    end

    transcript = load_transcript(vname, TRANSCRIPTS_DIR, transcript_cache)
    unless transcript
      $stderr.puts "  SKIP: #{vname} — no transcript"
      next
    end

    transcript['segments'].each do |seg|
      unified << seg.merge(
        '_video_path' => v['path'],
        '_video_basename' => vname,
        '_video_info' => v
      )
    end
    $stderr.puts "  #{vname}: #{transcript['segments'].length} segments"
  end

  if unified.empty?
    $stderr.puts "  ERROR: No segments for #{group[:name]} — skipping"
    group_results[group[:name]] = { body_start: nil, body_duration: 0, candidates: [] }
    next
  end

  $stderr.puts "  Unified timeline: #{unified.length} segments"

  # 2b. Match hooks and closes
  matches = match_hooks_closes(group[:shorts], script, unified)
  matched_count = matches.keys.length
  $stderr.puts "  Matched #{matched_count}/#{group[:shorts].length} shorts (hooks/closes)"

  # 2c. Find body section start (after last matched segment)
  last_matched_end = 0.0
  last_matched_idx = 0
  matches.each_value do |m|
    ['hook', 'close'].each do |role|
      next unless m[role]
      end_idx = m[role][:idx] + m[role][:size] - 1
      if unified[end_idx]['end'] > last_matched_end
        last_matched_end = unified[end_idx]['end']
        last_matched_idx = end_idx
      end
    end
  end

  # Body = everything after last matched segment
  body_segments = unified.select { |s| s['start'] >= last_matched_end }
  body_segments = body_segments.select { |s| segment_quality(s) > 0 }
  body_segments.sort_by! { |s| s['start'] }

  if body_segments.empty?
    $stderr.puts "  WARNING: Empty body section for #{group[:name]}"
    group_results[group[:name]] = { body_start: last_matched_end, body_duration: 0, candidates: [] }
    next
  end

  body_start = body_segments.first['start']
  body_end = body_segments.last['end']
  body_duration = body_end - body_start
  $stderr.puts "  Body section: #{fmt(body_start)} → #{fmt(body_end)} (#{fmt(body_duration)})"

  # 2d. Discover N candidates
  n_candidates = group[:shorts].length
  candidates = find_body_candidates(body_segments, n_candidates)
  $stderr.puts "  Found #{candidates.length}/#{n_candidates} body candidates"

  # Map candidates chronologically to short numbers
  candidates.each_with_index do |c, idx|
    c[:short_num] = group[:shorts][idx] if idx < group[:shorts].length
    c[:video_path] = c[:segments].first['_video_path']
    c[:video_basename] = c[:segments].first['_video_basename']
    c[:video_info] = c[:segments].first['_video_info']
    text = c[:segments].map { |s| s['text'].strip }.join(' ')
    c[:distillation] = text.length > 80 ? text[0..77] + '...' : text
    $stderr.puts "    Short #{'%02d' % c[:short_num]}: #{fmt(c[:duration])} @ #{fmt(c[:segments].first['start'])} (score: #{c[:score][:composite]})"
  end

  group_results[group[:name]] = {
    body_start: body_start,
    body_duration: body_duration,
    body_segment_count: body_segments.length,
    candidates: candidates
  }
end

# === PHASE 3: Overlap resolution ===

$stderr.puts "\n--- Phase 3: Overlap resolution ---"
overlap_resolutions = []

overlaps.each do |short_num, competing_groups|
  entries = competing_groups.map do |gname|
    cand = (group_results[gname] || {})[:candidates]&.find { |c| c[:short_num] == short_num }
    { group: gname, candidate: cand }
  end.select { |e| e[:candidate] }

  if entries.length < 2
    winner = entries.first
    $stderr.puts "  Short #{short_num}: only one group has a candidate (#{winner ? winner[:group] : 'none'}) — no contest"
    next
  end

  entries.sort_by! { |e| -e[:candidate][:score][:composite] }
  winner = entries.first
  loser = entries.last

  # Remove overlapping short from loser's allocation
  group_results[loser[:group]][:candidates].reject! { |c| c[:short_num] == short_num }

  resolution = {
    short_num: short_num,
    winner_group: winner[:group],
    winner_score: winner[:candidate][:score][:composite],
    loser_group: loser[:group],
    loser_score: loser[:candidate][:score][:composite],
    reasoning: "#{winner[:group]} scored #{winner[:candidate][:score][:composite]} vs #{loser[:group]} #{loser[:candidate][:score][:composite]} — " \
               "winner has better composite (quality #{winner[:candidate][:score][:quality_avg]}, " \
               "duration fitness #{winner[:candidate][:score][:duration_fitness]}, " \
               "speech density #{winner[:candidate][:score][:speech_density]})"
  }
  overlap_resolutions << resolution
  $stderr.puts "  Short #{short_num}: #{resolution[:winner_group]} WINS (#{resolution[:winner_score]}) over #{resolution[:loser_group]} (#{resolution[:loser_score]})"
  $stderr.puts "    Reason: #{resolution[:reasoning]}"
end

# === PHASE 4: Pre-flight report ===

$stderr.puts "\n"
$stderr.puts "=========================================="
$stderr.puts "PRE-FLIGHT REPORT"
$stderr.puts "=========================================="

$stderr.puts "\n--- Per Recording ---"
RECORDING_GROUPS.each do |group|
  gr = group_results[group[:name]]
  next unless gr
  $stderr.puts "#{group[:name]}: #{group[:videos].join(' + ')}"
  if gr[:body_start]
    $stderr.puts "  Body start: #{fmt(gr[:body_start])}"
    $stderr.puts "  Body duration: #{fmt(gr[:body_duration])}"
    $stderr.puts "  Body segments: #{gr[:body_segment_count] || 0}"
    $stderr.puts "  Candidates found: #{gr[:candidates].length} / #{group[:shorts].length} needed"
  else
    $stderr.puts "  NO BODY SECTION FOUND"
  end
  $stderr.puts ""
end

if overlap_resolutions.any?
  $stderr.puts "--- Overlap Resolutions ---"
  overlap_resolutions.each do |r|
    $stderr.puts "  Short #{r[:short_num]}: #{r[:winner_group]} wins (#{r[:winner_score]}) over #{r[:loser_group]} (#{r[:loser_score]})"
    $stderr.puts "    #{r[:reasoning]}"
  end
  $stderr.puts ""
end

$stderr.puts "--- Per Short ---"
$stderr.puts "%-6s %-12s %8s %s" % ['#', 'Source', 'Duration', 'Distillation']
$stderr.puts '-' * 90

all_candidates = []
RECORDING_GROUPS.each do |group|
  gr = group_results[group[:name]]
  next unless gr
  gr[:candidates].each { |c| all_candidates << c.merge(group_name: group[:name]) }
end

all_candidates.sort_by! { |c| c[:short_num] }
all_candidates.each do |c|
  $stderr.puts "%-6s %-12s %8s %s" % [
    "##{c[:short_num]}",
    c[:video_basename][0..11],
    fmt(c[:duration]),
    c[:distillation][0..49]
  ]
end

missing = (1..30).to_a - all_candidates.map { |c| c[:short_num] }
if missing.any?
  $stderr.puts "\nWARNING: Missing candidates for shorts: #{missing.join(', ')}"
end

$stderr.puts "\n=========================================="
$stderr.print "Approve and generate XMLs? (y/N): "
$stderr.flush
approval = $stdin.gets&.strip&.downcase
unless approval == 'y'
  $stderr.puts "Aborted by user."
  exit 0
end

# === PHASE 5: XML generation ===

$stderr.puts "\n--- Phase 5: Generating XMLs ---"
generated = []

all_candidates.sort_by! { |c| c[:short_num] }
all_candidates.each do |candidate|
  num = candidate[:short_num]
  padded = '%02d' % num
  short_def = script['shorts'].find { |s| s['number'] == num }

  $stderr.puts "\n  Short ##{padded}: #{short_def ? short_def['title'] : 'Unknown'}"

  video_info = candidate[:video_info]
  clips = merge_continuous_clips(candidate[:segments])

  total_dur = clips.sum { |c| c['video_end'] - c['video_start'] }

  # Build markers
  markers = []
  markers << { 'name' => 'NOTE', 'comment' => "AUDIO: Track 2 = production audio. Mute Track 1 (scratch). Body section — organic content after scripted beats.", 'time' => 0.0, 'color' => 'yellow' }
  markers << { 'name' => 'TITLE', 'comment' => "Title: '#{short_def ? short_def['title'] : "Short #{padded}"}' — body content.", 'time' => 0.0, 'color' => 'blue' }
  markers << { 'name' => 'MUSIC', 'comment' => 'Music cue: START — low background underscore. Fade in 1s.', 'time' => 0.0, 'color' => 'red' }
  markers << { 'name' => 'MUSIC', 'comment' => 'Music cue: RESOLVE — fade out 2s.', 'time' => total_dur.round(2), 'color' => 'red' }

  # Build YAML config
  yaml_data = {
    'video_path' => candidate[:video_path],
    'output_dir' => OUTPUT_DIR,
    'editor' => 'fcp7',
    'name' => "Short #{padded} Body",
    'breathing_room_frames' => 3,
    'auto_remove_pauses_above' => 500,
    'clips' => clips,
    'markers' => markers
  }

  if video_info && video_info['sync_audio']
    yaml_data['sync_audio'] = video_info['sync_audio']
  end

  if video_info && video_info['speech_analysis']
    yaml_data['speech_analysis'] = File.join(TRANSCRIPTS_DIR, video_info['speech_analysis'])
  end

  yaml_path = File.join(OUTPUT_DIR, "Short_#{padded}_body.yaml")
  File.write(yaml_path, yaml_data.to_yaml)
  $stderr.puts "  YAML: #{yaml_path}"

  # Build XML via build_structure_cut.rb
  build_output = `ruby #{Shellwords.escape(BUILD_SCRIPT)} #{Shellwords.escape(yaml_path)} 2>&1`
  raw_xml_path = build_output.strip.split("\n").last

  if raw_xml_path && File.exist?(raw_xml_path)
    final_xml = File.join(OUTPUT_DIR, "Short#{padded}body.xml")
    FileUtils.mv(raw_xml_path, final_xml)
    $stderr.puts "  XML: #{final_xml}"

    generated << {
      short_num: num,
      title: short_def ? short_def['title'] : "Short #{padded}",
      video: candidate[:video_basename],
      clips: clips.length,
      duration: total_dur.round(1),
      score: candidate[:score][:composite],
      xml: final_xml
    }
  else
    $stderr.puts "  ERROR: build_structure_cut.rb failed for Short #{padded}"
    $stderr.puts "  Output: #{build_output[0..200]}"
  end

  # Write arrangement log
  arr_log = {
    'arrangement_log' => {
      'structure_cut' => "Short_#{padded}_body.yaml",
      'timestamp' => Time.now.strftime('%Y-%m-%dT%H:%M:%S'),
      'branch' => 'B_body',
      'short_number' => num,
      'short_title' => short_def ? short_def['title'] : nil,
      'video' => candidate[:video_basename],
      'group' => candidate[:group_name],
      'scoring' => candidate[:score],
      'candidate_segments' => candidate[:segments].length,
      'candidate_duration' => candidate[:duration],
      'distillation' => candidate[:distillation],
      'metrics' => {
        'total_clips' => clips.length,
        'output_duration' => total_dur.round(1)
      }
    }
  }

  if overlap_resolutions.any? { |r| r[:short_num] == num }
    resolution = overlap_resolutions.find { |r| r[:short_num] == num }
    arr_log['arrangement_log']['overlap_resolution'] = {
      'winner' => resolution[:winner_group],
      'loser' => resolution[:loser_group],
      'winner_score' => resolution[:winner_score],
      'loser_score' => resolution[:loser_score],
      'reasoning' => resolution[:reasoning]
    }
  end

  arr_path = File.join(OUTPUT_DIR, "arrangement_log_short_#{padded}_body.yaml")
  File.write(arr_path, arr_log.to_yaml)
end

# === PHASE 6: Summary report ===

$stderr.puts "\n\n=========================================="
$stderr.puts "SHORT BODIES BATCH REPORT"
$stderr.puts "=========================================="
$stderr.puts ""
$stderr.puts "%-5s %-45s %-15s %6s %8s %6s" % ['#', 'Title', 'Video', 'Clips', 'Output', 'Score']
$stderr.puts '-' * 90

generated.each do |r|
  $stderr.puts "%-5s %-45s %-15s %6d %7.1fs %5.3f" % [
    "##{r[:short_num]}", r[:title][0..44], r[:video][0..14], r[:clips], r[:duration], r[:score]
  ]
end

$stderr.puts '-' * 90
if generated.any?
  total_clips = generated.sum { |r| r[:clips] }
  total_output = generated.sum { |r| r[:duration] }
  avg_score = generated.sum { |r| r[:score] } / generated.length
  $stderr.puts "%-5s %-45s %-15s %6d %7.1fs %5.3f" % [
    'TOT', "#{generated.length} shorts", '', total_clips, total_output, avg_score
  ]
end

$stderr.puts ""
$stderr.puts "All outputs in: #{OUTPUT_DIR}"

if overlap_resolutions.any?
  $stderr.puts "\nOverlap resolutions:"
  overlap_resolutions.each do |r|
    $stderr.puts "  Short #{r[:short_num]}: #{r[:winner_group]} won (#{r[:reasoning]})"
  end
end
