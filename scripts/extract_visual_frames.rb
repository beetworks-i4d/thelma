#!/usr/bin/env ruby
# Extract Visual Frames — Per-shot frame sampling for visual analysis.
#
# Reads scene data to build shot boundaries, extracts 3 representative frames
# per shot (opening, midpoint, closing), and writes a visual_analysis.yaml
# with the full per-shot schema (classification fields null until Session 2).
#
# Usage:
#   ruby scripts/extract_visual_frames.rb --library <name> --video <video_path>
#                                         [--scene-file <path>] [--force]
#
# --scene-file: path to per-source scene YAML (mine mode). Without this, reads
#               library-level scene_changes.yaml.
# --force:      regenerate even if cached visual_analysis.yaml exists.
#
# Output: transcripts/<basename>_visual_analysis.yaml + visual_frames/<basename>/*.jpg

require 'yaml'
require 'date'
require 'digest'
require 'open3'
require 'fileutils'
require_relative 'library_resolver'

ROOT_DIR = File.expand_path('..', __dir__)

# --- CLI parsing ---

library_name = nil
video_path = nil
scene_file = nil
force = false

args = ARGV.dup
while args.any?
  case args.first
  when '--library'
    args.shift
    library_name = args.shift
  when '--video'
    args.shift
    video_path = args.shift
  when '--scene-file'
    args.shift
    scene_file = args.shift
  when '--force'
    args.shift
    force = true
  else
    args.shift
  end
end

unless library_name && video_path
  $stderr.puts "Usage: ruby scripts/extract_visual_frames.rb --library <name> --video <video_path> [--scene-file <path>] [--force]"
  exit 1
end

unless File.exist?(video_path)
  $stderr.puts "ERROR: Video file not found: #{video_path}"
  exit 1
end

library_dir = LibraryResolver.resolve(library_name)
unless File.directory?(library_dir)
  $stderr.puts "ERROR: Library not found: #{library_dir}"
  exit 1
end

video_basename = File.basename(video_path)
src_basename = File.basename(video_path, File.extname(video_path))

transcripts_dir = File.join(library_dir, 'transcripts')
FileUtils.mkdir_p(transcripts_dir)

# --- Get video metadata via FFprobe ---

def probe_value(path, entry)
  cmd = ['ffprobe', '-v', 'quiet', '-show_entries', entry, '-of', 'csv=p=0', path]
  stdout, _, status = Open3.capture3(*cmd)
  return nil unless status.success?
  stdout.strip
end

duration = (probe_value(video_path, 'format=duration') || '0').to_f
if duration <= 0
  $stderr.puts "ERROR: Could not determine video duration"
  exit 1
end

fps_str = probe_value(video_path, 'stream=r_frame_rate')
fps = if fps_str && fps_str.include?('/')
  num, denom = fps_str.split('/').map(&:to_f)
  denom > 0 ? (num / denom).round(2) : 25.0
else
  25.0
end

# --- Load scene changes ---

scene_data = nil
scene_timestamps = []

# Priority: --scene-file flag > library-level scene_changes.yaml
scene_sources = [
  scene_file,
  File.join(library_dir, 'scene_changes.yaml')
].compact

scene_sources.each do |spath|
  next unless File.exist?(spath)
  scene_data = YAML.safe_load(File.read(spath), permitted_classes: [Date])
  break unless scene_data

  # Multi-source format: find this video's entry
  if scene_data['sources']
    entry = scene_data['sources'].find { |s| s['source'] == video_basename }
    if entry
      scene_timestamps = entry['sampled_timestamps'] || entry['timestamps'] || []
    end
  else
    # Single-source / per-source format
    scene_timestamps = scene_data['sampled_timestamps'] || scene_data['timestamps'] || []
  end
  break if scene_timestamps.any?
end

scene_timestamps = scene_timestamps.map { |t| t.to_f }.sort

$stderr.puts scene_timestamps.size > 1 ?
  "Loaded #{scene_timestamps.size} scene timestamps for #{video_basename}" :
  "WARNING: ≤1 scene timestamp — treating as single shot"

# --- Build shot boundaries ---

def build_shots(timestamps, duration)
  # Ensure 0.0 is included as the first shot start
  timestamps = [0.0] + timestamps.reject { |t| t <= 0.0 }
  timestamps = timestamps.sort.uniq

  shots = timestamps.each_with_index.map do |t_start, i|
    t_end = i < timestamps.size - 1 ? timestamps[i + 1] : duration
    # Skip degenerate shots (< 0.1s)
    next nil if (t_end - t_start) < 0.1
    {
      't_start' => t_start.round(3),
      't_end'   => t_end.round(3),
      'shot_id' => "s%03d" % (i + 1)
    }
  end.compact

  # Fallback: if no valid shots, create single shot spanning entire file
  if shots.empty?
    shots = [{ 't_start' => 0.0, 't_end' => duration.round(3), 'shot_id' => 's001' }]
  end

  shots
end

shots = build_shots(scene_timestamps, duration)
$stderr.puts "Shots: #{shots.size} (from #{scene_timestamps.size} scene boundaries)"

# --- Cache check ---

output_path = File.join(transcripts_dir, "#{src_basename}_visual_analysis.yaml")
frames_dir = File.join(library_dir, 'visual_frames', src_basename)

video_hash = Digest::MD5.hexdigest("#{video_path}:#{File.size(video_path)}")
scene_hash = scene_data ? Digest::MD5.hexdigest(scene_data.to_yaml) : 'no_scene_data'
cache_key = "#{video_hash}:#{scene_hash}"

unless force
  if File.exist?(output_path)
    existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date])
    if existing && existing['cache_key'] == cache_key
      # Verify all frame files exist
      all_frames_exist = (existing['shots'] || []).all? do |shot|
        (shot['frames_sampled'] || []).all? do |f|
          fp = f['frame_path']
          fp && File.exist?(File.join(library_dir, fp))
        end
      end
      if all_frames_exist
        $stderr.puts "Visual analysis cached (#{shots.size} shots)"
        puts output_path
        exit 0
      end
    end
  end
end

# --- Extract frames ---

FileUtils.mkdir_p(frames_dir)
# Clean old frames for this source
Dir.glob(File.join(frames_dir, '*.jpg')).each { |f| File.delete(f) }

def extract_frame(video_path, timestamp, output_path, duration)
  # Clamp to valid range
  ts = [[timestamp, 0.0].max, [duration - 0.05, 0.0].max].min
  hours = (ts / 3600).to_i
  mins = ((ts % 3600) / 60).to_i
  secs = ts % 60
  ts_str = "%02d:%02d:%06.3f" % [hours, mins, secs]

  cmd = [
    'ffmpeg', '-y', '-ss', ts_str, '-i', video_path,
    '-frames:v', '1', '-q:v', '2',
    '-vf', 'scale=1280:-1',
    output_path
  ]
  _, _, status = Open3.capture3(*cmd)
  status.success? && File.exist?(output_path) && File.size(output_path) > 0
end

total_frames = 0
failed_frames = 0

shots.each do |shot|
  t_start = shot['t_start']
  t_end = shot['t_end']
  shot_id = shot['shot_id']
  shot_dur = t_end - t_start

  # Determine sample points: opening, middle, closing
  # For very short shots (< 0.6s), reduce frame count
  sample_points = if shot_dur < 0.3
    # Ultra-short: single frame at midpoint
    [{ 'offset' => shot_dur / 2.0, 'label' => 'f01' }]
  elsif shot_dur < 0.6
    # Short: two frames
    [
      { 'offset' => [0.1, shot_dur * 0.2].max, 'label' => 'f01' },
      { 'offset' => shot_dur - [0.1, shot_dur * 0.2].max, 'label' => 'f02' }
    ]
  else
    # Standard: three frames
    [
      { 'offset' => [0.2, shot_dur * 0.1].max, 'label' => 'f01' },
      { 'offset' => shot_dur / 2.0, 'label' => 'f02' },
      { 'offset' => shot_dur - [0.2, shot_dur * 0.1].max, 'label' => 'f03' }
    ]
  end

  frames_sampled = []
  sample_points.each do |sp|
    t = (t_start + sp['offset']).round(3)
    filename = "#{shot_id}_#{sp['label']}.jpg"
    frame_abs = File.join(frames_dir, filename)
    rel_path = File.join('visual_frames', src_basename, filename)

    if extract_frame(video_path, t, frame_abs, duration)
      frames_sampled << { 't' => t, 'frame_path' => rel_path }
      total_frames += 1
    else
      $stderr.puts "  WARNING: Failed to extract frame at #{t}s for #{shot_id}"
      failed_frames += 1
    end
  end

  shot['frames_sampled'] = frames_sampled
end

$stderr.puts "Extracted #{total_frames} frames (#{failed_frames} failed) across #{shots.size} shots"

if total_frames == 0
  $stderr.puts "ERROR: No frames extracted"
  exit 1
end

# --- Build visual_analysis.yaml ---

output = {
  'source'          => video_basename,
  'source_duration' => duration.round(3),
  'source_fps'      => fps,
  'cache_key'       => cache_key,
  'generated'       => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'shots'           => shots.map do |shot|
    {
      'shot_id'                => shot['shot_id'],
      't_start'                => shot['t_start'],
      't_end'                  => shot['t_end'],
      'shot_type'              => nil,
      'composition'            => nil,
      'camera_motion'          => nil,
      'subject_motion'         => nil,
      'lighting'               => nil,
      'dominant_colors'        => [],
      'text_overlay_present'   => nil,
      'motion_graphic_present' => nil,
      'b_roll_semantic_tag'    => nil,
      'frames_sampled'         => shot['frames_sampled']
    }
  end,
  'pacing' => {
    'shot_duration_distribution' => {
      'mean'     => nil,
      'median'   => nil,
      'variance' => nil,
      'curve'    => nil
    },
    'rhythm_moments' => []
  },
  'b_roll_correlation' => {
    'coverage' => nil,
    'matches'  => []
  },
  'visual_hook' => {
    'first_3_seconds' => nil
  }
}

File.write(output_path, output.to_yaml)

$stderr.puts "Visual analysis: #{output_path}"
$stderr.puts "  #{shots.size} shots, #{total_frames} frames, #{src_basename}"
puts output_path
