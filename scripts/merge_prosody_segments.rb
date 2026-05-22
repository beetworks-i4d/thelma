#!/usr/bin/env ruby
# Aggregates per-word prosody data into per-segment summaries in segments_classified.yaml.
#
# Usage: ruby scripts/merge_prosody_segments.rb <segments_classified.yaml> <prosody.yaml>
#
# For each segment, computes:
#   stumble_count, mid_word_break_count, mean_trailing_pause_ms, max_within_segment_pause_ms

require 'yaml'
require 'date'

classified_yaml = ARGV[0]
prosody_yaml = ARGV[1]

abort "Usage: ruby scripts/merge_prosody_segments.rb <segments_classified.yaml> <prosody.yaml>" unless classified_yaml && prosody_yaml
abort "Segments not found: #{classified_yaml}" unless File.exist?(classified_yaml)
abort "Prosody not found: #{prosody_yaml}" unless File.exist?(prosody_yaml)

classified = YAML.safe_load(File.read(classified_yaml), permitted_classes: [Date])
prosody = YAML.safe_load(File.read(prosody_yaml), permitted_classes: [Date])

segments = classified['segments']
unless segments && !segments.empty?
  $stderr.puts "No segments in #{classified_yaml}, nothing to merge"
  exit 0
end

# Collect all words from all videos into one sorted array
all_words = []
prosody.each_value do |vid_data|
  next unless vid_data.is_a?(Hash) && vid_data['words']
  all_words.concat(vid_data['words'])
end
all_words.sort_by! { |w| w['start'].to_f }

if all_words.empty?
  $stderr.puts "No prosody words found, nothing to merge"
  exit 0
end

merged_count = 0
segments.each do |seg|
  t = seg['t'].to_f
  e = seg['e'].to_f

  # Find words within this segment's time window
  seg_words = all_words.select { |w| w['start'].to_f >= t && w['end'].to_f <= e }

  seg['stumble_count'] = seg_words.count { |w| w['stumble_marker'] }
  seg['mid_word_break_count'] = seg_words.count { |w| w['mid_word_break'] }

  trailing = seg_words.filter_map { |w| w['trailing_pause_ms'] }
  seg['mean_trailing_pause_ms'] = trailing.any? ? (trailing.sum.to_f / trailing.size).round : 0

  # Max gap between consecutive words within the segment
  if seg_words.size > 1
    sorted = seg_words.sort_by { |w| w['start'].to_f }
    max_gap = 0
    sorted.each_cons(2) do |a, b|
      gap_ms = ((b['start'].to_f - a['end'].to_f) * 1000).round
      max_gap = gap_ms if gap_ms > max_gap
    end
    seg['max_within_segment_pause_ms'] = max_gap
  else
    seg['max_within_segment_pause_ms'] = 0
  end

  merged_count += 1
end

File.write(classified_yaml, YAML.dump(classified))
$stderr.puts "Merged prosody summaries into #{merged_count} segments"
