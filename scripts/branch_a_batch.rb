#!/usr/bin/env ruby
# branch_a_batch.rb — Batch Branch A (script-driven) processing for Dylan Shorts Batch 1
#
# Algorithm: Sequential forward-only hook discovery across ordered video transcripts.
# 1. Build unified timeline from all video transcripts in library order
# 2. Pass 1: Find all 30 hooks sequentially (forward-only, sliding window word overlap)
# 3. Scope = hook[i] to hook[i+1] (no fixed window, no global search)
# 4. Per short: hook → all body content between hook and close → close
#
# Usage: ruby scripts/branch_a_batch.rb [short_numbers...]
#   No args = process all shorts 1-30
#   Args = process specific shorts, e.g.: ruby scripts/branch_a_batch.rb 2 3 4

require 'yaml'
require 'json'
require 'shellwords'
require 'fileutils'
require 'digest'
require 'date'

LIBRARY_DIR = File.expand_path('libraries/dylan-shorts-batch-1', __dir__.sub('/scripts', ''))
PROJECT_DIR = '/Users/i4d/Desktop/RAW/Dylan Shorts Batch 1'
OUTPUT_DIR = File.join(PROJECT_DIR, 'output')
TRANSCRIPTS_DIR = File.join(LIBRARY_DIR, 'transcripts')
BUILD_SCRIPT = File.expand_path('scripts/build_structure_cut.rb', __dir__.sub('/scripts', ''))

# --- Helpers ---

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
  return 0 if words.group_by { |w| w.downcase }.any? { |w, occ| occ.length >= 4 && w.length > 2 }
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

def classify_beat(role, text)
  t = text.to_s.downcase
  case role
  when 'hook'
    if t =~ /\?|question|ever been told|did you/
      { states: %w[curiosity belonging], signal: 'Question hook — engages viewer directly' }
    elsif t =~ /number|amount|\$|percent|money|paid|charge/
      { states: %w[curiosity aspiration], signal: 'Financial hook — specific number creates intrigue' }
    elsif t =~ /scam|wrong|embarrass|disaster|bad|worst/
      { states: %w[curiosity fear], signal: 'Vulnerability hook — admission creates trust' }
    else
      { states: %w[curiosity vindication], signal: 'Revelation hook — reframes viewer expectation' }
    end
  when 'close'
    if t =~ /same|once you|that\'s/
      { states: %w[vindication competence], signal: 'Reframe close — callbacks to hook' }
    elsif t =~ /don\'t need|you need|just/
      { states: %w[competence aspiration], signal: 'Prescription close — actionable takeaway' }
    else
      { states: %w[vindication fear], signal: 'Mic drop close — leaves emotional residue' }
    end
  when 'talking_point'
    if t =~ /feel|felt|emotion|awkward|embarrass/
      { states: %w[belonging fear], signal: 'Vulnerability TP — personal admission' }
    elsif t =~ /number|amount|\$|paid|charge|cost|money|revenue/
      { states: %w[competence aspiration], signal: 'Financial TP — specific proof' }
    elsif t =~ /how|what|when|why/
      { states: %w[curiosity competence], signal: 'Diagnostic TP — names the pattern' }
    else
      { states: %w[competence belonging], signal: 'Story TP — narrative building' }
    end
  else
    { states: %w[competence], signal: 'General content' }
  end
end

# --- Load data ---

$stderr.puts "Loading script and library..."
script = YAML.load_file(File.join(TRANSCRIPTS_DIR, 'script_parsed.yaml'), permitted_classes: [Date])
library = YAML.load_file(File.join(LIBRARY_DIR, 'library.yaml'), permitted_classes: [Date])

# Build video lookup
video_lookup = {}
library['videos'].each do |v|
  basename = File.basename(v['path'])
  video_lookup[basename] = v
end

# Determine which shorts to process
requested = ARGV.map(&:to_i)
shorts_to_process = if requested.empty?
  (1..30).to_a
else
  requested
end

$stderr.puts "Processing #{shorts_to_process.length} shorts: #{shorts_to_process.join(', ')}"

# Load all cleaned transcripts (cache)
transcript_cache = {}

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

# =============================================================
# PHASE 1: Build unified timeline from all videos in order
# =============================================================

$stderr.puts "\n--- Building unified timeline ---"
unified = []
library['videos'].each do |v|
  basename = File.basename(v['path'])
  transcript = load_transcript(basename, TRANSCRIPTS_DIR, transcript_cache)
  unless transcript
    $stderr.puts "  SKIP: #{basename} — no transcript"
    next
  end
  seg_count = transcript['segments'].length
  transcript['segments'].each do |seg|
    unified << seg.merge(
      '_video_path' => v['path'],
      '_video_basename' => basename,
      '_video_info' => v
    )
  end
  $stderr.puts "  #{basename}: #{seg_count} segments (ends at #{fmt(transcript['segments'].last['end'])})"
end
$stderr.puts "Unified timeline: #{unified.length} segments across #{library['videos'].length} videos"

# =============================================================
# PHASE 2: Find ALL hook positions sequentially (forward-only)
# =============================================================

$stderr.puts "\n--- Pass 1: Finding all hooks (forward-only) ---"
all_shorts = script['shorts'].sort_by { |s| s['number'] }
hook_positions = {}
cursor = 0

all_shorts.each do |short_def|
  num = short_def['number']
  hook_beat = short_def['beats'].find { |b| b['role'] == 'hook' }
  close_beat = short_def['beats'].find { |b| b['role'] == 'close' }
  next unless hook_beat
  hook_text = hook_beat['text']

  # Search forward from cursor with generous window (don't search backward)
  search_end = [cursor + 400, unified.length].min

  best_score = 0
  best_start = nil
  best_size = 1

  (cursor...search_end).each do |i|
    # Try sliding windows of 1-8 segments (hooks can span multiple sentences)
    max_win = [8, unified.length - i].min
    (1..max_win).each do |w|
      # Only combine segments from the same video
      break if unified[i + w - 1]['_video_path'] != unified[i]['_video_path']
      # Only combine segments that are close together (< 5s gap)
      break if w > 1 && unified[i + w - 1]['start'] - unified[i + w - 2]['end'] > 5

      window_text = unified[i, w].map { |s| s['text'] }.join(' ')
      score = word_overlap(hook_text, window_text)
      if score > best_score
        best_score = score
        best_start = i
        best_size = w
      end
    end
  end

  if best_start && best_score > 0.12
    # Also find the close AFTER the hook to advance cursor past both
    # Start close search from 3 segs after hook START (not after full window,
    # which may have greedily absorbed the close)
    close_cursor = best_start + [best_size, 3].min
    close_search_end = [close_cursor + 15, unified.length].min
    close_found_idx = nil
    close_found_size = 1
    close_found_score = 0

    if close_beat
      (close_cursor...close_search_end).each do |ci|
        break if unified[ci]['_video_path'] != unified[best_start]['_video_path']
        max_cw = [3, unified.length - ci].min
        (1..max_cw).each do |cw|
          break if ci + cw > unified.length
          break if cw > 1 && unified[ci + cw - 1]['start'] - unified[ci + cw - 2]['end'] > 5
          ctext = unified[ci, cw].map { |s| s['text'] }.join(' ')
          cscore = word_overlap(close_beat['text'], ctext)
          if cscore > close_found_score
            close_found_score = cscore
            close_found_idx = ci
            close_found_size = cw
          end
        end
      end
    end

    hook_positions[num] = {
      start_idx: best_start, size: best_size, score: best_score,
      close_idx: close_found_idx, close_size: close_found_size, close_score: close_found_score
    }

    # Advance cursor past CLOSE (not just hook) to prevent next short from absorbing it
    if close_found_idx && close_found_score > 0.12
      cursor = close_found_idx + close_found_size
      vname = File.basename(unified[best_start]['_video_path'])
      $stderr.puts "  #{'%2d' % num}: hook at #{fmt(unified[best_start]['start'])} close at #{fmt(unified[close_found_idx]['start'])} in #{vname} (h:#{best_score.round(3)}/#{best_size}s c:#{close_found_score.round(3)}/#{close_found_size}s)"
    else
      # No close found — advance past hook + skip margin
      cursor = best_start + best_size + 2
      vname = File.basename(unified[best_start]['_video_path'])
      $stderr.puts "  #{'%2d' % num}: hook at #{fmt(unified[best_start]['start'])} in #{vname} (h:#{best_score.round(3)}/#{best_size}s, no close)"
    end
  else
    $stderr.puts "  #{'%2d' % num}: HOOK NOT FOUND (best: #{(best_score || 0).round(3)}) — cursor at #{cursor}"
  end
end

found = hook_positions.keys.length
$stderr.puts "Found #{found}/#{all_shorts.length} hooks"

# =============================================================
# PHASE 3: Process each requested short
# =============================================================

results = []
shorts_to_process.each do |num|
  short_def = script['shorts'].find { |s| s['number'] == num }
  unless short_def
    $stderr.puts "\nShort ##{num}: not found in script_parsed.yaml, skipping"
    next
  end

  hook_pos = hook_positions[num]
  unless hook_pos
    $stderr.puts "\nShort ##{num}: no hook found, skipping"
    next
  end

  padded = '%02d' % num
  $stderr.puts "\n=== Short ##{padded}: #{short_def['title']} ==="

  # --- Determine scope ---
  hook_start_idx = hook_pos[:start_idx]
  hook_end_idx = hook_start_idx + hook_pos[:size] - 1

  # Scope ends at the next short's hook start (or end of timeline)
  scope_end_idx = unified.length - 1
  next_nums = all_shorts.select { |s| s['number'] > num }.map { |s| s['number'] }.sort
  next_nums.each do |nn|
    if hook_positions[nn]
      scope_end_idx = hook_positions[nn][:start_idx] - 1
      break
    end
  end

  # Constrain scope to same video as hook
  hook_video = unified[hook_start_idx]['_video_path']
  scope_segments = unified[hook_start_idx..scope_end_idx].select { |s| s['_video_path'] == hook_video }

  video_path = hook_video
  video_basename = unified[hook_start_idx]['_video_basename']
  video_info = unified[hook_start_idx]['_video_info']

  $stderr.puts "  Video: #{video_basename}"
  $stderr.puts "  Scope: #{fmt(scope_segments.first['start'])}-#{fmt(scope_segments.last['end'])} (#{scope_segments.length} segs)"

  beats = short_def['beats']
  hook_beat = beats.find { |b| b['role'] == 'hook' }
  close_beat = beats.find { |b| b['role'] == 'close' }
  tp_beats = beats.select { |b| b['role'] == 'talking_point' }

  # --- Use close position from Pass 1 if available ---
  p1_close_idx = hook_pos[:close_idx]
  p1_close_size = hook_pos[:close_size] || 1
  p1_close_score = hook_pos[:close_score] || 0

  if p1_close_idx && p1_close_score > 0.12
    # Use the close found in Pass 1 — find it within scope_segments
    p1_close_time = unified[p1_close_idx]['start']
    close_si = scope_segments.index { |s| (s['start'] - p1_close_time).abs < 0.5 }

    if close_si
      close_segments = scope_segments[close_si, [p1_close_size, scope_segments.length - close_si].min]
      hook_segments = close_si > 0 ? scope_segments[0...close_si] : [scope_segments.first]
      best_close_score = p1_close_score
    end
  end

  # If Pass 1 didn't provide a close, search within scope
  unless defined?(close_segments) && close_segments
    search_zone = scope_segments.select { |s| s['start'] - scope_segments.first['start'] < 120 }
    search_zone = scope_segments[0..[5, scope_segments.length - 1].min] if search_zone.length < 3

    best_close_score = 0
    best_close_si = nil
    best_close_size = 1
    min_close_start = [2, search_zone.length - 1].min

    (min_close_start...search_zone.length).each do |si|
      max_win = [3, search_zone.length - si].min
      (1..max_win).each do |w|
        break if w > 1 && search_zone[si + w - 1]['start'] - search_zone[si + w - 2]['end'] > 5
        window_text = search_zone[si, w].map { |s| s['text'] }.join(' ')
        score = word_overlap(close_beat['text'], window_text)
        if score > best_close_score || (score == best_close_score && si > (best_close_si || -1))
          best_close_score = score
          best_close_si = si
          best_close_size = w
        end
      end
    end

    if best_close_si && best_close_score > 0.15
      close_segments = search_zone[best_close_si, best_close_size]
      hook_segments = search_zone[0...best_close_si]
    else
      close_segments = [scope_segments.last]
      hook_segments = scope_segments.length > 1 ? scope_segments[0..-2] : scope_segments[0..0]
      best_close_score = 0.0
    end
  end

  # Ensure hook has at least 1 segment
  hook_segments = [scope_segments.first] if hook_segments.empty?

  # Body = segments strictly BETWEEN hook end and close start (not after close)
  hook_end_t = hook_segments.last['end']
  close_start_t = close_segments.first['start']
  hook_ids = hook_segments.map(&:object_id)
  close_ids = close_segments.map(&:object_id)
  body_segments = scope_segments.select do |s|
    s['start'] >= hook_end_t - 0.1 &&
      s['end'] <= close_start_t + 0.1 &&
      !hook_ids.include?(s.object_id) &&
      !close_ids.include?(s.object_id)
  end
  body_segments = body_segments.select { |s| segment_quality(s) > 0 }
  body_segments.sort_by! { |s| s['start'] }

  body_dur = body_segments.any? ? body_segments.sum { |s| s['end'] - s['start'] } : 0

  $stderr.puts "  Hook: #{hook_segments.length} segs, #{fmt(hook_segments.first['start'])}-#{fmt(hook_segments.last['end'])}"
  $stderr.puts "  Close: #{close_segments.length} segs, #{fmt(close_segments.first['start'])}-#{fmt(close_segments.last['end'])} (score: #{best_close_score.round(3)})"
  $stderr.puts "  Body: #{body_segments.length} segs, #{body_dur.round(1)}s" if body_segments.any?

  # --- Assemble clips in beat order: Hook → Body → Close ---
  all_clip_groups = []

  # Hook
  hook_clips = merge_continuous_clips(hook_segments)
  all_clip_groups << { role: 'hook', clips: hook_clips, beat_text: hook_beat['text'] }

  # Body (all content between hook and close, in recording order)
  if body_segments.any?
    body_clips = merge_continuous_clips(body_segments)
    all_clip_groups << { role: 'talking_point', clips: body_clips, beat_text: tp_beats.map { |tp| tp['text'] }.join(' | ') }
  end

  # Close
  close_clips = merge_continuous_clips(close_segments)
  all_clip_groups << { role: 'close', clips: close_clips, beat_text: close_beat['text'] }

  # Flatten to clip list
  clips = []
  beat_boundaries = []
  timeline_pos = 0.0

  all_clip_groups.each_with_index do |group, gi|
    beat_boundaries << { time: timeline_pos, role: group[:role], index: gi }
    group[:clips].each do |clip|
      clips << clip
      timeline_pos += clip['video_end'] - clip['video_start']
    end
  end

  total_duration = clips.sum { |c| c['video_end'] - c['video_start'] }
  scope_duration = scope_segments.last['end'] - scope_segments.first['start']
  total_clips = clips.length

  $stderr.puts "  Result: #{total_clips} clips, #{total_duration.round(1)}s output from #{scope_duration.round(1)}s scope"

  # --- Generate markers ---
  markers = []
  markers << { 'name' => 'NOTE', 'comment' => "AUDIO: Track 2 = production audio. Mute Track 1 (scratch). Branch A arrangement — script beat order.", 'time' => 0.0, 'color' => 'yellow' }
  markers << { 'name' => 'TITLE', 'comment' => "Title: '#{short_def['title']}' — display for 3 seconds.", 'time' => 0.0, 'color' => 'blue' }
  markers << { 'name' => 'MUSIC', 'comment' => 'Music cue: START — low background underscore. Fade in 1s.', 'time' => 0.0, 'color' => 'red' }

  beat_boundaries.each_with_index do |bb, bi|
    next if bi == 0
    prev = beat_boundaries[bi - 1]
    markers << {
      'name' => 'TRANSITION',
      'comment' => "#{prev[:role].gsub('_', ' ').capitalize} → #{bb[:role].gsub('_', ' ').capitalize}. Jump cut.",
      'time' => bb[:time].round(2),
      'color' => 'orange'
    }
  end

  close_boundary = beat_boundaries.find { |b| b[:role] == 'close' }
  if close_boundary
    markers << { 'name' => 'MUSIC', 'comment' => 'Music cue: RESOLVE — sting on close. Hard stop.', 'time' => close_boundary[:time].round(2), 'color' => 'red' }
  end

  # --- Write YAML ---
  yaml_data = {
    'video_path' => video_path,
    'output_dir' => OUTPUT_DIR,
    'editor' => 'fcp7',
    'name' => "Dylan Shorts #{padded}",
    'breathing_room_frames' => 3
  }

  if video_info && video_info['sync_audio']
    yaml_data['sync_audio'] = video_info['sync_audio']
  end

  if video_info && video_info['speech_analysis']
    yaml_data['speech_analysis'] = File.join(TRANSCRIPTS_DIR, video_info['speech_analysis'])
  end

  yaml_data['auto_remove_pauses_above'] = 500
  yaml_data['clips'] = clips
  yaml_data['markers'] = markers

  yaml_path = File.join(OUTPUT_DIR, "Short_#{padded}_A.yaml")
  File.write(yaml_path, yaml_data.to_yaml)
  $stderr.puts "  YAML: #{yaml_path}"

  # --- Build XML ---
  build_output = `ruby #{Shellwords.escape(BUILD_SCRIPT)} #{Shellwords.escape(yaml_path)} 2>&1`
  xml_path = build_output.strip.split("\n").last
  $stderr.puts "  XML: #{xml_path}"

  # --- Write classification ---
  classification = {
    'framework' => 'content_psychopharmacology',
    'branch' => 'A',
    'scope' => "Short ##{padded} — #{short_def['title']}",
    'segments_used' => []
  }

  all_clip_groups.each do |group|
    cl = classify_beat(group[:role], group[:beat_text])
    group[:clips].each do |clip|
      matching_segs = scope_segments.select { |s| s['start'] >= clip['video_start'] - 0.5 && s['end'] <= clip['video_end'] + 0.5 }
      text = matching_segs.map { |s| s['text'].strip }.join(' ')
      text = text[0..150] if text.length > 150

      classification['segments_used'] << {
        't' => clip['video_start'].round(2),
        'e' => clip['video_end'].round(2),
        'beat' => group[:role],
        'text' => text,
        'states' => cl[:states],
        'signal' => cl[:signal],
        'confidence' => (group[:role] == 'hook' || group[:role] == 'close') ? 'high' : 'medium',
        'rationale' => "#{group[:role].capitalize} beat matched to script. #{cl[:signal]}."
      }
    end
  end

  class_path = File.join(LIBRARY_DIR, "segments_classified_short_#{padded}.yaml")
  File.write(class_path, classification.to_yaml)

  # --- Write arrangement log ---
  beat_log = []
  all_clip_groups.each do |group|
    beat_log << {
      'beat' => group[:role],
      'script_text' => group[:beat_text][0..100],
      'matched_clips' => group[:clips].map { |c| "#{c['video_start'].round(2)}-#{c['video_end'].round(2)}" },
      'match_type' => (group[:role] == 'hook' || group[:role] == 'close') ? 'near_verbatim' : 'all_body_content',
      'confidence' => (group[:role] == 'hook' || group[:role] == 'close') ? 'high' : 'medium'
    }
  end

  arr_log = {
    'arrangement_log' => {
      'structure_cut' => "Short_#{padded}_A.yaml",
      'timestamp' => Time.now.strftime('%Y-%m-%dT%H:%M:%S'),
      'branch' => 'A',
      'short_number' => num,
      'short_title' => short_def['title'],
      'section' => short_def['section'],
      'video' => video_basename,
      'hook_score' => hook_pos[:score].round(3),
      'close_score' => best_close_score.round(3),
      'beat_matching' => beat_log,
      'script_fidelity' => {
        'hook_found' => hook_pos[:score] > 0.12,
        'close_found' => best_close_score > 0.12,
        'body_segments' => body_segments.length,
        'body_duration' => body_dur.round(1)
      },
      'metrics' => {
        'total_clips' => total_clips,
        'output_duration' => total_duration.round(1),
        'scope_duration' => scope_duration.round(1),
        'reduction' => "#{((1 - total_duration / [scope_duration, 0.1].max) * 100).round}%"
      }
    }
  }

  arr_path = File.join(OUTPUT_DIR, "arrangement_log_short_#{padded}_A.yaml")
  File.write(arr_path, arr_log.to_yaml)

  # Collect results for summary
  results << {
    number: num,
    title: short_def['title'],
    section: short_def['section'],
    video: video_basename,
    clips: total_clips,
    output_duration: total_duration.round(1),
    scope_duration: scope_duration.round(1),
    hook_score: hook_pos[:score].round(3),
    close_score: best_close_score.round(3),
    xml: xml_path
  }
end

# --- Summary report ---
$stderr.puts "\n\n=========================================="
$stderr.puts "BRANCH A BATCH REPORT"
$stderr.puts "=========================================="
$stderr.puts ""
$stderr.puts "%-5s %-45s %-20s %6s %8s %6s %6s" % ['#', 'Title', 'Video', 'Clips', 'Output', 'Hook', 'Close']
$stderr.puts '-' * 100

results.each do |r|
  $stderr.puts "%-5s %-45s %-20s %6d %7.1fs %5.2f %5.2f" % [
    "##{r[:number]}", r[:title][0..44], r[:video][0..19], r[:clips], r[:output_duration],
    r[:hook_score], r[:close_score]
  ]
end

$stderr.puts '-' * 100
total_clips = results.sum { |r| r[:clips] }
total_output = results.sum { |r| r[:output_duration] }
avg_hook = results.sum { |r| r[:hook_score] } / results.length
avg_close = results.sum { |r| r[:close_score] } / results.length
$stderr.puts "%-5s %-45s %-20s %6d %7.1fs %5.2f %5.2f" % [
  'TOT', "#{results.length} shorts", '', total_clips, total_output, avg_hook, avg_close
]
$stderr.puts ""
$stderr.puts "All outputs in: #{OUTPUT_DIR}"
