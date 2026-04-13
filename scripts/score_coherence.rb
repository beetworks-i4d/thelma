#!/usr/bin/env ruby
# Phase 1.8 — Coherence Pass & Combined Ranking
# Two-mode script: --prepare builds LLM evaluation payloads, --apply merges scores and ranks.
#
# Usage:
#   ruby scripts/score_coherence.rb --prepare <storylines_matched.yaml> <segments_classified.yaml>
#   ruby scripts/score_coherence.rb --apply <coherence_prep.yaml> <coherence_scores.yaml>
#
# Prepare outputs: coherence_prep.yaml (same directory as storylines_matched.yaml)
# Apply outputs: storylines_scored.yaml (same directory as coherence_prep.yaml)

require 'yaml'
require 'date'

mode = ARGV.shift
abort "Usage: ruby scripts/score_coherence.rb --prepare|--apply <files...>" unless %w[--prepare --apply].include?(mode)

# ============================================================
# PREPARE MODE
# ============================================================
if mode == '--prepare'
  matched_path = ARGV[0]
  classified_path = ARGV[1]
  abort "Usage: ruby scripts/score_coherence.rb --prepare <storylines_matched.yaml> <segments_classified.yaml>" unless matched_path && classified_path
  abort "File not found: #{matched_path}" unless File.exist?(matched_path)
  abort "File not found: #{classified_path}" unless File.exist?(classified_path)

  matched_data = YAML.safe_load(File.read(matched_path), permitted_classes: [Date])
  classified_data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])

  storylines = matched_data['storylines'] || []
  segments = classified_data['segments'] || []

  # Build segment lookup by t-value
  seg_by_t = {}
  segments.each { |s| seg_by_t[s['t'].to_f] = s }

  candidates = []

  storylines.each do |storyline|
    hook_t = storyline['hook_segment'].to_f
    close_t = storyline['close_segment'].to_f

    # Reconstruct distillation sequence (same logic as match_templates.rb)
    hook_seg = seg_by_t[hook_t]
    close_seg = seg_by_t[close_t]
    body_segs = segments.select { |s| s['t'].to_f > hook_t && s['t'].to_f < close_t }
                        .sort_by { |s| s['t'].to_f }

    distillations = []
    distillations << hook_seg['distillation'] if hook_seg
    body_segs.each { |s| distillations << s['distillation'] }
    distillations << close_seg['distillation'] if close_seg

    template_match = storyline['template_match'] || {}
    template_name = template_match['template'] || 'none'
    completeness = template_match['completeness'] || 0
    missing = template_match['missing_beats'] || []

    # Build numbered clip list for the prompt
    clip_lines = distillations.each_with_index.map { |d, i| "#{i + 1}. \"#{d}\"" }.join("\n")

    prompt = <<~PROMPT
      Rate narrative coherence 0-100 for this distilled clip sequence.
      Template: #{template_name} (#{completeness}% complete, #{missing.length} missing beats#{missing.any? ? ": #{missing.join(', ')}" : ''})
      Clips in order:
      #{clip_lines}
      Score criteria:
      - Do ideas flow logically from one to the next?
      - Does the sequence build toward a conclusion?
      - Are there jarring topic jumps or redundant clusters?
      Return ONLY valid YAML:
      coherence_score: <0-100>
      issues:
        - "<issue description>"
    PROMPT

    candidates << {
      'id' => storyline['id'],
      'profile' => storyline['profile'],
      'state_score' => storyline['score'],
      'template_fit' => template_match['fit_score'] || 0,
      'template_name' => template_name,
      'missing_beats' => missing,
      'segment_count' => distillations.length,
      'distillation_sequence' => distillations,
      'evaluation_prompt' => prompt.strip
    }
  end

  output_dir = File.dirname(matched_path)
  output_path = File.join(output_dir, 'coherence_prep.yaml')

  output = {
    'prepared_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
    'source_matched' => File.basename(matched_path),
    'source_classified' => File.basename(classified_path),
    'candidates' => candidates
  }

  File.write(output_path, output.to_yaml)
  $stderr.puts "Prepared #{candidates.length} candidates for coherence evaluation"
  $stderr.puts "Output: #{output_path}"
  puts output_path

# ============================================================
# APPLY MODE
# ============================================================
elsif mode == '--apply'
  prep_path = ARGV[0]
  scores_path = ARGV[1]
  abort "Usage: ruby scripts/score_coherence.rb --apply <coherence_prep.yaml> <coherence_scores.yaml>" unless prep_path && scores_path
  abort "File not found: #{prep_path}" unless File.exist?(prep_path)
  abort "File not found: #{scores_path}" unless File.exist?(scores_path)

  prep_data = YAML.safe_load(File.read(prep_path), permitted_classes: [Date])
  scores_data = YAML.safe_load(File.read(scores_path), permitted_classes: [Date])

  candidates = prep_data['candidates'] || []
  scores_list = scores_data['scores'] || []

  # Build score lookup by id
  score_by_id = {}
  scores_list.each { |s| score_by_id[s['id']] = s }

  # Load the original storylines_matched.yaml to preserve all fields
  source_matched = prep_data['source_matched']
  output_dir = File.dirname(prep_path)
  matched_path = File.join(output_dir, source_matched)
  abort "Source file not found: #{matched_path}" unless File.exist?(matched_path)

  matched_data = YAML.safe_load(File.read(matched_path), permitted_classes: [Date])
  storylines = matched_data['storylines'] || []

  # Merge coherence scores and compute combined scores
  storylines.each do |storyline|
    id = storyline['id']
    candidate = candidates.find { |c| c['id'] == id }
    score_entry = score_by_id[id]

    unless candidate && score_entry
      $stderr.puts "WARNING: No coherence score for #{id}, using 0"
      storyline['coherence'] = { 'score' => 0, 'issues' => ['No coherence evaluation available'] }
      storyline['combined_score'] = (storyline['score'] * 0.3 + (storyline.dig('template_match', 'fit_score') || 0) * 0.4).round
      storyline['quality_pass'] = storyline['combined_score'] >= 60
      next
    end

    state_score = candidate['state_score']
    template_fit = candidate['template_fit']
    coherence_score = score_entry['coherence_score']
    issues = score_entry['issues'] || []

    combined = (state_score * 0.3 + template_fit * 0.4 + coherence_score * 0.3).round

    storyline['coherence'] = {
      'score' => coherence_score,
      'issues' => issues
    }
    storyline['combined_score'] = combined
    storyline['quality_pass'] = combined >= 60
  end

  # Rank within each profile
  profiles = storylines.group_by { |s| s['profile'] }
  profiles.each do |profile_name, group|
    passing = group.select { |s| s['quality_pass'] }
                   .sort_by { |s| -s['combined_score'] }
    passing.each_with_index { |s, i| s['rank'] = i + 1 if i < 3 }
  end

  # Write output
  output_path = File.join(output_dir, 'storylines_scored.yaml')
  output_data = matched_data.dup
  output_data['storylines'] = storylines
  output_data['coherence_scored_at'] = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
  # Remove template_matched_at since we're superseding it
  output_data.delete('template_matched_at')

  File.write(output_path, output_data.to_yaml)

  # Report
  $stderr.puts "=" * 60
  $stderr.puts "COMBINED SCORING REPORT"
  $stderr.puts "=" * 60

  profiles.each do |profile_name, group|
    $stderr.puts "\nProfile: #{profile_name}"
    ranked = group.sort_by { |s| -s['combined_score'] }
    ranked.each do |s|
      rank_str = s['rank'] ? "##{s['rank']}" : "  "
      pass_str = s['quality_pass'] ? 'PASS' : 'FAIL'
      coherence_val = s.dig('coherence', 'score') || 0
      $stderr.puts "  #{rank_str} #{s['id']} — combined: #{s['combined_score']} " \
                   "(state: #{s['score']}, template: #{s.dig('template_match', 'fit_score')}, " \
                   "coherence: #{coherence_val}) #{pass_str}"
    end
  end

  total = storylines.length
  passing = storylines.count { |s| s['quality_pass'] }
  $stderr.puts "\nSummary: #{passing}/#{total} candidates pass quality floor (combined >= 60)"

  top3 = storylines.select { |s| s['rank'] }.sort_by { |s| -s['combined_score'] }.first(3)
  if top3.any?
    $stderr.puts "Top candidates: #{top3.map { |s| "#{s['id']} (#{s['combined_score']})" }.join(', ')}"
  end

  $stderr.puts "\nOutput: #{output_path}"
  puts output_path
end
