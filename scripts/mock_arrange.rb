#!/usr/bin/env ruby
# mock_arrange.rb — Deterministic mock arranger for arrangement schema v4.
#
# NOT the real arranger. Schema/mechanics validation prototype only.
# Uses simple heuristics instead of LLM reasoning.
#
# Usage:
#   ruby scripts/mock_arrange.rb --fixture <dir>
#   ruby scripts/mock_arrange.rb --fixture <dir> --validate-only
#
# Reads:  editorial_candidates.yaml from <dir>
# Writes: arrangement.yaml to <dir>
#
# Core invariant: LLMs judge meaning. Scripts handle mechanics.
# This mock replaces LLM judgment with deterministic scoring heuristics.

require 'yaml'
require 'digest'
require_relative 'arrangement_validator'
require 'set'

# ─── Constants ────────────────────────────────────────────────────────────────

MIN_EFFECTIVE_DURATION_S = 1.5
EXCLUSION_REMAINING_RATIO = 0.40
CHAPTER_SPLIT_MIN_SCORE = 2
MAX_CHAPTERS = 3

ENERGY_SCORE = { 'high' => 3, 'medium' => 2, 'low' => 1 }.freeze
PRIORITY_SCORE = { 'primary' => 3, 'secondary' => 2, 'tertiary' => 1 }.freeze
PROFILE_HOOK_BONUS = { 'emphatic' => 2, 'authoritative' => 1, 'building' => 1 }.freeze

VALID_NARRATIVE_ROLES = %w[hook setup continuation payoff transition claim evidence definition aside].freeze

CHAPTER_TITLES = ['Opening', 'Development', 'Resolution'].freeze

# ─── Helpers ──────────────────────────────────────────────────────────────────

def candidate_raw_duration(candidate)
  candidate['e'] - candidate['t']
end

def effective_duration(candidate)
  raw = candidate_raw_duration(candidate)
  dur = raw
  (candidate['exclusion_choices'] || []).each do |ex|
    next unless ex['recommended']
    ex_dur = ex['end'] - ex['start']
    remaining = dur - ex_dur
    dur = remaining if remaining >= raw * EXCLUSION_REMAINING_RATIO
  end
  dur
end

def candidate_score(c)
  ps = PRIORITY_SCORE[c['candidate_priority']] || 0
  es = ENERGY_SCORE[c.dig('prosody', 'energy')] || 0
  pb = PROFILE_HOOK_BONUS[c.dig('prosody', 'audio_profile')] || 0
  ps * 10 + es * 3 + pb
end

def select_safe_trim(candidate)
  candidate['trim_choices'].find do |t|
    t['mechanical_boundary_safe'] && t['content_preserved']
  end
end

def select_exclusions(candidate)
  raw = candidate_raw_duration(candidate)
  (candidate['exclusion_choices'] || []).select do |ex|
    next false unless ex['recommended']
    ex_dur = ex['end'] - ex['start']
    (raw - ex_dur) >= raw * EXCLUSION_REMAINING_RATIO
  end.map { |ex| ex['id'] }
end

def assign_role(candidate, position, total)
  return 'hook' if position == 0
  return 'payoff' if position == total - 1
  return 'claim' if candidate['candidate_priority'] == 'primary'
  return 'evidence' if effective_duration(candidate) > 8.0
  'continuation'
end

# ─── Chapter Splitting ────────────────────────────────────────────────────────

def compute_split_scores(selections, candidates_by_id)
  (1...selections.size).map do |i|
    prev_cand = candidates_by_id[selections[i - 1][:candidate_id]]
    curr_cand = candidates_by_id[selections[i][:candidate_id]]

    score = 0

    # Source-time gap (only positive gaps — temporal rewinds from hook pull are expected)
    gap = curr_cand['t'] - prev_cand['e']
    score += 4 if gap > 20.0
    score += 2 if gap > 10.0 && gap <= 20.0

    # Energy shift
    score += 3 if prev_cand.dig('prosody', 'energy') != curr_cand.dig('prosody', 'energy')

    # Profile shift
    score += 2 if prev_cand.dig('prosody', 'audio_profile') != curr_cand.dig('prosody', 'audio_profile')

    { index: i, score: score }
  end
end

def build_chapters(selections, candidates_by_id)
  return [{ segments: selections }] if selections.size <= 2

  split_scores = compute_split_scores(selections, candidates_by_id)
  qualified = split_scores.select { |s| s[:score] >= CHAPTER_SPLIT_MIN_SCORE }
  splits = qualified.sort_by { |s| -s[:score] }
                     .first(MAX_CHAPTERS - 1)
                     .map { |s| s[:index] }
                     .sort

  chapters = []
  prev = 0
  splits.each do |split_idx|
    chapters << { segments: selections[prev...split_idx] }
    prev = split_idx
  end
  chapters << { segments: selections[prev..] }
  chapters.reject { |ch| ch[:segments].empty? }
end

# ─── Unused Candidate Audit ──────────────────────────────────────────────────

def build_unused_audit(all_candidates, selected_candidates)
  selected_ids = Set.new(selected_candidates.map { |c| c['id'] })
  unused = all_candidates.reject { |c| selected_ids.include?(c['id']) }

  too_short = unused.select { |c| effective_duration(c) < MIN_EFFECTIVE_DURATION_S }
  other = unused.reject { |c| effective_duration(c) < MIN_EFFECTIVE_DURATION_S }

  {
    'cut_by_thesis' => [],
    'alternate_take_not_chosen' => [],
    'cut_for_pacing' => too_short.map { |c| c['id'] },
    'bridge_dropped' => other.map { |c| c['id'] }
  }
end

# ─── Core Arrangement Logic ──────────────────────────────────────────────────

def arrange(candidates_data)
  candidates = candidates_data['candidates']
  candidates_by_id = candidates.each_with_object({}) { |c, h| h[c['id']] = c }

  # Filter: skip unusable and too-short candidates
  eligible = candidates.select do |c|
    c['usability'] != 'unusable' && effective_duration(c) >= MIN_EFFECTIVE_DURATION_S
  end

  return nil if eligible.empty?

  used_clusters = Set.new

  # Hook: highest scoring candidate (ties broken by shorter duration = hookier)
  sorted = eligible.sort_by { |c| [-candidate_score(c), effective_duration(c)] }
  hook = sorted.first
  used_clusters << hook['cluster'] if hook['cluster'] && !hook['cluster'].to_s.strip.empty?

  # Remaining: source chronological order, skip duplicate clusters
  remaining = eligible.reject { |c| c['id'] == hook['id'] }.select do |c|
    cluster = c['cluster']
    if cluster && !cluster.to_s.strip.empty? && used_clusters.include?(cluster)
      false
    else
      used_clusters << cluster if cluster && !cluster.to_s.strip.empty?
      true
    end
  end
  remaining.sort_by! { |c| c['t'] }

  ordered = [hook] + remaining

  # Build segment selections
  selections = ordered.each_with_index.map do |c, i|
    trim = select_safe_trim(c)
    next nil unless trim
    {
      candidate_id: c['id'],
      trim_choice_id: trim['id'],
      exclusion_choice_ids: select_exclusions(c),
      narrative_role: assign_role(c, i, ordered.size)
    }
  end.compact

  return nil if selections.size < 2 # Need at least hook + payoff

  # Build chapters
  chapter_groups = build_chapters(selections, candidates_by_id)

  # Fingerprint
  fingerprint = Digest::SHA256.hexdigest(candidates_data.to_yaml + 'A')

  {
    'version' => '4',
    'branch' => 'A',
    'selected_thesis' => nil,
    'input_fingerprint' => fingerprint,
    'generated_at' => 'deterministic',
    'model' => 'deterministic-mock',
    'arrangement_reasoning' => 'Deterministic mock arrangement. Hook by prosody/priority score. Remaining in source chronological order. Chapters split by energy/profile shifts and source gaps.',
    'chapters' => chapter_groups.each_with_index.map do |ch, ci|
      {
        'id' => format('chapter_%03d', ci + 1),
        'title' => CHAPTER_TITLES[ci] || format('Chapter %d', ci + 1),
        'segments' => ch[:segments].map do |s|
          {
            'candidate_id' => s[:candidate_id],
            'trim_choice_id' => s[:trim_choice_id],
            'exclusion_choice_ids' => s[:exclusion_choice_ids],
            'narrative_role' => s[:narrative_role]
          }
        end
      }
    end,
    'unused_candidate_audit' => build_unused_audit(candidates, ordered)
  }
end

# ─── Validation ───────────────────────────────────────────────────────────────

def validate_arrangement(arrangement, candidates_data)
  ArrangementValidator.validate(arrangement, candidates_data)
end

# ─── Main ─────────────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  args = {}
  ARGV.each_with_index do |arg, i|
    case arg
    when '--fixture' then args[:fixture_dir] = ARGV[i + 1]
    when '--validate-only' then args[:validate_only] = true
    end
  end

  abort 'Usage: ruby scripts/mock_arrange.rb --fixture <dir>' unless args[:fixture_dir]

  candidates_path = File.join(args[:fixture_dir], 'editorial_candidates.yaml')
  abort "editorial_candidates.yaml not found in #{args[:fixture_dir]}" unless File.exist?(candidates_path)
  candidates_data = YAML.safe_load(File.read(candidates_path))

  if args[:validate_only]
    arrangement_path = File.join(args[:fixture_dir], 'arrangement.yaml')
    abort 'arrangement.yaml not found' unless File.exist?(arrangement_path)
    arrangement = YAML.safe_load(File.read(arrangement_path))
    result = validate_arrangement(arrangement, candidates_data)
    result[:warnings].each { |w| $stderr.puts w }
    if result[:errors].empty?
      puts 'Arrangement validation passed: 0 errors'
      exit 0
    else
      result[:errors].each { |e| $stderr.puts "ERROR: #{e}" }
      exit 1
    end
  end

  arrangement = arrange(candidates_data)
  abort 'Arrangement failed: no eligible candidates' unless arrangement

  # Self-validate before writing
  result = validate_arrangement(arrangement, candidates_data)
  result[:warnings].each { |w| $stderr.puts w }
  unless result[:errors].empty?
    $stderr.puts 'Self-validation FAILED:'
    result[:errors].each { |e| $stderr.puts "  ERROR: #{e}" }
    exit 1
  end

  output_path = File.join(args[:fixture_dir], 'arrangement.yaml')
  File.write(output_path, arrangement.to_yaml)

  total_segs = arrangement['chapters'].sum { |ch| ch['segments'].size }
  puts "arrangement.yaml written: #{arrangement['chapters'].size} chapters, #{total_segs} segments"
  puts output_path
end
