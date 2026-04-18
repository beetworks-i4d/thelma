#!/usr/bin/env ruby
# Extract cross-video creator profile from accumulated reports.
# Computes mean/median/variance for each metric to build a style fingerprint.
#
# Usage: ruby scripts/extract_creator_profile.rb reports/dylan_*.yaml --name dylan
#        ruby scripts/extract_creator_profile.rb --creator dylan
#
# Output: profiles/creators/<name>.yaml

require 'yaml'
require 'date'
require 'fileutils'

# --- Flag parsing ---

creator_name = nil
output_dir = nil
report_paths = []

args = ARGV.dup
while args.any?
  case args.first
  when '--name', '--creator'
    args.shift
    creator_name = args.shift
  when '--output-dir'
    args.shift
    output_dir = args.shift
  else
    path = args.shift
    if path.include?('*')
      report_paths += Dir.glob(path)
    else
      report_paths << path
    end
  end
end

# Auto-discover from reports/ if --creator given with no paths
if creator_name && report_paths.empty?
  reports_dir = File.expand_path('../../reports', __FILE__)
  report_paths = Dir.glob(File.join(reports_dir, "#{creator_name}*_report.yaml")).sort
end

abort "Usage: ruby scripts/extract_creator_profile.rb <report1.yaml> <report2.yaml> ... --name <creator>\n       ruby scripts/extract_creator_profile.rb --creator <name>" if report_paths.empty? || creator_name.nil?

# --- Load reports ---

reports = report_paths.filter_map do |path|
  next unless File.exist?(path)
  begin
    YAML.safe_load(File.read(path), permitted_classes: [Date])
  rescue => e
    $stderr.puts "Warning: skipping #{path}: #{e.message}"
    nil
  end
end

if reports.size < 2
  abort "Need at least 2 reports to extract a creator profile (got #{reports.size}). Analyze more videos first."
end

$stderr.puts "Extracting creator profile from #{reports.size} reports..."

# --- Statistical helpers ---

def mean(values)
  return nil if values.empty?
  values.sum.to_f / values.size
end

def median(values)
  return nil if values.empty?
  sorted = values.sort
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
end

def variance(values)
  return nil if values.size < 2
  m = mean(values)
  values.sum { |v| (v - m) ** 2 } / (values.size - 1).to_f
end

def confidence_level(values)
  return 'insufficient' if values.size < 3
  v = variance(values)
  m = mean(values)
  return 'high' if m && m != 0 && v && (v / m.abs) < 0.15
  return 'medium' if m && m != 0 && v && (v / m.abs) < 0.4
  'low'
end

def most_common(items)
  return nil if items.empty?
  counts = Hash.new(0)
  items.each { |i| counts[i] += 1 }
  counts.max_by { |_, c| c }.first
end

def top_n(items, n = 3)
  return [] if items.empty?
  counts = Hash.new(0)
  items.flatten.each { |i| counts[i] += 1 }
  counts.sort_by { |_, c| -c }.first(n).map(&:first)
end

# --- Extract metrics ---

# Pacing
avg_seg_durations = reports.filter_map { |r| r.dig('pacing', 'avg_segment_duration') }
median_seg_durations = reports.filter_map { |r| r.dig('pacing', 'median_segment_duration') }
total_segments = reports.filter_map { |r| r.dig('pacing', 'total_segments') }
over_12s = reports.filter_map { |r| r.dig('pacing', 'segments_over_12s') }

# Emotional architecture
all_primary_states = reports.filter_map { |r| r.dig('emotional_architecture', 'primary_states') }
all_spines = reports.filter_map { |r| r.dig('emotional_architecture', 'spine') }
tpm_values = reports.filter_map { |r| r.dig('emotional_architecture', 'transitions_per_minute') }
dur_arcs = reports.filter_map { |r| r.dig('emotional_architecture', 'durability_arc') }

# Structure / templates
templates = reports.filter_map { |r| r.dig('structure', 'template_match') }.reject { |t| t == 'none' }
fit_scores = reports.filter_map { |r| r.dig('structure', 'template_fit') }.select { |s| s > 0 }
beat_counts = reports.filter_map { |r| r.dig('structure', 'beat_count') }.select { |b| b > 0 }

# Audio delivery
audio_profiles = reports.filter_map { |r| r.dig('audio_delivery', 'dominant_profile') }
energy_levels = reports.filter_map { |r| r.dig('audio_delivery', 'energy_baseline') }
speaking_rates = reports.filter_map { |r| r.dig('audio_delivery', 'speaking_rate') }

# Visual language
scene_counts = reports.filter_map { |r| r.dig('visual_language', 'scene_changes') }
cuts_per_min = reports.filter_map { |r| r.dig('visual_language', 'cuts_per_minute') }
avg_shot_durations = reports.filter_map { |r| r.dig('visual_language', 'avg_shot_duration') }
th_ratios = reports.filter_map { |r| r.dig('visual_language', 'talking_head_ratio') }

# Hook / close
hook_durations = reports.filter_map { |r| r.dig('hook', 'duration') }
hook_states = reports.filter_map { |r|
  s = r.dig('hook', 'state')
  s&.split(' ')&.first  # "competence (identity)" → "competence"
}
hook_audio = reports.filter_map { |r| r.dig('hook', 'audio_profile') }

close_durations = reports.filter_map { |r| r.dig('close', 'duration') }
close_states = reports.filter_map { |r|
  s = r.dig('close', 'state')
  s&.split(' ')&.first
}
close_audio = reports.filter_map { |r| r.dig('close', 'audio_profile') }

# Duration
durations = reports.filter_map { |r| r['duration'] }

# --- Compute template affinities ---

template_affinities = {}
if templates.any?
  counts = Hash.new(0)
  templates.each { |t| counts[t] += 1 }
  total = templates.size.to_f
  template_affinities = counts.sort_by { |_, c| -c }.map { |t, c| { t => (c / total).round(2) } }
end

# --- Determine dominant durability preference ---

dur_types = []
dur_arcs.each do |arc|
  # Parse "identity(46) → mood(19) → spike(16)" — first entry is dominant
  match = arc.match(/^(\w+)\(/)
  dur_types << match[1] if match
end

# --- Build profile ---

profile = {
  'name' => creator_name,
  'videos_analyzed' => reports.size,
  'last_updated' => Time.now.strftime('%Y-%m-%d'),
  'avg_video_duration' => mean(durations)&.round(0),

  'editing_signature' => {
    'avg_segment_duration' => mean(avg_seg_durations)&.round(1),
    'avg_segment_duration_variance' => variance(avg_seg_durations)&.round(2),
    'median_segment_duration' => mean(median_seg_durations)&.round(1),
    'segments_per_video' => mean(total_segments)&.round(0),
    'segments_over_12s_per_video' => mean(over_12s)&.round(1),
  }.tap { |h|
    if scene_counts.any?
      h['avg_scene_changes'] = mean(scene_counts)&.round(0)
      h['cuts_per_minute'] = mean(cuts_per_min)&.round(1)
      h['avg_shot_duration'] = mean(avg_shot_durations)&.round(1)
    end
    h['talking_head_ratio'] = mean(th_ratios)&.round(2) if th_ratios.any?
    h['talking_head_ratio_variance'] = variance(th_ratios)&.round(3) if th_ratios.size >= 2
  },

  'emotional_signature' => {
    'dominant_states' => top_n(all_primary_states, 3),
    'spine' => most_common(all_spines),
    'spine_confidence' => confidence_level(tpm_values),
    'state_transitions_per_minute' => mean(tpm_values)&.round(2),
    'durability_preference' => most_common(dur_types)
  },

  'pacing_signature' => {
    'fast' => (mean(avg_seg_durations) || 99) < 9,
    'avg_segment_duration' => mean(avg_seg_durations)&.round(1),
    'segments_over_12s_per_video' => mean(over_12s)&.round(1)
  },

  'audio_signature' => {
    'dominant_profile' => most_common(audio_profiles),
    'energy_baseline' => most_common(energy_levels),
    'speaking_rate' => mean(speaking_rates)&.round(2)
  },

  'template_affinities' => template_affinities,

  'hook_patterns' => {
    'avg_duration' => mean(hook_durations)&.round(1),
    'typical_state' => most_common(hook_states),
    'typical_audio' => most_common(hook_audio)
  },

  'close_patterns' => {
    'avg_duration' => mean(close_durations)&.round(1),
    'typical_state' => most_common(close_states),
    'typical_audio' => most_common(close_audio)
  },

  'structure_patterns' => {
    'avg_template_fit' => mean(fit_scores)&.round(0),
    'avg_beat_count' => mean(beat_counts)&.round(1),
    'preferred_template' => most_common(templates)
  }
}

# --- Write output ---

creators_dir = output_dir || File.expand_path('../../profiles/creators', __FILE__)
FileUtils.mkdir_p(creators_dir)
output_path = File.join(creators_dir, "#{creator_name}.yaml")
File.write(output_path, profile.to_yaml)

$stderr.puts "Creator profile written to #{output_path}"
puts output_path
