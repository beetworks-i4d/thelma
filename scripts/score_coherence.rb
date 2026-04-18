#!/usr/bin/env ruby
# Phase 1.8 — Coherence Scoring & Combined Ranking
# Two-layer scoring: algorithmic pre-filter + LLM narrative judgment.
#
# Usage:
#   ruby scripts/score_coherence.rb <storylines_matched.yaml> <segments_classified.yaml>
#   ruby scripts/score_coherence.rb --no-llm <storylines_matched.yaml> <segments_classified.yaml>
#
# Default: writes storylines_scored.yaml with algorithmic scores and llm_eval_prompt
#          for candidates passing algorithmic threshold (>= 50). Agent reads prompts,
#          evaluates coherence, and updates llm_coherence + coherence_score in place.
# --no-llm: algorithmic-only mode, coherence_score = algorithmic_coherence (final).
#
# Output: storylines_scored.yaml (same directory as storylines_matched.yaml). Path to stdout.
# Combined score = state_score × 0.3 + template_fit × 0.4 + coherence_score × 0.3
# Quality floor: 60. Below = passed_floor: false.

require 'yaml'
require 'date'
require 'set'

# Parse flags
no_llm = ARGV.delete('--no-llm')
profile_name = nil
if (idx = ARGV.index('--profile'))
  profile_name = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end
matched_path = ARGV[0]
classified_path = ARGV[1]
abort "Usage: ruby scripts/score_coherence.rb [--no-llm] [--profile <name>] <storylines_matched.yaml> <segments_classified.yaml>" unless matched_path && classified_path
abort "File not found: #{matched_path}" unless File.exist?(matched_path)
abort "File not found: #{classified_path}" unless File.exist?(classified_path)

matched_data = YAML.safe_load(File.read(matched_path), permitted_classes: [Date])
classified_data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])

storylines = matched_data['storylines'] || []
segments = classified_data['segments'] || []

abort "No storylines found in #{matched_path}" if storylines.empty?

# === Load profile ===
require_relative 'load_profile'
profile = if profile_name
             load_profile_by_name(profile_name)
           else
             load_profile(File.basename(File.dirname(matched_path)))
           end
template_affinities = profile['template_affinities'] || []
closing_durability_pref = profile['closing_durability_preference']

# Segment lookup by t-value
seg_by_t = {}
segments.each { |s| seg_by_t[s['t'].to_f] = s }

INCOMPATIBLE_PAIRS = [
  Set['sensual', 'calm'],
  Set['schadenfreude', 'awe'],
  Set['outrage', 'amusement'],
  Set['belonging', 'schadenfreude'],
  Set['calm', 'fear']
].freeze

LLM_ALGORITHMIC_THRESHOLD = 50

def incompatible?(states_a, states_b)
  states_a.each do |a|
    states_b.each do |b|
      return true if INCOMPATIBLE_PAIRS.include?(Set[a, b])
    end
  end
  false
end

def reconstruct_arc(storyline, seg_by_t, all_segments)
  hook_t = storyline['hook_segment']&.to_f
  close_t = storyline['close_segment']&.to_f

  hook_seg = hook_t ? seg_by_t[hook_t] : nil
  close_seg = close_t ? seg_by_t[close_t] : nil

  body_segs = all_segments.select { |s|
    t = s['t'].to_f
    hook_t && t > hook_t && (close_t.nil? || t < close_t)
  }.sort_by { |s| s['t'].to_f }

  { hook: hook_seg, body: body_segs, close: close_seg }
end

def score_coherence_algorithmic(arc)
  hook = arc[:hook]
  body = arc[:body]
  close = arc[:close]

  all_segs = [hook, *body, close].compact
  return { score: 0, issues: ['No segments in arc'] } if all_segs.empty?

  score = 100
  issues = []

  unless close
    score -= 15
    issues << 'No close segment — arc ends open'
  end

  if hook && close
    hook_states = Set.new(hook['states'] || [])
    close_states = Set.new(close['states'] || [])
    if (hook_states & close_states).empty?
      score -= 10
      issues << "Hook states #{hook_states.to_a} share nothing with close states #{close_states.to_a}"
    end
  end

  incompat_count = 0
  all_segs.each_cons(2) do |a, b|
    incompat_count += 1 if incompatible?(a['states'] || [], b['states'] || [])
  end
  if incompat_count > 0
    penalty = [incompat_count * 5, 25].min
    score -= penalty
    issues << "#{incompat_count} incompatible adjacent transition(s)"
  end

  runs = []
  current_run = 1
  all_segs.each_cons(2) do |a, b|
    if (a['states'] || []).first == (b['states'] || []).first
      current_run += 1
    else
      runs << current_run if current_run > 3
      current_run = 1
    end
  end
  runs << current_run if current_run > 3
  excess = runs.sum { |r| r - 3 }
  if excess > 0
    penalty = [excess * 3, 25].min
    score -= penalty
    primary = all_segs.map { |s| (s['states'] || []).first }.compact
    longest_state = primary.chunk { |s| s }.map { |_, g| [g.first, g.size] }.max_by(&:last)
    issues << "#{longest_state[1]}-segment #{longest_state[0]} cluster (redundancy risk)" if longest_state
  end

  distillations = all_segs.map { |s| s['distillation'] }.compact
  if distillations.size > 1
    unique_ratio = distillations.uniq.size.to_f / distillations.size
    if unique_ratio < 0.7
      penalty = ((0.7 - unique_ratio) / 0.7 * 15).round
      score -= penalty
      issues << "Low distillation diversity (#{(unique_ratio * 100).round}% unique)"
    end
  end

  if body.size < 3 && (hook || close)
    score -= 10
    issues << "Short body (#{body.size} segments) — limited narrative development"
  end

  { score: [score, 0].max, issues: issues }
end

def build_llm_prompt(distillations, template_name)
  clip_lines = distillations.each_with_index.map { |d, i| "#{i + 1}. #{d}" }.join("\n")
  <<~PROMPT.strip
    Read this proposed video cut as distilled clip order. Judge whether it makes sense as a complete piece of communication from a cold viewer's perspective.

    Score 0-100:
    - 90-100: holds together completely, viewer can follow start to finish
    - 70-89: mostly coherent, minor jumps or unclear transitions
    - 50-69: noticeable incoherence, viewer would need to re-watch or guess
    - Below 50: fundamentally broken, doesn't work as a piece

    List specific issues if any:
    - Unexplained jumps in argument or topic
    - Missing context for ideas the body assumes
    - Conclusions that don't follow from what came before
    - Lost threads
    - Tonal or rhetorical shifts that break the frame

    Transformation arcs ("I was lost, then I found it") are coherent, not contradictory. Apparent contradictions with reframing language are fine. Only flag direct incoherence.

    Template match: #{template_name}
    Distilled clip order:
    #{clip_lines}
  PROMPT
end

# --- Score each storyline ---

output_storylines = []
llm_eligible_count = 0

storylines.each do |storyline|
  arc = reconstruct_arc(storyline, seg_by_t, segments)
  algorithmic = score_coherence_algorithmic(arc)

  state_score = storyline['score'] || 0
  template_fit = storyline.dig('template_match', 'fit_score') || 0
  algorithmic_coherence = algorithmic[:score]

  # In --no-llm mode, algorithmic score IS the final coherence score.
  # In default mode, algorithmic is placeholder until agent fills llm_coherence.
  coherence_score = algorithmic_coherence

  combined = (state_score * 0.3 + template_fit * 0.4 + coherence_score * 0.3).round

  # Profile bonuses: template affinity and closing durability preference
  matched_template = storyline.dig('template_match', 'template')
  if matched_template && template_affinities.include?(matched_template)
    combined += 5
  end
  if closing_durability_pref
    close_t = storyline['close_segment']
    close_seg = close_t ? seg_by_t[close_t.to_f] : nil
    if close_seg && close_seg['dur'] == closing_durability_pref
      combined += 3
    end
  end

  passed_floor = combined >= 60

  entry = {
    'id' => storyline['id'],
    'profile' => storyline['profile'],
    'state_score' => state_score,
    'template_fit' => template_fit,
    'algorithmic_coherence' => algorithmic_coherence,
    'llm_coherence' => nil,
    'coherence_score' => coherence_score,
    'coherence_issues' => algorithmic[:issues].empty? ? nil : algorithmic[:issues],
    'combined_score' => combined,
    'passed_floor' => passed_floor,
    'primary_state' => storyline['primary_state'],
    'secondary_states' => storyline['secondary_states'],
    'hook_segment' => storyline['hook_segment'],
    'hook_signal' => storyline['hook_signal'],
    'close_segment' => storyline['close_segment'],
    'close_signal' => storyline['close_signal'],
    'duration_estimate' => storyline['duration_estimate'],
    'segment_count' => storyline['segment_count'],
    'arc' => storyline['arc'],
    'pitch' => storyline['pitch'],
    'template_match' => storyline['template_match']
  }
  # Compact optional fields but preserve llm_coherence (intentionally nil until agent fills)
  entry.reject! { |k, v| v.nil? && k != 'llm_coherence' }

  # Build LLM prompt for eligible candidates (unless --no-llm)
  if !no_llm && algorithmic_coherence >= LLM_ALGORITHMIC_THRESHOLD
    all_segs = [arc[:hook], *arc[:body], arc[:close]].compact
    distillations = all_segs.map { |s| s['distillation'] }.compact
    template_name = storyline.dig('template_match', 'template') || 'none'
    entry['llm_eval_prompt'] = build_llm_prompt(distillations, template_name)
    llm_eligible_count += 1
  end

  output_storylines << entry
end

# Rank within each profile (passing candidates only, top 3)
profiles = output_storylines.group_by { |s| s['profile'] }
profiles.each do |_name, group|
  passing = group.select { |s| s['passed_floor'] }
                 .sort_by { |s| -s['combined_score'] }
  passing.each_with_index { |s, i| s['rank'] = i + 1 if i < 3 }
end

# --- Write output ---

output_dir = File.dirname(matched_path)
output_path = File.join(output_dir, 'storylines_scored.yaml')
source_name = File.basename(output_dir)

output = {
  'generated_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'source' => source_name,
  'transcript_hash' => matched_data['transcript_hash'],
  'scoring_mode' => no_llm ? 'algorithmic_only' : 'algorithmic_plus_llm',
  'llm_pass_pending' => !no_llm && llm_eligible_count > 0,
  'storylines' => output_storylines
}

File.write(output_path, output.to_yaml)

# --- Report ---

$stderr.puts "=" * 60
$stderr.puts "COHERENCE SCORING REPORT"
$stderr.puts "=" * 60
$stderr.puts "Mode: #{no_llm ? 'algorithmic only' : "algorithmic + LLM (#{llm_eligible_count} eligible)"}"

profiles.each do |profile_name, group|
  $stderr.puts "\nProfile: #{profile_name}"
  ranked = group.sort_by { |s| -s['combined_score'] }
  ranked.each do |s|
    rank_str = s['rank'] ? "##{s['rank']}" : "  "
    pass_str = s['passed_floor'] ? 'PASS' : 'FAIL'
    llm_str = s['llm_eval_prompt'] ? ' [LLM pending]' : ''
    $stderr.puts "  #{rank_str} #{s['id']} — combined: #{s['combined_score']} " \
                 "(state: #{s['state_score']}, template: #{s['template_fit']}, " \
                 "coherence: #{s['algorithmic_coherence']}) #{pass_str}#{llm_str}"
  end
end

total = output_storylines.length
passing = output_storylines.count { |s| s['passed_floor'] }
$stderr.puts "\nSummary: #{passing}/#{total} pass quality floor (combined >= 60)"
$stderr.puts "Output: #{output_path}"
puts output_path
