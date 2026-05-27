#!/usr/bin/env ruby
# semantic_labeler.rb — Pending-file LLM semantic labeling for Phase B.
#
# Workflow:
#   1. candidate_builder --semantic-mode pending  → writes semantic_labels_pending.yaml
#   2. User/Claude Code fills semantic_labels_response.yaml
#   3. candidate_builder --semantic-mode pending  → reads response, validates, merges
#
# Core invariant: LLM may interpret meaning. LLM may NOT invent substrate reality.
# Substrate-authoritative fields (id, segment_ids, t/e, trim_choices, exclusion_choices,
# cluster, prosody) are NEVER sourced from LLM output.

require 'yaml'
require 'json'
require 'digest'
require 'set'

module SemanticLabeler
  PROMPT_VERSION = '7D.1'

  # Schema enums (authoritative: editorial_candidate.schema.yaml v1.2)
  VALID_STATES = %w[
    vindication outrage awe competence fear schadenfreude amusement
    catharsis nostalgia belonging escape calm aspiration sensual curiosity
  ].freeze

  VALID_ROLES = %w[
    hook setup continuation payoff transition claim evidence definition aside
  ].freeze

  VALID_PRIORITIES   = %w[primary secondary tertiary].freeze
  VALID_DURABILITIES = %w[spike mood identity].freeze
  VALID_CONFIDENCES  = %w[high medium low].freeze
  VALID_USABILITIES  = %w[fine marginal unusable].freeze

  INCOMPATIBLE_STATE_PAIRS = [
    %w[vindication outrage],
    %w[amusement fear],
    %w[calm outrage],
    %w[escape belonging]
  ].freeze

  SEMANTIC_FIELDS = %w[
    summary distillation usability candidate_priority
    suggested_narrative_roles states durability confidence
    content_preserved_trims edit_notes
  ].freeze

  # ─── Pending Request Generation ─────────────────────────────────────────────

  def self.build_pending_request(substrate_candidates)
    candidates_for_labeling = substrate_candidates.map do |c|
      raw_dur = c['e'] - c['t']

      trims = c['trim_choices'].map do |tc|
        trim_dur = tc['out'] - tc['in']
        pct = raw_dur > 0 ? ((trim_dur / raw_dur) * 100).round(0) : 100
        {
          'id' => tc['id'],
          'label' => tc['label'],
          'keeps_percent' => pct,
          'mechanical_boundary_safe' => tc['mechanical_boundary_safe']
        }
      end

      exclusions = (c['exclusion_choices'] || []).map do |ex|
        {
          'id' => ex['id'],
          'type' => ex['type'],
          'reason' => ex['reason'],
          'duration_s' => (ex['end'] - ex['start']).round(2),
          'recommended' => ex['recommended']
        }
      end

      {
        'id' => c['id'],
        'text' => c['text'],
        'duration_s' => raw_dur.round(2),
        'audio_profile' => c.dig('prosody', 'audio_profile'),
        'energy' => c.dig('prosody', 'energy'),
        'pitch_trend' => c.dig('prosody', 'pitch_trend'),
        'stumble_count' => c.dig('prosody', 'stumble_count') || 0,
        'trim_choices' => trims,
        'exclusion_choices' => exclusions
      }
    end

    {
      'prompt_version' => PROMPT_VERSION,
      'schema_version' => '1.2',
      'instructions' => build_instructions,
      'constraints' => build_constraints,
      'output_format' => build_output_format,
      'candidates' => candidates_for_labeling
    }
  end

  def self.build_instructions
    <<~TEXT.strip
      You are a semantic labeling system for video editing. For each candidate below,
      classify it by rhetorical function, emotional state, and editorial value.

      Each candidate is an independently cuttable spoken segment extracted from video.
      Classify each candidate IN ISOLATION. Do not make cross-candidate editing decisions.

      You may NOT invent timestamps, segment IDs, candidate IDs, trim IDs, or any
      structural data. You may ONLY produce the semantic fields listed in output_format.

      For content_preserved_trims: judge whether each trim retains the candidate's core
      meaning. A full_clean trim that includes all text always preserves content.
      A tighter trim that removes key words or the main point does NOT preserve content.
    TEXT
  end

  def self.build_constraints
    {
      'states' => {
        'description' => '1-3 values from the enum. Primary state first.',
        'enum' => VALID_STATES,
        'incompatible_pairs' => INCOMPATIBLE_STATE_PAIRS
      },
      'suggested_narrative_roles' => {
        'description' => '1-2 entries, no duplicate roles.',
        'role_enum' => VALID_ROLES,
        'confidence_enum' => VALID_CONFIDENCES
      },
      'candidate_priority' => {
        'enum' => VALID_PRIORITIES,
        'description' => 'primary=central/important, secondary=supporting, tertiary=filler'
      },
      'durability' => {
        'enum' => VALID_DURABILITIES,
        'description' => 'spike=momentary, mood=sustained beat, identity=lasting shift'
      },
      'confidence' => {
        'enum' => VALID_CONFIDENCES,
        'description' => 'How confident you are in the classification'
      },
      'usability' => {
        'enum' => VALID_USABILITIES,
        'description' => 'fine=clean, marginal=minor issues, unusable=too broken'
      },
      'summary' => { 'max_words' => 25 },
      'distillation' => { 'max_words' => 5 }
    }
  end

  def self.build_output_format
    {
      'description' => 'Return a JSON array of candidate labels, one per candidate, in order.',
      'per_candidate_fields' => {
        'id' => 'echo back the candidate id unchanged',
        'summary' => 'string, max 25 words',
        'distillation' => 'string, exactly 5 words',
        'usability' => 'fine|marginal|unusable',
        'candidate_priority' => 'primary|secondary|tertiary',
        'suggested_narrative_roles' => '[{role: ROLE, confidence: CONFIDENCE}, ...]',
        'states' => '[STATE1, STATE2, ...]',
        'durability' => 'spike|mood|identity',
        'confidence' => 'high|medium|low',
        'content_preserved_trims' => '{trim_id: true|false, ...}',
        'edit_notes' => 'brief editorial note'
      }
    }
  end

  # ─── Response Validation ────────────────────────────────────────────────────

  def self.validate_response(response_labels, substrate_candidates)
    errors = []
    warnings = []
    substrate_by_id = substrate_candidates.each_with_object({}) { |c, h| h[c['id']] = c }

    unless response_labels.is_a?(Array)
      return { errors: ['response must be an array of candidate labels'], warnings: [] }
    end

    if response_labels.size != substrate_candidates.size
      errors << "expected #{substrate_candidates.size} candidates, got #{response_labels.size}"
    end

    per_candidate_errors = {}

    response_labels.each_with_index do |label, i|
      cand_id = label['id']
      ce = []

      unless cand_id && substrate_by_id.key?(cand_id)
        ce << "unknown or missing id: #{cand_id.inspect}"
        per_candidate_errors[i] = ce
        next
      end

      substrate_cand = substrate_by_id[cand_id]

      # Required semantic fields
      %w[summary distillation usability candidate_priority states durability confidence suggested_narrative_roles].each do |f|
        ce << "missing: #{f}" unless label.key?(f)
      end
      next per_candidate_errors[cand_id] = ce if ce.any?

      # summary
      if label['summary'].is_a?(String)
        ce << "summary > 25 words (#{label['summary'].split.size})" if label['summary'].split.size > 25
      else
        ce << "summary must be string"
      end

      # distillation
      if label['distillation'].is_a?(String)
        ce << "distillation > 5 words (#{label['distillation'].split.size})" if label['distillation'].split.size > 5
      else
        ce << "distillation must be string"
      end

      # usability
      ce << "invalid usability: #{label['usability']}" unless VALID_USABILITIES.include?(label['usability'])

      # candidate_priority
      ce << "invalid candidate_priority: #{label['candidate_priority']}" unless VALID_PRIORITIES.include?(label['candidate_priority'])

      # states
      st = label['states']
      if st.is_a?(Array) && st.size >= 1 && st.size <= 3
        st.each { |s| ce << "invalid state: #{s}" unless VALID_STATES.include?(s) }
        INCOMPATIBLE_STATE_PAIRS.each do |a, b|
          ce << "incompatible states: #{a}+#{b}" if st.include?(a) && st.include?(b)
        end
      else
        ce << "states must be array of 1-3"
      end

      # durability
      ce << "invalid durability: #{label['durability']}" unless VALID_DURABILITIES.include?(label['durability'])

      # confidence
      ce << "invalid confidence: #{label['confidence']}" unless VALID_CONFIDENCES.include?(label['confidence'])

      # suggested_narrative_roles
      roles = label['suggested_narrative_roles']
      if roles.is_a?(Array) && roles.size >= 1 && roles.size <= 2
        seen = Set.new
        roles.each do |r|
          unless r.is_a?(Hash) && r['role'] && r['confidence']
            ce << "invalid role entry"
            next
          end
          ce << "invalid role: #{r['role']}" unless VALID_ROLES.include?(r['role'])
          ce << "invalid role confidence: #{r['confidence']}" unless VALID_CONFIDENCES.include?(r['confidence'])
          ce << "duplicate role: #{r['role']}" if seen.include?(r['role'])
          seen << r['role']
        end
      else
        ce << "suggested_narrative_roles must be array of 1-2"
      end

      # content_preserved_trims (optional but validated if present)
      cpt = label['content_preserved_trims']
      if cpt.is_a?(Hash)
        trim_ids = substrate_cand['trim_choices'].map { |t| t['id'] }
        cpt.each_key { |k| ce << "unknown trim: #{k}" unless trim_ids.include?(k) }
        cpt.each { |k, v| ce << "content_preserved must be boolean for #{k}" unless [true, false].include?(v) }
      end

      # invented fields
      allowed = %w[id summary distillation usability candidate_priority states durability confidence suggested_narrative_roles content_preserved_trims edit_notes]
      label.each_key { |k| ce << "invented field: #{k}" unless allowed.include?(k) }

      per_candidate_errors[cand_id] = ce if ce.any?
    end

    per_candidate_errors.each do |cid, errs|
      errs.each { |e| errors << "#{cid}: #{e}" }
    end

    { errors: errors, warnings: warnings, per_candidate_errors: per_candidate_errors }
  end

  # ─── Merge ─────────────────────────────────────────────────────────────────

  def self.merge_labels(substrate_candidate, llm_label, mock_label)
    # Start from substrate, overlay with LLM semantic fields, fallback to mock
    merged = {}

    # Substrate-authoritative fields (NEVER from LLM)
    %w[id source segment_ids t e text exclusion_choices cluster prosody].each do |f|
      merged[f] = substrate_candidate[f]
    end

    # trim_choices: structure from substrate, content_preserved from LLM or mock
    cpt = llm_label['content_preserved_trims'] || {}
    merged['trim_choices'] = substrate_candidate['trim_choices'].map do |tc|
      tc = tc.dup
      if cpt.key?(tc['id'])
        tc['content_preserved'] = cpt[tc['id']]
      else
        # fallback: mock content_preserved logic
        tc['content_preserved'] = mock_label['trim_choices'].find { |mt| mt['id'] == tc['id'] }&.fetch('content_preserved', true) rescue true
      end
      tc
    end

    # Semantic fields from LLM
    %w[summary distillation usability candidate_priority suggested_narrative_roles states durability confidence].each do |f|
      merged[f] = llm_label[f]
    end

    merged['edit_notes'] = llm_label['edit_notes'] || "LLM labeled (#{SemanticLabeler::PROMPT_VERSION})"
    merged
  end
end
