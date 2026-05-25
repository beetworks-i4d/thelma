#!/usr/bin/env ruby
# candidate_builder.rb — Phase A: deterministic editorial candidate substrate.
#
# Reads segments_classified.yaml + word-level timing + VAD data.
# Produces candidate_substrate.yaml (Phase A only — no LLM, no Phase B fields).
#
# Usage:
#   ruby scripts/candidate_builder.rb --library <name>
#   ruby scripts/candidate_builder.rb --fixture <fixture_dir> --phase a
#
# Core invariant: LLMs judge meaning. Scripts handle mechanics.
# This script handles mechanics only.

require 'yaml'
require 'json'
require 'date'
require 'digest'
require 'set'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

# Contiguity threshold: segments from the same source with gap <= this are grouped.
CONTIGUITY_GAP_S = 1.0

# BREATHING_MARGIN applied to tighter trims (seconds).
BREATHING_MARGIN_S = 0.08

# Pause duration threshold for exclusion_choices (ms).
LONG_PAUSE_THRESHOLD_MS = 1500

# Boundary alignment tolerance (seconds).
BOUNDARY_TOLERANCE_S = 0.02

# Jaccard threshold for lexical clustering.
CLUSTER_JACCARD_THRESHOLD = 0.25

# Stop words excluded from Jaccard computation.
STOP_WORDS = Set.new(%w[
  a an the and or but is are was were be been being
  in on at to for of with by from as into through
  i you he she it we they me him her us them
  my your his its our their
  this that these those
  do does did not no nor
  so if then than just
]).freeze

# ─── CLI ─────────────────────────────────────────────────────────────────────

library_name = nil
fixture_dir  = nil
phase        = nil

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

unless library_name || fixture_dir
  abort "Usage: ruby scripts/candidate_builder.rb --fixture <dir> --phase a"
end

# ─── Load inputs ─────────────────────────────────────────────────────────────

if fixture_dir
  segments_path     = File.join(fixture_dir, 'segments_classified.yaml')
  transcript_path   = File.join(fixture_dir, 'cleaned_transcript.json')
  vad_path          = File.join(fixture_dir, 'speech_analysis.json')
  output_path       = File.join(fixture_dir, 'candidate_substrate.yaml')
else
  require_relative 'library_resolver'
  library_dir     = LibraryResolver.resolve(library_name)
  segments_path   = File.join(library_dir, 'segments_classified.yaml')
  # In library mode, transcript/VAD paths resolved from library.yaml
  # (not implemented yet — fixture mode only for Session 6A)
  abort "Library mode not yet implemented. Use --fixture for now."
end

abort "segments_classified.yaml not found: #{segments_path}" unless File.exist?(segments_path)
abort "cleaned_transcript.json not found: #{transcript_path}" unless File.exist?(transcript_path)
abort "speech_analysis.json not found: #{vad_path}" unless File.exist?(vad_path)

segments_data = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])
segments      = segments_data['segments'] || []
abort "No segments found in #{segments_path}" if segments.empty?

transcript_data = JSON.parse(File.read(transcript_path))
vad_data        = JSON.parse(File.read(vad_path))

# ─── Build word-timing index ─────────────────────────────────────────────────
# Map each segment id to its word-level timing array.

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

# For each segment, find words within its [t, e] window.
def words_in_range(all_words, t, e)
  all_words.select { |w| w['start'] >= t - 0.05 && w['end'] <= e + 0.05 }
end

# ─── Build VAD long-pause index ──────────────────────────────────────────────

long_pauses = (vad_data['long_pauses'] || []).map do |p|
  { 'start' => p['start'].to_f, 'end' => p['end'].to_f, 'duration_ms' => (p['duration'].to_f * 1000).round }
end

# ─── Phase A: Generate candidate spans ───────────────────────────────────────

# Build segment lookup.
seg_by_id = {}
segments.each { |s| seg_by_id[s['id']] = s }

# Group contiguous same-source segments.
# Segments are ordered as they appear in segments_classified.yaml.
# Two consecutive segments are grouped if:
#   1. Same source
#   2. Gap between previous.e and current.t <= CONTIGUITY_GAP_S

groups = []
current_group = [segments.first]

segments[1..].each do |seg|
  prev = current_group.last
  same_source = seg['source'] == prev['source']
  gap = seg['t'].to_f - prev['e'].to_f

  if same_source && gap <= CONTIGUITY_GAP_S
    current_group << seg
  else
    groups << current_group
    current_group = [seg]
  end
end
groups << current_group unless current_group.empty?

# ─── Phase A: Build candidates ──────────────────────────────────────────────

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

  # ── Trim choices ───────────────────────────────────────────────────────

  trim_choices = []
  seg_words = words_in_range(all_transcript_words, t, e)

  # 1. full_clean — always present
  trim_counter += 1
  trim_choices << {
    'id'    => format('trim_%03d', trim_counter),
    'in'    => t.round(2),
    'out'   => e.round(2),
    'label' => 'full_clean',
    'mechanical_boundary_safe' => true,
    'content_preserved' => nil
  }

  # 2. tighter_start — if first word starts after t + margin
  if seg_words.any?
    first_word_start = seg_words.first['start']
    tighter_in = (first_word_start - BREATHING_MARGIN_S).round(2)
    if tighter_in > t + BOUNDARY_TOLERANCE_S && tighter_in >= t
      trim_counter += 1
      safe = (first_word_start - tighter_in).abs <= BOUNDARY_TOLERANCE_S ||
             tighter_in >= t
      trim_choices << {
        'id'    => format('trim_%03d', trim_counter),
        'in'    => [tighter_in, t].max.round(2),
        'out'   => e.round(2),
        'label' => 'tighter_start',
        'mechanical_boundary_safe' => true,
        'content_preserved' => nil
      }
    end

    # 3. tighter_end — if last word ends before e - margin
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

    # 4. both_tighter — if both start and end can be tightened
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

  # ── Exclusion choices ──────────────────────────────────────────────────

  exclusion_choices = []

  # Find long pauses within this candidate's time range.
  candidate_pauses = long_pauses.select do |p|
    p['start'] > t + BOUNDARY_TOLERANCE_S &&
    p['end'] < e - BOUNDARY_TOLERANCE_S &&
    p['duration_ms'] >= LONG_PAUSE_THRESHOLD_MS
  end

  candidate_pauses.each do |p|
    ex_counter += 1
    # Check if exclusion boundaries align with word boundaries.
    pause_start_aligned = seg_words.any? { |w| (w['end'] - p['start']).abs <= BOUNDARY_TOLERANCE_S }
    pause_end_aligned   = seg_words.any? { |w| (w['start'] - p['end']).abs <= BOUNDARY_TOLERANCE_S }
    safe = pause_start_aligned && pause_end_aligned

    exclusion_choices << {
      'id'          => format('ex_%03d', ex_counter),
      'start'       => p['start'].round(2),
      'end'         => p['end'].round(2),
      'type'        => 'pacing',
      'reason'      => 'long_pause',
      'recommended' => true
    }
  end

  # ── Prosody aggregation ────────────────────────────────────────────────

  profiles = group.map { |s| s['audio_profile'] }.compact
  energies = group.map { |s| s['audio_energy'] }.compact
  stumbles = group.map { |s| s['stumble_count'] || 0 }
  pauses_ms = group.map { |s| s['max_within_segment_pause_ms'] || 0 }
  trends = group.map { |s| s['audio_pitch_trend'] }.compact

  # Aggregate energy: mean of float values -> enum
  avg_energy = energies.any? ? energies.sum / energies.size : 1.0
  energy_enum = if avg_energy > 1.3
                  'high'
                elsif avg_energy >= 0.75
                  'medium'
                else
                  'low'
                end

  # Aggregate audio_profile: most common, or first
  profile = if profiles.any?
              profiles.group_by(&:itself).max_by { |_, v| v.size }.first
            else
              'casual'
            end

  # Aggregate pitch_trend: most common, or first
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

  # ── Cluster detection ──────────────────────────────────────────────────
  # Deferred to post-loop pass (needs all candidates).

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

# ─── Phase A: Lexical cluster detection ──────────────────────────────────────

def tokenize(text)
  text.downcase.gsub(/[^a-z0-9\s]/, '').split.reject { |w| STOP_WORDS.include?(w) }
end

def jaccard(set_a, set_b)
  return 0.0 if set_a.empty? || set_b.empty?
  intersection = set_a & set_b
  union = set_a | set_b
  intersection.size.to_f / union.size
end

# Compute token sets per candidate.
token_sets = candidates.map { |c| Set.new(tokenize(c['text'])) }

# Find clusters: pairs with Jaccard >= threshold get the same label.
# Simple union-find approach.
cluster_labels = Array.new(candidates.size, nil)
cluster_counter = 0

candidates.each_with_index do |_c1, i|
  (i + 1...candidates.size).each do |j|
    score = jaccard(token_sets[i], token_sets[j])
    next unless score >= CLUSTER_JACCARD_THRESHOLD

    if cluster_labels[i] && cluster_labels[j]
      # Both already labeled — merge: relabel j's cluster to i's
      old_label = cluster_labels[j]
      new_label = cluster_labels[i]
      cluster_labels.map! { |l| l == old_label ? new_label : l }
    elsif cluster_labels[i]
      cluster_labels[j] = cluster_labels[i]
    elsif cluster_labels[j]
      cluster_labels[i] = cluster_labels[j]
    else
      # Neither labeled — create new cluster from shared tokens.
      shared = (token_sets[i] & token_sets[j]).to_a.sort.first(3).join('_')
      label = shared.empty? ? "cluster_#{cluster_counter += 1}" : shared
      cluster_labels[i] = label
      cluster_labels[j] = label
    end
  end
end

# Apply cluster labels.
candidates.each_with_index do |c, i|
  c['cluster'] = cluster_labels[i]
end

# ─── Phase A: Validation ────────────────────────────────────────────────────

errors = []

# Build segment id set for reference checks.
valid_seg_ids = Set.new(segments.map { |s| s['id'] })

candidates.each do |c|
  cid = c['id']

  # Structural: ID format
  errors << "#{cid}: id does not match cand_NNN" unless cid.match?(/\Acand_\d{3}\z/)

  # Structural: t < e
  errors << "#{cid}: t (#{c['t']}) >= e (#{c['e']})" unless c['t'] < c['e']

  # Structural: segment_ids exist
  c['segment_ids'].each do |sid|
    errors << "#{cid}: segment_ids references unknown #{sid}" unless valid_seg_ids.include?(sid)
  end
  errors << "#{cid}: segment_ids is empty" if c['segment_ids'].empty?

  # Structural: all segments share same source
  seg_sources = c['segment_ids'].map { |sid| seg_by_id[sid]&.[]('source') }.compact.uniq
  errors << "#{cid}: segments span multiple sources: #{seg_sources}" if seg_sources.size > 1

  # Trim choices
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

  # Exclusion choices
  ex_ids = Set.new
  c['exclusion_choices'].each do |ec|
    errors << "#{cid}: exclusion id '#{ec['id']}' does not match ex_NNN" unless ec['id'].match?(/\Aex_\d{3}\z/)
    errors << "#{cid}: duplicate exclusion id #{ec['id']}" if ex_ids.include?(ec['id'])
    ex_ids << ec['id']
    errors << "#{cid}: exclusion #{ec['id']} start (#{ec['start']}) < candidate t" if ec['start'] < c['t'] - 0.001
    errors << "#{cid}: exclusion #{ec['id']} end (#{ec['end']}) > candidate e" if ec['end'] > c['e'] + 0.001
    errors << "#{cid}: exclusion #{ec['id']} start >= end" unless ec['start'] < ec['end']
  end

  # Check for overlapping exclusion ranges.
  sorted_ex = c['exclusion_choices'].sort_by { |ec| ec['start'] }
  sorted_ex.each_cons(2) do |a, b|
    errors << "#{cid}: overlapping exclusions #{a['id']} and #{b['id']}" if a['end'] > b['start']
  end

  # Cluster: null or snake_case
  if c['cluster'] && !c['cluster'].match?(/\A[a-z0-9]+(_[a-z0-9]+)*\z/)
    errors << "#{cid}: cluster '#{c['cluster']}' is not snake_case"
  end

  # Prosody required fields
  %w[audio_profile energy stumble_count max_pause_ms pitch_trend].each do |field|
    errors << "#{cid}: prosody.#{field} missing" if c['prosody'][field].nil?
  end
end

# Global uniqueness: candidate ids
cand_ids = candidates.map { |c| c['id'] }
dupes = cand_ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
errors << "Duplicate candidate ids: #{dupes.join(', ')}" if dupes.any?

unless errors.empty?
  $stderr.puts "PHASE A VALIDATION FAILED (#{errors.size} errors):"
  errors.each { |e| $stderr.puts "  #{e}" }
  exit 1
end

# ─── Write output ────────────────────────────────────────────────────────────

input_fingerprint = Digest::SHA256.hexdigest(File.read(segments_path))

result = {
  'version'           => '1.2',
  'input_fingerprint' => input_fingerprint,
  'generated_at'      => 'deterministic',
  'candidate_count'   => candidates.size,
  'candidates'        => candidates
}

File.write(output_path, YAML.dump(result))
$stderr.puts "candidate_substrate.yaml written: #{candidates.size} candidates from #{segments.size} segments"
$stderr.puts "  Multi-atom candidates: #{candidates.count { |c| c['segment_ids'].size > 1 }}"
$stderr.puts "  Candidates with exclusions: #{candidates.count { |c| !c['exclusion_choices'].empty? }}"
$stderr.puts "  Clustered candidates: #{candidates.count { |c| c['cluster'] }}"
puts output_path
