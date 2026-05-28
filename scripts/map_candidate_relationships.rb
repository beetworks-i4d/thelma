#!/usr/bin/env ruby
# map_candidate_relationships.rb — Pass 2: deterministic relationship mapping.
#
# Identifies semantic relationships between editorial candidates using
# text-based heuristics. No LLM calls. Deterministic output.
#
# Usage:
#   ruby scripts/map_candidate_relationships.rb --fixture <dir>
#
# Reads:  editorial_candidates.yaml from <dir>
# Writes: candidate_relationships.yaml to <dir>
#
# Core invariant: LLMs judge meaning. Scripts handle mechanics.
# This script provides deterministic heuristic relationships as a
# baseline. Future LLM pass will produce richer semantic relationships.

require 'yaml'
require 'digest'
require 'set'
require 'date'

# ─── Constants ────────────────────────────────────────────────────────────────

VALID_RELATIONSHIP_TYPES = %w[
  duplicate_of alternate_take_of supports example_of elaborates
  contradicts setup_for payoff_of tangent_from bridge_to
].freeze

VALID_CONFIDENCES = %w[high medium low].freeze

STOP_WORDS = Set.new(%w[
  a an the and or but is are was were be been being
  in on at to for of with by from as into through
  i you he she it we they me him her us them
  my your his its our their
  this that these those what which who whom
  do does did not no nor
  so if then than when where how why
  just really very actually even also too
  have has had get got
]).freeze

EXAMPLE_MARKERS = ['for example', 'for instance', 'like when', 'such as', 'like this'].freeze
CONTRAST_MARKERS = %w[but however actually although though].freeze
CONTRAST_PHRASES = ['the problem is', 'the thing is', 'on the other hand', 'the truth is'].freeze
BRIDGE_MARKERS = ['so let me', 'now let', 'let me', 'moving on', 'next', 'so stick'].freeze
SETUP_MARKERS = ['have you', 'do you', 'what if', 'imagine', 'think about', 'nobody tells'].freeze
PAYOFF_MARKERS = ['that is why', "that's why", "that's when", 'and that is', "and that's",
                  'same person', 'completely different', 'the answer', 'the solution'].freeze

DUPLICATE_OVERLAP_THRESHOLD = 0.70
SUPPORTS_OVERLAP_THRESHOLD  = 0.20
ELABORATES_OVERLAP_THRESHOLD = 0.15
TANGENT_OVERLAP_CEILING = 0.10

# ─── Text Analysis Helpers ────────────────────────────────────────────────────

def content_words(text)
  text.downcase.gsub(/[^a-z0-9\s']/, ' ').split.reject { |w| STOP_WORDS.include?(w) }
end

def word_overlap_ratio(words_a, words_b)
  return 0.0 if words_a.empty? || words_b.empty?
  set_a = Set.new(words_a)
  set_b = Set.new(words_b)
  intersection = set_a & set_b
  smaller = [set_a.size, set_b.size].min
  intersection.size.to_f / smaller
end

def shared_terms(words_a, words_b)
  (Set.new(words_a) & Set.new(words_b)).to_a.sort
end

def text_contains_marker?(text, markers)
  lower = text.downcase
  markers.any? { |m| lower.include?(m) }
end

def candidates_adjacent_in_source?(a, b)
  return false unless a['source'] == b['source']
  gap = (b['t'] - a['e']).abs
  gap < 15.0
end

def candidate_precedes?(a, b)
  a['source'] == b['source'] && a['e'] <= b['t'] + 0.5
end

# ─── Relationship Detection ──────────────────────────────────────────────────

def detect_relationships(candidates)
  relationships = []
  rel_counter = 0

  pairs_seen = Set.new

  candidates.each_with_index do |a, i|
    words_a = content_words(a['text'])
    candidates.each_with_index do |b, j|
      next if i >= j # Only check each unordered pair once
      words_b = content_words(b['text'])
      overlap = word_overlap_ratio(words_a, words_b)
      shared = shared_terms(words_a, words_b)

      # ── duplicate_of: very high text overlap ──
      if overlap >= DUPLICATE_OVERLAP_THRESHOLD
        rel_counter += 1
        relationships << build_rel(rel_counter, 'duplicate_of', a, b, 'high',
          "text overlap #{(overlap * 100).round}%: #{shared.first(5).join(', ')}")
        next # Don't add more relationships for near-duplicates
      end

      # ── alternate_take_of: same cluster ──
      if a['cluster'] && b['cluster'] && a['cluster'] == b['cluster']
        rel_counter += 1
        relationships << build_rel(rel_counter, 'alternate_take_of', a, b, 'high',
          "same cluster: #{a['cluster']}")
      end

      # ── contradicts: contrast markers + some overlap ──
      if overlap >= ELABORATES_OVERLAP_THRESHOLD
        a_contrasts = text_contains_marker?(a['text'], CONTRAST_MARKERS) ||
                      text_contains_marker?(a['text'], CONTRAST_PHRASES)
        b_contrasts = text_contains_marker?(b['text'], CONTRAST_MARKERS) ||
                      text_contains_marker?(b['text'], CONTRAST_PHRASES)
        if a_contrasts || b_contrasts
          from, to = a_contrasts ? [b, a] : [a, b]
          pair_key = "contradicts:#{from['id']}:#{to['id']}"
          unless pairs_seen.include?(pair_key)
            pairs_seen << pair_key
            rel_counter += 1
            relationships << build_rel(rel_counter, 'contradicts', from, to, 'medium',
              "contrast marker + shared terms: #{shared.first(3).join(', ')}")
          end
        end
      end

      # ── example_of: example markers in one, claim/hook role in other ──
      [a, b].each_with_index do |example_cand, idx|
        other = idx == 0 ? b : a
        if text_contains_marker?(example_cand['text'], EXAMPLE_MARKERS)
          other_roles = (other['suggested_narrative_roles'] || []).map { |r| r['role'] }
          if other_roles.include?('claim') || other_roles.include?('hook')
            pair_key = "example_of:#{example_cand['id']}:#{other['id']}"
            unless pairs_seen.include?(pair_key)
              pairs_seen << pair_key
              rel_counter += 1
              relationships << build_rel(rel_counter, 'example_of', example_cand, other, 'medium',
                "example marker in #{example_cand['id']}, #{other['id']} has #{other_roles.first} role")
            end
          end
        end
      end

      # ── supports: claim + evidence with lexical overlap ──
      if overlap >= SUPPORTS_OVERLAP_THRESHOLD
        a_roles = (a['suggested_narrative_roles'] || []).map { |r| r['role'] }
        b_roles = (b['suggested_narrative_roles'] || []).map { |r| r['role'] }

        claim_cand, evidence_cand = nil, nil
        if (a_roles.include?('claim') || a_roles.include?('hook')) &&
           (b_roles.include?('evidence') || b_roles.include?('continuation') || b_roles.include?('setup'))
          claim_cand, evidence_cand = a, b
        elsif (b_roles.include?('claim') || b_roles.include?('hook')) &&
              (a_roles.include?('evidence') || a_roles.include?('continuation') || a_roles.include?('setup'))
          claim_cand, evidence_cand = b, a
        end

        if claim_cand && evidence_cand
          pair_key = "supports:#{evidence_cand['id']}:#{claim_cand['id']}"
          unless pairs_seen.include?(pair_key)
            pairs_seen << pair_key
            rel_counter += 1
            conf = overlap >= 0.35 ? 'high' : 'medium'
            relationships << build_rel(rel_counter, 'supports', evidence_cand, claim_cand, conf,
              "#{evidence_cand['id']} (#{(evidence_cand['suggested_narrative_roles']||[]).first&.dig('role')}) supports #{claim_cand['id']} (#{(claim_cand['suggested_narrative_roles']||[]).first&.dig('role')}); shared: #{shared.first(4).join(', ')}")
          end
        end
      end

      # ── elaborates: moderate overlap + continuation role ──
      if overlap >= ELABORATES_OVERLAP_THRESHOLD && overlap < DUPLICATE_OVERLAP_THRESHOLD
        a_roles = (a['suggested_narrative_roles'] || []).map { |r| r['role'] }
        b_roles = (b['suggested_narrative_roles'] || []).map { |r| r['role'] }

        if a_roles.include?('continuation') && candidate_precedes?(a, b) == false && candidate_precedes?(b, a)
          pair_key = "elaborates:#{a['id']}:#{b['id']}"
          unless pairs_seen.include?(pair_key)
            pairs_seen << pair_key
            rel_counter += 1
            relationships << build_rel(rel_counter, 'elaborates', a, b, 'low',
              "#{a['id']} continues theme of #{b['id']}; shared: #{shared.first(3).join(', ')}")
          end
        elsif b_roles.include?('continuation') && candidate_precedes?(a, b)
          pair_key = "elaborates:#{b['id']}:#{a['id']}"
          unless pairs_seen.include?(pair_key)
            pairs_seen << pair_key
            rel_counter += 1
            relationships << build_rel(rel_counter, 'elaborates', b, a, 'low',
              "#{b['id']} continues theme of #{a['id']}; shared: #{shared.first(3).join(', ')}")
          end
        end
      end

      # ── setup_for / payoff_of: setup markers in earlier, payoff markers in later ──
      if candidate_precedes?(a, b)
        if text_contains_marker?(a['text'], SETUP_MARKERS) && text_contains_marker?(b['text'], PAYOFF_MARKERS)
          pair_key = "setup_for:#{a['id']}:#{b['id']}"
          unless pairs_seen.include?(pair_key)
            pairs_seen << pair_key
            rel_counter += 1
            relationships << build_rel(rel_counter, 'setup_for', a, b, 'medium',
              "#{a['id']} poses question/setup, #{b['id']} resolves")
            rel_counter += 1
            relationships << build_rel(rel_counter, 'payoff_of', b, a, 'medium',
              "#{b['id']} resolves setup from #{a['id']}")
          end
        end
      end

      # ── bridge_to: transition wording, immediate neighbor only ──
      # Bridge connects to the candidate immediately after it in source time
      if candidate_precedes?(a, b)
        gap = b['t'] - a['e']
        if gap < 15.0 && (j == i + 1 || gap < 3.0)
          a_roles = (a['suggested_narrative_roles'] || []).map { |r| r['role'] }
          if a_roles.include?('transition') || text_contains_marker?(a['text'], BRIDGE_MARKERS)
            pair_key = "bridge_to:#{a['id']}:#{b['id']}"
            unless pairs_seen.include?(pair_key)
              pairs_seen << pair_key
              rel_counter += 1
              relationships << build_rel(rel_counter, 'bridge_to', a, b, 'medium',
                "#{a['id']} bridges to #{b['id']}")
            end
          end
        end
      end

      # ── tangent_from: adjacent in source but low overlap ──
      if overlap <= TANGENT_OVERLAP_CEILING && candidates_adjacent_in_source?(a, b)
        a_roles = (a['suggested_narrative_roles'] || []).map { |r| r['role'] }
        b_roles = (b['suggested_narrative_roles'] || []).map { |r| r['role'] }
        unless a_roles.include?('transition') || b_roles.include?('transition')
          pair_key = "tangent_from:#{b['id']}:#{a['id']}"
          unless pairs_seen.include?(pair_key)
            pairs_seen << pair_key
            rel_counter += 1
            relationships << build_rel(rel_counter, 'tangent_from', b, a, 'low',
              "#{b['id']} follows #{a['id']} but shares no vocabulary")
          end
        end
      end
    end
  end

  relationships
end

def build_rel(counter, type, from, to, confidence, evidence)
  {
    'id' => format('rel_%03d', counter),
    'type' => type,
    'from_candidate_id' => from['id'],
    'to_candidate_id' => to['id'],
    'confidence' => confidence,
    'evidence' => evidence
  }
end

# ─── Validation ───────────────────────────────────────────────────────────────

def validate_relationships(relationships, candidate_ids)
  errors = []

  valid_ids = Set.new(candidate_ids)
  seen_ids = Set.new
  seen_triples = Set.new

  relationships.each do |r|
    rid = r['id']

    # ID format
    unless rid&.match?(/\Arel_\d{3}\z/)
      errors << "#{rid}: invalid id format (expected rel_NNN)"
    end

    # Duplicate IDs
    if seen_ids.include?(rid)
      errors << "#{rid}: duplicate relationship id"
    end
    seen_ids << rid

    # Reference resolution
    from = r['from_candidate_id']
    to = r['to_candidate_id']
    errors << "#{rid}: unknown from_candidate_id '#{from}'" unless valid_ids.include?(from)
    errors << "#{rid}: unknown to_candidate_id '#{to}'" unless valid_ids.include?(to)

    # Self-relationship
    errors << "#{rid}: self-relationship (#{from} -> #{from})" if from == to

    # Duplicate triple
    triple = "#{r['type']}:#{from}:#{to}"
    errors << "#{rid}: duplicate relationship (#{triple})" if seen_triples.include?(triple)
    seen_triples << triple

    # Enum validation
    errors << "#{rid}: invalid type '#{r['type']}'" unless VALID_RELATIONSHIP_TYPES.include?(r['type'])
    errors << "#{rid}: invalid confidence '#{r['confidence']}'" unless VALID_CONFIDENCES.include?(r['confidence'])

    # Invented fields
    allowed = %w[id type from_candidate_id to_candidate_id confidence evidence]
    r.each_key { |k| errors << "#{rid}: invented field '#{k}'" unless allowed.include?(k) }
  end

  errors
end

# ─── Main ─────────────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  fixture_dir = nil
  args = ARGV.dup
  while args.any?
    case args.first
    when '--fixture' then args.shift; fixture_dir = args.shift
    else abort "Unknown argument: #{args.first}"
    end
  end

  abort 'Usage: ruby scripts/map_candidate_relationships.rb --fixture <dir>' unless fixture_dir

  editorial_path = File.join(fixture_dir, 'editorial_candidates.yaml')
  abort "editorial_candidates.yaml not found in #{fixture_dir}" unless File.exist?(editorial_path)

  candidates_data = YAML.safe_load(File.read(editorial_path), permitted_classes: [Date])
  candidates = candidates_data['candidates']
  candidate_ids = candidates.map { |c| c['id'] }

  $stderr.puts "Loaded #{candidates.size} candidates from #{editorial_path}"

  relationships = detect_relationships(candidates)

  errors = validate_relationships(relationships, candidate_ids)
  if errors.any?
    $stderr.puts "Validation FAILED:"
    errors.each { |e| $stderr.puts "  ERROR: #{e}" }
    exit 2
  end

  # Build output
  fingerprint = Digest::SHA256.hexdigest(File.read(editorial_path))
  output = {
    'version' => '1',
    'input_fingerprint' => fingerprint,
    'generated_at' => 'deterministic',
    'candidate_count' => candidates.size,
    'relationship_count' => relationships.size,
    'relationships' => relationships
  }

  output_path = File.join(fixture_dir, 'candidate_relationships.yaml')
  File.write(output_path, YAML.dump(output))

  # Summary by type
  by_type = relationships.group_by { |r| r['type'] }
  type_summary = by_type.map { |t, rs| "#{t}:#{rs.size}" }.join(' ')
  $stderr.puts "candidate_relationships.yaml written: #{relationships.size} relationships"
  $stderr.puts "  #{type_summary}" unless type_summary.empty?
  puts output_path
end
