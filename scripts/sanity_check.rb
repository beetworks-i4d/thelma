#!/usr/bin/env ruby
# DEPRECATED — see VISION.md P5. Will be replaced by finished-video template extraction.
# Phase 2.5 — Pre-Build Sanity Check
# Runs after Phase 1.8 coherence scoring, before Phase 3 XML generation.
# For each selected candidate, generates review data: shape descriptor,
# cold-open/close assessment, distilled segments.
# At project level, calculates unused high-signal segments.
#
# Usage:
#   ruby scripts/sanity_check.rb <storylines_scored.yaml> <segments_file.yaml> [candidate_ids...]
#   ruby scripts/sanity_check.rb --skip-sanity-check
#   ruby scripts/sanity_check.rb --all <storylines_scored.yaml> <segments_file.yaml>
#   ruby scripts/sanity_check.rb --batch <storylines_scored.yaml> <segments_file.yaml>
#   ruby scripts/sanity_check.rb --batch --strong-threshold 85 --acceptable-threshold 70 <scored> <segments>
#
# candidate_ids: space-separated IDs from storylines_scored.yaml. If omitted, reviews
#                all passing candidates (rank != nil). Use --all to review everything.
#
# --batch: Batch triage mode. Classifies candidates into tiers by combined_score:
#          Strong (80+): trusted, no extra review needed
#          Acceptable (65-79): brief summary only
#          Borderline (60-64): full sanity check
#          Failed (<60): already filtered by quality floor
#
# Output: sanity_check.yaml in same directory as storylines_scored.yaml. Path to stdout.

require 'yaml'
require 'date'
require 'set'

# --- Flag parsing ---

if ARGV.delete('--skip-sanity-check')
  $stderr.puts "Sanity check skipped (--skip-sanity-check)"
  exit 0
end

review_all = ARGV.delete('--all')
batch_mode = ARGV.delete('--batch')
profile_name = nil
if (idx = ARGV.index('--profile'))
  profile_name = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end

# Load profile for threshold defaults
require_relative 'load_profile'
profile = if profile_name
             load_profile_by_name(profile_name)
           else
             load_profile('_default')
           end

# Extract threshold overrides (--strong-threshold N, --acceptable-threshold N)
# CLI flags override profile values override hardcoded defaults
strong_threshold = profile['strong_threshold'] || 80
acceptable_threshold = profile['acceptable_threshold'] || 65

if (idx = ARGV.index('--strong-threshold'))
  strong_threshold = ARGV.delete_at(idx + 1).to_i
  ARGV.delete_at(idx)
end
if (idx = ARGV.index('--acceptable-threshold'))
  acceptable_threshold = ARGV.delete_at(idx + 1).to_i
  ARGV.delete_at(idx)
end

scored_path = ARGV[0]
segments_path = ARGV[1]
candidate_ids = ARGV[2..]

abort "Usage: ruby scripts/sanity_check.rb <storylines_scored.yaml> <segments_file.yaml> [candidate_ids...]" unless scored_path && segments_path
abort "File not found: #{scored_path}" unless File.exist?(scored_path)
abort "File not found: #{segments_path}" unless File.exist?(segments_path)

scored_data = YAML.safe_load(File.read(scored_path), permitted_classes: [Date])
segments_data = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])

storylines = scored_data['storylines'] || []
segments = segments_data['segments'] || []

abort "No storylines found in #{scored_path}" if storylines.empty?
abort "No segments found in #{segments_path}" if segments.empty?

# --- Segment lookup ---

seg_by_t = {}
segments.each { |s| seg_by_t[s['t'].to_f] = s }

# --- Select candidates to review ---

selected = if candidate_ids && !candidate_ids.empty?
             storylines.select { |s| candidate_ids.include?(s['id']) }
           elsif review_all
             storylines
           else
             storylines.select { |s| s['rank'] }
           end

abort "No matching candidates found for: #{candidate_ids.join(', ')}" if selected.empty? && candidate_ids && !candidate_ids.empty?

if selected.empty?
  $stderr.puts "No ranked candidates to review."
  exit 0
end

# --- Helpers ---

DUR_LABELS = { 'identity' => 'identity-durable', 'mood' => 'mood-durable', 'spike' => 'spike-only' }.freeze

INCOMPATIBLE_PAIRS = [
  Set['sensual', 'calm'],
  Set['schadenfreude', 'awe'],
  Set['outrage', 'amusement'],
  Set['belonging', 'schadenfreude'],
  Set['calm', 'fear']
].freeze

MIN_HIGH_SIGNAL_DURATION = 15.0  # seconds — minimum contiguous run for unused warning

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

def shape_descriptor(storyline, arc)
  template = storyline.dig('template_match', 'template')
  completeness = storyline.dig('template_match', 'completeness')

  # Build shape from distillation sequence
  all_segs = [arc[:hook], *arc[:body], arc[:close]].compact
  distillations = all_segs.map { |s| s['distillation'] }.compact

  # Detect narrative shape from state transitions
  states = all_segs.map { |s| (s['states'] || []).first }.compact
  state_transitions = states.chunk { |s| s }.map { |state, group| "#{state}(#{group.size})" }

  # Build human-readable shape
  parts = []
  if arc[:hook]
    hook_dur = arc[:hook]['dur'] || 'unknown'
    parts << "#{(arc[:hook]['states'] || ['unknown']).first.capitalize} #{hook_dur} hook"
  end

  if arc[:body].size > 0
    body_states = arc[:body].map { |s| (s['states'] || []).first }.compact.tally
    dominant = body_states.max_by { |_, c| c }&.first
    parts << "#{dominant || 'mixed'} body (#{arc[:body].size} segments)"
  end

  if arc[:close]
    close_dur = arc[:close]['dur'] || 'unknown'
    parts << "#{(arc[:close]['states'] || ['unknown']).first} #{close_dur} close"
  end

  shape = parts.join(' → ')

  if template && completeness
    shape += " [#{template.gsub('_', ' ')} #{completeness}% fit]"
  end

  shape
end

def cold_open_assessment(storyline, arc)
  hook = arc[:hook]
  return { 'works' => false, 'reason' => 'no hook segment' } unless hook

  confidence = hook['confidence'] || 'low'
  dur = hook['dur'] || 'spike'
  signal = hook['signal'] || ''
  distillation = hook['distillation'] || ''
  states = hook['states'] || []

  # Cold viability from storyline data (already scored in Phase 1.6)
  cold_viability = storyline.dig('scores', 'cold_viability') || 0

  # Assess
  works = dur != 'spike' || confidence == 'high'
  reasons = []

  case dur
  when 'identity'
    reasons << "identity-durable — holds without context"
  when 'mood'
    reasons << "mood-durable — sets tone cold"
  when 'spike'
    reasons << "spike-only — may need context to land"
  end

  if confidence == 'high'
    reasons << "high confidence signal"
  elsif confidence == 'low'
    works = false
    reasons << "low confidence — uncertain hook"
  end

  # Check if distillation suggests self-contained content
  if distillation.match?(/\d/) || distillation.match?(/\$/)
    reasons << "specific numbers/amounts grab without context"
    works = true
  end

  { 'works' => works, 'reason' => reasons.join('; ') }
end

def close_assessment(storyline, arc)
  close = arc[:close]
  return { 'works' => false, 'reason' => 'no close segment' } unless close

  dur = close['dur'] || 'spike'
  confidence = close['confidence'] || 'low'
  states = close['states'] || []
  hook_states = arc[:hook] ? (arc[:hook]['states'] || []) : []

  works = dur != 'spike'
  reasons = []

  case dur
  when 'identity'
    reasons << "identity-durable — stays with viewer"
    works = true
  when 'mood'
    reasons << "mood-durable — emotional landing"
    works = true
  when 'spike'
    reasons << "spike-only — may fade quickly"
    works = false
  end

  # Check if close echoes hook states (arc completion)
  shared = (Set.new(states) & Set.new(hook_states))
  if shared.any?
    reasons << "echoes hook state (#{shared.to_a.join(', ')})"
  else
    reasons << "no shared states with hook — arc may feel incomplete"
  end

  if confidence == 'low'
    works = false
    reasons << "low confidence"
  end

  { 'works' => works, 'reason' => reasons.join('; ') }
end


# --- Unused high-signal calculation ---

def calculate_unused_high_signal(segments, selected_storylines, seg_by_t)
  # Collect all segment t-values used across selected candidates
  used_t_values = Set.new
  selected_storylines.each do |sl|
    arc = reconstruct_arc(sl, seg_by_t, segments)
    [arc[:hook], *arc[:body], arc[:close]].compact.each { |s| used_t_values << s['t'].to_f }
  end

  # Filter unused segments to high-signal
  unused = segments.reject { |s| used_t_values.include?(s['t'].to_f) }

  high_signal = unused.select { |s|
    s['confidence'] == 'high' &&
    %w[identity mood].include?(s['dur']) &&
    s['distillation'] && s['distillation'].strip.length > 5
  }

  return [] if high_signal.empty?

  # Find contiguous runs of high-signal material (gaps <= 5s between segments)
  sorted = high_signal.sort_by { |s| s['t'].to_f }
  runs = []
  current_run = [sorted.first]

  sorted[1..].each do |seg|
    prev = current_run.last
    gap = seg['t'].to_f - prev['e'].to_f
    if gap <= 5.0
      current_run << seg
    else
      runs << current_run if run_duration(current_run) >= MIN_HIGH_SIGNAL_DURATION
      current_run = [seg]
    end
  end
  runs << current_run if current_run.any? && run_duration(current_run) >= MIN_HIGH_SIGNAL_DURATION

  # Format warnings
  runs.map do |run|
    start_t = run.first['t'].to_f
    end_t = run.last['e'].to_f
    duration = end_t - start_t

    distillations = run.map { |s| s['distillation'] }.compact.uniq
    states_with_dur = run.flat_map { |s|
      (s['states'] || []).map { |st| "#{st}(#{s['dur']})" }
    }.uniq

    {
      'start' => start_t,
      'end' => end_t,
      'duration' => duration.round(1),
      'segment_count' => run.size,
      'distillations' => distillations,
      'states' => states_with_dur
    }
  end
end

def run_duration(segments)
  return 0 if segments.empty?
  segments.last['e'].to_f - segments.first['t'].to_f
end

def fmt_time(seconds)
  m = (seconds / 60).to_i
  s = (seconds % 60).to_i
  format("%d:%02d", m, s)
end

def classify_tier(score, strong_threshold, acceptable_threshold)
  if score >= strong_threshold
    'strong'
  elsif score >= acceptable_threshold
    'acceptable'
  else
    'borderline'
  end
end

# --- Build review for each candidate ---

reviews = []

selected.each do |storyline|
  arc = reconstruct_arc(storyline, seg_by_t, segments)
  all_segs = [arc[:hook], *arc[:body], arc[:close]].compact
  distillations = all_segs.map { |s| s['distillation'] }.compact

  # Find next-ranked candidate in same profile for swap
  same_profile = storylines.select { |s|
    s['profile'] == storyline['profile'] &&
    s['id'] != storyline['id'] &&
    s['passed_floor']
  }.sort_by { |s| -(s['combined_score'] || 0) }
  next_candidate = same_profile.first

  score = storyline['combined_score'] || 0
  tier = batch_mode ? classify_tier(score, strong_threshold, acceptable_threshold) : nil

  review = {
    'id' => storyline['id'],
    'profile' => storyline['profile'],
    'duration_estimate' => storyline['duration_estimate'],
    'combined_score' => storyline['combined_score'],
    'template_match' => storyline['template_match']&.slice('template', 'completeness'),
    'coherence_score' => storyline['coherence_score'],
    'coherence_issues' => storyline['coherence_issues'],

    # Computed by script
    'shape' => shape_descriptor(storyline, arc),
    'cold_open' => cold_open_assessment(storyline, arc),
    'close' => close_assessment(storyline, arc),
    'distilled_segments' => distillations,

    # Swap target
    'next_candidate_id' => next_candidate&.fetch('id', nil),
    'next_candidate_score' => next_candidate&.fetch('combined_score', nil)
  }

  review['tier'] = tier if batch_mode

  reviews << review
end

# --- Unused high-signal ---

unused_warnings = calculate_unused_high_signal(segments, selected, seg_by_t)

# --- Output ---

output_dir = File.dirname(scored_path)
output_path = File.join(output_dir, 'sanity_check.yaml')
source_name = File.basename(output_dir)

output = {
  'generated_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'source' => source_name,
  'candidates_reviewed' => reviews.size,
  'candidates' => reviews,
  'unused_high_signal' => unused_warnings
}

if batch_mode
  strong = reviews.select { |r| r['tier'] == 'strong' }
  acceptable = reviews.select { |r| r['tier'] == 'acceptable' }
  borderline = reviews.select { |r| r['tier'] == 'borderline' }

  output['batch_mode'] = true
  output['thresholds'] = {
    'strong' => strong_threshold,
    'acceptable' => acceptable_threshold
  }
  output['tiers'] = {
    'strong' => { 'count' => strong.size, 'ids' => strong.map { |r| r['id'] } },
    'acceptable' => { 'count' => acceptable.size, 'ids' => acceptable.map { |r| r['id'] } },
    'borderline' => { 'count' => borderline.size, 'ids' => borderline.map { |r| r['id'] } }
  }
end

File.write(output_path, output.to_yaml)

# --- Report ---

if batch_mode
  strong = reviews.select { |r| r['tier'] == 'strong' }
  acceptable = reviews.select { |r| r['tier'] == 'acceptable' }
  borderline = reviews.select { |r| r['tier'] == 'borderline' }
  buildable = strong.size + acceptable.size

  $stderr.puts "=" * 60
  $stderr.puts "BATCH: #{reviews.size} candidates"
  $stderr.puts "=" * 60
  $stderr.puts ""
  $stderr.puts "Strong (#{strong_threshold}+): #{strong.size} — trusted, building without review"
  $stderr.puts "Acceptable (#{acceptable_threshold}-#{strong_threshold - 1}): #{acceptable.size} — summaries below"
  $stderr.puts "Borderline (#{acceptable_threshold - 5}-#{acceptable_threshold - 1}): #{borderline.size} — full review required"

  if borderline.any?
    $stderr.puts ""
    $stderr.puts "BORDERLINE REVIEW:"
    borderline.each do |r|
      cold = r['cold_open']['works'] ? nil : "Cold open: no (#{r['cold_open']['reason'].split(';').first.strip})"
      close = r['close']['works'] ? nil : "Close: no (#{r['close']['reason'].split(';').first.strip})"
      flags = [cold, close].compact.join(' | ')
      $stderr.puts "  #{r['id']} — Score #{r['combined_score']} | #{flags}"
    end
  end

  if acceptable.any?
    $stderr.puts ""
    $stderr.puts "ACCEPTABLE (summaries only):"
    acceptable.each do |r|
      distilled = r['distilled_segments']&.first || 'no distillation'
      $stderr.puts "  #{r['id']} — #{r['combined_score']} | \"#{distilled}\""
    end
  end

  if unused_warnings.any?
    $stderr.puts ""
    $stderr.puts "UNUSED HIGH-SIGNAL: #{unused_warnings.size} sequences flagged."
    unused_warnings.each do |w|
      $stderr.puts "  #{fmt_time(w['start'])}-#{fmt_time(w['end'])} (#{w['duration']}s) — #{w['distillations'].first}"
    end
  end

  $stderr.puts ""
  $stderr.puts "Build all #{buildable} strong+acceptable, review #{borderline.size} borderline? [y/review all/cancel/build all]"
else
  $stderr.puts "=" * 60
  $stderr.puts "PRE-BUILD SANITY CHECK"
  $stderr.puts "=" * 60

  reviews.each do |r|
    $stderr.puts ""
    $stderr.puts "CANDIDATE: #{r['id']}"
    $stderr.puts "Profile: #{r['profile']} | Duration: #{r['duration_estimate']}s | Combined score: #{r['combined_score']}"

    tm = r['template_match']
    $stderr.puts "Template: #{tm['template']} (#{tm['completeness']}% complete)" if tm

    coh = r['coherence_score']
    issues = r['coherence_issues']
    $stderr.puts "Coherence: #{coh} | Issues: #{issues && !issues.empty? ? issues.join(', ') : 'none'}"

    $stderr.puts ""
    $stderr.puts "Shape: #{r['shape']}"
    $stderr.puts ""
    $stderr.puts "Cold open: #{r['cold_open']['works'] ? 'yes' : 'no'} — #{r['cold_open']['reason']}"
    $stderr.puts "Close: #{r['close']['works'] ? 'yes' : 'no'} — #{r['close']['reason']}"

    if r['next_candidate_id']
      $stderr.puts "Swap available: #{r['next_candidate_id']} (score: #{r['next_candidate_score']})"
    end
  end

  if unused_warnings.any?
    $stderr.puts ""
    $stderr.puts "=" * 60
    $stderr.puts "WARNING: #{unused_warnings.size} high-signal sequence(s) unused."
    $stderr.puts "=" * 60
    unused_warnings.each do |w|
      $stderr.puts ""
      $stderr.puts "Position: #{fmt_time(w['start'])}-#{fmt_time(w['end'])} (#{w['duration']}s, #{w['segment_count']} segments)"
      $stderr.puts "Distillations:"
      w['distillations'].each { |d| $stderr.puts "  - \"#{d}\"" }
      $stderr.puts "States: #{w['states'].join(', ')}"
    end
  else
    $stderr.puts ""
    $stderr.puts "No unused high-signal sequences detected."
  end
end

$stderr.puts ""
$stderr.puts "Output: #{output_path}"
puts output_path
