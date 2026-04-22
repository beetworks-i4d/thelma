#!/usr/bin/env ruby
# Exports an arrangement.yaml to a Premiere Pro XML via build_structure_cut.rb
#
# Usage: ruby scripts/export_arrangement_xml.rb --library <name>
#
# Reads: libraries/<name>/arrangement.yaml
# Produces: libraries/<name>/output/<name>_arrangement_<timestamp>.xml
#
# Maps arrangement clips → structure cut YAML with:
#   - V1 clips sequential (no timeline_offset)
#   - V2+ clips positioned at the V1 timeline offset where their chapter starts
#   - Speech analysis for pause removal at natural boundaries

require 'yaml'
require 'json'
require 'fileutils'
require 'date'
require 'tmpdir'

SCRIPT_DIR = File.dirname(__FILE__)
BUILD_SCRIPT = File.join(SCRIPT_DIR, 'build_structure_cut.rb')

# === Parse CLI ===
library_name = nil
profile_name = nil
if (idx = ARGV.index('--library'))
  library_name = ARGV[idx + 1]
end
if (idx = ARGV.index('--profile'))
  profile_name = ARGV[idx + 1]
end
abort "Usage: ruby scripts/export_arrangement_xml.rb --library <name> [--profile <name>]" unless library_name

lib_dir = File.join(SCRIPT_DIR, '..', 'libraries', library_name)
abort "Library not found: #{lib_dir}" unless File.directory?(lib_dir)

arrangement_path = File.join(lib_dir, 'arrangement.yaml')
abort "arrangement.yaml not found in #{lib_dir}" unless File.exist?(arrangement_path)

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

# === Build clips from arrangement chapters ===
# V1 clips are sequential. V2+ clips get timeline_offset set to the
# V1 timeline position at the start of their parent chapter.
v1_clips = []
v2_clips = []
chapter_meta = []

arrangement['chapters'].each do |chapter|
  # Record V1 timeline position at chapter start (with breathing room buffers)
  # build_structure_cut.rb adds ~3 frames buffer at each cut boundary
  breathing_room_per_cut = 6.0 / 24.0  # 3 frames in + 3 frames out per cut
  v1_raw_duration = v1_clips.sum { |c| c['video_end'] - c['video_start'] }
  v1_buffer_total = v1_clips.size > 0 ? (v1_clips.size - 1) * breathing_room_per_cut : 0.0
  chapter_v1_start = v1_raw_duration + v1_buffer_total
  v1_clip_start_idx = v1_clips.size

  chapter['clips'].each do |clip|
    track = (clip['track'] || 'V1').upcase

    # Resolve per-clip source path from arrangement's source filename
    clip_source = clip['source']
    if clip_source
      clip_video_path = video_path_lookup[clip_source]
      abort "Unknown source '#{clip_source}' — not in library.yaml videos" unless clip_video_path
    else
      clip_video_path = video_path  # fallback to first video (single-source compat)
    end

    video_end = clip['t_out'].to_f

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

    clip_entry = {
      'video_start' => clip['t_in'].to_f,
      'video_end' => video_end,
      'track' => track,
      'video_path' => clip_video_path
    }

    # Pass through ingest trim fields
    clip_entry['trim_in'] = clip['trim_in'].to_f if clip['trim_in']
    clip_entry['mid_cuts'] = clip['mid_cuts'] if clip['mid_cuts']

    # Pass through narrative role for clip color coding
    clip_entry['narrative_role'] = clip['narrative_role'] if clip['narrative_role']

    if track == 'V1'
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
    'label' => chapter['label'],
    'v1_clip_start' => v1_clip_start_idx,
    'v1_clip_end' => v1_clips.size - 1
  }
end

# Interleave: V1 clips first (sequential), then V2 clips (each with explicit offset)
all_clips = v1_clips + v2_clips

# === Determine output directory (RAW project folder, not library) ===
video_dir = File.dirname(video_path)
output_dir = File.join(video_dir, 'output')
FileUtils.mkdir_p(output_dir)

config = {
  'video_path' => video_path,  # fallback for single-source; per-clip video_path takes priority
  'output_dir' => output_dir,
  'editor' => 'fcp7',
  'name' => "#{library_name}_arrangement",
  'clips' => all_clips,
  'chapters' => chapter_meta
}

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
