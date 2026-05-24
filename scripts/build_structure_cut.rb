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
#   auto_remove_pauses_above: 800    # optional, milliseconds (disabled by default)
#                                    # Silero long pauses above this threshold inside a clip
#                                    # are removed by splitting the clip into sub-clips.
#                                    # Enable via --remove-pauses CLI flag or this YAML field.
#                                    # Set to 0 or false to explicitly disable.
#
#   min_segment_duration: 2          # optional, seconds (default 2 from profile)
#                                    # After pause removal, segments shorter than this
#                                    # are merged with adjacent segments.
#
#                                    # Legacy: if set, splits clips exceeding this duration
#                                    # at sentence boundaries. Set to 0 or false to disable.
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

AUDIO_ONLY_EXTS = %w[.m4a .mp3 .wav .aac].freeze

def audio_only_path?(path)
  path && AUDIO_ONLY_EXTS.include?(File.extname(path.to_s).downcase)
end

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
cli_remove_pauses = !!ARGV.delete('--remove-pauses')
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
%w[output_dir clips].each do |key|
  abort "Missing required field: #{key}" unless config[key]
end

# video_path: global fallback for single-source; per-clip 'video_path' takes priority
video_path = config['video_path']
has_per_clip_paths = config['clips'].any? { |c| c['video_path'] }
if video_path
  abort "Video not found: #{video_path}" unless File.exist?(video_path)
elsif !has_per_clip_paths
  abort "Missing required field: video_path (no per-clip video_path found either)"
end

output_dir = config['output_dir']
editor = (config['editor'] || 'fcp7').to_sym

# === Source format detection ===
# Find the first non-audio-only path for probing video dimensions/frame rate.
probe_path = if video_path && !audio_only_path?(video_path)
  video_path
else
  config['clips'].find { |c| c['video_path'] && !audio_only_path?(c['video_path']) }&.dig('video_path') ||
    video_path ||
    config['clips'].first&.dig('video_path')
end
source_probe = JSON.parse(`ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate -of json #{Shellwords.escape(probe_path)}`)
source_stream = source_probe['streams']&.first || {}
source_width = (source_stream['width'] || 1920).to_i
source_height = (source_stream['height'] || 1080).to_i
source_fps_str = source_stream['r_frame_rate'] || '25/1'
source_fps_num, source_fps_denom = source_fps_str.split('/').map(&:to_f)
source_fps_exact = source_fps_denom > 0 ? source_fps_num / source_fps_denom : 25.0
source_vertical = source_height > source_width

# FPS for WAV frame calculations (timebase integer)
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

# BREATHING_MARGIN: fixed 80ms padding per side (D5.10).
# Atoms from semantic_segment.rb have precise word-level boundaries.
BREATHING_MARGIN = 0.080

# === Tier 0: Narrative role indicator markers (point markers at clip starts) ===
# Replaces clip label coloring (which Premiere ties to source media, not timeline instances).
ROLE_MARKER_PPRO = {
  'hook'         => 4279486782,   # Green
  'setup'        => 4280578025,   # Orange
  'continuation' => 4294153761,   # Blue
  'payoff'       => 4289734556,   # Purple
}.freeze

ROLE_MARKER_FCP_COLOR = {
  'hook'         => 'green',
  'setup'        => 'orange',
  'continuation' => 'blue',
  'payoff'       => 'purple',
}.freeze

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

# Per-source speech analysis map (multi-source support)
# Maps video_path → { speech_segments:, long_pauses: }
speech_analysis_cache = {}
if config['speech_analysis_map']
  config['speech_analysis_map'].each do |vpath, sa_path|
    if File.exist?(sa_path)
      sa_data = JSON.parse(File.read(sa_path))
      speech_analysis_cache[vpath] = {
        speech_segments: sa_data['speech_segments'],
        long_pauses: sa_data['long_pauses']
      }
    end
  end
  $stderr.puts "Loaded per-source speech analysis for #{speech_analysis_cache.size} source(s)" if speech_analysis_cache.any?
end

# === Load transcript for in-point restart trimming ===
transcript_words = nil
if config['transcript']
  tr_path = config['transcript']
  if File.exist?(tr_path)
    tr_data = JSON.parse(File.read(tr_path))
    transcript_words = tr_data['segments'].flat_map { |s| s['words'] || [] }
    $stderr.puts "Loaded transcript: #{transcript_words.size} words for restart trimming"
  else
    $stderr.puts "WARNING: Transcript not found: #{tr_path} — skipping restart trimming"
  end
end

# Per-source transcript map (multi-source support for restart trimming)
transcript_cache = {}
if config['transcript_map']
  config['transcript_map'].each do |vpath, t_path|
    if File.exist?(t_path)
      t_data = JSON.parse(File.read(t_path))
      words = t_data['segments'].flat_map { |s| s['words'] || [] }
      transcript_cache[vpath] = words
    end
  end
  $stderr.puts "Loaded per-source transcripts for #{transcript_cache.size} source(s)" if transcript_cache.any?
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

# === Load edit patterns for checklist markers ===
edit_patterns = nil
if config['edit_patterns']
  ep_path = config['edit_patterns']
  if File.exist?(ep_path)
    edit_patterns = YAML.safe_load(File.read(ep_path), permitted_classes: [Date])
    $stderr.puts "Loaded edit patterns: #{(edit_patterns['video_overlay_patterns'] || []).size} video, #{(edit_patterns['audio_overlay_patterns'] || []).size} audio"
  end
elsif config['classification']
  # Auto-detect in same directory as classification
  class_dir = File.dirname(config['classification'])
  ep_path = File.join(class_dir, 'edit_patterns.yaml')
  if File.exist?(ep_path)
    edit_patterns = YAML.safe_load(File.read(ep_path), permitted_classes: [Date])
    $stderr.puts "Auto-loaded edit patterns: #{(edit_patterns['video_overlay_patterns'] || []).size} video, #{(edit_patterns['audio_overlay_patterns'] || []).size} audio"
  end
end

# === Parse auto_remove_pauses_above ===
# Pause removal is OFF by default. Enable via --remove-pauses flag or
# explicit auto_remove_pauses_above in YAML config.
pause_removal_threshold = nil
if config.key?('auto_remove_pauses_above')
  val = config['auto_remove_pauses_above']
  if val && val != false && val.to_i > 0
    pause_removal_threshold = val.to_i / 1000.0
  end
elsif cli_remove_pauses
  # --remove-pauses flag: use profile threshold
  profile_pause_ms = profile['auto_remove_pauses_above'] || 800
  pause_removal_threshold = profile_pause_ms.to_i / 1000.0
end

if pause_removal_threshold && long_pauses
  $stderr.puts "Pause removal: enabled (threshold #{(pause_removal_threshold * 1000).round}ms)"
else
  $stderr.puts "Pause removal: disabled (use --remove-pauses to enable)"
end

# === Parse min_segment_duration (floor after splits) ===
min_segment_duration = nil
if config.key?('min_segment_duration')
  val = config['min_segment_duration']
  if val && val != false && val.to_f > 0
    min_segment_duration = val.to_f
  end
else
  min_segment_duration = (profile['min_segment_duration'] || 2).to_f
end



clips = []
wav_clip_info = []
# Track source WAV-time ranges for each output clip (for below-threshold pause markers)
clip_source_ranges = []
# Markers generated during pause removal (timeline positions computed after all clips built)
pause_removal_markers = []
removed_pause_count = 0
total_removed_ms = 0
# Track V1 timeline duration so V2+ clips can be positioned correctly
v1_timeline_duration = 0.0
# Tier 0: collect narrative role marker data during clip processing
tier0_role_markers = []

# === Per-clip time domain detection ===
# Field names are self-describing:
#   audio_start/audio_end → WAV time, convert to video time using sync_offset
#   video_start/video_end → video time, use directly
#   start/end (legacy) → requires time_domain flag, logs deprecation warning
config['clips'].each_with_index do |c, idx|
  # Per-clip sync audio (multi-source support)
  # Falls back to global sync values when per-clip fields aren't set
  clip_sync_offset = c['sync_audio_offset']&.to_f || sync_offset
  clip_sync_path   = c['sync_audio_path'] || sync_path
  clip_has_sync    = !clip_sync_path.nil? && clip_sync_path != ''

  if c['audio_start'] && c['audio_end']
    abort "sync_audio required for audio_start/audio_end clips" unless clip_has_sync
    start_time = c['audio_start'].to_f - clip_sync_offset
    end_time = c['audio_end'].to_f - clip_sync_offset
    $stderr.puts "Clip #{idx + 1}: audio #{c['audio_start']} → video #{'%.2f' % start_time}, audio #{c['audio_end']} → video #{'%.2f' % end_time}"
  elsif c['video_start'] && c['video_end']
    start_time = c['video_start'].to_f
    end_time = c['video_end'].to_f
  elsif c['start'] && c['end']
    if config['time_domain'] == 'audio'
      abort "sync_audio required for time_domain: audio" unless clip_has_sync
      $stderr.puts "DEPRECATION: time_domain + start/end is deprecated. Use audio_start/audio_end instead." if idx == 0
      start_time = c['start'].to_f - clip_sync_offset
      end_time = c['end'].to_f - clip_sync_offset
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

  # === Resolve per-clip speech analysis (multi-source) ===
  clip_speech_segments = speech_segments  # global default
  clip_long_pauses = long_pauses          # global default
  clip_source_path = c['video_path'] || video_path
  if clip_source_path && speech_analysis_cache[clip_source_path]
    clip_sa = speech_analysis_cache[clip_source_path]
    clip_speech_segments = clip_sa[:speech_segments]
    clip_long_pauses = clip_sa[:long_pauses]
  end

  # === Apply trim_in from ingest (LLM-designated in-point adjustment) ===
  if c['trim_in']
    trim_in_val = c['trim_in'].to_f
    if trim_in_val > start_time && trim_in_val < end_time
      $stderr.puts "Clip #{idx + 1}: trim_in #{'%.2f' % start_time}→#{'%.2f' % trim_in_val}s (ingest)"
      start_time = trim_in_val
    end
  end

  # === Apply mid_cuts from ingest (internal ranges to excise) ===
  mid_cut_ranges = []
  if c['mid_cuts'] && c['mid_cuts'].is_a?(Array)
    c['mid_cuts'].each do |mc|
      next unless mc.is_a?(Array) && mc.size == 2
      mc_start = mc[0].to_f
      mc_end = mc[1].to_f
      if mc_start > start_time && mc_end < end_time && mc_end > mc_start
        mid_cut_ranges << { 'start' => mc_start, 'end' => mc_end, 'duration' => mc_end - mc_start }
        $stderr.puts "Clip #{idx + 1}: mid_cut #{'%.2f' % mc_start}→#{'%.2f' % mc_end}s (#{'%.1f' % (mc_end - mc_start)}s excised, ingest)"
      end
    end
  end

  # === Find internal pauses to remove ===
  removable_pauses = []
  if pause_removal_threshold && clip_long_pauses
    wav_check_start = clip_has_sync ? start_time + clip_sync_offset : start_time
    wav_check_end = clip_has_sync ? end_time + clip_sync_offset : end_time

    clip_long_pauses.each do |p|
      if p['start'] > wav_check_start + 0.5 && p['end'] < wav_check_end - 0.5 &&
         p['duration'] >= pause_removal_threshold
        removable_pauses << p
      end
    end
    removable_pauses.sort_by! { |p| p['start'] }
  end

  # Merge mid_cut_ranges into removable_pauses (mid_cuts are in video time)
  if mid_cut_ranges.any?
    mid_cut_ranges.each do |mc|
      # Convert to WAV time if sync_audio is present (to match removable_pauses format)
      if clip_has_sync
        removable_pauses << { 'start' => mc['start'] + clip_sync_offset, 'end' => mc['end'] + clip_sync_offset, 'duration' => mc['duration'] }
      else
        removable_pauses << mc
      end
    end
    removable_pauses.sort_by! { |p| p['start'] }
  end

  # === Read per-clip track assignment ===
  clip_track_str = (c['track'] || 'V1').to_s.upcase
  clip_video_track = clip_track_str.sub(/^V/, '').to_i
  clip_video_track = 1 if clip_video_track < 1
  clip_timeline_offset = c['timeline_offset'] ? c['timeline_offset'].to_f : nil

  # Per-clip video path (multi-source support)
  clip_video_path = c['video_path'] || video_path
  abort "Clip #{idx + 1}: no video_path (set per-clip or global)" unless clip_video_path

  # Detect audio-only source (no video stream — audio clipitem only in XML)
  is_audio_only_clip = c['media_type'] == 'audio_only' || audio_only_path?(clip_video_path)

  # === Tier 0: Narrative role indicator marker at clip start ===
  role = c['narrative_role']
  if role && role != 'transition' && ROLE_MARKER_PPRO[role]
    role_tl_pos = (clip_video_track > 1) ? (clip_timeline_offset || v1_timeline_duration) : v1_timeline_duration
    tier0_role_markers << { role: role, time: role_tl_pos }
  end

  # === Build sub-clips (or single clip if no pauses to remove) ===
  if removable_pauses.any?
    # Split at pause boundaries — work in video time
    # Prefer sentence boundaries within 1s of pause when speech_segments available
    sub_ranges = []
    current_v = start_time
    removable_pauses.each do |p|
      p_start_v = clip_has_sync ? p['start'] - clip_sync_offset : p['start']
      p_end_v = clip_has_sync ? p['end'] - clip_sync_offset : p['end']

      # Refine split to sentence boundary if available within 1s
      if clip_speech_segments
        seg_end_target = clip_has_sync ? p['start'] : p_start_v
        best_boundary = nil
        best_dist = 1.0  # max 1 second tolerance
        clip_speech_segments.each do |seg|
          dist = (seg['end'] - seg_end_target).abs
          if dist < best_dist
            best_boundary = seg['end']
            best_dist = dist
          end
        end
        if best_boundary
          refined_v = clip_has_sync ? best_boundary - clip_sync_offset : best_boundary
          # Only use if it's within the clip and doesn't create a too-short segment
          if refined_v > current_v + 0.5 && refined_v < end_time - 0.5
            p_start_v = refined_v
          end
        end
      end

      sub_ranges << { start: current_v, end: p_start_v }
      current_v = p_end_v
    end
    sub_ranges << { start: current_v, end: end_time }

    # === Minimum segment duration floor: merge short segments with neighbors ===
    if min_segment_duration && sub_ranges.size > 1
      merged = true
      while merged
        merged = false
        sub_ranges.each_with_index do |sr, si|
          seg_dur = sr[:end] - sr[:start]
          next if seg_dur >= min_segment_duration
          # Merge with adjacent (prefer longer neighbor)
          if si == 0
            # Merge with next — extend next's start backwards (skip the pause)
            sub_ranges[si + 1][:start] = sr[:start]
            sub_ranges.delete_at(si)
          elsif si == sub_ranges.size - 1
            # Merge with previous — extend previous's end forward (skip the pause)
            sub_ranges[si - 1][:end] = sr[:end]
            sub_ranges.delete_at(si)
          else
            # Merge with the longer neighbor
            prev_dur = sub_ranges[si - 1][:end] - sub_ranges[si - 1][:start]
            next_dur = sub_ranges[si + 1][:end] - sub_ranges[si + 1][:start]
            if prev_dur >= next_dur
              sub_ranges[si - 1][:end] = sr[:end]
            else
              sub_ranges[si + 1][:start] = sr[:start]
            end
            sub_ranges.delete_at(si)
          end
          # Recount pauses that actually remain removed
          merged = true
          break
        end
      end
    end

    removed_ms = removable_pauses.sum { |p| (p['duration'] * 1000).round }
    $stderr.puts "  Clip #{idx + 1}: removing #{removable_pauses.size} pauses (#{removed_ms}ms) → #{sub_ranges.size} sub-clips"

    sub_ranges.each_with_index do |sr, si|
      is_first = si == 0
      is_last = si == sub_ranges.size - 1
      # Breathing room only at outer edges, not at internal split points
      start_buf = is_first ? BREATHING_MARGIN : 0.0
      end_buf = is_last ? BREATHING_MARGIN : 0.0

      buffered_start = sr[:start] - start_buf
      buffered_start = 0.0 if buffered_start < 0
      dur = (sr[:end] - sr[:start]) + start_buf + end_buf

      clip_hash = { path: clip_video_path, start_at: buffered_start, duration: dur }
      clip_hash[:media_type] = :audio_only if is_audio_only_clip
      if clip_video_track > 1
        clip_hash[:video_track] = clip_video_track
        clip_hash[:audio_track] = clip_video_track
        # V2+ clips: use explicit timeline_offset or current V1 position
        offset = clip_timeline_offset || v1_timeline_duration
        clip_hash[:timeline_offset] = offset + (is_first ? 0.0 : (sr[:start] - start_time))
      end
      clips << clip_hash

      wav_range_start = clip_has_sync ? sr[:start] + clip_sync_offset : sr[:start]
      wav_range_end = clip_has_sync ? sr[:end] + clip_sync_offset : sr[:end]
      clip_source_ranges << { wav_start: wav_range_start, wav_end: wav_range_end, source: clip_video_path }

      if clip_has_sync
        ws = (sr[:start] + clip_sync_offset) - start_buf
        ws = 0.0 if ws < 0
        wav_clip_info << { wav_start: ws, wav_duration: dur, wav_path: clip_sync_path, wav_offset: clip_sync_offset }
      else
        wav_clip_info << nil
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
    buffered_start = start_time - BREATHING_MARGIN
    buffered_start = 0.0 if buffered_start < 0
    duration = (end_time - start_time) + (BREATHING_MARGIN * 2)

    clip_hash = { path: clip_video_path, start_at: buffered_start, duration: duration }
    clip_hash[:media_type] = :audio_only if is_audio_only_clip
    if clip_video_track > 1
      clip_hash[:video_track] = clip_video_track
      clip_hash[:audio_track] = clip_video_track
      clip_hash[:timeline_offset] = clip_timeline_offset || v1_timeline_duration
    end
    clips << clip_hash

    wav_range_start = clip_has_sync ? start_time + clip_sync_offset : start_time
    wav_range_end = clip_has_sync ? end_time + clip_sync_offset : end_time
    clip_source_ranges << { wav_start: wav_range_start, wav_end: wav_range_end, source: clip_video_path }

    if clip_has_sync
      wav_start = (start_time + clip_sync_offset) - BREATHING_MARGIN
      wav_start = 0.0 if wav_start < 0
      wav_clip_info << { wav_start: wav_start, wav_duration: duration, wav_path: clip_sync_path, wav_offset: clip_sync_offset }
    else
      wav_clip_info << nil
    end
  end

  # Update V1 timeline duration (only V1 clips advance the timeline)
  if clip_video_track == 1
    v1_timeline_duration = clips.select { |cl| !cl.key?(:video_track) || cl[:video_track] == 1 }
                                .sum { |cl| cl[:duration] }
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
# V1 clips are sequential; V2+ clips use their explicit timeline_offset
timeline_positions = []
cumulative = 0.0
clips.each do |c|
  if c[:timeline_offset]
    timeline_positions << c[:timeline_offset]
  else
    timeline_positions << cumulative
    cumulative += c[:duration]
  end
end

# === Add "Auto-removed" markers at pause removal join points ===
pause_removal_markers.each do |prm|
  tl_time = timeline_positions[prm[:clip_index]].round(2)
  comment = "Auto-removed #{prm[:pause_ms]}ms pause"
  markers << {
    name: 'NOTE',
    comment: comment,
    time: tl_time,
    color: 'yellow'
  }
  $stderr.puts "  Auto-removed: #{prm[:pause_ms]}ms pause at timeline #{tl_time}s"
end

# === Add "tighten manually" markers for below-threshold internal pauses ===
if long_pauses || speech_analysis_cache.any?
  clip_source_ranges.each_with_index do |csr, i|
    # Use per-source pauses if available, else global
    source_pauses = if csr[:source] && speech_analysis_cache[csr[:source]]
      speech_analysis_cache[csr[:source]][:long_pauses]
    else
      long_pauses
    end
    next unless source_pauses

    source_pauses.each do |p|
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
# TIER 0: NARRATIVE ROLE INDICATOR MARKERS
# =============================================================================
# Point markers at each clip's start position, colored by narrative_role.
# Provides visual role identification in the timeline without relying on
# Premiere's <labels> system (which ties to source media, not instances).
# =============================================================================
tier0_role_markers.each do |rm|
  markers << {
    name: rm[:role].upcase,
    comment: "Role: #{rm[:role]}",
    time: rm[:time],
    color: ROLE_MARKER_FCP_COLOR[rm[:role]],
    pproColor: ROLE_MARKER_PPRO[rm[:role]]
  }
end
$stderr.puts "Tier 0 (role indicators): #{tier0_role_markers.size} markers" if tier0_role_markers.any?

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
#   Suggestions:   Cyan   = 4292131840
#   Reference:     Grey   = 4286611584
# =============================================================================

PPRO_HOOK     = 4279486782
PPRO_SECTION  = 4280578025
PPRO_PIVOT    = 4289734556
PPRO_REVEAL   = 4281678309
PPRO_CLOSE    = 4294153761
PPRO_ACTION   = 4281719037
PPRO_TRANSITION = 4292131840
PPRO_SUGGEST  = 4292131840
PPRO_REFERENCE = 4286611584

# Helper: find timeline position for a classified segment
# source: optional path to scope matching to a specific source file (multi-source support)
def seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync, source: nil)
  seg_t = seg['t'].to_f
  seg_wav_t = has_sync ? seg_t + sync_offset : seg_t

  clip_idx = clip_source_ranges.each_with_index.find { |csr, _|
    next false if source && csr[:source] != source
    seg_wav_t >= csr[:wav_start] - 0.05 && seg_wav_t < csr[:wav_end] + 0.05
  }&.last
  return nil unless clip_idx

  offset_in_clip = seg_wav_t - clip_source_ranges[clip_idx][:wav_start]
  (timeline_positions[clip_idx] + offset_in_clip).round(2)
end

def seg_end_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync, source: nil)
  seg_e = seg['e'].to_f
  seg_wav_e = has_sync ? seg_e + sync_offset : seg_e

  clip_idx = clip_source_ranges.each_with_index.find { |csr, _|
    next false if source && csr[:source] != source
    seg_wav_e >= csr[:wav_start] - 0.05 && seg_wav_e <= csr[:wav_end] + 0.5
  }&.last
  return nil unless clip_idx

  offset_in_clip = seg_wav_e - clip_source_ranges[clip_idx][:wav_start]
  (timeline_positions[clip_idx] + offset_in_clip).round(2)
end

tier1_markers = []
tier2_markers = []
tier3_markers = []

# === TIER 1: Chapter-driven SECTION markers (from arrangement) ===
chapters_used = false
if config['chapters'] && config['chapters'].is_a?(Array) && config['chapters'].any?
  # Compute chapter timeline ranges from V1 input clip durations
  # V1 clips are sequential in the input array; each has video_start/video_end
  v1_input_clips = config['clips'].select { |c| (c['track'] || 'V1').upcase == 'V1' }
  v1_durations = v1_input_clips.map { |c| c['video_end'].to_f - c['video_start'].to_f }

  chapters_used = true
  config['chapters'].each do |ch|
    label = ch['label'] || ch['id'] || 'untitled'
    v1_start_idx = ch['v1_clip_start'].to_i
    v1_end_idx = ch['v1_clip_end'].to_i
    next if v1_start_idx > v1_end_idx || v1_end_idx >= v1_durations.size

    # Chapter timeline start = sum of V1 durations before this chapter
    tl_start = v1_durations[0...v1_start_idx].sum
    # Chapter timeline end = sum of V1 durations through last clip of this chapter
    tl_end = v1_durations[0..v1_end_idx].sum
    next if tl_end <= tl_start

    tier1_markers << {
      name: "SECTION: #{label}",
      comment: "Chapter #{ch['id']} | V1 clips #{v1_start_idx + 1}–#{v1_end_idx + 1}",
      time: tl_start,
      out_time: tl_end,
      color: 'orange',
      pproColor: PPRO_SECTION
    }
  end
  $stderr.puts "Chapter SECTION markers: #{tier1_markers.size}" if tier1_markers.any?
end

# === Build segment → source lookup (multi-source support) ===
# Classification segments use 't'/'e' timestamps matching arrangement clip video_start/video_end.
# Build a lookup so seg_to_timeline can scope to the correct source file.
seg_source_lookup = {}
if has_per_clip_paths
  config['clips'].each do |c|
    seg_source_lookup[c['video_start'].to_f.round(2)] = c['video_path'] if c['video_path']
  end
end

# === TIER 1: Structure Markers (from classification) ===
# Only generated when classification segments are available (arranged segments)

if classification_segments && !classification_segments.empty?
  # Map arranged segments to timeline positions
  arranged = classification_segments.map { |seg|
    seg_source = seg_source_lookup[seg['t'].to_f.round(2)]
    tl_start = seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync, source: seg_source)
    tl_end = seg_end_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync, source: seg_source)
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

    # SECTIONS from template beats (if available) — skip if chapter-driven sections already exist
    if chapters_used
      # Chapter labels already provide SECTION markers; skip classification-based sections
    elsif template_match_data && template_match_data['matched_beats']
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
      seg_source = seg_source_lookup[seg['t'].to_f.round(2)]
      tl_start = seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync, source: seg_source)
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

# === CHECKLIST: Production design suggestions from edit patterns ===
checklist_markers = []
unless markers_only_structure
  if edit_patterns && classification_segments && !classification_branch_a
    video_patterns = edit_patterns['video_overlay_patterns'] || []

    classification_segments.each do |seg|
      seg_source = seg_source_lookup[seg['t'].to_f.round(2)]
      tl_time = seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync, source: seg_source)
      next unless tl_time

      matching_patterns = []

      video_patterns.each do |pattern|
        trigger = pattern['trigger'] || ''
        if trigger.start_with?('narrative_role = ')
          role = trigger.sub('narrative_role = ', '')
          matching_patterns << pattern if seg['narrative_role'] == role
        elsif trigger.start_with?('dur = ')
          dur_val = trigger.sub('dur = ', '')
          matching_patterns << pattern if seg['dur'] == dur_val
        end
      end

      matching_patterns.each do |pattern|
        freq = pattern['frequency'] || '?'
        dur_s = pattern['typical_duration'] ? "~#{pattern['typical_duration']}s" : ''
        note = pattern['note'] || pattern['trigger']
        checklist_markers << {
          name: "SUGGEST: #{note}",
          comment: "Production pattern: #{pattern['trigger']} | #{freq} past edits | #{dur_s} typical | \"#{seg['distillation']}\"",
          time: tl_time,
          color: 'blue',
          pproColor: PPRO_SUGGEST
        }
      end
    end
  end
end
$stderr.puts "Checklist (suggestions): #{checklist_markers.size} markers" if checklist_markers.any?

# === TIER 3: Reference Markers (per-segment classification) ===
# Suppressed by --no-emotion-markers or --markers-only-structure

tier3_count = 0
unless no_emotion_markers || markers_only_structure
  if classification_segments && !classification_branch_a
    classification_segments.each do |seg|
      seg_source = seg_source_lookup[seg['t'].to_f.round(2)]
      tl_time = seg_to_timeline(seg, clip_source_ranges, timeline_positions, sync_offset, has_sync, source: seg_source)
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
markers = tier1_markers + tier2_markers + checklist_markers + markers + tier3_markers

if removed_pause_count > 0
  $stderr.puts "Pause removal: #{removed_pause_count} pauses removed (#{(total_removed_ms / 1000.0).round(1)}s total)"
end

# === Generate base XML ===
FileUtils.mkdir_p(output_dir)
generator = ButterCut.new(clips, editor: editor, markers: markers, name: config['name'])
base_xml = generator.to_xml

# === Post-process: add sync audio track if present ===
# Per-clip sync: wav_clip_info entries carry their own wav_path + wav_offset.
# Non-synced clips have nil entries. Track is emitted if ANY clip has sync.
any_sync = wav_clip_info.any? { |wi| wi }
if any_sync
  doc = Nokogiri::XML(base_xml)

  # Probe unique WAV files for metadata (cache per path)
  wav_file_metadata = {}
  wav_clip_info.each do |wi|
    next unless wi
    wpath = wi[:wav_path]
    next if wav_file_metadata.key?(wpath)
    wav_info_raw = `ffprobe -v error -show_entries format=duration -show_entries stream=sample_rate,bits_per_sample,channels -of json #{Shellwords.escape(wpath)}`
    wm = JSON.parse(wav_info_raw)
    wav_dur_s = wm['format']['duration'].to_f
    ws = wm['streams']&.find { |s| s['codec_type'] == 'audio' } || {}
    wav_file_metadata[wpath] = {
      duration_frames: (wav_dur_s * fps).round,
      sample_rate: ws['sample_rate'] || '48000',
      bit_depth: ws['bits_per_sample'] || 16,
      channels: ws['channels'] || 2,
      pathurl: "file://#{wpath.gsub(' ', '%20')}",
      basename: File.basename(wpath, File.extname(wpath)),
      filename: File.basename(wpath)
    }
  end

  audio_node = doc.at_xpath('//sequence/media/audio')
  track_node = Nokogiri::XML::Node.new('track', doc)

  # Track which WAV file IDs have been emitted (first ref gets full <file>)
  emitted_file_ids = {}

  # Single source of truth for seconds->frames: replicate fcp7.rb's
  # frames_for_fraction(seconds_to_fraction(seconds), "1/fps s") exactly so
  # video, in-camera audio, and WAV clipitems all produce identical integer
  # frame counts for the same float seconds. Direct (seconds * fps).round
  # diverges from the rational path on boundary cases (15/303 clips for
  # Dylan005, accumulating 16 frames of A/V drift over 38 minutes).
  fcp7_seconds_to_frames = ->(seconds) {
    return 0 if seconds.nil? || seconds == 0
    abort "BUG: fcp7_seconds_to_frames received negative value (#{seconds}s) — caller must pass absolute time or duration" if seconds < 0
    numerator = (seconds * 10000).round
    ((numerator * fps).to_f / 10000.0).round
  }

  # Cumulative timeline position must sum *rounded* per-clip durations, not
  # float seconds rounded at the end — otherwise the WAV timeline drifts away
  # from the video timeline by the same fractional accumulation.
  wav_cumulative_tl_frames = 0
  wav_clip_count = 0

  wav_clip_info.each_with_index do |wi, i|
    # For non-synced V1 clips, advance timeline accumulator but emit no A2 clip
    unless wi
      if i < clips.size && (!clips[i].key?(:video_track) || clips[i][:video_track] == 1)
        tl_duration_frames = fcp7_seconds_to_frames.call(clips[i][:duration])
        wav_cumulative_tl_frames += tl_duration_frames
      end
      next
    end

    wav_clip_count += 1
    wpath  = wi[:wav_path]
    wmeta  = wav_file_metadata[wpath]

    tl_duration_frames = fcp7_seconds_to_frames.call(wi[:wav_duration])
    tl_start_frames    = wav_cumulative_tl_frames
    tl_end_frames      = tl_start_frames + tl_duration_frames

    # wav_start is already the correct source position within the WAV file,
    # computed in the clip loop as: (video_start + sync_offset) - BREATHING_MARGIN.
    # Use it directly — no need to undo/redo the offset in frame domain.
    src_in_frames  = fcp7_seconds_to_frames.call(wi[:wav_start])
    src_out_frames = src_in_frames + tl_duration_frames

    wav_cumulative_tl_frames += tl_duration_frames

    clip_node = Nokogiri::XML::Node.new('clipitem', doc)
    clip_node['id'] = "clipitem-wav-#{wav_clip_count}"
    clip_node.add_child("<name>#{wmeta[:basename]}</name>")
    clip_node.add_child("<enabled>TRUE</enabled>")
    clip_node.add_child("<duration>#{tl_duration_frames}</duration>")
    clip_node.add_child("<start>#{tl_start_frames}</start>")
    clip_node.add_child("<end>#{tl_end_frames}</end>")
    clip_node.add_child("<in>#{src_in_frames}</in>")
    clip_node.add_child("<out>#{src_out_frames}</out>")

    file_id = emitted_file_ids[wpath]
    if file_id
      file_xml = "<file id=\"#{file_id}\"/>"
    else
      file_id = "file-wav-#{emitted_file_ids.size + 1}"
      emitted_file_ids[wpath] = file_id
      file_xml = <<~XML
        <file id="#{file_id}">
          <name>#{wmeta[:filename]}</name>
          <pathurl>#{wmeta[:pathurl]}</pathurl>
          <rate><timebase>#{fps}</timebase><ntsc>FALSE</ntsc></rate>
          <duration>#{wmeta[:duration_frames]}</duration>
          <media>
            <audio>
              <samplecharacteristics>
                <samplerate>#{wmeta[:sample_rate]}</samplerate>
                <sampledepth>#{wmeta[:bit_depth]}</sampledepth>
              </samplecharacteristics>
            </audio>
          </media>
        </file>
      XML
    end
    clip_node.add_child(file_xml)
    clip_node.add_child("<sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>")
    clip_node.add_child("<channelcount>#{wmeta[:channels]}</channelcount>")
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
v1_clips = clips.reject { |c| c.key?(:video_track) && c[:video_track] > 1 }
v2_plus_clips = clips.select { |c| c.key?(:video_track) && c[:video_track] > 1 }
total_duration = v1_clips.sum { |c| c[:duration] }
mins = (total_duration / 60).floor
secs = (total_duration % 60).round

puts output_path
$stderr.puts "Structure cut generated: #{output_path}"
summary = "Duration: #{mins}:#{format('%02d', secs)} | Clips: #{clips.length} (V1: #{v1_clips.size}#{v2_plus_clips.any? ? ", V2+: #{v2_plus_clips.size}" : ''}) | Markers: #{markers.length}"
summary += " (T1:#{tier1_markers.size} T2:#{tier2_markers.size} T3:#{tier3_count})" if tier1_markers.any? || tier2_markers.any? || tier3_count > 0
summary += " | Pauses removed: #{removed_pause_count} (#{(total_removed_ms / 1000.0).round(1)}s)" if removed_pause_count > 0
$stderr.puts summary
if any_sync
  unique_wavs = wav_clip_info.compact.map { |wi| wi[:wav_path] }.uniq
  if unique_wavs.size == 1
    $stderr.puts "Sync audio: #{File.basename(unique_wavs.first)} (offset: #{wav_clip_info.compact.first[:wav_offset]}s)"
  else
    $stderr.puts "Sync audio: #{unique_wavs.size} WAV sources (multi-source)"
    unique_wavs.each { |wp| $stderr.puts "  #{File.basename(wp)}" }
  end
  $stderr.puts "Track 1: scratch audio (mute) | Track 2: production audio"
end

