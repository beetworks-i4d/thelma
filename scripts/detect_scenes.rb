#!/usr/bin/env ruby
# Detect visual scene changes in a video using FFmpeg scene detection.
# Zero token cost — runs locally.
#
# Usage: ruby scripts/detect_scenes.rb <video_path> [--threshold 0.3] [--output scene_changes.yaml]
#        ruby scripts/detect_scenes.rb --library <name>
#
# Single video: produces scene_changes.yaml with timestamps of every visual cut point.
# Library mode: iterates ALL videos, produces per-source scene data in one file.

require 'yaml'
require 'open3'
require 'date'
require_relative 'library_resolver'

# --- Flag parsing ---

threshold = 0.3
output_path = nil
library_name = nil
video_path = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--threshold'
    args.shift
    threshold = args.shift.to_f
  when '--output'
    args.shift
    output_path = args.shift
  when '--library'
    args.shift
    library_name = args.shift
  else
    video_path = args.shift
  end
end

# --- Cluster nearby timestamps if too many ---
# When > 50 scenes, cluster timestamps within 2s and take one representative per cluster

def cluster_timestamps(timestamps, max_count: 50, window: 2.0)
  return timestamps if timestamps.size <= max_count

  clusters = []
  current_cluster = [timestamps.first]

  timestamps[1..].each do |ts|
    if ts - current_cluster.last <= window
      current_cluster << ts
    else
      clusters << current_cluster
      current_cluster = [ts]
    end
  end
  clusters << current_cluster

  # Take midpoint of each cluster
  representatives = clusters.map { |c| c[c.size / 2] }

  # If still too many after clustering, subsample evenly
  if representatives.size > max_count
    step = representatives.size.to_f / max_count
    representatives = (0...max_count).map { |i| representatives[(i * step).floor] }
  end

  representatives
end

# Detect scenes for a single video file. Returns hash with scene data.
def detect_scenes_for_video(vpath, threshold)
  $stderr.puts "Detecting scenes in #{File.basename(vpath)} (threshold: #{threshold})..."

  cmd = [
    'ffmpeg', '-i', vpath,
    '-filter:v', "select='gt(scene,#{threshold})',showinfo",
    '-vsync', 'vfr',
    '-f', 'null', '-'
  ]

  _, stderr_output, status = Open3.capture3(*cmd)

  unless status.success?
    if stderr_output.include?('No such file') || stderr_output.include?('Invalid data')
      $stderr.puts "FFmpeg error for #{File.basename(vpath)}: #{stderr_output.lines.last(3).join}"
      return nil
    end
  end

  timestamps = []
  stderr_output.each_line do |line|
    if line.include?('pts_time:')
      match = line.match(/pts_time:\s*([\d.]+)/)
      timestamps << match[1].to_f if match
    end
  end

  timestamps.unshift(0.0) unless timestamps.include?(0.0)
  timestamps.sort!
  timestamps.uniq!

  sampled = cluster_timestamps(timestamps)
  $stderr.puts "  #{File.basename(vpath)}: #{timestamps.size} scene changes (#{sampled.size} sampled)"

  {
    'source' => File.basename(vpath),
    'source_path' => vpath,
    'total_scenes' => timestamps.size,
    'sampled_scenes' => sampled.size,
    'timestamps' => timestamps.map { |t| t.round(3) },
    'sampled_timestamps' => sampled.map { |t| t.round(3) }
  }
end

AUDIO_ONLY_EXTS = %w[.m4a .mp3 .wav .aac].freeze

# === Library mode: iterate all videos ===
if library_name
  library_dir = LibraryResolver.resolve(library_name)
  library_yaml = File.join(library_dir, 'library.yaml')
  abort "Library not found: #{library_dir}" unless File.exist?(library_yaml)
  library = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date])

  all_videos = library['videos'] || []
  abort "No videos in library #{library_name}" if all_videos.empty?

  output_path ||= File.join(library_dir, 'scene_changes.yaml')

  sources = []
  all_videos.each do |v|
    vpath = v['path']

    # Skip audio-only sources — no video stream for scene detection
    if vpath && AUDIO_ONLY_EXTS.include?(File.extname(vpath.to_s).downcase)
      $stderr.puts "  Skipping audio-only source: #{File.basename(vpath)}"
      next
    end

    unless vpath && File.exist?(vpath)
      $stderr.puts "  WARNING: Video not found, skipping: #{vpath}"
      next
    end
    scene_data = detect_scenes_for_video(vpath, threshold)
    sources << scene_data if scene_data
  end

  abort "No videos could be processed" if sources.empty?

  # Aggregate stats
  total = sources.sum { |s| s['total_scenes'] }

  result = {
    'scene_threshold' => threshold,
    'total_scenes' => total,
    'sources' => sources,
    'generated' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
  }

  # Backward compat: include first source's flat fields for single-source consumers
  first = sources.first
  result['source'] = first['source']
  result['source_path'] = first['source_path']
  result['sampled_scenes'] = first['sampled_scenes']
  result['timestamps'] = first['timestamps']
  result['sampled_timestamps'] = first['sampled_timestamps']

  File.write(output_path, result.to_yaml)
  $stderr.puts "Scene changes written to #{output_path} (#{sources.size} sources, #{total} total scenes)"
  puts output_path
  exit 0
end

# === Single video mode ===
abort "Usage: ruby scripts/detect_scenes.rb <video_path> [--threshold 0.3] [--output path]\n       ruby scripts/detect_scenes.rb --library <name>" unless video_path
abort "Video not found: #{video_path}" unless File.exist?(video_path)
output_path ||= File.join(File.dirname(video_path), 'scene_changes.yaml')

scene_data = detect_scenes_for_video(video_path, threshold)
abort "Failed to detect scenes in #{video_path}" unless scene_data

result = scene_data.merge(
  'scene_threshold' => threshold,
  'generated' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
)

File.write(output_path, result.to_yaml)
$stderr.puts "Scene changes written to #{output_path}"
puts output_path
