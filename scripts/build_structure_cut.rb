#!/usr/bin/env ruby
# Builds a structure cut XML from a YAML definition file.
#
# Usage: ruby scripts/build_structure_cut.rb <yaml_path>
#
# YAML format:
#   video_path: /absolute/path/to/video.mp4
#   output_dir: /absolute/path/to/output/
#   editor: fcp7
#   name: "My Structure Cut"          # optional, defaults to video basename
#   breathing_room_frames: 3          # optional, default 3
#   fps: 25                           # optional, auto-detected from video
#
#   output_format: match_source       # optional: "match_source" (default) or "vertical_short"
#                                    # "vertical_short" swaps width/height and adds center-crop scale.
#                                    # Auto-detected if project folder name contains "short".
#   output_resolution: 1080x1920     # optional: explicit WxH override for output sequence
#
#   sync_audio:                       # optional
#     path: /absolute/path/to/audio.wav
#     offset: 50.41                   # positive=audio before video
#
#   # time_domain: deprecated — use audio_start/audio_end or video_start/video_end instead.
#   #   Legacy start/end + time_domain still works but logs deprecation warnings.
#   #   Bare start/end WITHOUT time_domain will abort with an error.
#
#   clips:
#     - audio_start: 179.87           # WAV time — conversion mandatory (video_time = audio_time - sync_offset)
#       audio_end: 190.63
#     - video_start: 48.35            # video time — no conversion
#       video_end: 58.73
#
#   auto_remove_pauses_above: 500    # optional, milliseconds (default 500)
#                                    # Silero long pauses above this threshold inside a clip
#                                    # are removed by splitting the clip into sub-clips.
#                                    # Set to 0 or false to disable.
#
#   max_segment_duration: 12         # optional, seconds (default 12)
#                                    # After pause removal, any sub-clip exceeding this
#                                    # duration is split at the longest internal sentence
#                                    # boundary (pause >300ms). Set to 0 or false to disable.
#
#   markers:
#     - name: TITLE
#       comment: "Insert title card"
#       time: 0.0                     # timeline position (seconds)
#       color: blue

require_relative '../lib/buttercut'
require 'yaml'
require 'date'
require 'json'
require 'nokogiri'
require 'fileutils'
require 'shellwords'

# === Format helpers ===
def res_label(w, h)
  long_side = [w, h].max
  if long_side >= 3840 then '4K'
  elsif long_side >= 1920 then '1080p'
  elsif long_side >= 1280 then '720p'
  else "#{w}x#{h}"
  end
end

def fps_display(fps_str)
  num, denom = fps_str.split('/').map(&:to_f)
  exact = denom > 0 ? num / denom : 25.0
  if (exact - 23.976).abs < 0.01 then '23.976'
  elsif (exact - 29.97).abs < 0.01 then '29.97'
  elsif (exact - 59.94).abs < 0.01 then '59.94'
  elsif exact == exact.round then exact.round.to_s
  else '%.3f' % exact
  end
end

def orient_label(w, h)
  w > h ? 'horizontal' : (h > w ? 'vertical' : 'square')
end

no_emotion_markers = !!ARGV.delete('--no-emotion-markers')
markers_only_structure = !!ARGV.delete('--markers-only-structure')
profile_name = nil
if (idx = ARGV.index('--profile'))
  profile_name = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end
yaml_path = ARGV[0]
abort "Usage: ruby scripts/build_structure_cut.rb <yaml_path>" unless yaml_path
abort "YAML not found: #{yaml_path}" unless File.exist?(yaml_path)

config = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])

# === Load profile (fallback defaults) ===
require_relative 'load_profile'
profile = if profile_name
             load_profile_by_name(profile_name)
           else
             load_profile(config['name'] || File.basename(yaml_path, '.yaml'))
           end

# === Validate required fields ===
%w[video_path output_dir clips].each do |key|
  abort "Missing required field: #{key}" unless config[key]
end

video_path = config['video_path']
abort "Video not found: #{video_path}" unless File.exist?(video_path)

output_dir = config['output_dir']
editor = (config['editor'] || 'fcp7').to_sym

# === Source format detection ===
source_probe = JSON.parse(`ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of json #{Shellwords.escape(video_path)}`)
source_stream = source_probe['streams']&.first || {}
source_width = (source_stream['width'] || 1920).to_i
source_height = (source_stream['height'] || 1080).to_i
source_fps_str = source_stream['r_frame_rate'] || '25/1'
source_fps_num, source_fps_denom = source_fps_str.split('/').map(&:to_f)
source_fps_exact = source_fps_denom > 0 ? source_fps_num / source_fps_denom : 25.0
source_vertical = source_height > source_width

# FPS for buffer and WAV frame calculations (timebase integer)
if config['fps']
  fps = config['fps'].to_f
else
  fps = source_fps_exact.round
end

# === Output format determination ===
# Auto-detect shorts from project folder name only when output_format is not explicitly set
output_format = config['output_format']
if output_format.nil?
  project_folder = File.basename(File.dirname(config['output_dir'] || File.dirname(yaml_path)))
  output_format = project_folder.downcase.include?('short') ? 'vertical_short' : 'match_source'
end

# Determine output dimensions
if config['output_resolution']
  out_w, out_h = config['output_resolution'].split('x').map(&:to_i)
elsif output_format == 'vertical_short'
  if source_vertical
    out_w, out_h = source_width, source_height
  else
    out_w, out_h = source_height, source_width
  end
else
  out_w, out_h = source_width, source_height
end

needs_crop_scale = output_format == 'vertical_short' && !source_vertical
crop_scale = needs_crop_scale ? (out_h.to_f / source_height * 100).round(2) : nil

# === Format confirmation ===
fps_label = fps_display(source_fps_str)
source_desc = "#{source_width}x#{source_height} @ #{fps_label}fps (#{res_label(source_width, source_height)} #{orient_label(source_width, source_height)})"
out_desc = "#{out_w}x#{out_h} @ #{fps_label}fps"
if needs_crop_scale
  out_desc += " (#{res_label(out_w, out_h)} vertical short, center crop)"
elsif output_format == 'vertical_short' && source_vertical
  out_desc += " (#{res_label(out_w, out_h)} vertical, source already vertical)"
else
  out_desc += " (#{res_label(out_w, out_h)} #{orient_label(out_w, out_h)})"
end

$stderr.puts "Source: #{File.basename(video_path)} — #{source_desc}"
$stderr.puts "Output: #{out_desc}"

breathing_room_frames = config['breathing_room_frames'] || 3
buffer = breathing_room_frames.to_f / fps

# === Build clips ===
has_sync = config['sync_audio'] && config['sync_audio']['path']
sync_offset = has_sync ? config['sync_audio']['offset'].to_f : 0.0
sync_path = has_sync ? config['sync_audio']['path'] : nil

if has_sync && !File.exist?(sync_path)
  abort "Sync audio not found: #{sync_path}"
end

# === Load speech analysis for snap-to-boundary ===
speech_segments = nil
long_pauses = nil
if config['speech_analysis']
  sa_path = config['speech_analysis']
  abort "Speech analysis not found: #{sa_path}" unless File.exist?(sa_path)
  sa_data = JSON.parse(File.read(sa_path))
  speech_segments = sa_data['speech_segments']
  long_pauses = sa_data['long_pauses']
  $stderr.puts "Loaded speech analysis: #{speech_segments.size} segments, #{long_pauses.size} long pauses"
end

# === Load classification for tiered markers ===
classification_segments = nil
classification_branch_a = false
if config['classification']
  class_path = config['classification']
  if File.exist?(class_path)
    class_data = YAML.safe_load(File.read(class_path), permitted_classes: [Date])
    if class_data.key?('segments_used')
      classification_branch_a = true
      $stderr.puts "Classification is Branch A (script-locked) — Tier 2/3 markers limited"
    elsif class_data['segments']
      classification_segments = class_data['segments']
      $stderr.puts "Loaded #{classification_segments.size} classified segments for tiered markers"
    end
  else
    $stderr.puts "WARNING: Classification not found: #{class_path} — skipping classification-based markers"
  end
end

# === Load template match data for Tier 1 structure markers ===
template_match_data = nil
if config['template_match']
  tm_path = config['template_match']
  if File.exist?(tm_path)
    tm_data = YAML.safe_load(File.read(tm_path), permitted_classes: [Date])
    storylines = tm_data['storylines'] || []
    # Use the first (top-scored) storyline's template match
    template_match_data = storylines.first&.dig('template_match')
    if template_match_data
      $stderr.puts "Loaded template match: #{template_match_data['template']} (fit: #{template_match_data['fit_score']})"
    end
  end
elsif config['classification']
  # Try to find storylines_matched.yaml in same directory as classification
  class_dir = File.dirname(config['classification'])
  matched_path = File.join(class_dir, 'storylines_matched.yaml')
  if File.exist?(matched_path)
    tm_data = YAML.safe_load(File.read(matched_path), permitted_classes: [Date])
    storylines = tm_data['storylines'] || []
    template_match_data = storylines.first&.dig('template_match')
    if template_match_data
      $stderr.puts "Auto-loaded template match: #{template_match_data['template']} (fit: #{template_match_data['fit_score']})"
    end
  end
end

# === Parse auto_remove_pauses_above ===
pause_removal_threshold = nil
if config.key?('auto_remove_pauses_above')
  val = config['auto_remove_pauses_above']
  if val && val != false && val.to_i > 0
    pause_removal_threshold = val.to_i / 1000.0
  end
else
  pause_removal_threshold = 0.5  # default 500ms
end

if pause_removal_threshold && long_pauses
  $stderr.puts "Pause removal: enabled (threshold #{(pause_removal_threshold * 1000).round}ms)"
end

# === Parse max_segment_duration ===
max_segment_duration = nil
if config.key?('max_segment_duration')
  val = config['max_segment_duration']
  if val && val != false && val.to_i > 0
    max_segment_duration = val.to_i
  end
else
  max_segment_duration = profile['max_segment_duration'] || 12
end

if max_segment_duration && long_pauses
  $stderr.puts "Max segment duration: #{max_segment_duration}s (auto-split at sentence boundaries)"
end

# Find split points for an oversized clip using internal pauses.
# Recursively finds the longest pause, splits there, and checks sub-segments.
# Returns array of video-time split points sorted chronologically.
SENTENCE_BOUNDARY_THRESHOLD = 0.300  # 300ms minimum pause for sentence boundary

def find_split_points(video_start, video_end, pauses, max_dur, sync_offset, has_sync)
  duration = video_end - video_start
  return [] if duration <= max_dur

  # Find the longest qualifying pause inside this range (in video time)
  best_pause = nil
  best_dur = 0
  pauses.each do |p|
    p_start_v = has_sync ? p['start'] - sync_offset : p['start']
    next unless p_start_v > video_start + 0.5 && p_start_v < video_end - 0.5
    next unless p['duration'] >= SENTENCE_BOUNDARY_THRESHOLD
    if p['duration'] > best_dur
      best_pause = p
      best_dur = p['duration']
    end
  end

  return [] unless best_pause

  split_v = has_sync ? best_pause['start'] - sync_offset : best_pause['start']

  # Recursively check sub-segments
  left_splits = find_split_points(video_start, split_v, pauses, max_dur, sync_offset, has_sync)
  right_splits = find_split_points(split_v, video_end, pauses, max_dur, sync_offset, has_sync)

  left_splits + [split_v] + right_splits
end

# Snap a time to the nearest speech boundary within tolerance.
# boundary_type: :start snaps to segment starts, :end snaps to segment ends.
# Returns [snapped_time, adjustment] or [original_time, 0.0] if no match.
SNAP_TOLERANCE = (profile['snap_end_tolerance_ms'] || 100) / 1000.0
END_BUFFER = 0.100      # 100ms after speech end for breathing room

def snap_to_boundary(time, segments, boundary_type, tolerance = SNAP_TOLERANCE)
  return [time, 0.0] unless segments

  best = nil
  best_dist = tolerance

  segments.each do |seg|
    target = boundary_type == :start ? seg['start'] : seg['end']
    dist = (time - target).abs
    if dist < best_dist
      best = target
      best_dist = dist
    end
  end

  if best
    snapped = boundary_type == :end ? best + END_BUFFER : best
    [(snapped * 1000).round / 1000.0, (snapped - time).round(3)]
  else
    [time, 0.0]
  end
end

clips = []
wav_clip_info = []
# Track source WAV-time ranges for each output clip (for below-threshold pause markers)
clip_source_ranges = []
# Markers generated during pause removal (timeline positions computed after all clips built)
pause_removal_markers = []
removed_pause_count = 0
total_removed_ms = 0

# === Per-clip time domain detection ===
# Field names are self-describing:
#   audio_start/audio_end → WAV time, convert to video time using sync_offset
#   video_start/video_end → video time, use directly
#   start/end (legacy) → requires time_domain flag, logs deprecation warning
config['clips'].each_with_index do |c, idx|
  if c['audio_start'] && c['audio_end']
    abort "sync_audio required for audio_start/audio_end clips" unless has_sync
    start_time = c['audio_start'].to_f - sync_offset
    end_time = c['audio_end'].to_f - sync_offset
    $stderr.puts "Clip #{idx + 1}: audio #{c['audio_start']} → video #{'%.2f' % start_time}, audio #{c['audio_end']} → video #{'%.2f' % end_time}"
  elsif c['video_start'] && c['video_end']
    start_time = c['video_start'].to_f
    end_time = c['video_end'].to_f
  elsif c['start'] && c['end']
    if config['time_domain'] == 'audio'
      abort "sync_audio required for time_domain: audio" unless has_sync
      $stderr.puts "DEPRECATION: time_domain + start/end is deprecated. Use audio_start/audio_end instead." if idx == 0
      start_time = c['start'].to_f - sync_offset
      end_time = c['end'].to_f - sync_offset
    elsif config.key?('time_domain')
      $stderr.puts "DEPRECATION: time_domain + start/end is deprecated. Use video_start/video_end instead." if idx == 0
      start_time = c['start'].to_f
      end_time = c['end'].to_f
    else
      abort "ERROR: Clip #{idx + 1} uses bare 'start'/'end' without time_domain. Use audio_start/audio_end or video_start/video_end to specify time domain."
    end
  else
    abort "ERROR: Clip #{idx + 1} missing time fields. Expected audio_start/audio_end or video_start/video_end."
  end

  abort "Clip end (#{end_time}) must be after start (#{start_time})" if end_time <= start_time

  # Snap-to-boundary if speech analysis is available
  if speech_segments
    if has_sync
      wav_start = start_time + sync_offset
      wav_end = end_time + sync_offset

      snapped_start, adj_s = snap_to_boundary(wav_start, speech_segments, :start)
      snapped_end, adj_e = snap_to_boundary(wav_end, speech_segments, :end)

      start_time = snapped_start - sync_offset
      end_time = snapped_end - sync_offset
    else
      start_time, adj_s = snap_to_boundary(start_time, speech_segments, :start)
      end_time, adj_e = snap_to_boundary(end_time, speech_segments, :end)
    end

    if adj_s != 0.0 || adj_e != 0.0
      $stderr.puts "Clip #{idx + 1}: snapped start #{'%+.3f' % adj_s}s, end #{'%+.3f' % adj_e}s"
    end
  end

  # === Find internal pauses to remove ===
  removable_pauses = []
  if pause_removal_threshold && long_pauses
    wav_check_start = has_sync ? start_time + sync_offset : start_time
    wav_check_end = has_sync ? end_time + sync_offset : end_time

    long_pauses.each do |p|
      if p['start'] > wav_check_start + 0.5 && p['end'] < wav_check_end - 0.5 &&
         p['duration'] >= pause_removal_threshold
        removable_pauses << p
      end
    end
    removable_pauses.sort_by! { |p| p['start'] }
  end

  # === Build sub-clips (or single clip if no pauses to remove) ===
  if removable_pauses.any?
    # Split at pause boundaries — work in video time
    sub_ranges = []
    current_v = start_time
    removable_pauses.each do |p|
      p_start_v = has_sync ? p['start'] - sync_offset : p['start']
      p_end_v = has_sync ? p['end'] - sync_offset : p['end']
      sub_ranges << { start: current_v, end: p_start_v }
      current_v = p_end_v
    end
    sub_ranges << { start: current_v, end: end_time }

    removed_ms = removable_pauses.sum { |p| (p['duration'] * 1000).round }
    $stderr.puts "  Clip #{idx + 1}: removing #{removable_pauses.size} pauses (#{removed_ms}ms) → #{sub_ranges.size} sub-clips"

    sub_ranges.each_with_index do |sr, si|
      is_first = si == 0
      is_last = si == sub_ranges.size - 1
      # Breathing room only at outer edges, not at internal split points
      start_buf = is_first ? buffer : 0.0
      end_buf = is_last ? buffer : 0.0

      buffered_start = sr[:start] - start_buf
      buffered_start = 0.0 if buffered_start < 0
      dur = (sr[:end] - sr[:start]) + start_buf + end_buf

      clips << { path: video_path, start_at: buffered_start, duration: dur }

      wav_range_start = has_sync ? sr[:start] + sync_offset : sr[:start]
      wav_range_end = has_sync ? sr[:end] + sync_offset : sr[:end]
      clip_source_ranges << { wav_start: wav_range_start, wav_end: wav_range_end }

      if has_sync
        ws = (sr[:start] + sync_offset) - start_buf
        ws = 0.0 if ws < 0
        wav_clip_info << { wav_start: ws, wav_duration: dur }
      end

      # Record join-point marker (not for first sub-clip)
      if si > 0
        pause = removable_pauses[si - 1]
        pause_ms = (pause['duration'] * 1000).round
        removed_pause_count += 1
        total_removed_ms += pause_ms
        pause_removal_markers << { clip_index: clips.size - 1, pause_ms: pause_ms }
      end
    end
  else
    # Single clip — no pauses to remove
    buffered_start = start_time - buffer
    buffered_start = 0.0 if buffered_start < 0
    duration = (end_time - start_time) + (buffer * 2)

    clips << { path: video_path, start_at: buffered_start, duration: duration }

    wav_range_start = has_sync ? start_time + sync_offset : start_time
    wav_range_end = has_sync ? end_time + sync_offset : end_time
    clip_source_ranges << { wav_start: wav_range_start, wav_end: wav_range_end }

    if has_sync
      wav_start = (start_time + sync_offset) - buffer
      wav_start = 0.0 if wav_start < 0
      wav_clip_info << { wav_start: wav_start, wav_duration: duration }
    end
  end
end

# === Auto-split oversized segments ===
split_count = 0
if max_segment_duration && long_pauses
  new_clips = []
  new_wav_clip_info = []
  new_clip_source_ranges = []
  new_pause_removal_markers = []

  clips.each_with_index do |clip, ci|
    if clip[:duration] <= max_segment_duration
      # Remap any existing pause_removal_markers for this clip
      pause_removal_markers.each do |prm|
        if prm[:clip_index] == ci
          new_pause_removal_markers << prm.merge(clip_index: new_clips.size)
        end
      end
      new_clips << clip
      new_wav_clip_info << wav_clip_info[ci] if has_sync && ci < wav_clip_info.size
      new_clip_source_ranges << clip_source_ranges[ci] if ci < clip_source_ranges.size
      next
    end

    # Determine clip's video-time range (strip breathing room for split calculation)
    clip_video_start = clip[:start_at] + buffer
    clip_video_end = clip[:start_at] + clip[:duration] - buffer

    split_points = find_split_points(clip_video_start, clip_video_end,
                                      long_pauses, max_segment_duration,
                                      sync_offset, has_sync)

    if split_points.empty?
      # No valid split points — remap markers and keep as-is
      pause_removal_markers.each do |prm|
        if prm[:clip_index] == ci
          new_pause_removal_markers << prm.merge(clip_index: new_clips.size)
        end
      end
      new_clips << clip
      new_wav_clip_info << wav_clip_info[ci] if has_sync && ci < wav_clip_info.size
      new_clip_source_ranges << clip_source_ranges[ci] if ci < clip_source_ranges.size
      next
    end

    # Build sub-clips from split points
    boundaries = [clip_video_start] + split_points + [clip_video_end]
    boundaries.each_cons(2).with_index do |(sub_start, sub_end), si|
      is_first = si == 0
      is_last = si == boundaries.size - 2
      start_buf = is_first ? buffer : 0.0
      end_buf = is_last ? buffer : 0.0

      buffered_start = sub_start - start_buf
      buffered_start = 0.0 if buffered_start < 0
      dur = (sub_end - sub_start) + start_buf + end_buf

      new_clips << { path: video_path, start_at: buffered_start, duration: dur }

      wav_s = has_sync ? sub_start + sync_offset : sub_start
      wav_e = has_sync ? sub_end + sync_offset : sub_end
      new_clip_source_ranges << { wav_start: wav_s, wav_end: wav_e }

      if has_sync
        ws = wav_s - start_buf
        ws = 0.0 if ws < 0
        new_wav_clip_info << { wav_start: ws, wav_duration: dur }
      end

      if si > 0
        new_pause_removal_markers << { clip_index: new_clips.size - 1, pause_ms: 0, auto_split: true }
        split_count += 1
      end
    end

    $stderr.puts "  Clip #{ci + 1}: auto-split #{clip[:duration].round(1)}s → #{boundaries.size - 1} sub-clips at sentence boundaries"
  end

  if split_count > 0
    clips = new_clips
    wav_clip_info = new_wav_clip_info
    clip_source_ranges = new_clip_source_ranges
    pause_removal_markers = new_pause_removal_markers
    $stderr.puts "Auto-split: #{split_count} segments split at sentence boundaries (max #{max_segment_duration}s)"
  end
end

# === Build markers (convert string keys to symbols) ===
markers = (config['markers'] || []).map do |m|
  {
    name: m['name'],
    comment: m['comment'],
    time: m['time'].to_f,
    color: m['color']
  }
end

# === Compute timeline positions ===
timeline_positions = []
cumulative = 0.0
clips.each do |c|
  timeline_positions << cumulative
  cumulative += c[:duration]
end

# === Add "Auto-removed" / "Auto-split" markers at split join points ===
pause_removal_markers.each do |prm|
  tl_time = timeline_positions[prm[:clip_index]].round(2)
  if prm[:auto_split]
    comment = "Auto-split: segment exceeded #{max_segment_duration}s"
    log_msg = "  Auto-split at timeline #{tl_time}s"
  else
    comment = "Auto-removed #{prm[:pause_ms]}ms pause"
    log_msg = "  Auto-removed: #{prm[:pause_ms]}ms pause at timeline #{tl_time}s"
  end
  markers << {
    name: 'NOTE',
    comment: comment,
    time: tl_time,
    color: 'yellow'
  }
  $stderr.puts log_msg
end

# === Add "tighten manually" markers for below-threshold internal pauses ===
if long_pauses && speech_segments
  clip_source_ranges.each_with_index do |csr, i|
    long_pauses.each do |p|
      next unless p['start'] > csr[:wav_start] + 0.5 && p['end'] < csr[:wav_end] - 0.5
      # Skip pauses that were already removed
      next if pause_removal_threshold && p['duration'] >= pause_removal_threshold

      pause_ms = (p['duration'] * 1000).round
      pause_offset = p['start'] - csr[:wav_start]
      tl_time = (timeline_positions[i] + pause_offset).round(2)

      markers << {
        name: 'NOTE',
        comment: "Internal pause \u2014 tighten manually (#{pause_ms}ms)",
        time: tl_time,
        color: 'yellow'
      }
    end
  end
end

# =============================================================================
# THREE-TIER MARKER SYSTEM
# =============================================================================
#
# Tier 1: Structure markers (bright colors, range markers, 5-8 per video)
# Tier 2: Alert markers (yellow/cyan, point markers, selective)
# Tier 3: Reference markers (white, point markers, every segment)
#
# pproColor values for Premiere Pro:
#   Hook:          Green  = 4279486782
#   Section:       Orange = 4280578025
#   Pivot:         Purple = 4289734556
#   Reveal/Climax: Red    = 4281678309
#   Close:         Blue   = 4294153761
#   Action items:  Yellow = 4281719037
#   Transitions:   Cyan   = 4292131840
#   Reference:     Grey   = 4286611584
# =============================================================================

PPRO_HOOK     = 4279486782
PPRO_SECTION  = 4280578025
PPRO_PIVOT    = 4289734556
PPRO_REVEAL   = 4281678309
PPRO_CLOSE    = 4294153761
PPRO_ACTION   = 4281719037
PPRO_TRANSITION = 4292131840
PPRO_REFERENCE = 4286611584

# Helper: find timeline position for a classified segment
def seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync)
  seg_t = seg['t'].to_f
  seg_wav_t = has_sync ? seg_t + sync_offset : seg_t

  clip_idx = clip_source_ranges.each_with_index.find { |csr, _|
    seg_wav_t >= csr[:wav_start] - 0.05 && seg_wav_t < csr[:wav_end] + 0.05
  }&.last
  return nil unless clip_idx

  offset_in_clip = seg_wav_t - clip_source_ranges[clip_idx][:wav_start]
  (timeline_positions[clip_idx] + offset_in_clip).round(2)
end

def seg_end_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync)
  seg_e = seg['e'].to_f
  seg_wav_e = has_sync ? seg_e + sync_offset : seg_e

  clip_idx = clip_source_ranges.each_with_index.find { |csr, _|
    seg_wav_e >= csr[:wav_start] - 0.05 && seg_wav_e <= csr[:wav_end] + 0.5
  }&.last
  return nil unless clip_idx

  offset_in_clip = seg_wav_e - clip_source_ranges[clip_idx][:wav_start]
  (timeline_positions[clip_idx] + offset_in_clip).round(2)
end

tier1_markers = []
tier2_markers = []
tier3_markers = []

# === TIER 1: Structure Markers ===
# Only generated when classification segments are available (arranged segments)

if classification_segments && !classification_segments.empty?
  # Map arranged segments to timeline positions
  arranged = classification_segments.map { |seg|
    tl_start = seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync)
    tl_end = seg_end_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync)
    next nil unless tl_start
    seg.merge('tl_start' => tl_start, 'tl_end' => tl_end || tl_start + 1.0)
  }.compact.sort_by { |s| s['tl_start'] }

  if arranged.any?
    # HOOK: first segment in arrangement
    hook = arranged.first
    hook_end = hook['tl_end']
    tier1_markers << {
      name: "HOOK: #{hook['distillation'] || 'opening'}",
      comment: "Structure: hook region | dur: #{(hook_end - hook['tl_start']).round(1)}s | #{hook['dur'] || 'mood'}",
      time: hook['tl_start'],
      out_time: hook_end,
      color: 'green',
      pproColor: PPRO_HOOK
    }

    # CLOSE: last identity-durable segment, or just last segment
    close_candidates = arranged.select { |s| s['dur'] == 'identity' }
    close = close_candidates.any? ? close_candidates.last : arranged.last
    if close != hook
      tier1_markers << {
        name: "CLOSE: #{close['distillation'] || 'closing'}",
        comment: "Structure: close region | dur: #{(close['tl_end'] - close['tl_start']).round(1)}s | #{close['dur'] || 'mood'}",
        time: close['tl_start'],
        out_time: close['tl_end'],
        color: 'blue',
        pproColor: PPRO_CLOSE
      }
    end

    # SECTIONS from template beats (if available)
    if template_match_data && template_match_data['matched_beats']
      matched_beats = template_match_data['matched_beats']
      template_name = template_match_data['template'] || 'unknown'

      matched_beats.each do |beat_id, beat_info|
        next if beat_id == 'hook_claim' || beat_id == 'close' # already covered
        beat_t = beat_info['segment_t'].to_f
        beat_seg = arranged.find { |s| (s['t'].to_f - beat_t).abs < 0.1 }
        next unless beat_seg

        tier1_markers << {
          name: "SECTION: #{beat_info['distillation'] || beat_id.tr('_', ' ')}",
          comment: "Structure: #{beat_id} (#{template_name}) | starts at t=#{beat_t.round(1)}",
          time: beat_seg['tl_start'],
          out_time: beat_seg['tl_end'],
          color: 'orange',
          pproColor: PPRO_SECTION
        }
      end
    else
      # Fallback: detect topic shifts via distillation clustering
      # When distillation topic changes significantly between segments, mark section boundary
      prev_distillation = nil
      arranged.each_with_index do |seg, idx|
        next if idx == 0 || seg == close # skip hook and close
        curr_distillation = (seg['distillation'] || '').downcase.split(/\s+/)
        if prev_distillation
          # Simple overlap check — if fewer than 1 word overlaps, it's a topic shift
          overlap = (curr_distillation & prev_distillation).size
          if overlap == 0 && curr_distillation.size >= 2
            tier1_markers << {
              name: "SECTION: #{seg['distillation'] || 'topic shift'}",
              comment: "Structure: topic shift detected at segment #{idx + 1}",
              time: seg['tl_start'],
              out_time: seg['tl_end'],
              color: 'orange',
              pproColor: PPRO_SECTION
            }
          end
        end
        prev_distillation = curr_distillation
      end
    end

    # PIVOT: segment with identity durability + state shift mid-video, or highest-scored identity segment
    mid_start = arranged.size / 4
    mid_end = arranged.size * 3 / 4
    mid_range = arranged[mid_start..mid_end] || []
    pivot = mid_range.find { |s| s['dur'] == 'identity' && s != hook && s != close }
    if pivot
      tier1_markers << {
        name: "PIVOT: #{pivot['distillation'] || 'turning point'}",
        comment: "Structure: emotional pivot | #{(pivot['states'] || []).join(', ')} | #{pivot['dur']}",
        time: pivot['tl_start'],
        out_time: pivot['tl_end'],
        color: 'purple',
        pproColor: PPRO_PIVOT
      }
    end

    # REVEAL: highest-confidence identity segment (not hook/close/pivot)
    reveal_candidates = arranged.select { |s|
      s['confidence'] == 'high' && s != hook && s != close && s != pivot
    }
    reveal = reveal_candidates.max_by { |s|
      score = 0
      score += 2 if s['dur'] == 'identity'
      score += 1 if s['dur'] == 'mood'
      score += 1 if (s['roles'] || []).include?('primary')
      score
    }
    if reveal
      tier1_markers << {
        name: "REVEAL: #{reveal['distillation'] || 'payoff'}",
        comment: "Structure: reveal/climax | #{(reveal['states'] || []).join(', ')} | confidence: #{reveal['confidence']}",
        time: reveal['tl_start'],
        out_time: reveal['tl_end'],
        color: 'red',
        pproColor: PPRO_REVEAL
      }
    end
  end
end

$stderr.puts "Tier 1 (structure): #{tier1_markers.size} markers" if tier1_markers.any?

# === TIER 2: Alert Markers ===
# Generated unless --markers-only-structure is set

unless markers_only_structure
  if classification_segments && !classification_segments.empty? && !classification_branch_a
    arranged = classification_segments.map { |seg|
      tl_start = seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync)
      next nil unless tl_start
      seg.merge('tl_start' => tl_start)
    }.compact.sort_by { |s| s['tl_start'] }

    # State transitions: where primary state changes between adjacent segments
    arranged.each_cons(2) do |prev_seg, curr_seg|
      prev_state = (prev_seg['states'] || []).first
      curr_state = (curr_seg['states'] || []).first
      if prev_state && curr_state && prev_state != curr_state
        tier2_markers << {
          name: "TRANSITION: #{prev_state} \u2192 #{curr_state}",
          comment: "State change: #{prev_state}(#{prev_seg['dur']}) → #{curr_state}(#{curr_seg['dur']}) | pacing shift point",
          time: curr_seg['tl_start'],
          color: 'blue',
          pproColor: PPRO_TRANSITION
        }
      end
    end

    # Durability shifts: where durability class changes
    arranged.each_cons(2) do |prev_seg, curr_seg|
      prev_dur = prev_seg['dur']
      curr_dur = curr_seg['dur']
      if prev_dur && curr_dur && prev_dur != curr_dur
        # Only flag significant shifts (spike→mood, mood→identity, identity→spike)
        shift_map = { 'spike' => 0, 'mood' => 1, 'identity' => 2 }
        if shift_map[prev_dur] && shift_map[curr_dur]
          tier2_markers << {
            name: "SHIFT: #{prev_dur} \u2192 #{curr_dur}",
            comment: "Durability shift: #{prev_dur} → #{curr_dur} | pacing change point",
            time: curr_seg['tl_start'],
            color: 'blue',
            pproColor: PPRO_TRANSITION
          }
        end
      end
    end

    # Signpost segments: flagged for cutting
    arranged.each do |seg|
      if seg['signpost']
        tier2_markers << {
          name: "SIGNPOST: cut candidate",
          comment: "Signpost: meta-commentary | \"#{seg['distillation']}\" | consider removing",
          time: seg['tl_start'],
          color: 'yellow',
          pproColor: PPRO_ACTION
        }
      end
    end

    # Long segments > max_segment_duration
    max_dur_check = max_segment_duration || 12
    arranged.each do |seg|
      seg_duration = seg['e'].to_f - seg['t'].to_f
      if seg_duration > max_dur_check
        tier2_markers << {
          name: "SPLIT: #{seg_duration.round(1)}s segment",
          comment: "Long segment: #{seg_duration.round(1)}s exceeds #{max_dur_check}s | consider splitting | \"#{seg['distillation']}\"",
          time: seg['tl_start'],
          color: 'yellow',
          pproColor: PPRO_ACTION
        }
      end
    end

    # Low confidence segments
    arranged.each do |seg|
      if seg['confidence'] == 'low'
        tier2_markers << {
          name: "REVIEW: low confidence",
          comment: "Low confidence classification | \"#{seg['distillation']}\" | verify clip works in context",
          time: seg['tl_start'],
          color: 'yellow',
          pproColor: PPRO_ACTION
        }
      end
    end
  end
end

$stderr.puts "Tier 2 (alerts): #{tier2_markers.size} markers" if tier2_markers.any?

# === TIER 3: Reference Markers (per-segment classification) ===
# Suppressed by --no-emotion-markers or --markers-only-structure

tier3_count = 0
unless no_emotion_markers || markers_only_structure
  if classification_segments && !classification_branch_a
    classification_segments.each do |seg|
      tl_time = seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync)
      next unless tl_time

      seg_t = seg['t'].to_f
      primary_state = (seg['states'] || []).first || 'unknown'
      distillation = seg['distillation'] || ''
      dur = seg['dur'] || 'mood'
      states_str = (seg['states'] || []).map { |s| "#{s}(#{dur})" }.join(', ')

      comment_parts = ["states: #{states_str}"]
      comment_parts << "role: #{seg['narrative_role'] || 'unclassified'}"
      comment_parts << "signal: #{seg['signal']}" if seg['signal']
      comment_parts << "audio: #{seg['audio_profile']}" if seg['audio_profile']
      comment_parts << "confidence: #{seg['confidence'] || 'unknown'}"
      comment_parts << "t=#{seg_t}"

      tier3_markers << {
        name: "#{primary_state}(#{dur}) | #{distillation}",
        comment: comment_parts.join(' | '),
        time: tl_time,
        color: 'white',
        pproColor: PPRO_REFERENCE
      }
      tier3_count += 1
    end
  end
end

$stderr.puts "Tier 3 (reference): #{tier3_count} markers" if tier3_count > 0

# === Combine markers: Tier 1 first, then Tier 2, then Tier 3 ===
# This ordering ensures structure markers appear first in Premiere's marker panel
markers = tier1_markers + tier2_markers + markers + tier3_markers

if removed_pause_count > 0
  $stderr.puts "Pause removal: #{removed_pause_count} pauses removed (#{(total_removed_ms / 1000.0).round(1)}s total)"
end

# === Generate base XML ===
FileUtils.mkdir_p(output_dir)
generator = ButterCut.new(clips, editor: editor, markers: markers, name: config['name'])
base_xml = generator.to_xml

# === Post-process: add sync audio track if present ===
if has_sync
  doc = Nokogiri::XML(base_xml)

  # Get WAV properties via ffprobe
  wav_info_raw = `ffprobe -v error -show_entries format=duration -show_entries stream=sample_rate,bits_per_sample,channels -of json #{Shellwords.escape(sync_path)}`
  wav_meta = JSON.parse(wav_info_raw)
  wav_duration_s = wav_meta['format']['duration'].to_f
  wav_duration_frames = (wav_duration_s * fps).round

  wav_stream = wav_meta['streams']&.find { |s| s['codec_type'] == 'audio' } || {}
  wav_sample_rate = wav_stream['sample_rate'] || '48000'
  wav_bit_depth = wav_stream['bits_per_sample'] || 16
  wav_channels = wav_stream['channels'] || 2

  wav_pathurl = "file://#{sync_path.gsub(' ', '%20')}"
  wav_basename = File.basename(sync_path, File.extname(sync_path))
  wav_filename = File.basename(sync_path)

  audio_node = doc.at_xpath('//sequence/media/audio')
  track_node = Nokogiri::XML::Node.new('track', doc)
  wav_file_id = "file-wav-production"
  first_clip = true

  # Compute timeline positions
  timeline_pos = []
  cumulative = 0.0
  clips.each do |c|
    timeline_pos << cumulative
    cumulative += c[:duration]
  end

  wav_clip_info.each_with_index do |wi, i|
    tl_start_frames = (timeline_pos[i] * fps).round
    tl_duration_frames = (wi[:wav_duration] * fps).round
    tl_end_frames = tl_start_frames + tl_duration_frames
    src_in_frames = (wi[:wav_start] * fps).round
    src_in_frames = 0 if src_in_frames < 0
    src_out_frames = src_in_frames + tl_duration_frames

    clip_node = Nokogiri::XML::Node.new('clipitem', doc)
    clip_node['id'] = "clipitem-wav-#{i + 1}"
    clip_node.add_child("<name>#{wav_basename}</name>")
    clip_node.add_child("<enabled>TRUE</enabled>")
    clip_node.add_child("<duration>#{tl_duration_frames}</duration>")
    clip_node.add_child("<start>#{tl_start_frames}</start>")
    clip_node.add_child("<end>#{tl_end_frames}</end>")
    clip_node.add_child("<in>#{src_in_frames}</in>")
    clip_node.add_child("<out>#{src_out_frames}</out>")

    if first_clip
      file_xml = <<~XML
        <file id="#{wav_file_id}">
          <name>#{wav_filename}</name>
          <pathurl>#{wav_pathurl}</pathurl>
          <rate><timebase>#{fps}</timebase><ntsc>FALSE</ntsc></rate>
          <duration>#{wav_duration_frames}</duration>
          <media>
            <audio>
              <samplecharacteristics>
                <samplerate>#{wav_sample_rate}</samplerate>
                <sampledepth>#{wav_bit_depth}</sampledepth>
              </samplecharacteristics>
            </audio>
          </media>
        </file>
      XML
      first_clip = false
    else
      file_xml = "<file id=\"#{wav_file_id}\"/>"
    end
    clip_node.add_child(file_xml)
    clip_node.add_child("<sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>")
    clip_node.add_child("<channelcount>#{wav_channels}</channelcount>")
    track_node.add_child(clip_node)
  end

  audio_node.add_child(track_node)
  final_xml = doc.to_xml
else
  final_xml = base_xml
end

# === Output format override — sequence dimensions + center-crop scale ===
if needs_crop_scale || out_w != source_width || out_h != source_height
  doc = Nokogiri::XML(final_xml)

  # Override sequence samplecharacteristics dimensions
  seq_sc = doc.at_xpath('//sequence/media/video/format/samplecharacteristics')
  if seq_sc
    seq_sc.at_xpath('width').content = out_w.to_s
    seq_sc.at_xpath('height').content = out_h.to_s
  end

  # Add center-crop scale to each video clipitem
  if needs_crop_scale
    video_clipitems = doc.xpath('//sequence/media/video/track/clipitem')
    video_clipitems.each do |clipitem|
      filter = Nokogiri::XML::Node.new('filter', doc)
      effect = Nokogiri::XML::Node.new('effect', doc)
      effect.add_child('<name>Basic Motion</name>')
      effect.add_child('<effectid>basic</effectid>')
      effect.add_child('<effectcategory>motion</effectcategory>')
      effect.add_child('<effecttype>motion</effecttype>')
      effect.add_child('<mediatype>video</mediatype>')

      param = Nokogiri::XML::Node.new('parameter', doc)
      param['authoringApp'] = 'PremierePro'
      param.add_child('<parameterid>scale</parameterid>')
      param.add_child('<name>Scale</name>')
      param.add_child('<valuemin>0</valuemin>')
      param.add_child('<valuemax>600</valuemax>')
      param.add_child("<value>#{crop_scale}</value>")

      effect.add_child(param)
      filter.add_child(effect)
      clipitem.add_child(filter)
    end
    $stderr.puts "Applied center-crop scale: #{crop_scale}% to #{video_clipitems.size} clips"
  end

  final_xml = doc.to_xml
end

# === Save with timestamp ===
cut_name = config['name'] || File.basename(video_path, File.extname(video_path))
timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
safe_name = cut_name.gsub(/[^a-zA-Z0-9_\-]/, '_')
output_path = File.join(output_dir, "#{safe_name}_#{timestamp}.xml")
File.write(output_path, final_xml)

# === Summary ===
total_duration = clips.sum { |c| c[:duration] }
mins = (total_duration / 60).floor
secs = (total_duration % 60).round

puts output_path
$stderr.puts "Structure cut generated: #{output_path}"
summary = "Duration: #{mins}:#{format('%02d', secs)} | Clips: #{clips.length} | Markers: #{markers.length}"
summary += " (T1:#{tier1_markers.size} T2:#{tier2_markers.size} T3:#{tier3_count})" if tier1_markers.any? || tier2_markers.any? || tier3_count > 0
summary += " | Pauses removed: #{removed_pause_count} (#{(total_removed_ms / 1000.0).round(1)}s)" if removed_pause_count > 0
$stderr.puts summary
if has_sync
  $stderr.puts "Sync audio: #{File.basename(sync_path)} (offset: #{sync_offset}s)"
  $stderr.puts "Track 1: scratch audio (mute) | Track 2: production audio"
end
