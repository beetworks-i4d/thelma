#!/usr/bin/env ruby
# augment_candidate_relationships.rb — Pass 2 LLM augmentation layer.
#
# Takes deterministic candidate_relationships.yaml as baseline.
# Writes a pending JSON request for LLM relationship critique.
# When response exists, validates and merges into augmented output.
#
# Usage:
#   ruby scripts/augment_candidate_relationships.rb --fixture <dir>
#   ruby scripts/augment_candidate_relationships.rb --fixture <dir> --mode pending
#   ruby scripts/augment_candidate_relationships.rb --fixture <dir> --mode mock
#
# Modes:
#   pending (default) — write request if no response; merge if response exists
#   mock              — use deterministic baseline as-is, no augmentation
#
# Core invariant: LLMs judge meaning. Scripts handle mechanics.
# LLM may add relationships, upgrade/downgrade confidence, attach rationale.
# LLM may NOT invent candidate IDs, timestamps, trims, exclusions.

require 'yaml'
require 'json'
require 'digest'
require 'set'
require 'date'

SCRIPTS_DIR = File.dirname(__FILE__)

# ─── Constants ────────────────────────────────────────────────────────────────

VALID_RELATIONSHIP_TYPES = %w[
  duplicate_of alternate_take_of supports example_of elaborates
  contradicts setup_for payoff_of tangent_from bridge_to
].freeze

VALID_CONFIDENCES = %w[high medium low].freeze

ALLOWED_RELATIONSHIP_FIELDS = %w[
  id type from_candidate_id to_candidate_id confidence evidence
].freeze

ALLOWED_AUGMENTATION_ACTIONS = %w[add upgrade downgrade remove reclassify].freeze

PROMPT_VERSION = '8B.1'

# ─── Pending Request Generation ──────────────────────────────────────────────

def build_augmentation_request(candidates, baseline_relationships)
  candidate_summaries = candidates.map do |c|
    {
      'id' => c['id'],
      'text' => c['text'],
      'summary' => c['summary'],
      'states' => c['states'],
      'candidate_priority' => c['candidate_priority'],
      'suggested_narrative_roles' => c['suggested_narrative_roles']
    }
  end

  baseline_summary = baseline_relationships.map do |r|
    {
      'id' => r['id'],
      'type' => r['type'],
      'from_candidate_id' => r['from_candidate_id'],
      'to_candidate_id' => r['to_candidate_id'],
      'confidence' => r['confidence'],
      'evidence' => r['evidence']
    }
  end

  {
    'prompt_version' => PROMPT_VERSION,
    'instructions' => build_instructions,
    'constraints' => build_constraints,
    'output_format' => build_output_format,
    'candidates' => candidate_summaries,
    'baseline_relationships' => baseline_summary
  }
end

def build_instructions
  <<~TEXT.strip
    You are an editorial relationship critic for video editing. You are reviewing
    a set of deterministic heuristic relationships between spoken video candidates.

    Your job is to critique and augment these relationships. You may:
    1. ADD new relationships the heuristics missed (especially setup_for, payoff_of, example_of, elaborates)
    2. UPGRADE confidence on relationships that are clearly correct
    3. DOWNGRADE confidence on relationships that seem like false positives
    4. REMOVE false positive relationships by marking them for removal
    5. RECLASSIFY relationships that have the wrong type

    You must evaluate each candidate's TEXT to determine semantic relationships.
    Do not rely solely on the heuristic evidence — read what the speaker actually says.

    You may NOT invent candidate IDs. Only use IDs from the candidates list.
    You may NOT invent relationship types. Only use the allowed enum.
    You may NOT add timestamps, trims, exclusions, or any structural data.
  TEXT
end

def build_constraints
  {
    'relationship_types' => VALID_RELATIONSHIP_TYPES,
    'confidence_levels' => VALID_CONFIDENCES,
    'actions' => ALLOWED_AUGMENTATION_ACTIONS
  }
end

def build_output_format
  {
    'description' => 'Return a JSON object with augmentations to the baseline relationships.',
    'fields' => {
      'augmentations' => 'Array of augmentation actions',
      'per_augmentation' => {
        'action' => 'add|upgrade|downgrade|remove|reclassify',
        'relationship_id' => 'For upgrade/downgrade/remove/reclassify: the baseline rel_NNN id',
        'new_type' => 'For reclassify: the new relationship type',
        'new_confidence' => 'For upgrade/downgrade: the new confidence level',
        'rationale' => 'Brief explanation of why this change is warranted',
        'relationship' => 'For add only: {type, from_candidate_id, to_candidate_id, confidence, evidence}'
      }
    }
  }
end

# ─── Response Validation ─────────────────────────────────────────────────────

def validate_augmentation_response(augmentations, candidate_ids, baseline_ids)
  errors = []
  valid_cand_ids = Set.new(candidate_ids)
  valid_baseline_ids = Set.new(baseline_ids)

  unless augmentations.is_a?(Array)
    return ['response augmentations must be an array']
  end

  augmentations.each_with_index do |aug, i|
    prefix = "augmentation[#{i}]"

    # Action validation
    action = aug['action']
    unless ALLOWED_AUGMENTATION_ACTIONS.include?(action)
      errors << "#{prefix}: invalid action '#{action}'"
      next
    end

    # Rationale required
    errors << "#{prefix}: missing rationale" unless aug['rationale'].is_a?(String) && !aug['rationale'].empty?

    case action
    when 'add'
      rel = aug['relationship']
      unless rel.is_a?(Hash)
        errors << "#{prefix}: add action requires 'relationship' object"
        next
      end
      errors << "#{prefix}: invalid type '#{rel['type']}'" unless VALID_RELATIONSHIP_TYPES.include?(rel['type'])
      errors << "#{prefix}: invalid confidence '#{rel['confidence']}'" unless VALID_CONFIDENCES.include?(rel['confidence'])
      errors << "#{prefix}: unknown from '#{rel['from_candidate_id']}'" unless valid_cand_ids.include?(rel['from_candidate_id'])
      errors << "#{prefix}: unknown to '#{rel['to_candidate_id']}'" unless valid_cand_ids.include?(rel['to_candidate_id'])
      if rel['from_candidate_id'] == rel['to_candidate_id']
        errors << "#{prefix}: self-relationship"
      end

    when 'upgrade', 'downgrade'
      rid = aug['relationship_id']
      errors << "#{prefix}: unknown relationship_id '#{rid}'" unless valid_baseline_ids.include?(rid)
      errors << "#{prefix}: missing new_confidence" unless VALID_CONFIDENCES.include?(aug['new_confidence'])

    when 'remove'
      rid = aug['relationship_id']
      errors << "#{prefix}: unknown relationship_id '#{rid}'" unless valid_baseline_ids.include?(rid)

    when 'reclassify'
      rid = aug['relationship_id']
      errors << "#{prefix}: unknown relationship_id '#{rid}'" unless valid_baseline_ids.include?(rid)
      errors << "#{prefix}: invalid new_type '#{aug['new_type']}'" unless VALID_RELATIONSHIP_TYPES.include?(aug['new_type'])
    end

    # Invented fields check
    allowed = %w[action relationship_id new_type new_confidence rationale relationship]
    aug.each_key { |k| errors << "#{prefix}: invented field '#{k}'" unless allowed.include?(k) }
  end

  errors
end

# ─── Merge ────────────────────────────────────────────────────────────────────

def merge_augmentations(baseline_relationships, augmentations)
  merged = baseline_relationships.map(&:dup)
  merged_by_id = merged.each_with_object({}) { |r, h| h[r['id']] = r }
  removed_ids = Set.new
  next_id = baseline_relationships.size

  augmentations.each do |aug|
    case aug['action']
    when 'add'
      rel = aug['relationship']
      next_id += 1
      merged << {
        'id' => format('rel_%03d', next_id),
        'type' => rel['type'],
        'from_candidate_id' => rel['from_candidate_id'],
        'to_candidate_id' => rel['to_candidate_id'],
        'confidence' => rel['confidence'],
        'evidence' => "LLM: #{aug['rationale']}"
      }

    when 'upgrade', 'downgrade'
      target = merged_by_id[aug['relationship_id']]
      if target
        target['confidence'] = aug['new_confidence']
        target['evidence'] = "#{target['evidence']} | LLM #{aug['action']}: #{aug['rationale']}"
      end

    when 'remove'
      removed_ids << aug['relationship_id']

    when 'reclassify'
      target = merged_by_id[aug['relationship_id']]
      if target
        target['type'] = aug['new_type']
        target['evidence'] = "#{target['evidence']} | LLM reclassify: #{aug['rationale']}"
      end
    end
  end

  merged.reject { |r| removed_ids.include?(r['id']) }
end

# ─── Output Validation ───────────────────────────────────────────────────────

def validate_merged_relationships(relationships, candidate_ids)
  errors = []
  valid_ids = Set.new(candidate_ids)
  seen_ids = Set.new
  seen_triples = Set.new

  relationships.each do |r|
    rid = r['id']

    unless rid&.match?(/\Arel_\d{3}\z/)
      errors << "#{rid}: invalid id format"
    end

    if seen_ids.include?(rid)
      errors << "#{rid}: duplicate relationship id"
    end
    seen_ids << rid

    from = r['from_candidate_id']
    to = r['to_candidate_id']
    errors << "#{rid}: unknown from '#{from}'" unless valid_ids.include?(from)
    errors << "#{rid}: unknown to '#{to}'" unless valid_ids.include?(to)
    errors << "#{rid}: self-relationship" if from == to

    triple = "#{r['type']}:#{from}:#{to}"
    errors << "#{rid}: duplicate (#{triple})" if seen_triples.include?(triple)
    seen_triples << triple

    errors << "#{rid}: invalid type '#{r['type']}'" unless VALID_RELATIONSHIP_TYPES.include?(r['type'])
    errors << "#{rid}: invalid confidence '#{r['confidence']}'" unless VALID_CONFIDENCES.include?(r['confidence'])

    allowed = %w[id type from_candidate_id to_candidate_id confidence evidence]
    r.each_key { |k| errors << "#{rid}: invented field '#{k}'" unless allowed.include?(k) }
  end

  errors
end

# ─── Main ─────────────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  fixture_dir = nil
  mode = 'pending'

  args = ARGV.dup
  while args.any?
    case args.first
    when '--fixture' then args.shift; fixture_dir = args.shift
    when '--mode'    then args.shift; mode = args.shift
    else abort "Unknown argument: #{args.first}"
    end
  end

  abort 'Usage: ruby scripts/augment_candidate_relationships.rb --fixture <dir>' unless fixture_dir
  abort "Invalid --mode: #{mode}. Use pending or mock." unless %w[pending mock].include?(mode)

  editorial_path = File.join(fixture_dir, 'editorial_candidates.yaml')
  baseline_path  = File.join(fixture_dir, 'candidate_relationships.yaml')
  pending_path   = File.join(fixture_dir, 'relationship_augmentation_pending.json')
  response_path  = File.join(fixture_dir, 'relationship_augmentation_response.json')
  output_path    = File.join(fixture_dir, 'augmented_candidate_relationships.yaml')

  abort "editorial_candidates.yaml not found" unless File.exist?(editorial_path)
  abort "candidate_relationships.yaml not found. Run map_candidate_relationships.rb first." unless File.exist?(baseline_path)

  candidates_data = YAML.safe_load(File.read(editorial_path), permitted_classes: [Date])
  candidates = candidates_data['candidates']
  candidate_ids = candidates.map { |c| c['id'] }

  baseline_data = YAML.safe_load(File.read(baseline_path))
  baseline_rels = baseline_data['relationships']
  baseline_ids = baseline_rels.map { |r| r['id'] }

  $stderr.puts "Loaded #{candidates.size} candidates, #{baseline_rels.size} baseline relationships"

  if mode == 'mock'
    # Pass through baseline as-is
    fingerprint = Digest::SHA256.hexdigest(File.read(editorial_path) + File.read(baseline_path))
    output = {
      'version' => '1',
      'mode' => 'mock',
      'input_fingerprint' => fingerprint,
      'generated_at' => 'deterministic',
      'candidate_count' => candidates.size,
      'baseline_relationship_count' => baseline_rels.size,
      'augmented_relationship_count' => baseline_rels.size,
      'augmentations_applied' => 0,
      'relationships' => baseline_rels
    }
    File.write(output_path, YAML.dump(output))
    $stderr.puts "augmented_candidate_relationships.yaml written: #{baseline_rels.size} relationships (mock, no augmentation)"
    puts output_path
    exit 0
  end

  # ── Pending mode ──

  if File.exist?(response_path)
    $stderr.puts "Reading relationship_augmentation_response.json..."
    response_data = JSON.parse(File.read(response_path))
    augmentations = response_data['augmentations'] || response_data

    errors = validate_augmentation_response(augmentations, candidate_ids, baseline_ids)
    if errors.any?
      $stderr.puts "Augmentation response validation FAILED:"
      errors.each { |e| $stderr.puts "  ERROR: #{e}" }
      abort "Fix relationship_augmentation_response.json and rerun."
    end

    merged = merge_augmentations(baseline_rels, augmentations)

    merge_errors = validate_merged_relationships(merged, candidate_ids)
    if merge_errors.any?
      $stderr.puts "Merged relationship validation FAILED:"
      merge_errors.each { |e| $stderr.puts "  ERROR: #{e}" }
      abort "Merge produced invalid relationships."
    end

    # Count augmentation stats
    adds = augmentations.count { |a| a['action'] == 'add' }
    upgrades = augmentations.count { |a| a['action'] == 'upgrade' }
    downgrades = augmentations.count { |a| a['action'] == 'downgrade' }
    removes = augmentations.count { |a| a['action'] == 'remove' }
    reclassifies = augmentations.count { |a| a['action'] == 'reclassify' }

    fingerprint = Digest::SHA256.hexdigest(File.read(editorial_path) + File.read(baseline_path) + File.read(response_path))
    output = {
      'version' => '1',
      'mode' => 'augmented',
      'prompt_version' => PROMPT_VERSION,
      'input_fingerprint' => fingerprint,
      'generated_at' => 'deterministic',
      'candidate_count' => candidates.size,
      'baseline_relationship_count' => baseline_rels.size,
      'augmented_relationship_count' => merged.size,
      'augmentations_applied' => augmentations.size,
      'augmentation_summary' => {
        'adds' => adds,
        'upgrades' => upgrades,
        'downgrades' => downgrades,
        'removes' => removes,
        'reclassifies' => reclassifies
      },
      'relationships' => merged
    }

    File.write(output_path, YAML.dump(output))
    $stderr.puts "augmented_candidate_relationships.yaml written: #{merged.size} relationships (#{augmentations.size} augmentations)"
    $stderr.puts "  +#{adds} add, #{upgrades} upgrade, #{downgrades} downgrade, #{removes} remove, #{reclassifies} reclassify"
    puts output_path
  else
    # Write pending request
    request = build_augmentation_request(candidates, baseline_rels)
    File.write(pending_path, JSON.pretty_generate(request))
    $stderr.puts "relationship_augmentation_pending.json written: #{candidates.size} candidates, #{baseline_rels.size} baseline relationships"
    $stderr.puts "Fill #{response_path} and rerun."
    puts pending_path
    exit 0
  end
end
