#!/usr/bin/env ruby
# select_thesis.rb — Pass 3: thesis / angle selection.
#
# Given candidates + relationships, identify coherent editorial directions.
# Deterministic baseline from graph analysis + optional LLM augmentation.
#
# Usage:
#   ruby scripts/select_thesis.rb --fixture <dir>
#   ruby scripts/select_thesis.rb --fixture <dir> --mode mock
#   ruby scripts/select_thesis.rb --fixture <dir> --mode pending
#
# Modes:
#   mock    — deterministic thesis only, no LLM augmentation
#   pending — write pending request if no response; merge if response exists
#
# Input:
#   editorial_candidates.yaml
#   augmented_candidate_relationships.yaml (or candidate_relationships.yaml)
#
# Output:
#   selected_thesis.yaml
#
# Core invariant: LLMs judge meaning. Scripts handle mechanics.
# LLM may refine thesis wording, rank thesis strength, identify stronger
# hook/payoff. LLM may NOT invent candidate IDs, relationships, or
# unsupported theses.

require 'yaml'
require 'json'
require 'digest'
require 'set'
require 'date'

# ─── Constants ────────────────────────────────────────────────────────────────

VALID_CONFIDENCES = %w[high medium low].freeze

VALID_RELATIONSHIP_TYPES = %w[
  duplicate_of alternate_take_of supports example_of elaborates
  contradicts setup_for payoff_of tangent_from bridge_to
].freeze

# Relationship types that indicate thematic support
REINFORCING_TYPES = %w[supports elaborates example_of setup_for payoff_of].freeze
OPPOSING_TYPES    = %w[contradicts].freeze

PROMPT_VERSION = '9A.1'

STOP_WORDS = Set.new(%w[
  a an the and or but is are was were be been being
  in on at to for of with by from as into through
  i you he she it we they me him her us them
  my your his its our their
  this that these those what which who whom
  do does did not no nor
  so if then than when where how why
  just really very actually even also too
  have has had get got can could would should
  about been more there here now all
  know like going think right
]).freeze

# ─── Graph Analysis ───────────────────────────────────────────────────────────

def build_relationship_graph(relationships)
  # Build adjacency structures
  inbound  = Hash.new { |h, k| h[k] = [] }  # cand_id => [relationships pointing TO it]
  outbound = Hash.new { |h, k| h[k] = [] }  # cand_id => [relationships pointing FROM it]

  relationships.each do |r|
    inbound[r['to_candidate_id']] << r
    outbound[r['from_candidate_id']] << r
  end

  { inbound: inbound, outbound: outbound }
end

def compute_thesis_score(cand, graph, candidates_by_id)
  score = 0.0

  # Inbound reinforcing relationships (others support/elaborate this candidate)
  inbound_reinforcing = graph[:inbound][cand['id']].select { |r| REINFORCING_TYPES.include?(r['type']) }
  inbound_reinforcing.each do |r|
    weight = case r['confidence']
             when 'high' then 3.0
             when 'medium' then 2.0
             when 'low' then 1.0
             else 1.0
             end
    # setup_for and payoff_of are especially valuable for thesis anchoring
    weight *= 1.5 if %w[setup_for payoff_of].include?(r['type'])
    score += weight
  end

  # Outbound reinforcing (this candidate supports others — it's connective)
  outbound_reinforcing = graph[:outbound][cand['id']].select { |r| REINFORCING_TYPES.include?(r['type']) }
  outbound_reinforcing.each do |r|
    weight = case r['confidence']
             when 'high' then 1.5
             when 'medium' then 1.0
             when 'low' then 0.5
             else 0.5
             end
    score += weight
  end

  # Candidate priority bonus
  case cand['candidate_priority']
  when 'primary'   then score += 2.0
  when 'secondary' then score += 1.0
  when 'tertiary'  then score += 0.0
  end

  # Durability bonus (identity > mood > spike)
  case cand['durability']
  when 'identity' then score += 3.0
  when 'mood'     then score += 1.5
  when 'spike'    then score += 0.5
  end

  # Narrative role bonus — claim/hook candidates are natural thesis anchors
  roles = (cand['suggested_narrative_roles'] || []).map { |r| r['role'] }
  score += 2.0 if roles.include?('claim')
  score += 1.5 if roles.include?('hook')

  # Penalty for transition/aside roles (not thesis material)
  score -= 2.0 if roles.include?('transition')
  score -= 1.0 if roles.include?('aside')

  # Usability gate
  score = -100.0 if cand['usability'] == 'unusable'

  score
end

def find_supporting_cluster(anchor_id, graph, candidates_by_id)
  supporting = Set.new
  opposing = Set.new

  # Direct inbound reinforcing
  graph[:inbound][anchor_id].each do |r|
    if REINFORCING_TYPES.include?(r['type'])
      supporting << r['from_candidate_id']
    elsif OPPOSING_TYPES.include?(r['type'])
      opposing << r['from_candidate_id']
    end
  end

  # Direct outbound reinforcing (anchor supports others)
  graph[:outbound][anchor_id].each do |r|
    if REINFORCING_TYPES.include?(r['type'])
      supporting << r['to_candidate_id']
    elsif OPPOSING_TYPES.include?(r['type'])
      opposing << r['to_candidate_id']
    end
  end

  # Second-degree: candidates that support our supporters
  first_degree = supporting.dup
  first_degree.each do |sup_id|
    graph[:inbound][sup_id].each do |r|
      if REINFORCING_TYPES.include?(r['type']) && r['from_candidate_id'] != anchor_id
        supporting << r['from_candidate_id']
      end
    end
    graph[:outbound][sup_id].each do |r|
      if REINFORCING_TYPES.include?(r['type']) && r['to_candidate_id'] != anchor_id
        supporting << r['to_candidate_id']
      end
    end
  end

  supporting.delete(anchor_id)
  opposing.delete(anchor_id)
  # Remove candidates that are both supporting and opposing
  ambiguous = supporting & opposing
  supporting -= ambiguous
  opposing -= ambiguous

  { supporting: supporting.to_a.sort, opposing: opposing.to_a.sort }
end

def find_hook_candidate(anchor_id, cluster_ids, graph, candidates_by_id)
  # Best hook: candidate with hook role that's in the cluster
  candidates_in_cluster = ([anchor_id] + cluster_ids).uniq
  best_hook = nil
  best_score = -1

  candidates_in_cluster.each do |cid|
    cand = candidates_by_id[cid]
    next unless cand
    roles = (cand['suggested_narrative_roles'] || []).map { |r| r['role'] }
    next unless roles.include?('hook') || roles.include?('claim')

    score = 0
    score += 3 if roles.include?('hook')
    score += 1 if roles.include?('claim')
    score += 2 if cand['candidate_priority'] == 'primary'
    score += 1 if cand['prosody'] && cand['prosody']['energy'] == 'high'

    if score > best_score
      best_score = score
      best_hook = cid
    end
  end

  best_hook || anchor_id
end

def find_payoff_candidate(anchor_id, cluster_ids, graph, candidates_by_id)
  # Best payoff: candidate that is a payoff_of something in the cluster
  candidates_in_cluster = ([anchor_id] + cluster_ids).uniq

  # Look for explicit payoff relationships
  candidates_in_cluster.each do |cid|
    graph[:outbound][cid].each do |r|
      if r['type'] == 'payoff_of' && candidates_in_cluster.include?(r['to_candidate_id'])
        return cid
      end
    end
    graph[:inbound][cid].each do |r|
      if r['type'] == 'payoff_of' && candidates_in_cluster.include?(r['from_candidate_id'])
        return r['from_candidate_id']
      end
    end
  end

  # Fallback: candidate with payoff or claim role
  best = nil
  best_score = -1
  candidates_in_cluster.each do |cid|
    next if cid == anchor_id # Don't duplicate the anchor
    cand = candidates_by_id[cid]
    next unless cand
    roles = (cand['suggested_narrative_roles'] || []).map { |r| r['role'] }

    score = 0
    score += 3 if roles.include?('payoff')
    score += 2 if roles.include?('claim')
    score += 1 if cand['durability'] == 'identity'
    if score > best_score
      best_score = score
      best_hook = cid
      best = cid
    end
  end

  best
end

def extract_content_words(text)
  text.downcase.gsub(/[^a-z0-9\s']/, ' ').split.reject { |w| STOP_WORDS.include?(w) }
end

def detect_recurring_themes(candidates)
  # Count content words across all candidates
  word_freq = Hash.new(0)
  candidates.each do |c|
    words = extract_content_words(c['text'])
    words.uniq.each { |w| word_freq[w] += 1 }
  end
  # Themes: words that appear in 2+ candidates (excluding very short words)
  word_freq.select { |w, count| count >= 2 && w.length >= 4 }
           .sort_by { |_, count| -count }
           .first(10)
           .map(&:first)
end

def build_thesis_statement(anchor, supporting_cands, themes)
  # Use anchor summary/distillation as the thesis core
  summary = anchor['summary'] || anchor['distillation'] || anchor['text'][0..80]
  summary.gsub(/\s+/, ' ').strip
end

def estimate_duration(candidate_ids, candidates_by_id)
  total = 0.0
  candidate_ids.each do |cid|
    cand = candidates_by_id[cid]
    next unless cand
    total += (cand['e'] - cand['t'])
  end
  total.round
end

def detect_throughlines(anchor_id, cluster, graph, candidates_by_id)
  throughlines = []
  all_ids = [anchor_id] + cluster[:supporting]

  # Throughline 1: The main thesis arc
  anchor = candidates_by_id[anchor_id]
  if anchor
    throughlines << {
      'id' => 'tl_001',
      'description' => "Core argument: #{(anchor['summary'] || anchor['distillation'] || '')[0..80]}".strip
    }
  end

  # Throughline 2: Look for setup/payoff arcs in the cluster
  setup_payoff_pairs = []
  all_ids.each do |cid|
    graph[:outbound][cid].each do |r|
      if %w[setup_for payoff_of].include?(r['type']) && all_ids.include?(r['to_candidate_id'])
        setup_payoff_pairs << [r['from_candidate_id'], r['to_candidate_id'], r['type']]
      end
    end
  end
  unless setup_payoff_pairs.empty?
    pair = setup_payoff_pairs.first
    from_cand = candidates_by_id[pair[0]]
    to_cand = candidates_by_id[pair[1]]
    if from_cand && to_cand
      throughlines << {
        'id' => 'tl_002',
        'description' => "Setup/payoff arc: #{(from_cand['summary'] || from_cand['distillation'] || '')[0..40]} → #{(to_cand['summary'] || to_cand['distillation'] || '')[0..40]}".strip
      }
    end
  end

  # Throughline 3: Emotional continuity (dominant state across cluster)
  state_counts = Hash.new(0)
  all_ids.each do |cid|
    cand = candidates_by_id[cid]
    next unless cand
    (cand['states'] || []).each { |s| state_counts[s] += 1 }
  end
  dominant_state = state_counts.max_by { |_, c| c }&.first
  if dominant_state && state_counts[dominant_state] >= 2
    throughlines << {
      'id' => format('tl_%03d', throughlines.size + 1),
      'description' => "Emotional throughline: #{dominant_state} across #{state_counts[dominant_state]} candidates"
    }
  end

  throughlines.first(3)
end

# ─── Thesis Generation ────────────────────────────────────────────────────────

def generate_theses(candidates, relationships)
  candidates_by_id = candidates.each_with_object({}) { |c, h| h[c['id']] = c }
  graph = build_relationship_graph(relationships)
  themes = detect_recurring_themes(candidates)

  # Score every candidate as a potential thesis anchor
  scored = candidates.map do |c|
    { candidate: c, score: compute_thesis_score(c, graph, candidates_by_id) }
  end.sort_by { |s| -s[:score] }

  # Generate theses from top-scoring anchors
  theses = []
  used_anchors = Set.new
  thesis_counter = 0

  scored.each do |entry|
    anchor = entry[:candidate]
    next if entry[:score] <= 0
    next if used_anchors.include?(anchor['id'])
    next if anchor['usability'] == 'unusable'

    cluster = find_supporting_cluster(anchor['id'], graph, candidates_by_id)
    primary_ids = [anchor['id']] + cluster[:supporting]

    # Skip single-candidate "theses" — can't sustain a narrative
    next if primary_ids.size < 2

    # Skip if this cluster overlaps heavily with an existing thesis
    next if theses.any? { |t| (Set.new(t['primary_candidates']) & Set.new(primary_ids)).size > primary_ids.size / 2 }

    hook = find_hook_candidate(anchor['id'], cluster[:supporting], graph, candidates_by_id)
    payoff = find_payoff_candidate(anchor['id'], cluster[:supporting], graph, candidates_by_id)

    # Determine excluded candidates
    all_cand_ids = candidates.map { |c| c['id'] }
    included = Set.new(primary_ids + cluster[:opposing])
    excluded = all_cand_ids.reject { |id| included.include?(id) }
    # Don't exclude candidates that have reinforcing relationships to our cluster
    excluded.reject! do |eid|
      graph[:outbound][eid].any? { |r| REINFORCING_TYPES.include?(r['type']) && primary_ids.include?(r['to_candidate_id']) } ||
      graph[:inbound][eid].any? { |r| REINFORCING_TYPES.include?(r['type']) && primary_ids.include?(r['from_candidate_id']) }
    end

    statement = build_thesis_statement(anchor, cluster[:supporting].map { |id| candidates_by_id[id] }.compact, themes)
    throughlines = detect_throughlines(anchor['id'], cluster, graph, candidates_by_id)
    duration = estimate_duration(primary_ids, candidates_by_id)

    # Determine confidence
    confidence = if primary_ids.size >= 3 && entry[:score] >= 8.0
                   'high'
                 elsif primary_ids.size >= 2 && entry[:score] >= 4.0
                   'medium'
                 else
                   'low'
                 end

    thesis_counter += 1
    theses << {
      'id' => format('thesis_%03d', thesis_counter),
      'thesis_statement' => statement,
      'confidence' => confidence,
      'anchor_candidate' => anchor['id'],
      'primary_candidates' => [anchor['id']] + cluster[:supporting],
      'supporting_candidates' => cluster[:opposing], # opposing candidates provide contrast
      'excluded_candidates' => excluded,
      'likely_hook' => hook,
      'likely_payoff' => payoff,
      'throughlines' => throughlines,
      'score' => entry[:score].round(1),
      'reasoning' => build_reasoning(anchor, cluster, graph, candidates_by_id, themes)
    }

    used_anchors << anchor['id']
    break if theses.size >= 3 # Max 3 theses
  end

  theses
end

def build_reasoning(anchor, cluster, graph, candidates_by_id, themes)
  parts = []
  parts << "Anchor: #{anchor['id']} (#{anchor['candidate_priority']}, #{anchor['durability']})"

  roles = (anchor['suggested_narrative_roles'] || []).map { |r| r['role'] }
  parts << "Roles: #{roles.join(', ')}" unless roles.empty?

  inbound_count = graph[:inbound][anchor['id']].count { |r| REINFORCING_TYPES.include?(r['type']) }
  parts << "#{inbound_count} inbound reinforcing relationships" if inbound_count > 0

  parts << "#{cluster[:supporting].size} supporting candidates" unless cluster[:supporting].empty?
  parts << "#{cluster[:opposing].size} opposing candidates" unless cluster[:opposing].empty?

  states = anchor['states'] || []
  parts << "Primary state: #{states.first}" unless states.empty?

  parts << "Recurring themes: #{themes.first(3).join(', ')}" unless themes.empty?

  parts.join('. ') + '.'
end

# ─── Validation ───────────────────────────────────────────────────────────────

def validate_theses(theses, candidate_ids)
  errors = []
  valid_cand_ids = Set.new(candidate_ids)
  seen_thesis_ids = Set.new

  unless theses.is_a?(Array) && theses.size >= 1
    return ['must have at least one thesis']
  end

  theses.each_with_index do |t, i|
    prefix = t['id'] || "thesis[#{i}]"

    # ID format
    unless t['id']&.match?(/\Athesis_\d{3}\z/)
      errors << "#{prefix}: invalid thesis id format"
    end

    # Duplicate IDs
    if seen_thesis_ids.include?(t['id'])
      errors << "#{prefix}: duplicate thesis id"
    end
    seen_thesis_ids << t['id']

    # Thesis statement
    unless t['thesis_statement'].is_a?(String) && !t['thesis_statement'].empty?
      errors << "#{prefix}: missing thesis_statement"
    end
    if t['thesis_statement'].is_a?(String) && t['thesis_statement'].split.size > 50
      errors << "#{prefix}: thesis_statement exceeds 50 words"
    end

    # Confidence
    unless VALID_CONFIDENCES.include?(t['confidence'])
      errors << "#{prefix}: invalid confidence '#{t['confidence']}'"
    end

    # Candidate references
    (t['primary_candidates'] || []).each do |cid|
      errors << "#{prefix}: unknown primary_candidate '#{cid}'" unless valid_cand_ids.include?(cid)
    end
    (t['supporting_candidates'] || []).each do |cid|
      errors << "#{prefix}: unknown supporting_candidate '#{cid}'" unless valid_cand_ids.include?(cid)
    end
    (t['excluded_candidates'] || []).each do |cid|
      errors << "#{prefix}: unknown excluded_candidate '#{cid}'" unless valid_cand_ids.include?(cid)
    end

    # No candidate in multiple groups
    primary   = Set.new(t['primary_candidates'] || [])
    supporting = Set.new(t['supporting_candidates'] || [])
    excluded  = Set.new(t['excluded_candidates'] || [])

    overlap_ps = primary & supporting
    overlap_pe = primary & excluded
    overlap_se = supporting & excluded
    errors << "#{prefix}: candidate(s) in both primary and supporting: #{overlap_ps.to_a.join(', ')}" unless overlap_ps.empty?
    errors << "#{prefix}: candidate(s) in both primary and excluded: #{overlap_pe.to_a.join(', ')}" unless overlap_pe.empty?
    errors << "#{prefix}: candidate(s) in both supporting and excluded: #{overlap_se.to_a.join(', ')}" unless overlap_se.empty?

    # Hook/payoff must exist
    if t['likely_hook']
      errors << "#{prefix}: unknown likely_hook '#{t['likely_hook']}'" unless valid_cand_ids.include?(t['likely_hook'])
    end
    if t['likely_payoff']
      errors << "#{prefix}: unknown likely_payoff '#{t['likely_payoff']}'" unless valid_cand_ids.include?(t['likely_payoff'])
    end

    # Target duration
    if t['target_duration_s']
      unless t['target_duration_s'].is_a?(Integer) && t['target_duration_s'] > 0
        errors << "#{prefix}: target_duration_s must be a positive integer"
      end
    end

    # Throughlines
    if t['throughlines']
      unless t['throughlines'].is_a?(Array) && t['throughlines'].size >= 1 && t['throughlines'].size <= 3
        errors << "#{prefix}: throughlines must have 1-3 entries"
      end
    end

    # Invented fields check
    allowed = %w[id thesis_statement confidence anchor_candidate primary_candidates
                  supporting_candidates excluded_candidates likely_hook likely_payoff
                  throughlines target_duration_s score reasoning]
    t.each_key do |k|
      errors << "#{prefix}: invented field '#{k}'" unless allowed.include?(k)
    end
  end

  errors
end

# ─── LLM Pending Request ─────────────────────────────────────────────────────

def build_thesis_pending_request(candidates, relationships, baseline_theses)
  candidate_summaries = candidates.map do |c|
    {
      'id' => c['id'],
      'text' => c['text'],
      'summary' => c['summary'],
      'distillation' => c['distillation'],
      'states' => c['states'],
      'durability' => c['durability'],
      'candidate_priority' => c['candidate_priority'],
      'suggested_narrative_roles' => c['suggested_narrative_roles']
    }
  end

  {
    'prompt_version' => PROMPT_VERSION,
    'instructions' => build_thesis_instructions,
    'constraints' => build_thesis_constraints(candidates),
    'output_format' => build_thesis_output_format,
    'candidates' => candidate_summaries,
    'relationships' => relationships.map { |r|
      { 'id' => r['id'], 'type' => r['type'],
        'from_candidate_id' => r['from_candidate_id'],
        'to_candidate_id' => r['to_candidate_id'],
        'confidence' => r['confidence'],
        'evidence' => r['evidence'] }
    },
    'baseline_theses' => baseline_theses
  }
end

def build_thesis_instructions
  <<~TEXT.strip
    You are an editorial thesis selector for video editing. You are reviewing
    deterministic baseline theses generated from a relationship graph.

    Your job is to refine and improve the thesis selection. You may:
    1. REFINE thesis wording to be more compelling and accurate
    2. RERANK theses by editorial strength
    3. UPGRADE or DOWNGRADE thesis confidence
    4. IMPROVE hook/payoff selection with better candidates
    5. ADJUST primary/supporting/excluded candidate groupings
    6. ADD throughlines the heuristics missed

    Read each candidate's TEXT carefully. The thesis must be grounded in what
    the speaker actually says, not what the heuristics infer from metadata.

    You may NOT invent candidate IDs. Only use IDs from the candidates list.
    You may NOT invent relationships. Only reference relationships from the provided list.
    You may NOT create theses unsupported by the candidate content.
    You may NOT add timestamps, trims, exclusions, or structural data.
  TEXT
end

def build_thesis_constraints(candidates)
  {
    'valid_candidate_ids' => candidates.map { |c| c['id'] },
    'confidence_levels' => VALID_CONFIDENCES,
    'max_thesis_statement_words' => 50,
    'max_throughlines' => 3,
    'max_theses' => 3
  }
end

def build_thesis_output_format
  {
    'description' => 'Return a JSON object with refined theses.',
    'fields' => {
      'theses' => 'Array of refined thesis objects',
      'per_thesis' => {
        'id' => 'thesis_NNN (keep the same IDs from baseline)',
        'thesis_statement' => 'Refined thesis statement (max 50 words)',
        'confidence' => 'high|medium|low',
        'primary_candidates' => 'Array of cand_NNN IDs central to this thesis',
        'supporting_candidates' => 'Array of cand_NNN IDs that provide contrast/support',
        'excluded_candidates' => 'Array of cand_NNN IDs that dilute this thesis',
        'likely_hook' => 'cand_NNN — strongest opening candidate',
        'likely_payoff' => 'cand_NNN — strongest closing candidate',
        'throughlines' => 'Array of {id, description} — 1-3 narrative threads',
        'target_duration_s' => 'Estimated edit duration in seconds',
        'reasoning' => 'Why this thesis is the strongest editorial direction'
      }
    }
  }
end

# ─── LLM Response Validation ─────────────────────────────────────────────────

def validate_thesis_response(response_theses, candidate_ids)
  errors = []
  valid_cand_ids = Set.new(candidate_ids)

  unless response_theses.is_a?(Array)
    return ['response theses must be an array']
  end

  response_theses.each_with_index do |t, i|
    prefix = t['id'] || "thesis[#{i}]"

    unless t['id']&.match?(/\Athesis_\d{3}\z/)
      errors << "#{prefix}: invalid thesis id format"
    end

    unless VALID_CONFIDENCES.include?(t['confidence'])
      errors << "#{prefix}: invalid confidence '#{t['confidence']}'"
    end

    (t['primary_candidates'] || []).each do |cid|
      errors << "#{prefix}: unknown primary_candidate '#{cid}'" unless valid_cand_ids.include?(cid)
    end
    (t['supporting_candidates'] || []).each do |cid|
      errors << "#{prefix}: unknown supporting_candidate '#{cid}'" unless valid_cand_ids.include?(cid)
    end
    (t['excluded_candidates'] || []).each do |cid|
      errors << "#{prefix}: unknown excluded_candidate '#{cid}'" unless valid_cand_ids.include?(cid)
    end

    if t['likely_hook'] && !valid_cand_ids.include?(t['likely_hook'])
      errors << "#{prefix}: unknown likely_hook '#{t['likely_hook']}'"
    end
    if t['likely_payoff'] && !valid_cand_ids.include?(t['likely_payoff'])
      errors << "#{prefix}: unknown likely_payoff '#{t['likely_payoff']}'"
    end

    if t['thesis_statement'].is_a?(String) && t['thesis_statement'].split.size > 50
      errors << "#{prefix}: thesis_statement exceeds 50 words"
    end

    if t['throughlines'].is_a?(Array) && t['throughlines'].size > 3
      errors << "#{prefix}: throughlines exceeds 3 entries"
    end

    # No candidate in multiple groups
    primary   = Set.new(t['primary_candidates'] || [])
    supporting = Set.new(t['supporting_candidates'] || [])
    excluded  = Set.new(t['excluded_candidates'] || [])
    overlap_ps = primary & supporting
    overlap_pe = primary & excluded
    errors << "#{prefix}: candidate in both primary and supporting: #{overlap_ps.to_a.join(', ')}" unless overlap_ps.empty?
    errors << "#{prefix}: candidate in both primary and excluded: #{overlap_pe.to_a.join(', ')}" unless overlap_pe.empty?

    # Invented fields check
    allowed = %w[id thesis_statement confidence anchor_candidate primary_candidates
                  supporting_candidates excluded_candidates likely_hook likely_payoff
                  throughlines target_duration_s score reasoning]
    t.each_key do |k|
      errors << "#{prefix}: invented field '#{k}'" unless allowed.include?(k)
    end
  end

  errors
end

def merge_thesis_response(baseline_theses, response_theses)
  # Response replaces baseline entirely (it's a refinement, not a diff)
  # But we preserve score from baseline if not provided
  baseline_by_id = baseline_theses.each_with_object({}) { |t, h| h[t['id']] = t }

  response_theses.map do |rt|
    bt = baseline_by_id[rt['id']]
    merged = rt.dup
    merged['score'] ||= bt['score'] if bt
    merged
  end
end

# ─── Main ─────────────────────────────────────────────────────────────────────

if __FILE__ == $PROGRAM_NAME
  fixture_dir = nil
  mode = 'mock'

  args = ARGV.dup
  while args.any?
    case args.first
    when '--fixture' then args.shift; fixture_dir = args.shift
    when '--mode'    then args.shift; mode = args.shift
    else abort "Unknown argument: #{args.first}"
    end
  end

  abort 'Usage: ruby scripts/select_thesis.rb --fixture <dir>' unless fixture_dir
  abort "Invalid --mode: #{mode}. Use mock or pending." unless %w[mock pending].include?(mode)

  editorial_path = File.join(fixture_dir, 'editorial_candidates.yaml')
  augmented_path = File.join(fixture_dir, 'augmented_candidate_relationships.yaml')
  baseline_path  = File.join(fixture_dir, 'candidate_relationships.yaml')
  pending_path   = File.join(fixture_dir, 'thesis_selection_pending.json')
  response_path  = File.join(fixture_dir, 'thesis_selection_response.json')
  output_path    = File.join(fixture_dir, 'selected_thesis.yaml')

  abort 'editorial_candidates.yaml not found' unless File.exist?(editorial_path)

  # Prefer augmented relationships, fall back to baseline
  rel_path = File.exist?(augmented_path) ? augmented_path : baseline_path
  abort 'No relationship file found. Run map_candidate_relationships.rb first.' unless File.exist?(rel_path)

  candidates_data = YAML.safe_load(File.read(editorial_path), permitted_classes: [Date])
  candidates = candidates_data['candidates']
  candidate_ids = candidates.map { |c| c['id'] }

  rel_data = YAML.safe_load(File.read(rel_path), permitted_classes: [Date])
  relationships = rel_data['relationships']

  $stderr.puts "Loaded #{candidates.size} candidates, #{relationships.size} relationships from #{File.basename(rel_path)}"

  # Generate deterministic baseline theses
  theses = generate_theses(candidates, relationships)

  if theses.empty?
    abort 'No viable thesis found. Candidates lack sufficient relationships for thesis formation.'
  end

  # Add target_duration_s
  candidates_by_id = candidates.each_with_object({}) { |c, h| h[c['id']] = c }
  theses.each do |t|
    t['target_duration_s'] = estimate_duration(t['primary_candidates'], candidates_by_id)
  end

  # Validate baseline
  baseline_errors = validate_theses(theses, candidate_ids)
  if baseline_errors.any?
    $stderr.puts "Baseline thesis validation FAILED:"
    baseline_errors.each { |e| $stderr.puts "  ERROR: #{e}" }
    exit 2
  end

  if mode == 'mock'
    fingerprint = Digest::SHA256.hexdigest(File.read(editorial_path) + File.read(rel_path))
    output = {
      'version' => '1',
      'mode' => 'mock',
      'prompt_version' => PROMPT_VERSION,
      'input_fingerprint' => fingerprint,
      'generated_at' => 'deterministic',
      'candidate_count' => candidates.size,
      'relationship_count' => relationships.size,
      'thesis_count' => theses.size,
      'selected_thesis' => theses.first['id'],
      'possible_theses' => theses
    }
    File.write(output_path, YAML.dump(output))
    $stderr.puts "selected_thesis.yaml written: #{theses.size} theses (mock)"
    theses.each { |t| $stderr.puts "  #{t['id']}: #{t['confidence']} (score=#{t['score']}) — #{t['thesis_statement'][0..60]}" }
    puts output_path
    exit 0
  end

  # ── Pending mode ──

  if File.exist?(response_path)
    $stderr.puts 'Reading thesis_selection_response.json...'
    response_data = JSON.parse(File.read(response_path))
    response_theses = response_data['theses'] || response_data

    errors = validate_thesis_response(response_theses, candidate_ids)
    if errors.any?
      $stderr.puts 'Thesis response validation FAILED:'
      errors.each { |e| $stderr.puts "  ERROR: #{e}" }
      abort 'Fix thesis_selection_response.json and rerun.'
    end

    merged = merge_thesis_response(theses, response_theses)

    merge_errors = validate_theses(merged, candidate_ids)
    if merge_errors.any?
      $stderr.puts 'Merged thesis validation FAILED:'
      merge_errors.each { |e| $stderr.puts "  ERROR: #{e}" }
      abort 'Merge produced invalid theses.'
    end

    fingerprint = Digest::SHA256.hexdigest(
      File.read(editorial_path) + File.read(rel_path) + File.read(response_path)
    )
    output = {
      'version' => '1',
      'mode' => 'augmented',
      'prompt_version' => PROMPT_VERSION,
      'input_fingerprint' => fingerprint,
      'generated_at' => 'deterministic',
      'candidate_count' => candidates.size,
      'relationship_count' => relationships.size,
      'thesis_count' => merged.size,
      'selected_thesis' => merged.first['id'],
      'possible_theses' => merged
    }
    File.write(output_path, YAML.dump(output))
    $stderr.puts "selected_thesis.yaml written: #{merged.size} theses (augmented)"
    merged.each { |t| $stderr.puts "  #{t['id']}: #{t['confidence']} — #{t['thesis_statement'][0..60]}" }
    puts output_path
  else
    # Write pending request
    request = build_thesis_pending_request(candidates, relationships, theses)
    File.write(pending_path, JSON.pretty_generate(request))
    $stderr.puts "thesis_selection_pending.json written: #{theses.size} baseline theses, #{candidates.size} candidates"
    $stderr.puts "Fill #{response_path} and rerun."
    puts pending_path
    exit 0
  end
end
