#!/usr/bin/env ruby
# Phase 1.7 — Template Matching for Storyline Candidates
# Scores how well each storyline's distilled segments fit known narrative templates.
# Enables future combined scoring: state 30% + template fit 40% + coherence 30%.
#
# Usage: ruby scripts/match_templates.rb <storylines.yaml> <segments_classified.yaml>
# Output: storylines_matched.yaml in same directory as storylines input. Path to stdout, report to stderr.

require 'yaml'
require 'date'

storylines_path = ARGV[0]
classified_path = ARGV[1]

abort "Usage: ruby scripts/match_templates.rb <storylines.yaml> <segments_classified.yaml>" unless storylines_path && classified_path
abort "File not found: #{storylines_path}" unless File.exist?(storylines_path)
abort "File not found: #{classified_path}" unless File.exist?(classified_path)

# --- Load templates ---
templates_dir = File.join(File.dirname(__FILE__), '..', 'templates', 'story_structures')
abort "Templates directory not found: #{templates_dir}" unless Dir.exist?(templates_dir)

templates = Dir.glob(File.join(templates_dir, '**', '*.yaml')).map do |path|
  YAML.safe_load(File.read(path))
end
abort "No templates found in #{templates_dir}" if templates.empty?

# --- Load data ---
storylines_data = YAML.safe_load(File.read(storylines_path), permitted_classes: [Date])
classified_data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])

storylines = storylines_data['storylines'] || []
segments = classified_data['segments'] || []

# Build segment lookup by t-value (float key)
seg_by_t = {}
segments.each { |s| seg_by_t[s['t'].to_f] = s }

# --- Position mapping ---
# Maps position labels to expected fractional range within the sequence
POSITION_RANGES = {
  'early'     => [0.0, 0.2],
  'early_mid' => [0.2, 0.4],
  'mid'       => [0.4, 0.6],
  'late_mid'  => [0.6, 0.8],
  'late'      => [0.8, 1.0]
}.freeze

# Check if a distillation matches any keyword in a beat's keyword list
def keyword_match?(distillation, keywords)
  text = distillation.downcase
  keywords.any? { |kw| text.include?(kw.downcase) }
end

# Score a single storyline against a single template
def score_template(distillations, template)
  beats = template['beats']
  total_beats = beats.length
  matched = []

  beats.each do |beat|
    # Scan all distillations for keyword hits
    best_match = nil
    distillations.each_with_index do |dist, idx|
      if keyword_match?(dist[:distillation], beat['keywords'])
        best_match = { index: idx, segment_t: dist[:t], distillation: dist[:distillation] }
        break # Take first match (chronological order)
      end
    end
    matched << { beat: beat, match: best_match } if best_match
  end

  completeness = (matched.length.to_f / total_beats * 100).round

  # Order score: check if matched beats appear in expected position order
  order_correct = 0
  matched.each do |m|
    beat_pos = m[:beat]['position']

    # Normalized position of this match within the distillation sequence
    normalized = distillations.length > 1 ? m[:match][:index].to_f / (distillations.length - 1) : 0.5

    # Handle both label positions ("early") and numeric positions (0.15)
    tolerance = 0.15
    if beat_pos.is_a?(Numeric)
      beat_tol = m[:beat]['position_tolerance'] || tolerance
      if (normalized - beat_pos).abs <= [beat_tol + tolerance, 0.25].min
        order_correct += 1
      end
    else
      range = POSITION_RANGES[beat_pos]
      next unless range
      if normalized >= (range[0] - tolerance) && normalized <= (range[1] + tolerance)
        order_correct += 1
      end
    end
  end

  order_score = matched.empty? ? 0 : (order_correct.to_f / matched.length * 100).round
  fit_score = (completeness * 0.6 + order_score * 0.4).round

  missing_beats = beats.select { |b| matched.none? { |m| m[:beat]['id'] == b['id'] } }
                       .map { |b| b['id'] }

  matched_beats = {}
  matched.each do |m|
    matched_beats[m[:beat]['id']] = {
      'segment_t' => m[:match][:segment_t],
      'distillation' => m[:match][:distillation]
    }
  end

  {
    'template' => template['name'],
    'fit_score' => fit_score,
    'completeness' => completeness,
    'order_score' => order_score,
    'missing_beats' => missing_beats,
    'matched_beats' => matched_beats
  }
end

# --- Process each storyline ---
$stderr.puts "=" * 60
$stderr.puts "TEMPLATE MATCHING REPORT"
$stderr.puts "=" * 60
$stderr.puts "Templates loaded: #{templates.map { |t| t['name'] }.join(', ')}"
$stderr.puts "Storylines: #{storylines.length}"
$stderr.puts

storylines.each do |storyline|
  hook_t = storyline['hook_segment'].to_f
  close_t = storyline['close_segment'].to_f

  # Reconstruct distillation sequence
  hook_seg = seg_by_t[hook_t]
  close_seg = seg_by_t[close_t]

  # Body = all segments between hook and close, sorted by t
  body_segs = segments.select { |s| s['t'].to_f > hook_t && s['t'].to_f < close_t }
                      .sort_by { |s| s['t'].to_f }

  distillations = []
  distillations << { t: hook_t, distillation: hook_seg['distillation'] } if hook_seg
  body_segs.each { |s| distillations << { t: s['t'].to_f, distillation: s['distillation'] } }
  distillations << { t: close_t, distillation: close_seg['distillation'] } if close_seg

  if distillations.empty?
    $stderr.puts "#{storyline['id']}: no segments found, skipping"
    storyline['template_match'] = { 'template' => 'none', 'fit_score' => 0, 'completeness' => 0, 'order_score' => 0, 'missing_beats' => [], 'matched_beats' => {} }
    next
  end

  # Score against all templates, pick best
  results = templates.map { |t| score_template(distillations, t) }
  best = results.max_by { |r| r['fit_score'] }

  storyline['template_match'] = best

  # Report
  $stderr.puts "#{storyline['id']}"
  $stderr.puts "  Segments: #{distillations.length} (hook #{hook_t} → close #{close_t})"
  $stderr.puts "  Best template: #{best['template']} (fit: #{best['fit_score']}, completeness: #{best['completeness']}%, order: #{best['order_score']}%)"
  $stderr.puts "  Matched beats: #{best['matched_beats'].keys.join(', ')}"
  $stderr.puts "  Missing beats: #{best['missing_beats'].empty? ? 'none' : best['missing_beats'].join(', ')}"

  # Show runner-up if close
  runner_up = results.sort_by { |r| -r['fit_score'] }[1]
  if runner_up && runner_up['fit_score'] >= best['fit_score'] - 15
    $stderr.puts "  Runner-up: #{runner_up['template']} (fit: #{runner_up['fit_score']})"
  end
  $stderr.puts
end

# --- Write output ---
output_dir = File.dirname(storylines_path)
output_path = File.join(output_dir, 'storylines_matched.yaml')

output_data = storylines_data.dup
output_data['storylines'] = storylines
output_data['template_matched_at'] = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')

File.write(output_path, output_data.to_yaml)

$stderr.puts "=" * 60
$stderr.puts "Output: #{output_path}"
puts output_path
