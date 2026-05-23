#!/usr/bin/env ruby
# Exports an arrangement.yaml to a Premiere Pro XML via build_structure_cut.rb
#
# Usage: ruby scripts/export_arrangement_xml.rb --library <name> [--profile <name>]
#        [--arrangement <path>] [--output-name <base>]
#
# --arrangement defaults to libraries/<name>/arrangement.yaml.
# --output-name overrides the XML base name (default: <library>_arrangement).
#
# Reads: arrangement YAML (chapters schema — v1 or v2)
# Produces: <project>/output/<output-name>_<timestamp>.xml
#
# Supports two arrangement schemas:
#   v1 (Branch A/D): chapter['clips'] with t_in/t_out, track, narrative_role
#   v2 (Session 3):  chapter['segments'] with seg_id, clip_in/clip_out, source
#
# Maps arrangement → structure cut YAML with:
#   - V1 clips sequential (no timeline_offset)
#   - V2+ clips positioned at the V1 timeline offset where their chapter starts
#   - Speech analysis for pause removal at natural boundaries
#   - Per-chapter markers from arrangement (v2) wired to Premiere markers

require 'yaml'
require 'json'
require 'fileutils'
require 'date'
require 'tmpdir'

AUDIO_ONLY_EXTS_EARXML = %w[.m4a .mp3 .wav .aac].freeze

SCRIPT_DIR = File.dirname(__FILE__)
BUILD_SCRIPT = File.join(SCRIPT_DIR, 'build_structure_cut.rb')
require_relative 'library_resolver'

# === Parse CLI ===
library_name = nil
profile_name = nil
arrangement_override = nil
output_name_override = nil
if (idx = ARGV.index('--library'))
  library_name = ARGV[idx + 1]
end
if (idx = ARGV.index('--profile'))
  profile_name = ARGV[idx + 1]
end
if (idx = ARGV.index('--arrangement'))
  arrangement_override = ARGV[idx + 1]
end
if (idx = ARGV.index('--output-name'))
  output_name_override = ARGV[idx + 1]
end
abort "Usage: ruby scripts/export_arrangement_xml.rb --library <name> [--profile <name>] [--arrangement <path>] [--output-name <name>]" unless library_name

lib_dir = LibraryResolver.resolve(library_name)
abort "Library not found: #{lib_dir}" unless File.directory?(lib_dir)

arrangement_path = arrangement_override || File.join(lib_dir, 'arrangement.yaml')
abort "arrangement YAML not found: #{arrangement_path}" unless File.exist?(arrangement_path)

library_yaml = YAML.safe_load(File.read(File.join(lib_dir, 'library.yaml')), permitted_classes: [Date])
arrangement = YAML.safe_load(File.read(arrangement_path), permitted_classes: [Date])

# === Build filename → absolute path lookup from all videos ===
video_path_lookup = {}
library_yaml['videos'].each do |v|
  abs = File.expand_path(v['path'])
  video_path_lookup[File.basename(abs)] = abs
end

# === Build filename → duration lookup via ffprobe ===
source_duration_lookup = {}
video_path_lookup.each do |filename, abs_path|
  dur_str = `ffprobe -v error -show_entries format=duration -of csv=p=0 "#{abs_path}" 2>/dev/null`.strip
  source_duration_lookup[filename] = dur_str.to_f if dur_str =~ /\d/
end

# First video entry for speech_analysis/transcript (global metadata)
video_entry = library_yaml['videos'].first
video_path = video_entry['path']
abort "Video file not found: #{video_path}" unless File.exist?(video_path)

# === Resolve speech analysis (per-source) ===
speech_analysis_map = {}
library_yaml['videos'].each do |v|
  if v['speech_analysis']
    sa_path = File.join(lib_dir, 'transcripts', v['speech_analysis'])
    speech_analysis_map[File.expand_path(v['path'])] = sa_path if File.exist?(sa_path)
  end
end
# First video's speech analysis as legacy fallback
speech_analysis_path = speech_analysis_map[File.expand_path(video_entry['path'])]

# === Resolve transcripts for restart trimming (per-source) ===
transcript_map = {}
library_yaml['videos'].each do |v|
  if v['transcript']
    t_path = File.join(lib_dir, 'transcripts', v['transcript'])
    transcript_map[File.expand_path(v['path'])] = t_path if File.exist?(t_path)
  end
end
# First video's transcript as legacy fallback for single-source
transcript_path = transcript_map[File.expand_path(video_entry['path'])]

# === Build per-source sync audio lookup ===
# Each source video may have its own sync_audio WAV with a different offset.
# Multi-source arrangements (v2) need per-clip offset for correct conversion.
sync_audio_lookup = {}
library_yaml['videos'].each do |v|
  if v['sync_audio'] && v['sync_audio']['path'] && v['sync_audio']['offset']
    filename = File.basename(v['path'])
    sync_audio_lookup[filename] = {
      'path'   => v['sync_audio']['path'],
      'offset' => v['sync_audio']['offset'].to_f
    }
  end
end

# === Determine time domain for conversion ===
# Arrangement timestamps come from the transcript, which was generated from
# the sync_audio WAV (if present). So arrangement times are in WAV time domain.
# build_structure_cut.rb expects video_start/video_end in video time domain.
# Convert: video_time = wav_time - sync_offset
arr_time_domain = arrangement['time_domain'] || 'wav'
convert_from_wav = false
if sync_audio_lookup.any?
  if arr_time_domain == 'wav'
    convert_from_wav = true
    $stderr.puts "  Time domain: arrangement is WAV time, converting per-source (#{sync_audio_lookup.size} sources with sync_audio)"
  elsif arr_time_domain == 'video'
    $stderr.puts "  Time domain: arrangement is already video time, no conversion needed"
  else
    abort "Unknown time_domain '#{arr_time_domain}' in arrangement.yaml (expected 'wav' or 'video')"
  end
end

# === Detect arrangement schema version ===
# v2 (Session 3): chapters have 'segments' array with seg_id, clip_in, clip_out
# v1 (Branch A/D): chapters have 'clips' array with t_in, t_out, track
first_chapter = (arrangement['chapters'] || []).first
is_v2 = first_chapter && first_chapter.key?('segments')
$stderr.puts "  Arrangement schema: #{is_v2 ? 'v2 (Session 3)' : 'v1 (legacy)'}"

# === Marker category → Premiere color mapping (CLAUDE.md spec) ===
MARKER_CATEGORY_COLOR = {
  'TITLE'      => 'blue',
  'B-ROLL'     => 'green',
  'TRANSITION' => 'orange',
  'SFX'        => 'purple',
  'MUSIC'      => 'red',
  'NOTE'       => 'yellow'
}.freeze

# === Build clips from arrangement chapters ===
# V1 clips are sequential. V2+ clips get timeline_offset set to the
# V1 timeline position at the start of their parent chapter.
v1_clips = []
v2_clips = []
chapter_meta = []
# Track seg_id → V1 clip index for resolving marker at_seg references
seg_id_to_clip_idx = {}
# Collect arrangement markers (v2) for post-processing once all clips are built
arrangement_markers_raw = []

arrangement['chapters'].each do |chapter|
  # Record V1 timeline position at chapter start (with breathing room buffers)
  # build_structure_cut.rb adds ~3 frames buffer at each cut boundary
  breathing_room_per_cut = 6.0 / 24.0  # 3 frames in + 3 frames out per cut
  v1_raw_duration = v1_clips.sum { |c| c['video_end'] - c['video_start'] }
  v1_buffer_total = v1_clips.size > 0 ? (v1_clips.size - 1) * breathing_room_per_cut : 0.0
  chapter_v1_start = v1_raw_duration + v1_buffer_total
  v1_clip_start_idx = v1_clips.size

  # Normalize: v2 'segments' → unified clip list; v1 'clips' passed through
  raw_clips = if is_v2
    (chapter['segments'] || []).map do |seg|
      {
        'source' => seg['source'],
        't_in'   => seg['clip_in'],
        't_out'  => seg['clip_out'],
        'track'  => 'V1',  # Session 3: all segments default to V1
        'seg_id' => seg['seg_id']
      }
    end
  else
    chapter['clips'] || []
  end

  raw_clips.each do |clip|
    track = (clip['track'] || 'V1').upcase

    # Resolve per-clip source path from arrangement's source filename
    clip_source = clip['source']
    if clip_source
      clip_video_path = video_path_lookup[clip_source]
      abort "Unknown source '#{clip_source}' — not in library.yaml videos" unless clip_video_path
    else
      clip_video_path = video_path  # fallback to first video (single-source compat)
    end

    # Per-source sync offset for time domain conversion
    source_filename = clip_source || File.basename(video_path)
    clip_sync = sync_audio_lookup[source_filename]
    clip_sync_offset = (convert_from_wav && clip_sync) ? clip_sync['offset'] : 0.0

    # Convert from arrangement time domain (WAV) to video time domain
    video_start = clip['t_in'].to_f - clip_sync_offset
    video_end = clip['t_out'].to_f - clip_sync_offset

    # Clamp video_end to source file duration — LLM may produce round-number
    # t_out values that exceed the actual file length, causing black frames
    source_filename = clip_source || File.basename(video_path)
    source_dur = source_duration_lookup[source_filename]
    if source_dur && video_end > source_dur + 0.01  # 10ms tolerance for ffprobe rounding
      overshoot = video_end - source_dur
      clip_idx = v1_clips.size + v2_clips.size + 1
      $stderr.puts "  WARN: clip ##{clip_idx} (source: #{source_filename}) t_out clamped from #{'%.2f' % video_end} to #{'%.2f' % source_dur} (overshoot #{'%.2f' % overshoot}s)"
      video_end = source_dur
    elsif source_dur && video_end > source_dur
      video_end = source_dur  # silent micro-clamp for rounding noise
    end

    # Clamp video_start to 0 — WAV may have started before video
    video_start = 0.0 if video_start < 0

    clip_entry = {
      'video_start' => video_start,
      'video_end'   => video_end,
      'track'       => track,
      'video_path'  => clip_video_path
    }

    # Propagate audio-only media type so build_structure_cut emits audio clipitem only
    if AUDIO_ONLY_EXTS_EARXML.include?(File.extname(clip_video_path.to_s).downcase)
      clip_entry['media_type'] = 'audio_only'
    end

    # v1 pass-through fields (not present in v2 — known limitation for Session 3)
    unless is_v2
      clip_entry['trim_in'] = clip['trim_in'].to_f if clip['trim_in']
      clip_entry['mid_cuts'] = clip['mid_cuts'] if clip['mid_cuts']
      clip_entry['narrative_role'] = clip['narrative_role'] if clip['narrative_role']
      clip_entry['beat_id'] = clip['beat_id'] if clip['beat_id']
    end

    # Pass through chapter identity for diagnostic logs in build_structure_cut
    clip_entry['chapter_id'] = chapter['id'] if chapter['id']

    # Per-clip sync audio for multi-source WAV track
    if clip_sync
      clip_entry['sync_audio_path']   = clip_sync['path']
      clip_entry['sync_audio_offset'] = clip_sync['offset']
    end

    if track == 'V1'
      # Track seg_id → clip index for marker resolution
      seg_id_to_clip_idx[clip['seg_id']] = v1_clips.size if clip['seg_id']
      v1_clips << clip_entry
    else
      # V2+ clips: position at chapter start on V1 timeline
      clip_entry['timeline_offset'] = chapter_v1_start
      v2_clips << clip_entry
    end
  end

  # Track V1 clip index range for this chapter (for SECTION markers)
  chapter_meta << {
    'id' => chapter['id'],
    'label' => chapter['title'] || chapter['label'],
    'v1_clip_start' => v1_clip_start_idx,
    'v1_clip_end' => v1_clips.size - 1
  }

  # Collect v2 arrangement markers for post-processing
  if is_v2 && chapter['markers']
    chapter['markers'].each do |m|
      arrangement_markers_raw << m.merge('_chapter_id' => chapter['id'])
    end
  end
end

# Interleave: V1 clips first (sequential), then V2 clips (each with explicit offset)
all_clips = v1_clips + v2_clips

# === Resolve arrangement markers (v2) to timeline positions ===
# Each marker has at_seg → resolve to the V1 clip's timeline start position.
# Timeline position = sum of preceding V1 clip durations + breathing room buffers.
arrangement_markers = []
if arrangement_markers_raw.any?
  # Pre-compute V1 timeline positions (same logic as chapter_v1_start above)
  v1_timeline_positions = []
  cumulative_dur = 0.0
  v1_clips.each_with_index do |c, i|
    v1_timeline_positions << cumulative_dur
    clip_dur = c['video_end'] - c['video_start']
    buffer = i > 0 ? (6.0 / 24.0) : 0.0
    cumulative_dur += clip_dur + buffer
  end

  arrangement_markers_raw.each do |m|
    seg_id = m['at_seg']
    clip_idx = seg_id_to_clip_idx[seg_id] if seg_id
    unless clip_idx
      $stderr.puts "  WARN: marker at_seg '#{seg_id}' not found in arrangement clips — skipping"
      next
    end

    tl_time = v1_timeline_positions[clip_idx] || 0.0
    color = MARKER_CATEGORY_COLOR[m['type']] || 'yellow'

    arrangement_markers << {
      'name'    => m['type'] || 'NOTE',
      'comment' => m['comment'] || '',
      'time'    => tl_time.round(3),
      'color'   => color
    }
  end
  $stderr.puts "  Arrangement markers: #{arrangement_markers.size} (from #{arrangement_markers_raw.size} raw)"
end

# === Determine output directory (RAW project folder, not library) ===
video_dir = File.dirname(video_path)
output_dir = File.join(video_dir, 'output')
FileUtils.mkdir_p(output_dir)

config = {
  'video_path' => video_path,  # fallback for single-source; per-clip video_path takes priority
  'output_dir' => output_dir,
  'editor' => 'fcp7',
  'name' => output_name_override || "#{library_name}_arrangement",
  'clips' => all_clips,
  'chapters' => chapter_meta
}

# Wire arrangement markers (v2) into config for build_structure_cut.rb
if arrangement_markers.any?
  config['markers'] = arrangement_markers
end

# Add speech analysis for natural boundary pause removal
if speech_analysis_path
  config['speech_analysis'] = speech_analysis_path
end

# Add per-source speech analysis map for multi-source boundary snapping
if speech_analysis_map.size > 1
  config['speech_analysis_map'] = speech_analysis_map
end

# Add transcript for in-point restart trimming
if transcript_path
  config['transcript'] = transcript_path
end

# Add per-source transcript map for multi-source restart trimming
if transcript_map.size > 1
  config['transcript_map'] = transcript_map
end

# Add classification for Tier 2/3 markers
classification_path = File.join(lib_dir, 'segments_classified.yaml')
if File.exist?(classification_path)
  config['classification'] = classification_path
end

# Add sync audio (HQ WAV) for dedicated production audio track
if video_entry['sync_audio'] && video_entry['sync_audio']['path']
  sync_audio_path = video_entry['sync_audio']['path']
  if File.exist?(sync_audio_path)
    config['sync_audio'] = {
      'path'   => sync_audio_path,
      'offset' => video_entry['sync_audio']['offset'].to_f
    }
  else
    $stderr.puts "WARNING: sync_audio not found: #{sync_audio_path}"
  end
end

# No max_segment_duration — natural boundaries only
# Pause removal uses profile default (800ms)

# === Write temp YAML and run build_structure_cut.rb ===
Dir.mktmpdir do |tmpdir|
  yaml_path = File.join(tmpdir, 'arrangement_cut.yaml')
  File.write(yaml_path, config.to_yaml)

  cmd = ['ruby', BUILD_SCRIPT, yaml_path]
  cmd += ['--profile', profile_name] if profile_name
  $stderr.puts "Running: #{cmd.join(' ')}"
  $stderr.puts "Clips: #{v1_clips.size} V1, #{v2_clips.size} V2+"

  require 'open3'
  stdout_str, stderr_str, status = Open3.capture3(*cmd)

  $stderr.puts stderr_str unless stderr_str.empty?

  if status.success?
    xml_path = stdout_str.strip
    if xml_path.end_with?('.xml') && File.exist?(xml_path)
      puts xml_path
      $stderr.puts "Export complete: #{xml_path}"
    else
      abort "ERROR: build_structure_cut.rb did not produce XML output"
    end
  else
    abort "ERROR: build_structure_cut.rb failed (exit #{status.exitstatus})"
  end
end
