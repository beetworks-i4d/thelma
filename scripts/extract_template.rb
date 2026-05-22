#!/usr/bin/env ruby
# DEPRECATED — see VISION.md P5. Will be replaced by finished-video template extraction.
# Phase 2.1 — Template Extraction Pipeline
# Extracts reusable narrative templates from multiple source videos that share
# a structural pattern. Minimum 3 segments_classified.yaml files required.
#
# Usage:
#   ruby scripts/extract_template.rb <seg1.yaml> <seg2.yaml> <seg3.yaml> [...]
#   ruby scripts/extract_template.rb seg1.yaml seg2.yaml seg3.yaml --label "comparative walkthrough"
#   ruby scripts/extract_template.rb seg1.yaml seg2.yaml seg3.yaml --update existing_template.yaml
#   ruby scripts/extract_template.rb seg1.yaml seg2.yaml seg3.yaml --category explainer
#
# --label:    Human-readable name for the template (converted to snake_case).
# --update:   Merge new source data into existing template (increments version).
# --category: Subdirectory under templates/story_structures/ for saving.
#
# Output: template_extracted.yaml in same directory as first input. Path to stdout.

require 'yaml'
require 'date'
require 'set'
require 'fileutils'

# --- Constants ---
SHARED_THRESHOLD  = 0.70   # Beat in ≥70% of sources = shared
VARIABLE_THRESHOLD = 0.30  # Beat in 30-70% of sources = variable
POSITION_TOLERANCE = 0.15  # ±15% position window for matching
DEDUP_GAP          = 0.08  # Minimum position gap between distinct beats
MIN_SOURCES        = 3
MIN_DISTILLATION   = 6     # Minimum chars for substantive distillation

STOP_WORDS = Set.new(%w[
  a an the and or but in on at to for of is it that this with from by as
  was were be been being have has had do does did will would could should
  may might shall can not no so if then than when where what which who whom
  how all each every both few more most other some such its my your his her
  our their they them we us he she you i me him just also very much really
  about into over after before between through during without along across
  like get got make made know knew think thought see saw go went come came
  take took give gave well still even back only now here there
])

# --- Helpers ---

def content_words(text)
  text.to_s.downcase.gsub(/[^a-z0-9\s]/, '').split
      .reject { |w| STOP_WORDS.include?(w) || w.length < 2 }
end

def fmt_time(seconds)
  m = (seconds / 60).to_i
  s = (seconds % 60).to_i
  format('%d:%02d', m, s)
end

# --- Flag parsing ---

label = nil
if (idx = ARGV.index('--label'))
  label = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end

update_path = nil
if (idx = ARGV.index('--update'))
  update_path = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end

category = nil
if (idx = ARGV.index('--category'))
  category = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end

source_paths = ARGV.dup

# --- Validation ---

abort 'Usage: ruby scripts/extract_template.rb <seg1.yaml> <seg2.yaml> <seg3.yaml> [...]' if source_paths.empty?
abort "Minimum #{MIN_SOURCES} transcripts required. Got #{source_paths.size}." if source_paths.size < MIN_SOURCES

source_paths.each do |path|
  abort "File not found: #{path}" unless File.exist?(path)
end

if update_path && !File.exist?(update_path)
  abort "Update target not found: #{update_path}"
end

# --- Load and normalize sources ---

normalized_sources = source_paths.map do |path|
  data = YAML.safe_load(File.read(path), permitted_classes: [Date])
  abort "Branch A (script-locked) not supported: #{path}" if data.key?('segments_used')
  segments = data['segments'] || []
  abort "No segments found in #{path}" if segments.empty?

  sorted = segments.sort_by { |s| s['t'].to_f }
  substantive = sorted.select { |s| s['distillation'].to_s.strip.length >= MIN_DISTILLATION }

  if substantive.empty?
    $stderr.puts "Warning: no substantive segments in #{path}, skipping."
    next nil
  end

  first_t  = substantive.first['t'].to_f
  last_e   = substantive.last['e'].to_f
  duration = last_e - first_t

  normalized = substantive.map do |seg|
    pos = duration > 0 ? ((seg['t'].to_f - first_t) / duration).clamp(0.0, 1.0) : 0.5
    {
      position:         pos.round(4),
      distillation:     seg['distillation'],
      keywords:         content_words(seg['distillation']),
      states:           (seg['states'] || []).map(&:to_s),
      dur:              seg['dur'],
      duration_seconds: (seg['e'].to_f - seg['t'].to_f).round(1),
      confidence:       seg['confidence']
    }
  end

  { path: path, source_name: File.basename(File.dirname(path)), duration: duration, segments: normalized }
end.compact

abort "Not enough sources with substantive segments. Need #{MIN_SOURCES}, got #{normalized_sources.size}." if normalized_sources.size < MIN_SOURCES

num_sources = normalized_sources.size

# --- Cross-source beat matching ---
# For each segment in each source, find the best-matching segment in every
# other source (position proximity + keyword overlap). Record how many
# sources contain a match.

beat_candidates = []

normalized_sources.each_with_index do |ref_source, ref_idx|
  ref_source[:segments].each do |ref_seg|
    matches = [{ source_idx: ref_idx, segment: ref_seg }]

    normalized_sources.each_with_index do |other_source, other_idx|
      next if other_idx == ref_idx

      best = nil
      best_score = -Float::INFINITY

      other_source[:segments].each do |other_seg|
        pos_diff = (ref_seg[:position] - other_seg[:position]).abs
        next if pos_diff > POSITION_TOLERANCE

        kw_overlap = (ref_seg[:keywords] & other_seg[:keywords]).size
        next if kw_overlap < 1

        score = kw_overlap.to_f - pos_diff * 5
        if score > best_score
          best_score = score
          best = other_seg
        end
      end

      matches << { source_idx: other_idx, segment: best } if best
    end

    source_count = matches.map { |m| m[:source_idx] }.uniq.size
    fraction = source_count.to_f / num_sources
    avg_pos = matches.map { |m| m[:segment][:position] }.sum / matches.size

    beat_candidates << {
      matches:      matches,
      fraction:     fraction,
      source_count: source_count,
      avg_position: avg_pos.round(4)
    }
  end
end

# --- Deduplicate: keep strongest non-overlapping beats ---

beat_candidates.sort_by! { |b| [-b[:fraction], b[:avg_position]] }

used_positions = []
final_beats = []

beat_candidates.each do |candidate|
  next if used_positions.any? { |p| (p - candidate[:avg_position]).abs < DEDUP_GAP }
  next if candidate[:source_count] < 2 # Must appear in at least 2 sources to be a pattern

  if candidate[:fraction] >= SHARED_THRESHOLD
    final_beats << candidate.merge(type: 'shared')
    used_positions << candidate[:avg_position]
  elsif candidate[:fraction] >= VARIABLE_THRESHOLD
    final_beats << candidate.merge(type: 'variable')
    used_positions << candidate[:avg_position]
  end
end

final_beats.sort_by! { |b| b[:avg_position] }

# --- Compute properties for each beat ---

beats_output = final_beats.each_with_index.map do |beat, idx|
  all_segments = beat[:matches].map { |m| m[:segment] }

  # Position stats
  positions = all_segments.map { |s| s[:position] }
  avg_pos = (positions.sum / positions.size).round(4)
  pos_tolerance = positions.map { |p| (p - avg_pos).abs }.max.round(4)

  # State profile (top 3 by frequency)
  state_counts = Hash.new(0)
  all_segments.each { |s| s[:states].each { |st| state_counts[st] += 1 } }
  state_profile = state_counts.sort_by { |_, c| -c }.first(3).map(&:first)

  # Duration range
  durations = all_segments.map { |s| s[:duration_seconds] }.sort
  duration_typical = "#{durations.first.round(0).to_i}-#{durations.last.round(0).to_i}s"

  # Keywords: union across matches, ranked by frequency
  keyword_counts = Hash.new(0)
  all_segments.each { |s| s[:keywords].each { |kw| keyword_counts[kw] += 1 } }
  min_freq = [2, (all_segments.size * 0.3).ceil].min
  top_keywords = keyword_counts.select { |_, c| c >= min_freq }
                               .sort_by { |_, c| -c }.first(10).map(&:first)
  top_keywords = keyword_counts.sort_by { |_, c| -c }.first(8).map(&:first) if top_keywords.size < 3

  # Examples (unique distillations)
  examples = all_segments.map { |s| s[:distillation] }.uniq

  # Auto-generate beat ID from top keyword
  id = if top_keywords.any? { |kw| kw.length >= 3 }
    stem = top_keywords.select { |kw| kw.length >= 3 }.first(2).join('_')
    stem.gsub(/[^a-z0-9_]/, '')
  else
    "beat_#{idx + 1}"
  end

  {
    'id'                => id,
    'description'       => nil,
    'keywords'          => top_keywords,
    'position'          => avg_pos,
    'position_tolerance'=> pos_tolerance,
    'state_profile'     => state_profile,
    'duration_typical'  => duration_typical,
    'optional'          => beat[:type] == 'variable',
    'examples'          => examples,
    '_type'             => beat[:type],
    '_source_count'     => beat[:source_count]
  }
end

# --- Overlap check with existing templates ---

templates_dir = File.join(File.dirname(__FILE__), '..', 'templates', 'story_structures')

existing_templates = if Dir.exist?(templates_dir)
  Dir.glob(File.join(templates_dir, '**', '*.yaml')).map { |p| YAML.safe_load(File.read(p)) }
else
  []
end

POSITION_RANGES = {
  'early'     => [0.0, 0.2],
  'early_mid' => [0.2, 0.4],
  'mid'       => [0.4, 0.6],
  'late_mid'  => [0.6, 0.8],
  'late'      => [0.8, 1.0]
}.freeze

overlap_analysis = existing_templates.map do |template|
  template_beats = template['beats'] || []
  next nil if template_beats.empty?

  overlapping = []
  beats_output.each do |proposed|
    template_beats.each do |tb|
      tb_kws = (tb['keywords'] || []).map(&:downcase)
      pr_kws = proposed['keywords'].map(&:downcase)
      kw_overlap = (Set.new(tb_kws) & Set.new(pr_kws)).size
      next if kw_overlap < 2

      # Position check: handle both numeric and label positions
      tb_pos = tb['position']
      if tb_pos.is_a?(Numeric)
        pos_match = (tb_pos - proposed['position']).abs <= POSITION_TOLERANCE
      else
        range = POSITION_RANGES[tb_pos.to_s] || [0.0, 1.0]
        pos_match = proposed['position'] >= (range[0] - 0.1) && proposed['position'] <= (range[1] + 0.1)
      end
      next unless pos_match

      overlapping << { proposed_beat: proposed['id'], template_beat: tb['id'] }
    end
  end

  total = beats_output.size
  overlap_pct = total > 0 ? (overlapping.size.to_f / total * 100).round : 0

  {
    'template'         => template['name'],
    'overlapping_beats'=> overlapping.map { |o| "#{o[:proposed_beat]}~#{o[:template_beat]}" },
    'shared_count'     => overlapping.size,
    'total_proposed'   => total,
    'overlap_pct'      => overlap_pct
  }
end.compact.sort_by { |o| -o['overlap_pct'] }

highest_overlap = overlap_analysis.first
overlap_recommendation = if highest_overlap && highest_overlap['overlap_pct'] > 70
  "Consider updating '#{highest_overlap['template']}' instead of creating new template (#{highest_overlap['overlap_pct']}% overlap)."
end

# --- Confidence ---

shared_count   = final_beats.count { |b| b[:type] == 'shared' }
variable_count = final_beats.count { |b| b[:type] == 'variable' }

confidence = if shared_count >= 5 then 0.90
             elsif shared_count >= 3 then 0.80
             elsif shared_count >= 2 then 0.70
             else 0.60
             end

avg_tolerance = beats_output.empty? ? 0 : beats_output.map { |b| b['position_tolerance'] }.sum / beats_output.size
confidence -= 0.10 if avg_tolerance > 0.12
confidence = confidence.clamp(0.0, 1.0).round(2)

# --- Handle --update mode ---

if update_path
  existing = YAML.safe_load(File.read(update_path), permitted_classes: [Date])
  abort "No beats in update target: #{update_path}" unless existing['beats']&.any?

  existing['beats'].each do |eb|
    match = beats_output.find do |pb|
      kw_overlap = (Set.new((eb['keywords'] || []).map(&:downcase)) & Set.new(pb['keywords'].map(&:downcase))).size
      if eb['position'].is_a?(Numeric)
        pos_close = (eb['position'] - pb['position']).abs < POSITION_TOLERANCE
      else
        range = POSITION_RANGES[eb['position'].to_s] || [0.0, 1.0]
        pos_close = pb['position'] >= range[0] && pb['position'] <= range[1]
      end
      kw_overlap >= 1 && pos_close
    end
    next unless match

    # Widen position tolerance
    if match['position_tolerance']
      eb['position_tolerance'] = [eb['position_tolerance'].to_f, match['position_tolerance']].max.round(4)
    end

    # Add new keywords
    new_kws = match['keywords'] - (eb['keywords'] || [])
    eb['keywords'] = ((eb['keywords'] || []) + new_kws).first(15) if new_kws.any?

    # Add new examples
    eb['examples'] = ((eb['examples'] || []) + (match['examples'] || [])).uniq.first(6)

    # Add state profile if absent
    eb['state_profile'] ||= match['state_profile']
    eb['duration_typical'] ||= match['duration_typical']
  end

  # Version increment
  old_version = existing['version'].to_s
  parts = old_version.split('.')
  parts[-1] = (parts[-1].to_i + 1).to_s if parts.size >= 2
  new_version = parts.size >= 2 ? parts.join('.') : "#{old_version.to_f + 0.1}"
  existing['version'] = new_version

  # Source videos
  existing['source_videos'] ||= []
  normalized_sources.each { |s| existing['source_videos'] << s[:source_name] }
  existing['source_videos'].uniq!

  # History
  existing['history'] ||= []
  existing['history'] << "#{new_version}: updated with #{num_sources} additional source videos"

  output_dir  = File.dirname(update_path)
  basename    = File.basename(update_path, '.yaml')
  output_path = File.join(output_dir, "#{basename}_updated.yaml")
  File.write(output_path, existing.to_yaml)

  $stderr.puts '=' * 60
  $stderr.puts 'TEMPLATE UPDATE'
  $stderr.puts '=' * 60
  $stderr.puts "Source: #{update_path}"
  $stderr.puts "Version: #{old_version} -> #{new_version}"
  $stderr.puts "Sources added: #{normalized_sources.map { |s| s[:source_name] }.join(', ')}"
  $stderr.puts ''
  $stderr.puts "Output: #{output_path}"
  puts output_path
  exit 0
end

# --- LLM prompts ---

beat_summary = beats_output.each_with_index.map { |b, i|
  type_tag = b['_type'] == 'shared' ? 'SHARED' : 'VARIABLE'
  examples_str = b['examples'].first(2).join('; ')
  "#{i + 1}. [#{type_tag}] pos=#{b['position']} keywords=[#{b['keywords'].first(5).join(', ')}] states=[#{b['state_profile'].join(', ')}] examples: #{examples_str}"
}.join("\n")

description_prompt = <<~PROMPT.strip
  Below are narrative beats extracted from #{num_sources} source videos sharing a structural pattern. Each beat shows type (SHARED=in >=70% of sources, VARIABLE=30-70%), position (0.0=start, 1.0=end), keywords, emotional states, and example distillations.

  Write ONE sentence describing this narrative structure. Be specific — name the structure type (e.g., "comparative walkthrough", "credibility ladder"). Do not be generic.

  Also assign a snake_case name for this template (e.g., "comparative_walkthrough").

  Beats:
  #{beat_summary}

  Respond in this format:
  name: snake_case_name
  description: One sentence description.
PROMPT

beat_description_prompt = <<~PROMPT.strip
  For each beat below, write a concise description (1 sentence) explaining what this beat does in the narrative. Also suggest a better snake_case ID if the auto-generated one is unclear.

  #{beats_output.each_with_index.map { |b, i|
    "#{i + 1}. id=#{b['id']} keywords=[#{b['keywords'].join(', ')}] states=[#{b['state_profile'].join(', ')}] examples: #{b['examples'].join(' | ')}"
  }.join("\n")}

  Respond as a numbered list:
  1. id: better_id, description: What this beat does
  2. ...
PROMPT

# --- Build output ---

clean_beats = beats_output.map do |b|
  beat = b.dup
  beat.delete('_type')
  beat.delete('_source_count')
  beat
end

template_name = label ? label.downcase.gsub(/[^a-z0-9]+/, '_').gsub(/^_|_$/, '') : nil

proposed_template = {
  'name'          => template_name,
  'version'       => '1.0',
  'category'      => category,
  'description'   => nil,
  'source_videos' => normalized_sources.map { |s| s[:source_name] },
  'confidence'    => confidence,
  'beats'         => clean_beats,
  'history'       => ["1.0: extracted from #{num_sources} source videos"]
}

output = {
  'generated_at'            => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'source_count'            => num_sources,
  'sources'                 => source_paths,
  'shared_beats'            => shared_count,
  'variable_beats'          => variable_count,
  'total_beats'             => beats_output.size,
  'confidence'              => confidence,
  'overlap_analysis'        => overlap_analysis,
  'overlap_recommendation'  => overlap_recommendation,
  'proposed_template'       => proposed_template,
  'description_prompt'      => description_prompt,
  'beat_description_prompt' => beat_description_prompt
}

output_dir  = File.dirname(source_paths.first)
output_path = File.join(output_dir, 'template_extracted.yaml')
File.write(output_path, output.to_yaml)

# --- Report ---

$stderr.puts '=' * 60
$stderr.puts 'TEMPLATE EXTRACTION'
$stderr.puts '=' * 60
$stderr.puts "Sources: #{num_sources}"
source_paths.each { |p| $stderr.puts "  - #{File.basename(File.dirname(p))}" }
$stderr.puts ''
$stderr.puts "Beats found: #{beats_output.size} (#{shared_count} shared, #{variable_count} variable)"
$stderr.puts "Confidence: #{(confidence * 100).round}%"
$stderr.puts ''

if beats_output.any?
  $stderr.puts 'Beat structure:'
  beats_output.each do |b|
    tag = b['_type'] == 'shared' ? 'S' : 'V'
    $stderr.puts "  [#{tag}] #{b['id']} -- pos #{b['position']} +/-#{b['position_tolerance']} -- #{b['state_profile'].join(', ')}"
    b['examples'].first(2).each { |ex| $stderr.puts "      ex: #{ex}" }
  end
  $stderr.puts ''
end

if overlap_analysis.any? { |o| o['overlap_pct'] > 0 }
  $stderr.puts 'Template overlap:'
  overlap_analysis.select { |o| o['overlap_pct'] > 0 }.each do |o|
    $stderr.puts "  #{o['template']}: #{o['overlap_pct']}% (#{o['shared_count']}/#{o['total_proposed']} beats)"
  end
  $stderr.puts ''
  $stderr.puts "NOTE: #{overlap_recommendation}" if overlap_recommendation
  $stderr.puts ''
end

$stderr.puts 'Agent action required:'
$stderr.puts '  1. Run description_prompt -> fill proposed_template.name + description'
$stderr.puts '  2. Run beat_description_prompt -> fill beat descriptions + refine IDs'
$stderr.puts '  3. Review and save template'
$stderr.puts ''

if category
  $stderr.puts "Category: #{category} (saves to templates/story_structures/#{category}/)"
else
  $stderr.puts 'Category: none (saves to templates/story_structures/)'
end

$stderr.puts ''
$stderr.puts "Output: #{output_path}"
puts output_path
