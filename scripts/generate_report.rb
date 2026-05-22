#!/usr/bin/env ruby
# DEPRECATED — see VISION.md P5. Will be replaced by finished-video template extraction.
# Phase C — Generate analysis report for a library.
# Reads all pipeline outputs and formats into standardized report YAML.
#
# Usage: ruby scripts/generate_report.rb <library_path> [--profile <name>]
# Output: reports/<library-name>_report.yaml. Path to stdout.

require 'yaml'
require 'date'
require 'fileutils'
require_relative 'load_profile'

# --- Flag parsing ---

profile_name = nil
output_dir = nil
if (idx = ARGV.index('--profile'))
  profile_name = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end
if (idx = ARGV.index('--output-dir'))
  output_dir = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end

library_path = ARGV[0]
abort "Usage: ruby scripts/generate_report.rb <library_path> [--profile <name>] [--output-dir <path>]" unless library_path

library_yaml_path = if File.directory?(library_path)
  File.join(library_path, 'library.yaml')
else
  library_path
end
abort "File not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

library_dir = File.dirname(library_yaml_path)
library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
library_name = library['library_name'] || File.basename(library_dir)

# --- Load profile ---
profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)
creator = profile['name'] || 'unknown'
creator = 'unknown' if creator == '_default'

# --- Load pipeline outputs ---

classified_path = File.join(library_dir, 'segments_classified.yaml')
scored_path = File.join(library_dir, 'storylines_scored.yaml')

classified = File.exist?(classified_path) ? YAML.safe_load(File.read(classified_path), permitted_classes: [Date]) : nil
scored = File.exist?(scored_path) ? YAML.safe_load(File.read(scored_path), permitted_classes: [Date]) : nil

segments = classified ? (classified['segments'] || []) : []

# --- Video info ---

video = library['videos']&.first || {}
duration_str = video['duration'] || '0:00'
duration_parts = duration_str.to_s.split(':').map(&:to_f)
duration_seconds = case duration_parts.length
  when 3 then duration_parts[0] * 3600 + duration_parts[1] * 60 + duration_parts[2]
  when 2 then duration_parts[0] * 60 + duration_parts[1]
  else duration_parts[0]
end

# --- Structure analysis ---

structure = {}
if scored
  storylines = scored['storylines'] || []
  top = storylines.max_by { |s| s['combined_score'].to_i }
  if top
    tm = top['template_match'] || {}
    structure = {
      'template_match' => tm['template'] || 'none',
      'template_fit' => tm['fit_score'] || 0,
      'beats' => (tm['matched_beats'] || {}).keys,
      'beat_count' => (tm['matched_beats'] || {}).size,
      'avg_beat_duration' => nil
    }

    # Calculate average beat duration from matched segments
    if classified && !structure['beats'].empty?
      seg_by_t = {}
      segments.each { |s| seg_by_t[s['t'].to_f] = s }
      matched_durations = (tm['matched_beats'] || {}).values.map { |mb|
        seg = seg_by_t[mb['segment_t'].to_f]
        seg ? (seg['e'].to_f - seg['t'].to_f) : nil
      }.compact
      structure['avg_beat_duration'] = matched_durations.empty? ? nil : (matched_durations.sum / matched_durations.size).round(1)
    end
  end
end

# --- Emotional architecture ---

emotional = {}
if segments.any?
  state_counts = Hash.new(0)
  dur_sequence = []
  transition_count = 0
  prev_states = nil

  segments.each do |seg|
    states = seg['states'] || []
    states.each { |s| state_counts[s] += 1 }
    dur_sequence << seg['dur']

    if prev_states && (states & prev_states).empty?
      transition_count += 1
    end
    prev_states = states
  end

  top_states = state_counts.sort_by { |_, c| -c }.first(3).map(&:first)
  spine = top_states.first

  # Durability arc: summarize sequence pattern
  dur_counts = Hash.new(0)
  dur_sequence.each { |d| dur_counts[d] += 1 }
  dur_arc = dur_counts.sort_by { |_, c| -c }.map { |d, c| "#{d}(#{c})" }.join(' → ')

  total_duration_content = segments.last['e'].to_f - segments.first['t'].to_f
  tpm = total_duration_content > 0 ? (transition_count / (total_duration_content / 60.0)).round(2) : 0

  emotional = {
    'primary_states' => top_states,
    'spine' => spine,
    'durability_arc' => dur_arc,
    'state_transitions' => transition_count,
    'transitions_per_minute' => tpm
  }
end

# --- Pacing ---

pacing = {}
if segments.any?
  durations = segments.map { |s| s['e'].to_f - s['t'].to_f }.sort
  avg = (durations.sum / durations.size).round(1)
  median = durations[durations.size / 2].round(1)
  over_12 = durations.count { |d| d > 12 }

  pacing = {
    'avg_segment_duration' => avg,
    'median_segment_duration' => median,
    'segments_over_12s' => over_12,
    'total_segments' => segments.size
  }
end

# --- Audio delivery ---

audio_delivery = {}
audio_features_file = Dir.glob(File.join(library_dir, 'transcripts', '*_audio_features.yaml')).first ||
                      Dir.glob(File.join(library_dir, '*_audio_features.yaml')).first

if audio_features_file && File.exist?(audio_features_file)
  af = YAML.safe_load(File.read(audio_features_file), permitted_classes: [Date])
  af_segments = af['segments'] || []

  if af_segments.any?
    profile_counts = Hash.new(0)
    energies = []
    pitch_ranges = []
    rates = []

    af_segments.each do |s|
      profile_counts[s['audio_profile']] += 1 if s['audio_profile']
      energies << s['energy_relative'].to_f if s['energy_relative']
      pitch_ranges << s['pitch_range_hz'].to_f if s['pitch_range_hz']
      rates << s['speaking_rate_relative'].to_f if s['speaking_rate_relative']
    end

    dominant = profile_counts.max_by { |_, c| c }&.first || 'unknown'
    avg_energy = energies.any? ? energies.sum / energies.size : 1.0
    avg_pitch_range = pitch_ranges.any? ? pitch_ranges.sum / pitch_ranges.size : 0
    avg_rate = rates.any? ? rates.sum / rates.size : 1.0

    energy_level = if avg_energy > 1.2 then 'high'
                   elsif avg_energy < 0.8 then 'low'
                   else 'medium'
                   end

    pitch_var = if avg_pitch_range > 30 then 'wide'
                elsif avg_pitch_range < 15 then 'narrow'
                else 'moderate'
                end

    audio_delivery = {
      'dominant_profile' => dominant,
      'energy_baseline' => energy_level,
      'pitch_variation' => pitch_var,
      'speaking_rate' => avg_rate.round(2)
    }
  end
end

# --- Hook and close ---

hook_info = {}
close_info = {}

if scored
  storylines = scored['storylines'] || []
  top = storylines.max_by { |s| s['combined_score'].to_i }
  if top && classified
    seg_by_t = {}
    segments.each { |s| seg_by_t[s['t'].to_f] = s }

    hook_seg = seg_by_t[top['hook_segment'].to_f]
    if hook_seg
      hook_info = {
        'duration' => (hook_seg['e'].to_f - hook_seg['t'].to_f).round(1),
        'state' => "#{(hook_seg['states'] || []).first} (#{hook_seg['dur']})",
        'audio_profile' => hook_seg['audio_profile'] || 'unknown'
      }
    end

    close_t = top['close_segment']
    close_seg = close_t ? seg_by_t[close_t.to_f] : nil
    if close_seg
      close_info = {
        'duration' => (close_seg['e'].to_f - close_seg['t'].to_f).round(1),
        'state' => "#{(close_seg['states'] || []).first} (#{close_seg['dur']})",
        'audio_profile' => close_seg['audio_profile'] || 'unknown'
      }
    end
  end
end

# --- Visual language ---

visual_language = { 'talking_head_ratio' => nil }

# Scene detection data
scene_changes_path = File.join(library_dir, 'scene_changes.yaml')
if File.exist?(scene_changes_path)
  scene_data = YAML.safe_load(File.read(scene_changes_path), permitted_classes: [Date])
  scene_count = scene_data['total_scenes'] || 0
  scene_ts = scene_data['timestamps'] || []

  visual_language['scene_changes'] = scene_count

  if duration_seconds > 0 && scene_count > 0
    visual_language['cuts_per_minute'] = (scene_count / (duration_seconds / 60.0)).round(1)
    visual_language['avg_shot_duration'] = (duration_seconds / scene_count).round(1)
  end
end

# Visual transcript data
visual_path = video['visual_transcript']
if visual_path
  full_visual_path = File.join(library_dir, 'transcripts', visual_path)
  if File.exist?(full_visual_path)
    visual_data = JSON.parse(File.read(full_visual_path)) rescue nil
    if visual_data
      vis_segments = visual_data['segments'] || []
      total = vis_segments.size
      talking_head = vis_segments.count { |s|
        v = (s['visual'] || '').downcase
        v.include?('speaking') || v.include?('camera') || v.include?('talking') || v.include?('same shot') || v.include?('same framing')
      }
      visual_language['talking_head_ratio'] = total > 0 ? (talking_head.to_f / total).round(2) : nil
    end
  end
end

# --- Build report ---

report = {
  'video' => File.basename(video['path'] || library_name),
  'creator' => creator,
  'duration' => duration_seconds.round(1),
  'analyzed' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'structure' => structure,
  'emotional_architecture' => emotional,
  'pacing' => pacing,
  'audio_delivery' => audio_delivery,
  'visual_language' => visual_language,
  'hook' => hook_info,
  'close' => close_info
}

# --- Write output ---

reports_dir = output_dir || File.join(File.dirname(__FILE__), '..', 'reports')
FileUtils.mkdir_p(reports_dir)
output_path = File.join(reports_dir, "#{library_name}_report.yaml")
File.write(output_path, report.to_yaml)

$stderr.puts "Report generated: #{output_path}"
puts output_path
