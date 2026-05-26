#!/usr/bin/env ruby
# candidate_builder.rb — Phase A/B/C editorial candidate pipeline.
#
# Phase A: deterministic substrate (no LLM)
# Phase B: semantic labeling (mock-deterministic or LLM)
# Phase C: deterministic validation (no LLM)
#
# Usage:
#   ruby scripts/candidate_builder.rb --fixture <dir> --phase a
#   ruby scripts/candidate_builder.rb --fixture <dir> --phase abc
#
# Core invariant: LLMs judge meaning. Scripts handle mechanics.

require 'yaml'
require 'json'
require 'date'
require 'digest'
require 'set'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

# ─── Constants ────────────────────────────────────────────────────────────────

CONTIGUITY_GAP_S = 1.0
BREATHING_MARGIN_S = 0.08
LONG_PAUSE_THRESHOLD_MS = 1500
BOUNDARY_TOLERANCE_S = 0.02
CLUSTER_JACCARD_THRESHOLD = 0.25

# V2 Boundary Heuristic — atom-default with multi-signal merge
MERGE_SIGNAL_THRESHOLD = 2
VAD_PAUSE_SOFT_MS = 700

STRONG_BOUNDARY_MARKERS = %w[but however so now another second third finally here's].freeze
STRONG_BOUNDARY_PHRASES = ['the problem is', 'the point is', 'that said'].freeze

COMPATIBLE_PROFILES = [
  Set.new(%w[casual building]),
  Set.new(%w[building emphatic]),
  Set.new(%w[reflective casual]),
  Set.new(%w[landing reflective]),
  Set.new(%w[authoritative emphatic]),
  Set.new(%w[urgent emphatic])
].freeze

STOP_WORDS = Set.new(%w[
  a an the and or but is are was were be been being
  in on at to for of with by from as into through
  i you he she it we they me him her us them
  my your his its our their
  this that these those
  do does did not no nor
  so if then than just
]).freeze

VALID_STATES = %w[vindication outrage awe competence fear schadenfreude
                   amusement catharsis nostalgia belonging escape calm
                   aspiration sensual curiosity].freeze

VALID_DURABILITY = %w[spike mood identity].freeze
VALID_PRIORITY = %w[primary secondary tertiary].freeze
VALID_CONFIDENCE = %w[high medium low].freeze
VALID_USABILITY = %w[fine marginal unusable].freeze
VALID_ENERGY = %w[low medium high].freeze
VALID_AUDIO_PROFILE = %w[casual building emphatic landing reflective urgent authoritative].freeze
VALID_PITCH_TREND = %w[rising falling flat level varied].freeze
VALID_TRIM_LABELS = %w[full_clean tighter_start tighter_end both_tighter minimal_trim].freeze
VALID_EXCLUSION_TYPES = %w[defect pacing].freeze
VALID_EXCLUSION_REASONS = %w[long_pause stumble abandonment false_start trailing_off low_energy_pause dead_air].freeze
VALID_NARRATIVE_ROLES = %w[hook setup continuation payoff transition claim evidence definition aside].freeze

INCOMPATIBLE_STATE_PAIRS = [
  %w[sensual calm],
  %w[schadenfreude awe],
  %w[outrage amusement],
  %w[belonging schadenfreude],
  %w[calm fear]
].freeze

# Phase B mock: audio_profile → states mapping
PROFILE_STATE_MAP = {
  'emphatic'      => %w[vindication competence],
  'reflective'    => %w[calm],
  'casual'        => %w[amusement],
  'building'      => %w[aspiration competence],
  'landing'       => %w[catharsis],
  'urgent'        => %w[fear],
  'authoritative' => %w[competence vindication]
}.freeze

# Phase B mock: primary state → durability
STATE_DURABILITY_MAP = {
  'vindication' => 'mood', 'outrage' => 'spike', 'awe' => 'mood',
  'competence' => 'identity', 'fear' => 'mood', 'schadenfreude' => 'spike',
  'amusement' => 'spike', 'catharsis' => 'mood', 'nostalgia' => 'identity',
  'belonging' => 'identity', 'escape' => 'spike', 'calm' => 'mood',
  'aspiration' => 'identity', 'sensual' => 'spike', 'curiosity' => 'spike'
}.freeze

# Phase B mock: audio_profile → suggested narrative roles
PROFILE_ROLE_MAP = {
  'emphatic'      => [{ 'role' => 'claim', 'confidence' => 'high' },
                      { 'role' => 'hook', 'confidence' => 'medium' }],
  'reflective'    => [{ 'role' => 'setup', 'confidence' => 'medium' }],
  'casual'        => [{ 'role' => 'aside', 'confidence' => 'medium' },
                      { 'role' => 'transition', 'confidence' => 'low' }],
  'building'      => [{ 'role' => 'evidence', 'confidence' => 'high' },
                      { 'role' => 'setup', 'confidence' => 'medium' }],
  'landing'       => [{ 'role' => 'payoff', 'confidence' => 'high' }],
  'urgent'        => [{ 'role' => 'hook', 'confidence' => 'high' }],
  'authoritative' => [{ 'role' => 'claim', 'confidence' => 'high' }]
}.freeze

# ─── Shared helpers ───────────────────────────────────────────────────────────

def tokenize(text)
  text.downcase.gsub(/[^a-z0-9\s]/, '').split.reject { |w| STOP_WORDS.include?(w) }
end

def jaccard(set_a, set_b)
  return 0.0 if set_a.empty? || set_b.empty?
  intersection = set_a & set_b
  union = set_a | set_b
  intersection.size.to_f / union.size
end

# ─── V2 Boundary Signal Helpers ─────────────────────────────────────────────

def starts_with_boundary_marker?(text)
  normalized = text.to_s.strip.downcase
  STRONG_BOUNDARY_PHRASES.each do |phrase|
    return true if normalized.start_with?(phrase)
  end
  first_word = normalized.split(/\s+/).first.to_s.gsub(/[^a-z']/, '')
  STRONG_BOUNDARY_MARKERS.include?(first_word)
end

def prosody_compatible?(seg_a, seg_b)
  pa = seg_a['audio_profile'].to_s
  pb = seg_b['audio_profile'].to_s
  return true if pa == pb
  COMPATIBLE_PROFILES.any? { |pair| pair == Set.new([pa, pb]) }
end

def sentence_continues?(prev_seg, next_seg)
  prev_text = prev_seg['text'].to_s.strip
  next_text = next_seg['text'].to_s.strip
  # Previous atom doesn't end with sentence-final punctuation
  return true unless prev_text.match?(/[.!?]["']?\z/)
  # Next atom starts lowercase (mid-sentence continuation)
  next_text.match?(/\A[a-z]/) ? true : false
end

def lexical_overlap?(seg_a, seg_b)
  tokens_a = Set.new(tokenize(seg_a['text']))
  tokens_b = Set.new(tokenize(seg_b['text']))
  return false if tokens_a.empty? || tokens_b.empty?
  (tokens_a & tokens_b).any?
end

def gap_has_long_pause?(prev_seg, next_seg, pauses, threshold_ms)
  gap_start = prev_seg['e'].to_f
  gap_end = next_seg['t'].to_f
  pauses.any? do |p|
    p['start'] < gap_end + 0.05 &&
    p['end'] > gap_start - 0.05 &&
    p['duration_ms'] >= threshold_ms
  end
end

def count_merge_signals(prev_seg, next_seg, pauses)
  signals = 0
  signals += 1 if prosody_compatible?(prev_seg, next_seg)
  signals += 1 if sentence_continues?(prev_seg, next_seg)
  signals += 1 if lexical_overlap?(prev_seg, next_seg)
  signals += 1 unless gap_has_long_pause?(prev_seg, next_seg, pauses, VAD_PAUSE_SOFT_MS)
  signals
end

# ─── CLI ──────────────────────────────────────────────────────────────────────

library_name = nil
fixture_dir  = nil
phase        = 'a'

args = ARGV.dup
while args.any?
  case args.first
  when '--library'  then args.shift; library_name = args.shift
  when '--fixture'  then args.shift; fixture_dir  = args.shift
  when '--phase'    then args.shift; phase        = args.shift
  else
    abort "Unknown argument: #{args.first}"
  end
end

phase = phase.downcase
unless phase.chars.all? { |c| 'abc'.include?(c) } && !phase.empty?
  abort "Invalid --phase: #{phase}. Use a, b, c, ab, bc, or abc."
end

unless library_name || fixture_dir
  abort "Usage: ruby scripts/candidate_builder.rb --fixture <dir> --phase a"
end

# ─── Path resolution ──────────────────────────────────────────────────────────

if fixture_dir
  segments_path   = File.join(fixture_dir, 'segments_classified.yaml')
  transcript_path = File.join(fixture_dir, 'cleaned_transcript.json')
  vad_path        = File.join(fixture_dir, 'speech_analysis.json')
  substrate_path  = File.join(fixture_dir, 'candidate_substrate.yaml')
  editorial_path  = File.join(fixture_dir, 'editorial_candidates.yaml')
  warnings_path   = File.join(fixture_dir, 'candidate_builder_warnings.log')
else
  abort "Library mode not yet implemented. Use --fixture for now."
end

# ─── Phase A: Deterministic Substrate ─────────────────────────────────────────

if phase.include?('a')
  abort "segments_classified.yaml not found: #{segments_path}" unless File.exist?(segments_path)
  abort "cleaned_transcript.json not found: #{transcript_path}" unless File.exist?(transcript_path)
  abort "speech_analysis.json not found: #{vad_path}" unless File.exist?(vad_path)

  segments_data = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])
  segments      = segments_data['segments'] || []
  abort "No segments found in #{segments_path}" if segments.empty?

  transcript_data = JSON.parse(File.read(transcript_path))
  vad_data        = JSON.parse(File.read(vad_path))

  # Build word-timing index
  all_transcript_words = []
  (transcript_data['segments'] || []).each do |ts|
    (ts['words'] || []).each do |w|
      all_transcript_words << {
        'word'  => w['word'].to_s,
        'start' => w['start'].to_f,
        'end'   => w['end'].to_f
      }
    end
  end
  all_transcript_words.sort_by! { |w| w['start'] }

  def words_in_range(all_words, t, e)
    all_words.select { |w| w['start'] >= t - 0.05 && w['end'] <= e + 0.05 }
  end

  # Build VAD long-pause index
  long_pauses = (vad_data['long_pauses'] || []).map do |p|
    { 'start' => p['start'].to_f, 'end' => p['end'].to_f, 'duration_ms' => (p['duration'].to_f * 1000).round }
  end

  # Build segment lookup
  seg_by_id = {}
  segments.each { |s| seg_by_id[s['id']] = s }

  # V2: Atom-default grouping with multi-signal merge.
  # Each segment starts as its own candidate. Adjacent same-source segments
  # merge only when no hard-split fires AND at least MERGE_SIGNAL_THRESHOLD
  # continuity signals are positive.
  #
  # Hard splits: source change, gap > CONTIGUITY_GAP_S, strong rhetorical
  #   marker at next atom start, VAD pause >= LONG_PAUSE_THRESHOLD_MS in gap.
  # Merge signals (4): prosody compatibility, sentence continuation,
  #   lexical overlap, pause continuity (no VAD pause >= VAD_PAUSE_SOFT_MS).
  groups = []
  current_group = [segments.first]

  segments[1..].each do |seg|
    prev = current_group.last
    same_source = seg['source'] == prev['source']
    gap = seg['t'].to_f - prev['e'].to_f

    hard_split = !same_source ||
                 gap > CONTIGUITY_GAP_S ||
                 starts_with_boundary_marker?(seg['text']) ||
                 gap_has_long_pause?(prev, seg, long_pauses, LONG_PAUSE_THRESHOLD_MS)

    if hard_split
      groups << current_group
      current_group = [seg]
    elsif count_merge_signals(prev, seg, long_pauses) >= MERGE_SIGNAL_THRESHOLD
      current_group << seg
    else
      groups << current_group
      current_group = [seg]
    end
  end
  groups << current_group unless current_group.empty?

  # Build candidates
  candidates = []
  trim_counter = 0
  ex_counter   = 0

  groups.each_with_index do |group, gi|
    cand_id = format('cand_%03d', gi + 1)

    segment_ids = group.map { |s| s['id'] }
    source      = group.first['source']
    t           = group.first['t'].to_f
    e           = group.last['e'].to_f
    text        = group.map { |s| s['text'] }.join(' ')

    # Trim choices
    trim_choices = []
    seg_words = words_in_range(all_transcript_words, t, e)

    trim_counter += 1
    trim_choices << {
      'id'    => format('trim_%03d', trim_counter),
      'in'    => t.round(2),
      'out'   => e.round(2),
      'label' => 'full_clean',
      'mechanical_boundary_safe' => true,
      'content_preserved' => nil
    }

    if seg_words.any?
      first_word_start = seg_words.first['start']
      tighter_in = (first_word_start - BREATHING_MARGIN_S).round(2)
      if tighter_in > t + BOUNDARY_TOLERANCE_S && tighter_in >= t
        trim_counter += 1
        trim_choices << {
          'id'    => format('trim_%03d', trim_counter),
          'in'    => [tighter_in, t].max.round(2),
          'out'   => e.round(2),
          'label' => 'tighter_start',
          'mechanical_boundary_safe' => true,
          'content_preserved' => nil
        }
      end

      last_word_end = seg_words.last['end']
      tighter_out = (last_word_end + BREATHING_MARGIN_S).round(2)
      if tighter_out < e - BOUNDARY_TOLERANCE_S && tighter_out <= e
        trim_counter += 1
        trim_choices << {
          'id'    => format('trim_%03d', trim_counter),
          'in'    => t.round(2),
          'out'   => [tighter_out, e].min.round(2),
          'label' => 'tighter_end',
          'mechanical_boundary_safe' => true,
          'content_preserved' => nil
        }
      end

      if trim_choices.any? { |tc| tc['label'] == 'tighter_start' } &&
         trim_choices.any? { |tc| tc['label'] == 'tighter_end' }
        ts_trim = trim_choices.find { |tc| tc['label'] == 'tighter_start' }
        te_trim = trim_choices.find { |tc| tc['label'] == 'tighter_end' }
        if ts_trim['in'] < te_trim['out']
          trim_counter += 1
          trim_choices << {
            'id'    => format('trim_%03d', trim_counter),
            'in'    => ts_trim['in'],
            'out'   => te_trim['out'],
            'label' => 'both_tighter',
            'mechanical_boundary_safe' => true,
            'content_preserved' => nil
          }
        end
      end
    end

    # Exclusion choices
    exclusion_choices = []

    candidate_pauses = long_pauses.select do |p|
      p['start'] > t + BOUNDARY_TOLERANCE_S &&
      p['end'] < e - BOUNDARY_TOLERANCE_S &&
      p['duration_ms'] >= LONG_PAUSE_THRESHOLD_MS
    end

    candidate_pauses.each do |p|
      ex_counter += 1
      exclusion_choices << {
        'id'          => format('ex_%03d', ex_counter),
        'start'       => p['start'].round(2),
        'end'         => p['end'].round(2),
        'type'        => 'pacing',
        'reason'      => 'long_pause',
        'recommended' => true
      }
    end

    # Prosody aggregation
    profiles = group.map { |s| s['audio_profile'] }.compact
    energies = group.map { |s| s['audio_energy'] }.compact
    stumbles = group.map { |s| s['stumble_count'] || 0 }
    pauses_ms = group.map { |s| s['max_within_segment_pause_ms'] || 0 }
    trends = group.map { |s| s['audio_pitch_trend'] }.compact

    avg_energy = energies.any? ? energies.sum / energies.size : 1.0
    energy_enum = if avg_energy > 1.3
                    'high'
                  elsif avg_energy >= 0.75
                    'medium'
                  else
                    'low'
                  end

    profile = if profiles.any?
                profiles.group_by(&:itself).max_by { |_, v| v.size }.first
              else
                'casual'
              end

    trend = if trends.any?
              trend_counts = trends.group_by(&:itself).transform_values(&:size)
              if trend_counts.size == 1
                trends.first
              elsif trends.uniq.size == trends.size
                'varied'
              else
                trend_counts.max_by { |_, v| v }.first
              end
            else
              'level'
            end

    prosody = {
      'audio_profile' => profile,
      'energy'        => energy_enum,
      'stumble_count' => stumbles.sum,
      'max_pause_ms'  => pauses_ms.max,
      'pitch_trend'   => trend
    }

    candidates << {
      'id'                => cand_id,
      'source'            => source,
      'segment_ids'       => segment_ids,
      't'                 => t.round(2),
      'e'                 => e.round(2),
      'text'              => text,
      'trim_choices'      => trim_choices,
      'exclusion_choices' => exclusion_choices,
      'cluster'           => nil,
      'prosody'           => prosody
    }
  end

  # Lexical cluster detection
  token_sets = candidates.map { |c| Set.new(tokenize(c['text'])) }

  cluster_labels = Array.new(candidates.size, nil)
  cluster_counter = 0

  candidates.each_with_index do |_c1, i|
    (i + 1...candidates.size).each do |j|
      score = jaccard(token_sets[i], token_sets[j])
      next unless score >= CLUSTER_JACCARD_THRESHOLD

      if cluster_labels[i] && cluster_labels[j]
        old_label = cluster_labels[j]
        new_label = cluster_labels[i]
        cluster_labels.map! { |l| l == old_label ? new_label : l }
      elsif cluster_labels[i]
        cluster_labels[j] = cluster_labels[i]
      elsif cluster_labels[j]
        cluster_labels[i] = cluster_labels[j]
      else
        shared = (token_sets[i] & token_sets[j]).to_a.sort.first(3).join('_')
        label = shared.empty? ? "cluster_#{cluster_counter += 1}" : shared
        cluster_labels[i] = label
        cluster_labels[j] = label
      end
    end
  end

  candidates.each_with_index do |c, i|
    c['cluster'] = cluster_labels[i]
  end

  # Phase A self-validation
  errors = []
  valid_seg_ids = Set.new(segments.map { |s| s['id'] })

  candidates.each do |c|
    cid = c['id']
    errors << "#{cid}: id does not match cand_NNN" unless cid.match?(/\Acand_\d{3}\z/)
    errors << "#{cid}: t (#{c['t']}) >= e (#{c['e']})" unless c['t'] < c['e']
    c['segment_ids'].each do |sid|
      errors << "#{cid}: segment_ids references unknown #{sid}" unless valid_seg_ids.include?(sid)
    end
    errors << "#{cid}: segment_ids is empty" if c['segment_ids'].empty?

    seg_sources = c['segment_ids'].map { |sid| seg_by_id[sid]&.[]('source') }.compact.uniq
    errors << "#{cid}: segments span multiple sources: #{seg_sources}" if seg_sources.size > 1

    trim_ids = Set.new
    c['trim_choices'].each do |tc|
      errors << "#{cid}: trim id '#{tc['id']}' does not match trim_NNN" unless tc['id'].match?(/\Atrim_\d{3}\z/)
      errors << "#{cid}: duplicate trim id #{tc['id']}" if trim_ids.include?(tc['id'])
      trim_ids << tc['id']
      errors << "#{cid}: trim #{tc['id']} in (#{tc['in']}) < candidate t (#{c['t']})" if tc['in'] < c['t'] - 0.001
      errors << "#{cid}: trim #{tc['id']} out (#{tc['out']}) > candidate e (#{c['e']})" if tc['out'] > c['e'] + 0.001
      errors << "#{cid}: trim #{tc['id']} in >= out" unless tc['in'] < tc['out']
    end
    errors << "#{cid}: no full_clean trim_choice" unless c['trim_choices'].any? { |tc| tc['label'] == 'full_clean' }

    ex_ids = Set.new
    c['exclusion_choices'].each do |ec|
      errors << "#{cid}: exclusion id '#{ec['id']}' does not match ex_NNN" unless ec['id'].match?(/\Aex_\d{3}\z/)
      errors << "#{cid}: duplicate exclusion id #{ec['id']}" if ex_ids.include?(ec['id'])
      ex_ids << ec['id']
      errors << "#{cid}: exclusion #{ec['id']} start (#{ec['start']}) < candidate t" if ec['start'] < c['t'] - 0.001
      errors << "#{cid}: exclusion #{ec['id']} end (#{ec['end']}) > candidate e" if ec['end'] > c['e'] + 0.001
      errors << "#{cid}: exclusion #{ec['id']} start >= end" unless ec['start'] < ec['end']
    end

    sorted_ex = c['exclusion_choices'].sort_by { |ec| ec['start'] }
    sorted_ex.each_cons(2) do |a, b|
      errors << "#{cid}: overlapping exclusions #{a['id']} and #{b['id']}" if a['end'] > b['start']
    end

    if c['cluster'] && !c['cluster'].match?(/\A[a-z0-9]+(_[a-z0-9]+)*\z/)
      errors << "#{cid}: cluster '#{c['cluster']}' is not snake_case"
    end

    %w[audio_profile energy stumble_count max_pause_ms pitch_trend].each do |field|
      errors << "#{cid}: prosody.#{field} missing" if c['prosody'][field].nil?
    end
  end

  cand_ids = candidates.map { |c| c['id'] }
  dupes = cand_ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
  errors << "Duplicate candidate ids: #{dupes.join(', ')}" if dupes.any?

  unless errors.empty?
    $stderr.puts "PHASE A VALIDATION FAILED (#{errors.size} errors):"
    errors.each { |e| $stderr.puts "  #{e}" }
    exit 1
  end

  # Write Phase A output
  input_fingerprint = Digest::SHA256.hexdigest(File.read(segments_path))

  result = {
    'version'           => '1.2',
    'input_fingerprint' => input_fingerprint,
    'generated_at'      => 'deterministic',
    'candidate_count'   => candidates.size,
    'candidates'        => candidates
  }

  File.write(substrate_path, YAML.dump(result))
  $stderr.puts "candidate_substrate.yaml written: #{candidates.size} candidates from #{segments.size} segments"
  $stderr.puts "  Multi-atom candidates: #{candidates.count { |c| c['segment_ids'].size > 1 }}"
  $stderr.puts "  Candidates with exclusions: #{candidates.count { |c| !c['exclusion_choices'].empty? }}"
  $stderr.puts "  Clustered candidates: #{candidates.count { |c| c['cluster'] }}"
  puts substrate_path
end

# ─── Phase B: Mock Semantic Labeling ──────────────────────────────────────────
#
# Deterministic mock that simulates LLM structure.
# In production, this section would be replaced by the pending-file pattern
# and an actual LLM call.
#
# Hard rules enforced:
#   - No timestamps generated
#   - No invented IDs
#   - No substrate mutation (trim/exclusion structure unchanged)
#   - Only Phase B fields populated

if phase.include?('b')
  abort "candidate_substrate.yaml not found: #{substrate_path}" unless File.exist?(substrate_path)

  substrate = YAML.safe_load(File.read(substrate_path), permitted_classes: [Date])
  b_candidates = substrate['candidates'] || []
  abort "No candidates in substrate" if b_candidates.empty?

  labeled = b_candidates.map do |c|
    profile = c['prosody']['audio_profile']
    energy  = c['prosody']['energy']

    # summary: first sentence, max 25 words
    first_sentence = c['text'].split(/(?<=\.)\s+/).first || c['text']
    summary_words = first_sentence.split
    summary = summary_words.first(25).join(' ')

    # distillation: first 5 non-stop content words
    distillation = tokenize(c['text']).first(5).join(' ')

    # usability from stumble_count
    stumbles = c['prosody']['stumble_count'] || 0
    usability = if stumbles > 2 then 'unusable'
                elsif stumbles > 0 then 'marginal'
                else 'fine'
                end

    # candidate_priority from energy
    priority = case energy
               when 'high' then 'primary'
               when 'low'  then 'tertiary'
               else 'secondary'
               end

    # states from audio_profile
    states = (PROFILE_STATE_MAP[profile] || ['curiosity']).dup
    # Remove incompatible pairs (keep first, drop second)
    INCOMPATIBLE_STATE_PAIRS.each do |a, b|
      states.delete(b) if states.include?(a) && states.include?(b)
    end
    states = states.first(3)

    # durability from primary state
    durability = STATE_DURABILITY_MAP[states.first] || 'spike'

    # confidence
    confidence = if usability == 'unusable' then 'low'
                 elsif usability == 'fine' && energy != 'low' then 'high'
                 else 'medium'
                 end

    # suggested_narrative_roles
    roles = (PROFILE_ROLE_MAP[profile] || [{ 'role' => 'continuation', 'confidence' => 'medium' }]).map(&:dup)

    # content_preserved per trim_choice
    updated_trims = c['trim_choices'].map do |tc|
      tc = tc.dup
      if tc['label'] == 'full_clean'
        tc['content_preserved'] = true
      else
        duration = c['e'] - c['t']
        trim_duration = tc['out'] - tc['in']
        tc['content_preserved'] = duration > 0 ? (trim_duration / duration) >= 0.8 : true
      end
      tc
    end

    edit_notes = "Mock labeling: #{profile}/#{energy}"

    # Build candidate in canonical schema field order
    {
      'id'                       => c['id'],
      'source'                   => c['source'],
      'segment_ids'              => c['segment_ids'],
      't'                        => c['t'],
      'e'                        => c['e'],
      'text'                     => c['text'],
      'trim_choices'             => updated_trims,
      'exclusion_choices'        => c['exclusion_choices'],
      'summary'                  => summary,
      'distillation'             => distillation,
      'usability'                => usability,
      'candidate_priority'       => priority,
      'suggested_narrative_roles' => roles,
      'states'                   => states,
      'durability'               => durability,
      'confidence'               => confidence,
      'cluster'                  => c['cluster'],
      'prosody'                  => c['prosody'],
      'edit_notes'               => edit_notes
    }
  end

  editorial_result = {
    'version'           => substrate['version'],
    'input_fingerprint' => substrate['input_fingerprint'],
    'generated_at'      => substrate['generated_at'],
    'candidate_count'   => substrate['candidate_count'],
    'candidates'        => labeled
  }

  File.write(editorial_path, YAML.dump(editorial_result))
  $stderr.puts "editorial_candidates.yaml written: #{labeled.size} candidates labeled (mock)"
  puts editorial_path
end

# ─── Phase C: Deterministic Validation ────────────────────────────────────────
#
# Validates editorial_candidates.yaml against editorial_candidate.schema.yaml v1.2.
# Hard gate — pipeline aborts on failure.
#
# Exit codes:
#   0 = valid
#   1 = structural errors
#   2 = taxonomy violations
#   3 = data errors

if phase.include?('c')
  abort "editorial_candidates.yaml not found: #{editorial_path}" unless File.exist?(editorial_path)
  abort "segments_classified.yaml not found: #{segments_path}" unless File.exist?(segments_path)

  editorial = YAML.safe_load(File.read(editorial_path), permitted_classes: [Date])
  seg_data_c = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])
  segs_c = seg_data_c['segments'] || []

  valid_seg_ids_c = Set.new(segs_c.map { |s| s['id'] })
  seg_sources_c = {}
  segs_c.each { |s| seg_sources_c[s['id']] = s['source'] }

  c_candidates = editorial['candidates'] || []

  structural = []
  taxonomy   = []
  data_errs  = []
  warnings   = []

  # File-level checks
  structural << "version must be '1.2', got '#{editorial['version']}'" unless editorial['version'] == '1.2'
  structural << "input_fingerprint missing or empty" unless editorial['input_fingerprint'].is_a?(String) && !editorial['input_fingerprint'].empty?
  structural << "candidate_count mismatch: header=#{editorial['candidate_count']} actual=#{c_candidates.size}" unless editorial['candidate_count'] == c_candidates.size
  structural << "candidates array empty" if c_candidates.empty?

  all_cand_ids = []
  all_trim_ids = []
  all_ex_ids   = []

  c_candidates.each do |c|
    cid = c['id'] || '(nil)'
    all_cand_ids << cid

    # ── Structural ──────────────────────────────────────────────────────────

    structural << "#{cid}: id does not match cand_NNN" unless cid.match?(/\Acand_\d{3}\z/)

    unless c['segment_ids'].is_a?(Array) && !c['segment_ids'].empty?
      structural << "#{cid}: segment_ids missing or empty"
    end
    (c['segment_ids'] || []).each do |sid|
      structural << "#{cid}: segment_ids references unknown #{sid}" unless valid_seg_ids_c.include?(sid)
    end

    seg_srcs = (c['segment_ids'] || []).map { |sid| seg_sources_c[sid] }.compact.uniq
    structural << "#{cid}: segments span multiple sources" if seg_srcs.size > 1

    unless c['trim_choices'].is_a?(Array) && !c['trim_choices'].empty?
      structural << "#{cid}: trim_choices missing or empty"
    end

    has_full_clean = false
    (c['trim_choices'] || []).each do |tc|
      tid = tc['id'] || '(nil)'
      all_trim_ids << tid
      structural << "#{cid}: trim #{tid} does not match trim_NNN" unless tid.match?(/\Atrim_\d{3}\z/)
      structural << "#{cid}: trim #{tid} in < candidate t" if tc['in'] && c['t'] && tc['in'] < c['t'] - 0.001
      structural << "#{cid}: trim #{tid} out > candidate e" if tc['out'] && c['e'] && tc['out'] > c['e'] + 0.001
      structural << "#{cid}: trim #{tid} in >= out" if tc['in'] && tc['out'] && tc['in'] >= tc['out']
      has_full_clean = true if tc['label'] == 'full_clean'
    end
    structural << "#{cid}: no full_clean trim" unless has_full_clean

    (c['exclusion_choices'] || []).each do |ec|
      eid = ec['id'] || '(nil)'
      all_ex_ids << eid
      structural << "#{cid}: exclusion #{eid} does not match ex_NNN" unless eid.match?(/\Aex_\d{3}\z/)
      structural << "#{cid}: exclusion #{eid} start < candidate t" if ec['start'] && c['t'] && ec['start'] < c['t'] - 0.001
      structural << "#{cid}: exclusion #{eid} end > candidate e" if ec['end'] && c['e'] && ec['end'] > c['e'] + 0.001
      structural << "#{cid}: exclusion #{eid} start >= end" if ec['start'] && ec['end'] && ec['start'] >= ec['end']
    end

    sorted_ex = (c['exclusion_choices'] || []).sort_by { |ec| ec['start'] || 0 }
    sorted_ex.each_cons(2) do |a, b|
      structural << "#{cid}: overlapping exclusions #{a['id']} and #{b['id']}" if a['end'] && b['start'] && a['end'] > b['start']
    end

    # ── Taxonomy ────────────────────────────────────────────────────────────

    if !c['states'].is_a?(Array) || c['states'].empty?
      taxonomy << "#{cid}: states missing or empty"
    else
      taxonomy << "#{cid}: states exceeds max 3 (got #{c['states'].size})" if c['states'].size > 3
      c['states'].each do |s|
        taxonomy << "#{cid}: invalid state '#{s}'" unless VALID_STATES.include?(s)
      end
      INCOMPATIBLE_STATE_PAIRS.each do |a, b|
        taxonomy << "#{cid}: incompatible state pair #{a}+#{b}" if c['states'].include?(a) && c['states'].include?(b)
      end
    end

    taxonomy << "#{cid}: invalid durability '#{c['durability']}'" unless VALID_DURABILITY.include?(c['durability'])
    taxonomy << "#{cid}: invalid candidate_priority '#{c['candidate_priority']}'" unless VALID_PRIORITY.include?(c['candidate_priority'])
    taxonomy << "#{cid}: invalid confidence '#{c['confidence']}'" unless VALID_CONFIDENCE.include?(c['confidence'])
    taxonomy << "#{cid}: invalid usability '#{c['usability']}'" unless VALID_USABILITY.include?(c['usability'])

    if c['distillation'].is_a?(String)
      wc = c['distillation'].split.size
      taxonomy << "#{cid}: distillation exceeds 5 words (#{wc})" if wc > 5
    else
      taxonomy << "#{cid}: distillation missing"
    end

    if c['summary'].is_a?(String)
      wc = c['summary'].split.size
      taxonomy << "#{cid}: summary exceeds 25 words (#{wc})" if wc > 25
    else
      taxonomy << "#{cid}: summary missing"
    end

    if c['suggested_narrative_roles'].is_a?(Array)
      roles = c['suggested_narrative_roles'].map { |r| r['role'] }
      roles.each do |r|
        taxonomy << "#{cid}: invalid narrative role '#{r}'" unless VALID_NARRATIVE_ROLES.include?(r)
      end
      taxonomy << "#{cid}: duplicate narrative roles" if roles.uniq.size != roles.size
    else
      taxonomy << "#{cid}: suggested_narrative_roles missing or not array"
    end

    if c['prosody'].is_a?(Hash)
      taxonomy << "#{cid}: invalid audio_profile '#{c['prosody']['audio_profile']}'" unless VALID_AUDIO_PROFILE.include?(c['prosody']['audio_profile'])
      taxonomy << "#{cid}: invalid energy '#{c['prosody']['energy']}'" unless VALID_ENERGY.include?(c['prosody']['energy'])
      taxonomy << "#{cid}: invalid pitch_trend '#{c['prosody']['pitch_trend']}'" unless VALID_PITCH_TREND.include?(c['prosody']['pitch_trend'])
    else
      taxonomy << "#{cid}: prosody missing or not hash"
    end

    (c['trim_choices'] || []).each do |tc|
      taxonomy << "#{cid}: invalid trim label '#{tc['label']}'" unless VALID_TRIM_LABELS.include?(tc['label'])
    end

    (c['exclusion_choices'] || []).each do |ec|
      taxonomy << "#{cid}: invalid exclusion type '#{ec['type']}'" unless VALID_EXCLUSION_TYPES.include?(ec['type'])
      taxonomy << "#{cid}: invalid exclusion reason '#{ec['reason']}'" unless VALID_EXCLUSION_REASONS.include?(ec['reason'])
    end

    # ── Data ────────────────────────────────────────────────────────────────

    data_errs << "#{cid}: t >= e" if c['t'] && c['e'] && c['t'] >= c['e']

    (c['trim_choices'] || []).each do |tc|
      data_errs << "#{cid}: trim #{tc['id']} content_preserved not set" if tc['content_preserved'].nil?
      data_errs << "#{cid}: trim #{tc['id']} mechanical_boundary_safe not set" if tc['mechanical_boundary_safe'].nil?
    end

    # Arrangement-safe: at least one trim with both safe=true and preserved=true
    if c['usability'] != 'unusable'
      safe_trims = (c['trim_choices'] || []).select do |tc|
        tc['mechanical_boundary_safe'] == true && tc['content_preserved'] == true
      end
      data_errs << "#{cid}: no arrangement-safe trim (needs mechanical_boundary_safe + content_preserved)" if safe_trims.empty?
    end

    # Cluster: null or snake_case
    if c['cluster'] && !c['cluster'].match?(/\A[a-z0-9]+(_[a-z0-9]+)*\z/)
      structural << "#{cid}: cluster '#{c['cluster']}' is not snake_case"
    end

    # ── Warnings ────────────────────────────────────────────────────────────

    full_clean = (c['trim_choices'] || []).find { |tc| tc['label'] == 'full_clean' }
    if full_clean && full_clean['content_preserved'] == false
      warnings << "[WARN] #{cid}: full_clean trim has content_preserved=false"
    end

    if c['usability'] == 'unusable' && c['confidence'] == 'high'
      warnings << "[WARN] #{cid}: unusable candidate with high confidence"
    end
  end

  # Global ID uniqueness
  [['candidate', all_cand_ids], ['trim', all_trim_ids], ['exclusion', all_ex_ids]].each do |label, ids|
    dupes = ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
    structural << "Duplicate #{label} ids: #{dupes.join(', ')}" if dupes.any?
  end

  # Cluster state mismatch warning
  clusters = {}
  c_candidates.each do |c|
    next unless c['cluster']
    clusters[c['cluster']] ||= []
    clusters[c['cluster']] << c
  end
  clusters.each do |label, members|
    next if members.size < 2
    all_state_sets = members.map { |m| m['states'] || [] }
    shared = all_state_sets.reduce { |acc, s| acc & s }
    if shared.empty?
      ids = members.map { |m| m['id'] }.join(', ')
      warnings << "[WARN] Cluster '#{label}' members (#{ids}) share no common state"
    end
  end

  # Write warnings log
  if warnings.any?
    File.write(warnings_path, warnings.join("\n") + "\n")
  elsif File.exist?(warnings_path)
    File.delete(warnings_path)
  end

  # Report all errors
  all_errors = structural + taxonomy + data_errs
  unless all_errors.empty?
    if structural.any?
      $stderr.puts "PHASE C STRUCTURAL ERRORS (#{structural.size}):"
      structural.each { |e| $stderr.puts "  #{e}" }
    end
    if taxonomy.any?
      $stderr.puts "PHASE C TAXONOMY ERRORS (#{taxonomy.size}):"
      taxonomy.each { |e| $stderr.puts "  #{e}" }
    end
    if data_errs.any?
      $stderr.puts "PHASE C DATA ERRORS (#{data_errs.size}):"
      data_errs.each { |e| $stderr.puts "  #{e}" }
    end

    exit 1 if structural.any?
    exit 2 if taxonomy.any?
    exit 3 if data_errs.any?
  end

  unless warnings.empty?
    $stderr.puts "PHASE C WARNINGS (#{warnings.size}):"
    warnings.each { |w| $stderr.puts "  #{w}" }
  end

  $stderr.puts "Phase C validation passed: #{c_candidates.size} candidates valid"
  puts editorial_path
end
