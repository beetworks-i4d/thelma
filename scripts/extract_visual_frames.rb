#!/usr/bin/env ruby
# Extract Visual Frames — Extracts one frame per scene change for Claude Vision analysis.
# Reads scene_changes.yaml and uses FFmpeg to extract JPG frames at those timestamps.
#
# Usage:
#   ruby scripts/extract_visual_frames.rb --library <name> --video <video_path>
#
# Fallback: If scene_changes.yaml has ≤1 scene change (static talking head),
# extracts 3 frames (start, middle, end) instead.
#
# Output: visual_frames.yaml listing frame paths and timestamps.

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

args = ARGV.dup
while args.any?
  case args.first
  when '--library'
    args.shift
    library_name = args.shift
  when '--video'
    args.shift
    video_path = args.shift
  else
    args.shift
  end
end

unless library_name && video_path
  $stderr.puts "Usage: ruby scripts/extract_visual_frames.rb --library <name> --video <video_path>"
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

# --- Get video duration via FFprobe ---

def get_video_duration(path)
  cmd = ['ffprobe', '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0', path]
  stdout, _, status = Open3.capture3(*cmd)
  return 0 unless status.success?
  stdout.strip.to_f
end

duration = get_video_duration(video_path)
if duration <= 0
  $stderr.puts "ERROR: Could not determine video duration"
  exit 1
end

# --- Load scene changes ---

scene_changes_path = File.join(library_dir, 'scene_changes.yaml')
scene_data = nil
scene_timestamps = []

if File.exist?(scene_changes_path)
  scene_data = YAML.safe_load(File.read(scene_changes_path), permitted_classes: [Date])

  # Multi-source: find this video's scene data from sources array
  video_basename = File.basename(video_path)
  if scene_data['sources']
    source_entry = scene_data['sources'].find { |s| s['source'] == video_basename }
    if source_entry
      scene_timestamps = source_entry['sampled_timestamps'] || source_entry['timestamps'] || []
      $stderr.puts "Loaded #{scene_timestamps.size} scene timestamps for #{video_basename}"
    else
      $stderr.puts "WARNING: No scene data for #{video_basename} — using fallback"
    end
  else
    # Single-source / legacy format
    scene_timestamps = scene_data['sampled_timestamps'] || scene_data['timestamps'] || []
    $stderr.puts "Loaded #{scene_timestamps.size} scene timestamps"
  end
else
  $stderr.puts "WARNING: scene_changes.yaml not found — using fallback frame extraction"
end

# --- Determine extraction strategy ---

def fallback_timestamps(duration)
  # Static talking head: start, middle, end
  start_t = [2.0, duration * 0.05].min
  mid_t = duration / 2.0
  end_t = [duration - 2.0, duration * 0.95].max
  [start_t.round(3), mid_t.round(3), end_t.round(3)]
end

if scene_timestamps.size <= 1
  # Static or single-scene video: use 3-frame fallback
  extraction_timestamps = fallback_timestamps(duration)
  strategy = 'fallback_3_frame'
  $stderr.puts "Strategy: fallback (≤1 scene change) — extracting 3 frames"
else
  # Scene-driven extraction
  extraction_timestamps = scene_timestamps.map { |t| t.to_f.round(3) }
  strategy = scene_timestamps.size > 50 ? 'clustered' : 'scene_driven'
  $stderr.puts "Strategy: #{strategy} — extracting #{extraction_timestamps.size} frames"
end

# --- Check cache ---

visual_frames_path = File.join(library_dir, 'visual_frames.yaml')
video_hash = Digest::MD5.hexdigest("#{video_path}:#{File.size(video_path)}")
scene_hash = scene_data ? Digest::MD5.hexdigest(scene_data.to_yaml) : 'no_scene_data'
cache_key = "#{video_hash}:#{scene_hash}"

if File.exist?(visual_frames_path)
  existing = YAML.safe_load(File.read(visual_frames_path), permitted_classes: [Date])
  if existing && existing['cache_key'] == cache_key
    $stderr.puts "Visual frames already extracted (cached)"
    puts visual_frames_path
    exit 0
  end
end

# --- Extract frames via FFmpeg ---

frames_dir = File.join(library_dir, 'frames')
FileUtils.mkdir_p(frames_dir)

# Clean old frames
Dir.glob(File.join(frames_dir, 'frame_*.jpg')).each { |f| File.delete(f) }

frames = []
extraction_timestamps.each_with_index do |ts, idx|
  # Clamp to valid range
  ts = [[ts, 0.0].max, duration - 0.1].min

  frame_filename = "frame_%04d_%.3f.jpg" % [idx, ts]
  frame_path = File.join(frames_dir, frame_filename)

  # Format timestamp for FFmpeg
  hours = (ts / 3600).to_i
  mins = ((ts % 3600) / 60).to_i
  secs = ts % 60
  ts_str = "%02d:%02d:%06.3f" % [hours, mins, secs]

  cmd = [
    'ffmpeg', '-y', '-ss', ts_str, '-i', video_path,
    '-frames:v', '1', '-q:v', '2',
    '-vf', 'scale=1280:-1',
    frame_path
  ]

  _, stderr, status = Open3.capture3(*cmd)
  if status.success? && File.exist?(frame_path) && File.size(frame_path) > 0
    frames << {
      'index' => idx,
      'timestamp' => ts,
      'path' => frame_path,
      'filename' => frame_filename
    }
  else
    $stderr.puts "  WARNING: Failed to extract frame at #{ts}s"
  end
end

$stderr.puts "Extracted #{frames.size}/#{extraction_timestamps.size} frames"

if frames.empty?
  $stderr.puts "ERROR: No frames extracted"
  exit 1
end

# --- Write output ---

output = {
  'library' => library_name,
  'video' => File.basename(video_path),
  'video_path' => video_path,
  'duration' => duration.round(3),
  'strategy' => strategy,
  'frame_count' => frames.size,
  'cache_key' => cache_key,
  'generated' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'frames' => frames
}

File.write(visual_frames_path, output.to_yaml)

$stderr.puts "Visual frames written: #{visual_frames_path}"
puts visual_frames_path
