#!/usr/bin/env ruby
# Extract Edit Patterns — Aggregates overlay patterns from parsed finished edits.
# Reads finished_edit_analysis*.yaml files and produces edit_patterns.yaml.
#
# Usage:
#   ruby scripts/extract_edit_patterns.rb --library <name>
#
# NOT part of the standard pipeline. Run manually after parsing finished edits.

require 'yaml'
require 'date'

ROOT_DIR = File.expand_path('..', __dir__)

# --- CLI parsing ---

library_name = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'
    args.shift
    library_name = args.shift
  else
    args.shift
  end
end

unless library_name
  $stderr.puts "Usage: ruby scripts/extract_edit_patterns.rb --library <name>"
  exit 1
end

library_dir = File.join(ROOT_DIR, 'libraries', library_name)
unless File.directory?(library_dir)
  $stderr.puts "ERROR: Library not found: #{library_dir}"
  exit 1
end

# --- Load all finished edit analyses ---

analysis_files = Dir.glob(File.join(library_dir, 'finished_edit_analysis*.yaml')).sort
if analysis_files.empty?
  $stderr.puts "ERROR: No finished_edit_analysis files found in #{library_dir}"
  $stderr.puts "Run parse_finished_edit.rb first."
  exit 1
end

analyses = analysis_files.map { |f| YAML.safe_load(File.read(f), permitted_classes: [Date]) }
$stderr.puts "Loaded #{analyses.size} finished edit analysis file(s)"

# --- Load classified segments for total counts ---

classified_path = File.join(library_dir, 'segments_classified.yaml')
all_classified = nil
if File.exist?(classified_path)
  data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])
  all_classified = data['segments'] || []
end

# --- Aggregate overlay data ---

all_video_overlays = []
all_audio_overlays = []
total_duration = 0.0
total_primary_clips = 0

analyses.each do |a|
  total_duration += a['duration_seconds'].to_f
  total_primary_clips += a['primary_clips'].to_i

  (a['overlay_placements'] || []).each do |p|
    if p['type'] == 'video_overlay'
      all_video_overlays << p
    elsif p['type'] == 'audio_overlay'
      all_audio_overlays << p
    end
  end
end

# --- Video overlay patterns ---

def count_segments_by_field(classified_segments, field)
  counts = Hash.new(0)
  classified_segments&.each do |seg|
    val = seg[field]
    counts[val] += 1 if val
  end
  counts
end

video_patterns = []

# Pattern by narrative_role
role_overlay_counts = Hash.new { |h, k| h[k] = { count: 0, durations: [] } }
all_video_overlays.each do |ov|
  role = ov.dig('underlying_segment', 'narrative_role')
  next unless role
  role_overlay_counts[role][:count] += 1
  role_overlay_counts[role][:durations] << ov['duration'].to_f
end

if all_classified
  role_totals = count_segments_by_field(all_classified, 'narrative_role')
  role_overlay_counts.each do |role, data|
    total = role_totals[role] || data[:count]
    avg_dur = data[:durations].empty? ? 0 : (data[:durations].sum / data[:durations].size).round(1)
    video_patterns << {
      'trigger' => "narrative_role = #{role}",
      'frequency' => "#{data[:count]}/#{total}",
      'typical_duration' => avg_dur,
      'note' => "overlays on #{role} segments"
    }
  end
end

# Pattern by durability
dur_overlay_counts = Hash.new { |h, k| h[k] = { count: 0, durations: [] } }
all_video_overlays.each do |ov|
  dur = ov.dig('underlying_segment', 'dur')
  next unless dur
  dur_overlay_counts[dur][:count] += 1
  dur_overlay_counts[dur][:durations] << ov['duration'].to_f
end

if all_classified
  dur_totals = count_segments_by_field(all_classified, 'dur')
  dur_overlay_counts.each do |dur, data|
    total = dur_totals[dur] || data[:count]
    avg_dur = data[:durations].empty? ? 0 : (data[:durations].sum / data[:durations].size).round(1)
    video_patterns << {
      'trigger' => "dur = #{dur}",
      'frequency' => "#{data[:count]}/#{total}",
      'typical_duration' => avg_dur,
      'note' => "overlays on #{dur} segments"
    }
  end
end

# Sort by frequency (descending)
video_patterns.sort_by! do |p|
  parts = p['frequency'].split('/')
  parts.size == 2 ? -(parts[0].to_f / [parts[1].to_f, 1].max) : 0
end

# --- Audio overlay patterns ---

audio_patterns = []

all_audio_overlays.each do |ov|
  dur = ov['duration'].to_f
  # Full-length bed: duration > 60% of sequence
  if total_duration > 0 && dur > total_duration * 0.6
    audio_patterns << {
      'trigger' => 'full_length_bed',
      'frequency' => "#{all_audio_overlays.count { |a| a['duration'].to_f > total_duration * 0.6 }}/#{analyses.size}",
      'note' => 'continuous music bed'
    }
  end
end

# Deduplicate audio patterns by trigger
audio_patterns.uniq! { |p| p['trigger'] }

# Short audio overlays (SFX-like)
short_audio = all_audio_overlays.select { |a| total_duration == 0 || a['duration'].to_f <= total_duration * 0.6 }
if short_audio.any?
  avg_dur = (short_audio.sum { |a| a['duration'].to_f } / short_audio.size).round(1)
  audio_patterns << {
    'trigger' => 'short_audio_overlay',
    'frequency' => "#{short_audio.size}/#{analyses.size}",
    'typical_duration' => avg_dur,
    'note' => 'SFX or accent audio'
  }
end

# --- Pacing observations ---

total_video_overlays = all_video_overlays.size
total_minutes = total_duration / 60.0
overlays_per_minute = total_minutes > 0 ? (total_video_overlays / total_minutes).round(1) : 0

# Average primary clip duration
avg_primary_dur = 0.0
if total_primary_clips > 0 && total_duration > 0
  avg_primary_dur = (total_duration / total_primary_clips).round(1)
end

# Longest unbroken primary run (gaps between video overlays)
longest_gap = 0.0
if all_video_overlays.any?
  sorted_overlays = all_video_overlays.sort_by { |o| o['start'].to_f }
  prev_end = 0.0
  sorted_overlays.each do |ov|
    gap = ov['start'].to_f - prev_end
    longest_gap = gap if gap > longest_gap
    prev_end = ov['end'].to_f
  end
  # Also check gap from last overlay to end of sequence
  final_gap = total_duration - (sorted_overlays.last['end']&.to_f || 0)
  longest_gap = final_gap if final_gap > longest_gap
end

pacing = {
  'overlays_per_minute' => overlays_per_minute,
  'avg_primary_clip_duration' => avg_primary_dur,
  'longest_unbroken_primary_run' => longest_gap.round(1)
}

# --- Build output ---

output = {
  'patterns_from' => analyses.size,
  'generated_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S'),
  'video_overlay_patterns' => video_patterns,
  'audio_overlay_patterns' => audio_patterns,
  'pacing_observations' => pacing
}

output_path = File.join(library_dir, 'edit_patterns.yaml')
File.write(output_path, output.to_yaml)

$stderr.puts "Patterns written: #{output_path}"
$stderr.puts "  #{video_patterns.size} video patterns, #{audio_patterns.size} audio patterns"
$stderr.puts "  Pacing: #{overlays_per_minute} overlays/min, #{avg_primary_dur}s avg primary clip"
puts output_path
