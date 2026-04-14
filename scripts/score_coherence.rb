#!/usr/bin/env ruby
# Phase 1.8 — Coherence Scoring & Combined Ranking (single-pass)
# Reads storylines_matched.yaml + segments_classified.yaml, scores coherence
# algorithmically, computes combined ranking, writes storylines_scored.yaml.
#
# Usage: ruby scripts/score_coherence.rb <storylines_matched.yaml> <segments_classified.yaml>
# Output: storylines_scored.yaml (same directory as storylines_matched.yaml). Path to stdout.
#
# Combined score = state_score × 0.3 + template_fit × 0.4 + coherence_score × 0.3
# Quality floor: 60. Below = passed_floor: false.

require 'yaml'
require 'date'
require 'set'

matched_path = ARGV[0]
classified_path = ARGV[1]
abort "Usage: ruby scripts/score_coherence.rb <storylines_matched.yaml> <segments_classified.yaml>" unless matched_path && classified_path
abort "File not found: #{matched_path}" unless File.exist?(matched_path)
abort "File not found: #{classified_path}" unless File.exist?(classified_path)

matched_data = YAML.safe_load(File.read(matched_path), permitted_classes: [Date])
classified_data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])

storylines = matched_data['storylines'] || []
segments = classified_data['segments'] || []

abort "No storylines found in #{matched_path}" if storylines.empty?

# Segment lookup by t-value
seg_by_t = {}
segments.each { |s| seg_by_t[s['t'].to_f] = s }

# Incompatible state pairs (from discover_storylines.rb / content_psychopharmacology.md)
INCOMPATIBLE_PAIRS = [
  Set['sensual', 'calm'],
  Set['schadenfreude', 'awe'],
  Set['outrage', 'amusement'],
  Set['belonging', 'schadenfreude'],
  Set['calm', 'fear']
].freeze

def incompatible?(states_a, states_b)
  states_a.each do |a|
    states_b.each do |b|
      return true if INCOMPATIBLE_PAIRS.include?(Set[a, b])
    end
  end
  false
end

# Reconstruct arc segments for a storyline
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

# Score coherence algorithmically (0-100, penalty-based)
def score_coherence(arc)
  hook = arc[:hook]
  body = arc[:body]
  close = arc[:close]

  all_segs = [hook, *body, close].compact
  return { score: 0, issues: ['No segments in arc'] } if all_segs.empty?

  score = 100
  issues = []

  # 1. Missing close (-15)
  unless close
    score -= 15
    issues << 'No close segment — arc ends open'
  end

  # 2. Hook-close state disconnect (-10)
  if hook && close
    hook_states = Set.new(hook['states'] || [])
    close_states = Set.new(close['states'] || [])
    if (hook_states & close_states).empty?
      score -= 10
      issues << "Hook states #{hook_states.to_a} share nothing with close states #{close_states.to_a}"
    end
  end

  # 3. Incompatible adjacent transitions (-5 each, max -25)
  incompat_count = 0
  all_segs.each_cons(2) do |a, b|
    if incompatible?(a['states'] || [], b['states'] || [])
      incompat_count += 1
    end
  end
  if incompat_count > 0
    penalty = [incompat_count * 5, 25].min
    score -= penalty
    issues << "#{incompat_count} incompatible adjacent transition(s)"
  end

  # 4. Redundant state clusters (-3 per segment beyond 3 in a run, max -25)
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

  # 5. Low distillation diversity (-0 to -15)
  distillations = all_segs.map { |s| s['distillation'] }.compact
  if distillations.size > 1
    unique_ratio = distillations.uniq.size.to_f / distillations.size
    if unique_ratio < 0.7
      penalty = ((0.7 - unique_ratio) / 0.7 * 15).round
      score -= penalty
      issues << "Low distillation diversity (#{(unique_ratio * 100).round}% unique)"
    end
  end

  # 6. Short body (-10)
  if body.size < 3 && (hook || close)
    score -= 10
    issues << "Short body (#{body.size} segments) — limited narrative development"
  end

  { score: [score, 0].max, issues: issues }
end

# --- Score each storyline ---

output_storylines = []

storylines.each do |storyline|
  arc = reconstruct_arc(storyline, seg_by_t, segments)
  coherence = score_coherence(arc)

  state_score = storyline['score'] || 0
  template_fit = storyline.dig('template_match', 'fit_score') || 0
  coherence_score = coherence[:score]

  combined = (state_score * 0.3 + template_fit * 0.4 + coherence_score * 0.3).round
  passed_floor = combined >= 60

  output_storylines << {
    'id' => storyline['id'],
    'profile' => storyline['profile'],
    'state_score' => state_score,
    'template_fit' => template_fit,
    'coherence_score' => coherence_score,
    'coherence_issues' => coherence[:issues].empty? ? nil : coherence[:issues],
    'combined_score' => combined,
    'passed_floor' => passed_floor,
    # Preserve useful fields for Phase 2
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
  }.compact
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
  'storylines' => output_storylines
}

File.write(output_path, output.to_yaml)

# --- Report ---

$stderr.puts "=" * 60
$stderr.puts "COHERENCE SCORING REPORT"
$stderr.puts "=" * 60

profiles.each do |profile_name, group|
  $stderr.puts "\nProfile: #{profile_name}"
  ranked = group.sort_by { |s| -s['combined_score'] }
  ranked.each do |s|
    rank_str = s['rank'] ? "##{s['rank']}" : "  "
    pass_str = s['passed_floor'] ? 'PASS' : 'FAIL'
    $stderr.puts "  #{rank_str} #{s['id']} — combined: #{s['combined_score']} " \
                 "(state: #{s['state_score']}, template: #{s['template_fit']}, " \
                 "coherence: #{s['coherence_score']}) #{pass_str}"
  end
end

total = output_storylines.length
passing = output_storylines.count { |s| s['passed_floor'] }
$stderr.puts "\nSummary: #{passing}/#{total} candidates pass quality floor (combined >= 60)"
$stderr.puts "Output: #{output_path}"
puts output_path
