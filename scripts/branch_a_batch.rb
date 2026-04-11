#!/usr/bin/env ruby
# branch_a_batch.rb — Batch Branch A (script-driven) processing for Dylan Shorts Batch 1
#
# Usage: ruby scripts/branch_a_batch.rb [short_numbers...]
#   No args = process all shorts 2-27 (skip 1, already done)
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

def word_overlap(text_a, text_b)
  return 0.0 if text_a.nil? || text_b.nil? || text_a.empty? || text_b.empty?
  words_a = text_a.downcase.gsub(/[^a-z0-9\s]/, '').split.reject { |w| w.length < 3 }
  words_b = text_b.downcase.gsub(/[^a-z0-9\s]/, '').split.reject { |w| w.length < 3 }
  return 0.0 if words_a.empty? || words_b.empty?
  intersection = (words_a & words_b).length
  intersection.to_f / [words_a.length, words_b.length].min
end

def segment_quality(seg)
  text = seg['text'].to_s.strip
  return 0 if text.length < 10
  return 0 if text =~ /^(okay|ok|yeah|so|um|uh|hmm|right)[.,]?\s*$/i
  words = text.scan(/\b(\w+)\b/).flatten
  return 0 if words.group_by { |w| w.downcase }.any? { |w, occ| occ.length >= 4 && w.length > 2 }
  # Penalize trailing-off (ends without punctuation and is short)
  penalty = (text[-1] !~ /[.!?"]/ && text.length < 40) ? 0.5 : 1.0
  # Penalize restarts ("the thing is that that")
  penalty *= 0.7 if text =~ /\b(\w{3,})\s+\1\b/i
  dur = seg['end'] - seg['start']
  # Prefer segments 3-15 seconds
  dur_score = dur >= 3 && dur <= 15 ? 1.0 : (dur > 15 ? 0.7 : 0.3)
  penalty * dur_score
end

def pick_best_segments(segments, target_duration, max_segments: 5)
  return [] if segments.empty?

  # Score and sort by quality
  scored = segments.map { |s| [s, segment_quality(s)] }.reject { |_, q| q <= 0 }
  return [] if scored.empty?

  # Sort by start time to maintain chronological order within the beat
  scored.sort_by! { |s, _| s['start'] }

  selected = []
  total_dur = 0

  scored.each do |seg, quality|
    break if total_dur >= target_duration
    break if selected.length >= max_segments
    dur = seg['end'] - seg['start']
    # Skip if it would overshoot by more than 50%
    next if total_dur > 0 && total_dur + dur > target_duration * 1.5
    selected << seg
    total_dur += dur
  end

  # If we're way under target, add more segments sorted by quality
  if total_dur < target_duration * 0.5 && scored.length > selected.length
    remaining = scored.reject { |s, _| selected.include?(s) }.sort_by { |_, q| -q }
    remaining.each do |seg, _|
      break if total_dur >= target_duration
      dur = seg['end'] - seg['start']
      selected << seg
      total_dur += dur
    end
    selected.sort_by! { |s| s['start'] }
  end

  selected
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
      clips << { 'start' => current_start, 'end' => current_end }
      current_start = seg['start']
      current_end = seg['end']
    end
  end
  clips << { 'start' => current_start, 'end' => current_end }
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
  (2..27).to_a
else
  requested
end

$stderr.puts "Processing #{shorts_to_process.length} shorts: #{shorts_to_process.join(', ')}"

# Load all cleaned transcripts (cache)
transcript_cache = {}

def load_transcript(video_basename, transcripts_dir, cache)
  return cache[video_basename] if cache[video_basename]

  # Find cleaned version first — handle spaces vs underscores
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

# --- Process each short ---

results = []
shorts_to_process.each do |num|
  short_def = script['shorts'].find { |s| s['number'] == num }
  unless short_def
    $stderr.puts "Short ##{num}: not found in script_parsed.yaml, skipping"
    next
  end

  padded = '%02d' % num
  $stderr.puts "\n=== Short ##{padded}: #{short_def['title']} ==="

  # Load existing fast mode YAML for scope reference
  fast_path = File.join(OUTPUT_DIR, "Short_#{padded}.yaml")
  unless File.exist?(fast_path)
    $stderr.puts "  WARNING: No fast mode YAML at #{fast_path}, skipping"
    next
  end
  fast_yaml = YAML.load_file(fast_path)
  video_path = fast_yaml['video_path']
  video_basename = File.basename(video_path)
  video_info = video_lookup[video_basename]

  # Load transcript
  transcript = load_transcript(video_basename, TRANSCRIPTS_DIR, transcript_cache)
  unless transcript
    $stderr.puts "  SKIP: no transcript"
    next
  end
  all_segments = transcript['segments']

  # Get scope from fast mode clips
  fast_clips = fast_yaml['clips']
  scope_start = fast_clips.first['start']
  scope_end = fast_clips.last['end']

  # Get segments in scope
  scope_segments = all_segments.select { |s| s['start'] >= scope_start - 1 && s['end'] <= scope_end + 1 }
  $stderr.puts "  Scope: #{fmt(scope_start)}-#{fmt(scope_end)} (#{scope_segments.length} segments)"

  beats = short_def['beats']
  hook_beat = beats.find { |b| b['role'] == 'hook' }
  close_beat = beats.find { |b| b['role'] == 'close' }
  tp_beats = beats.select { |b| b['role'] == 'talking_point' }

  # --- Match HOOK ---
  hook_candidates = scope_segments.select { |s| word_overlap(hook_beat['text'], s['text']) > 0.25 }
  if hook_candidates.empty?
    # Fall back to first few segments in scope
    hook_candidates = scope_segments.first(5)
  end
  # Sort by overlap score and take the cluster
  hook_candidates.sort_by! { |s| -word_overlap(hook_beat['text'], s['text']) }
  best_hook_start = hook_candidates.first['start']

  # Find all segments near the best hook that form a continuous cluster
  hook_segments = scope_segments.select { |s|
    s['start'] >= best_hook_start - 0.5 &&
    s['start'] < best_hook_start + 30 &&
    (word_overlap(hook_beat['text'], s['text']) > 0.15 || s['start'] - best_hook_start < 2)
  }
  # Trim to just the hook content — stop at first segment with no overlap that's > 3s after start
  trimmed_hook = [hook_segments.first]
  hook_segments[1..].each do |seg|
    break if seg['start'] - trimmed_hook.last['end'] > 3
    overlap = word_overlap(hook_beat['text'], seg['text'])
    # Keep if it overlaps with hook text OR is a natural continuation (< 1s gap)
    if overlap > 0.1 || seg['start'] - trimmed_hook.last['end'] < 1.5
      trimmed_hook << seg
    else
      break
    end
  end
  hook_segments = trimmed_hook

  $stderr.puts "  Hook: #{hook_segments.length} segments, #{fmt(hook_segments.first['start'])}-#{fmt(hook_segments.last['end'])}"

  # --- Match CLOSE ---
  close_candidates = scope_segments.select { |s| word_overlap(close_beat['text'], s['text']) > 0.3 }
  if close_candidates.empty?
    close_candidates = scope_segments.select { |s| word_overlap(close_beat['text'], s['text']) > 0.15 }
  end
  if close_candidates.empty?
    # Fall back to segments near the hook (close often recorded right after hook)
    hook_end = hook_segments.last['end']
    close_candidates = scope_segments.select { |s| s['start'] > hook_end && s['start'] < hook_end + 30 }
  end

  # Prefer the best overlap
  close_candidates.sort_by! { |s| -word_overlap(close_beat['text'], s['text']) }
  close_segments = close_candidates.empty? ? [] : [close_candidates.first]

  # If close is multi-sentence, grab adjacent segments
  if close_segments.any? && word_overlap(close_beat['text'], close_segments.first['text']) < 0.6
    close_start = close_segments.first['start']
    nearby = scope_segments.select { |s|
      s['start'] >= close_start - 1 && s['end'] <= close_start + 15 &&
      !hook_segments.include?(s) && word_overlap(close_beat['text'], s['text']) > 0.1
    }
    close_segments = nearby.sort_by { |s| s['start'] } if nearby.length > close_segments.length
  end

  if close_segments.any?
    $stderr.puts "  Close: #{close_segments.length} segments, #{fmt(close_segments.first['start'])}-#{fmt(close_segments.last['end'])}"
  else
    $stderr.puts "  Close: NOT FOUND — will use last segment in scope"
    close_segments = [scope_segments.last]
  end

  # --- Match TALKING POINTS ---
  # Identify TP range: segments not in hook or close
  hook_times = hook_segments.map { |s| s['start'] }
  close_times = close_segments.map { |s| s['start'] }
  tp_pool = scope_segments.reject { |s| hook_times.include?(s['start']) || close_times.include?(s['start']) }

  # Filter out low-quality segments
  tp_pool = tp_pool.select { |s| segment_quality(s) > 0 }

  $stderr.puts "  TP pool: #{tp_pool.length} segments"

  # Target duration per TP
  total_hook_dur = hook_segments.sum { |s| s['end'] - s['start'] }
  total_close_dur = close_segments.sum { |s| s['end'] - s['start'] }
  target_total = 55.0  # target short duration
  tp_budget = [target_total - total_hook_dur - total_close_dur, tp_beats.length * 4].max
  tp_target = tp_budget / tp_beats.length

  # Strategy: divide TP pool into N regions by position, assign to TPs in order
  # But also try keyword matching for each TP
  tp_matched = []

  if tp_pool.any?
    # Split pool into roughly equal chunks by index
    chunk_size = (tp_pool.length.to_f / tp_beats.length).ceil
    chunks = tp_pool.each_slice([chunk_size, 1].max).to_a

    tp_beats.each_with_index do |tp, i|
      chunk = chunks[i] || chunks.last || []

      # Also check if any segment in the ENTIRE pool has strong keyword match
      tp_keywords = tp['text'].downcase.gsub(/[^a-z0-9\s]/, '').split.reject { |w| w.length < 4 }
      keyword_matches = tp_pool.select { |s|
        seg_words = s['text'].downcase.split
        tp_keywords.any? { |kw| seg_words.any? { |sw| sw.include?(kw) } }
      }

      # Use keyword matches if they're in this chunk's neighborhood, else use positional chunk
      candidates = if keyword_matches.any? && chunk.any?
        # Prefer keyword matches that are near the positional chunk
        chunk_mid = chunk[chunk.length / 2]['start']
        nearby_kw = keyword_matches.select { |s| (s['start'] - chunk_mid).abs < 120 }
        nearby_kw.any? ? (chunk + nearby_kw).uniq.sort_by { |s| s['start'] } : chunk
      else
        chunk
      end

      selected = pick_best_segments(candidates, tp_target)
      tp_matched << {
        beat: tp,
        segments: selected,
        beat_index: i
      }
    end
  else
    tp_beats.each_with_index do |tp, i|
      tp_matched << { beat: tp, segments: [], beat_index: i }
    end
  end

  # Log TP matches
  tp_matched.each do |tm|
    segs = tm[:segments]
    if segs.any?
      dur = segs.sum { |s| s['end'] - s['start'] }
      $stderr.puts "  TP#{tm[:beat_index] + 1}: #{segs.length} segs, #{dur.round(1)}s — #{segs.first['text'][0..60]}..."
    else
      $stderr.puts "  TP#{tm[:beat_index] + 1}: NO MATCH"
    end
  end

  # --- Assemble clips in beat order ---
  all_clip_groups = []

  # Hook
  hook_clips = merge_continuous_clips(hook_segments)
  all_clip_groups << { role: 'hook', clips: hook_clips, beat_text: hook_beat['text'] }

  # TPs in script order
  tp_matched.each do |tm|
    next if tm[:segments].empty?
    tp_clips = merge_continuous_clips(tm[:segments])
    all_clip_groups << { role: 'talking_point', clips: tp_clips, beat_text: tm[:beat]['text'], beat_index: tm[:beat_index] }
  end

  # Close
  close_clips = merge_continuous_clips(close_segments)
  all_clip_groups << { role: 'close', clips: close_clips, beat_text: close_beat['text'] }

  # Flatten to clip list
  clips = []
  beat_boundaries = [] # timeline positions where beats change
  timeline_pos = 0.0

  all_clip_groups.each_with_index do |group, gi|
    beat_boundaries << { time: timeline_pos, role: group[:role], index: gi }
    group[:clips].each do |clip|
      clips << clip
      timeline_pos += clip['end'] - clip['start']
    end
  end

  total_duration = clips.sum { |c| c['end'] - c['start'] }
  source_material = scope_end - scope_start
  total_clips = clips.length

  $stderr.puts "  Result: #{total_clips} clips, #{total_duration.round(1)}s output from #{source_material.round(1)}s source"

  # --- Generate markers ---
  markers = []
  markers << { 'name' => 'NOTE', 'comment' => "AUDIO: Track 2 = production audio. Mute Track 1 (scratch). Branch A arrangement — script beat order.", 'time' => 0.0, 'color' => 'yellow' }
  markers << { 'name' => 'TITLE', 'comment' => "Title: '#{short_def['title']}' — display for 3 seconds.", 'time' => 0.0, 'color' => 'blue' }
  markers << { 'name' => 'MUSIC', 'comment' => 'Music cue: START — low background underscore. Fade in 1s.', 'time' => 0.0, 'color' => 'red' }

  beat_boundaries.each_with_index do |bb, bi|
    next if bi == 0 # skip first (hook start = timeline 0)
    prev = beat_boundaries[bi - 1]
    markers << {
      'name' => 'TRANSITION',
      'comment' => "#{prev[:role].gsub('_', ' ').capitalize} → #{bb[:role].gsub('_', ' ').capitalize}. Jump cut.",
      'time' => bb[:time].round(2),
      'color' => 'orange'
    }
  end

  # Music close marker
  close_boundary = beat_boundaries.find { |b| b[:role] == 'close' }
  if close_boundary
    markers << { 'name' => 'MUSIC', 'comment' => 'Music cue: RESOLVE — sting on close. Hard stop.', 'time' => close_boundary[:time].round(2), 'color' => 'red' }
  end

  # --- Write YAML ---
  yaml_data = {
    'video_path' => video_path,
    'output_dir' => OUTPUT_DIR,
    'editor' => 'fcp7',
    'name' => "Short_#{padded}_A",
    'breathing_room_frames' => 3
  }

  if fast_yaml['sync_audio']
    yaml_data['sync_audio'] = fast_yaml['sync_audio']
  end

  if fast_yaml['speech_analysis']
    yaml_data['speech_analysis'] = fast_yaml['speech_analysis']
  elsif video_info && video_info['speech_analysis']
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
      # Find the original transcript text for this clip range
      matching_segs = scope_segments.select { |s| s['start'] >= clip['start'] - 0.5 && s['end'] <= clip['end'] + 0.5 }
      text = matching_segs.map { |s| s['text'].strip }.join(' ')
      text = text[0..150] if text.length > 150

      classification['segments_used'] << {
        't' => clip['start'].round(2),
        'e' => clip['end'].round(2),
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
      'matched_clips' => group[:clips].map { |c| "#{c['start'].round(2)}-#{c['end'].round(2)}" },
      'match_type' => (group[:role] == 'hook' || group[:role] == 'close') ? 'near_verbatim' : 'thematic',
      'confidence' => (group[:role] == 'hook' || group[:role] == 'close') ? 'high' : 'medium'
    }
  end

  unmatched = tp_matched.select { |tm| tm[:segments].empty? }.map { |tm| tm[:beat]['text'][0..80] }

  arr_log = {
    'arrangement_log' => {
      'structure_cut' => "Short_#{padded}_A.yaml",
      'timestamp' => Time.now.strftime('%Y-%m-%dT%H:%M:%S'),
      'branch' => 'A',
      'short_number' => num,
      'short_title' => short_def['title'],
      'section' => short_def['section'],
      'beat_matching' => beat_log,
      'script_fidelity' => {
        'total_beats' => beats.length,
        'matched_beats' => beats.length - unmatched.length,
        'coverage' => "#{((beats.length - unmatched.length).to_f / beats.length * 100).round}%",
        'unmatched_beats' => unmatched
      },
      'metrics' => {
        'total_clips' => total_clips,
        'output_duration' => total_duration.round(1),
        'source_material' => source_material.round(1),
        'reduction' => "#{((1 - total_duration / source_material) * 100).round}%"
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
    clips: total_clips,
    output_duration: total_duration.round(1),
    source_material: source_material.round(1),
    reduction: ((1 - total_duration / source_material) * 100).round,
    beats_total: beats.length,
    beats_matched: beats.length - unmatched.length,
    fidelity: "#{((beats.length - unmatched.length).to_f / beats.length * 100).round}%",
    xml: xml_path
  }
end

# --- Summary report ---
$stderr.puts "\n\n=========================================="
$stderr.puts "BRANCH A BATCH REPORT"
$stderr.puts "=========================================="
$stderr.puts ""
$stderr.puts "%-5s %-50s %6s %8s %8s %5s %9s" % ['#', 'Title', 'Clips', 'Output', 'Source', 'Cut%', 'Fidelity']
$stderr.puts '-' * 95

results.each do |r|
  $stderr.puts "%-5s %-50s %6d %7.1fs %7.1fs %4d%% %9s" % [
    "##{r[:number]}", r[:title][0..49], r[:clips], r[:output_duration],
    r[:source_material], r[:reduction], r[:fidelity]
  ]
end

$stderr.puts '-' * 95
total_clips = results.sum { |r| r[:clips] }
total_output = results.sum { |r| r[:output_duration] }
total_source = results.sum { |r| r[:source_material] }
avg_fidelity = results.sum { |r| r[:beats_matched].to_f / r[:beats_total] } / results.length * 100
$stderr.puts "%-5s %-50s %6d %7.1fs %7.1fs %4d%% %8.0f%%" % [
  'TOT', "#{results.length} shorts", total_clips, total_output, total_source,
  ((1 - total_output / total_source) * 100).round, avg_fidelity
]
$stderr.puts ""
$stderr.puts "All outputs in: #{OUTPUT_DIR}"
