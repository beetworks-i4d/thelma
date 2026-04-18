#!/usr/bin/env ruby
# Detect visual scene changes in a video using FFmpeg scene detection.
# Zero token cost — runs locally.
#
# Usage: ruby scripts/detect_scenes.rb <video_path> [--threshold 0.3] [--output scene_changes.yaml]
#        ruby scripts/detect_scenes.rb --library <name>
#
# Output: scene_changes.yaml with timestamps of every visual cut point.

require 'yaml'
require 'open3'
require 'date'

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

# Resolve video from library if --library provided
if library_name
  library_dir = File.expand_path("../../libraries/#{library_name}", __FILE__)
  library_yaml = File.join(library_dir, 'library.yaml')
  abort "Library not found: #{library_dir}" unless File.exist?(library_yaml)
  library = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date])
  video = library['videos']&.first
  abort "No video in library #{library_name}" unless video
  video_path = video['path']
  output_path ||= File.join(library_dir, 'scene_changes.yaml')
end

abort "Usage: ruby scripts/detect_scenes.rb <video_path> [--threshold 0.3] [--output path]\n       ruby scripts/detect_scenes.rb --library <name>" unless video_path
abort "Video not found: #{video_path}" unless File.exist?(video_path)
output_path ||= File.join(File.dirname(video_path), 'scene_changes.yaml')

$stderr.puts "Detecting scenes in #{File.basename(video_path)} (threshold: #{threshold})..."

# --- Run FFmpeg scene detection ---

cmd = [
  'ffmpeg', '-i', video_path,
  '-filter:v', "select='gt(scene,#{threshold})',showinfo",
  '-vsync', 'vfr',
  '-f', 'null', '-'
]

_, stderr_output, status = Open3.capture3(*cmd)

unless status.success?
  # FFmpeg writes to stderr even on success; check for fatal errors
  if stderr_output.include?('No such file') || stderr_output.include?('Invalid data')
    abort "FFmpeg error: #{stderr_output.lines.last(3).join}"
  end
end

# --- Parse scene change timestamps from showinfo output ---

timestamps = []
stderr_output.each_line do |line|
  # showinfo filter outputs lines like:
  # [Parsed_showinfo_1 @ 0x...] n:   0 pts:    600 pts_time:2.4    ...
  if line.include?('pts_time:')
    match = line.match(/pts_time:\s*([\d.]+)/)
    timestamps << match[1].to_f if match
  end
end

# Always include 0.0 as the first scene
timestamps.unshift(0.0) unless timestamps.include?(0.0)
timestamps.sort!
timestamps.uniq!

$stderr.puts "Found #{timestamps.size} scene changes"

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

sampled = cluster_timestamps(timestamps)

# --- Write output ---

result = {
  'source' => File.basename(video_path),
  'source_path' => video_path,
  'scene_threshold' => threshold,
  'total_scenes' => timestamps.size,
  'sampled_scenes' => sampled.size,
  'timestamps' => timestamps.map { |t| t.round(3) },
  'sampled_timestamps' => sampled.map { |t| t.round(3) },
  'generated' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
}

File.write(output_path, result.to_yaml)
$stderr.puts "Scene changes written to #{output_path}"
puts output_path
