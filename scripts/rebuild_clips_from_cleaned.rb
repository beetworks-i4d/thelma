#!/usr/bin/env ruby
# Rebuilds a structure cut YAML by splitting clips to exclude segments
# that were removed by transcript_cleanup.rb.
#
# Usage: ruby scripts/rebuild_clips_from_cleaned.rb <structure.yaml> <raw_transcript.json> <cleaned_transcript.json>
#
# Reads the existing YAML clip ranges, finds which raw transcript segments
# within each clip were dropped in the cleaned version, splits clips to
# skip those segments, and writes a new YAML with _cleaned suffix.
#
# Outputs the new YAML path to stdout. Logs changes to stderr.

require 'json'
require 'yaml'
require 'date'

def fmt(seconds)
  m = (seconds / 60).floor
  s = seconds % 60
  format("%02d:%05.2f", m, s)
end

yaml_path = ARGV[0]
raw_path = ARGV[1]
cleaned_path = ARGV[2]

abort "Usage: ruby scripts/rebuild_clips_from_cleaned.rb <structure.yaml> <raw_transcript.json> <cleaned_transcript.json>" unless yaml_path && raw_path && cleaned_path
[yaml_path, raw_path, cleaned_path].each { |p| abort "File not found: #{p}" unless File.exist?(p) }

config = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
raw_data = JSON.parse(File.read(raw_path))
cleaned_data = JSON.parse(File.read(cleaned_path))

raw_segs = raw_data['segments'] || []
cleaned_segs = cleaned_data['segments'] || []

# Build set of dropped segment start times (using start as unique key)
cleaned_starts = cleaned_segs.map { |s| s['start'].round(3) }.to_set
dropped_segs = raw_segs.reject { |s| cleaned_starts.include?(s['start'].round(3)) }
dropped_ranges = dropped_segs.map { |s| { start: s['start'].to_f, end: s['end'].to_f, text: s['text'].to_s.strip } }

$stderr.puts "Dropped segments in transcript: #{dropped_ranges.size}"

original_clips = config['clips'] || []
new_clips = []
changes = 0

original_clips.each_with_index do |clip, idx|
  cs = clip['start'].to_f
  ce = clip['end'].to_f

  # Find dropped segments that overlap with this clip
  overlapping = dropped_ranges.select { |d| d[:start] >= cs - 0.5 && d[:end] <= ce + 0.5 }

  if overlapping.empty?
    new_clips << clip
    next
  end

  # Split the clip around dropped segments
  changes += overlapping.size
  overlapping.sort_by! { |d| d[:start] }

  sub_ranges = []
  current = cs
  overlapping.each do |d|
    # Keep the portion before the dropped segment
    if current < d[:start] - 0.1
      sub_ranges << { 'start' => current.round(2), 'end' => (d[:start] - 0.05).round(2) }
    end
    current = d[:end] + 0.05
    $stderr.puts "  Clip #{idx + 1}: excising #{fmt(d[:start])}-#{fmt(d[:end])} (\"#{d[:text][0..60]}\")"
  end
  # Keep the portion after the last dropped segment
  if current < ce - 0.1
    sub_ranges << { 'start' => current.round(2), 'end' => ce.round(2) }
  end

  sub_ranges.each { |sr| new_clips << sr }
end

if changes == 0
  $stderr.puts "No clips affected by cleanup — YAML unchanged."
  puts yaml_path
  exit 0
end

# Rebuild config
config['clips'] = new_clips

# Adjust marker times proportionally if clip count changed
# (markers are timeline positions — they'll be recomputed by build_structure_cut.rb)

# Compute duration delta
old_dur = original_clips.sum { |c| c['end'].to_f - c['start'].to_f }
new_dur = new_clips.sum { |c| c['end'].to_f - c['start'].to_f }
delta = old_dur - new_dur

$stderr.puts "---"
$stderr.puts "Clips: #{original_clips.size} → #{new_clips.size} | Duration: #{fmt(old_dur)} → #{fmt(new_dur)} (#{'-' if delta > 0}#{fmt(delta.abs)} removed)"

# Write new YAML
dir = File.dirname(yaml_path)
base = File.basename(yaml_path, '.yaml')
output_path = File.join(dir, "#{base}_cleaned.yaml")
File.write(output_path, config.to_yaml)

puts output_path
