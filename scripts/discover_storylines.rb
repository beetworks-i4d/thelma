#!/usr/bin/env ruby
# Phase 1.6 — Storyline Discovery
# Clusters classified segments into candidate storylines ranked by quality.
# Runs after Phase 1.5 classification, before Phase 2 editorial questions.
#
# Usage: ruby scripts/discover_storylines.rb <segments_classified.yaml> [--library <library.yaml>]
# Output: storylines.yaml in same directory as input. Path to stdout, progress to stderr.

require 'yaml'
require 'date'
require 'digest'

classified_path = nil
library_path = nil

i = 0
while i < ARGV.length
  case ARGV[i]
  when '--library'
    library_path = ARGV[i + 1]
    i += 2
  else
    classified_path = ARGV[i]
    i += 1
  end
end

abort "Usage: ruby scripts/discover_storylines.rb <segments_classified.yaml> [--library <library.yaml>]" unless classified_path
abort "File not found: #{classified_path}" unless File.exist?(classified_path)

data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])
segments = data['segments'] || []
transcript_hash = data['transcript_hash']

output_dir = File.dirname(classified_path)
output_path = File.join(output_dir, 'storylines.yaml')

# Cache check — skip if storylines.yaml exists with matching hash
if File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date])
  if existing && existing['transcript_hash'] == transcript_hash
    $stderr.puts "storylines.yaml up to date (hash #{transcript_hash[0..7]})"
    puts output_path
    exit 0
  end
end

# --- Constants ---

INCOMPATIBLE_PAIRS = [
  Set['sensual', 'calm'],
  Set['schadenfreude', 'awe'],
  Set['outrage', 'amusement'],
  Set['belonging', 'schadenfreude'],
  Set['calm', 'fear']
].freeze

DUR_RANK = { 'identity' => 3, 'mood' => 2, 'spike' => 1 }.freeze
CONF_RANK = { 'high' => 3, 'medium' => 2, 'low' => 1 }.freeze

def fmt(seconds)
  m = (seconds / 60).to_i
  s = seconds - m * 60
  format("%d:%05.2f", m, s)
end

def incompatible?(states_a, states_b)
  states_a.each do |a|
    states_b.each do |b|
      return true if INCOMPATIBLE_PAIRS.include?(Set[a, b])
    end
  end
  false
end

# --- Find candidates by role ---

primaries = segments.select { |s| (s['roles'] || []).include?('primary') && s['confidence'] != 'low' }
tertiaries = segments.select { |s| (s['roles'] || []).include?('tertiary') }
secondaries = segments.select { |s| (s['roles'] || []).include?('secondary') }

$stderr.puts "Found #{primaries.size} primary, #{secondaries.size} secondary, #{tertiaries.size} tertiary candidates"

abort "No primary candidates found — classification may be incomplete" if primaries.empty?

# --- Build arcs ---

seg_by_t = segments.each_with_object({}) { |s, h| h[s['t']] = s }
all_t_values = Set.new(segments.map { |s| s['t'] })

def score_arc(hook, close, body, segments, all_t_values)
  scores = {}
  primary_state = hook['states'].first

  # 1. Spine continuity (20 pts)
  carrying = body.count { |s| (s['states'] || []).include?(primary_state) }
  total_body = body.size
  scores['spine'] = total_body > 0 ? ((carrying.to_f / total_body) * 20).round : 0

  # 2. Arc completeness (20 pts)
  completeness = 0
  completeness += 8 if hook
  completeness += 4 if body.size >= 3
  completeness += 8 if close
  scores['completeness'] = completeness

  # 3. State density (15 pts)
  arc_start = hook['t']
  arc_end = close ? close['e'] : (body.last ? body.last['e'] : hook['e'])
  arc_span = arc_end - arc_start
  classified_time = ([hook] + body + [close].compact).sum { |s| s['e'] - s['t'] }
  scores['density'] = arc_span > 0 ? ((classified_time / arc_span) * 15).round : 0

  # 4. Cold viability (15 pts) — based on hook
  cv = case hook['dur']
       when 'identity' then 15
       when 'mood' then 10
       when 'spike' then 5
       else 0
       end
  cv += case hook['confidence']
        when 'high' then 5
        when 'medium' then 3
        else 0
        end
  scores['cold_viability'] = [cv, 15].min

  # 5. Closing durability (15 pts) — based on close
  if close
    scores['close_durability'] = case close['dur']
                                 when 'identity' then 15
                                 when 'mood' then 10
                                 when 'spike' then 5
                                 else 0
                                 end
  else
    scores['close_durability'] = 0
  end

  # 6. No broken refs (5 pts)
  arc_segments = [hook] + body + [close].compact
  all_valid = arc_segments.all? { |s| all_t_values.include?(s['t']) }
  scores['references'] = all_valid ? 5 : 0

  # 7. Structural integrity (10 pts)
  integrity = 10

  # Penalty: post-tertiary content
  if close
    post_tertiary = body.select { |s| s['t'] > close['t'] }
    integrity -= 5 unless post_tertiary.empty?
  end

  # Penalty: incompatible adjacencies
  ordered = arc_segments.sort_by { |s| s['t'] }
  incompat_count = 0
  ordered.each_cons(2) do |a, b|
    incompat_count += 1 if incompatible?(a['states'] || [], b['states'] || [])
  end
  integrity -= [incompat_count * 2, 5].min

  scores['structural'] = [integrity, 0].max

  scores
end

def build_arc_summary(hook, close, body, primary_state)
  secondary_states = body.flat_map { |s| s['states'] || [] }.uniq - [primary_state]
  tertiary_state = close ? close['states'].first : nil

  mid = secondary_states.empty? ? "body" : secondary_states[0..1].join(' + ')
  close_desc = close ? (close['notes'] || close['signal'] || 'close') : 'open'
  "#{primary_state.capitalize} proof → #{mid} → #{close_desc.downcase}"
end

storylines = []

primaries.each do |hook|
  primary_state = hook['states'].first
  hook_t = hook['t']

  # Pick best tertiary close — prefer identity dur + high confidence, exclude hook's t
  close_candidates = tertiaries.select { |s| s['t'] != hook_t && s['t'] > hook_t }
  best_close = close_candidates.sort_by { |s|
    [-(DUR_RANK[s['dur']] || 0), -(CONF_RANK[s['confidence']] || 0)]
  }.first

  # Determine arc range
  arc_end_t = best_close ? best_close['t'] : (segments.last ? segments.last['t'] : hook_t)

  # Post-tertiary cutoff: body is between hook and close only
  body = secondaries.select { |s|
    s['t'] != hook_t &&
    s['t'] > hook_t &&
    (best_close.nil? || s['t'] < best_close['t'])
  }

  scores = score_arc(hook, best_close, body, segments, all_t_values)
  total = scores.values.sum

  secondary_states = body.flat_map { |s| s['states'] || [] }
                         .tally
                         .sort_by { |_, c| -c }
                         .map(&:first)
                         .reject { |st| st == primary_state }
                         .first(3)

  all_arc = [hook] + body + [best_close].compact
  duration_est = all_arc.sum { |s| s['e'] - s['t'] }

  # Generate readable ID from hook signal
  hook_id = (hook['signal'] || 'unnamed').downcase
                .gsub(/[^a-z0-9\s]/, '')
                .split.first(2).join('_') + '_led'

  storyline = {
    'id' => hook_id,
    'score' => total,
    'scores' => scores,
    'primary_state' => primary_state,
    'secondary_states' => secondary_states,
    'tertiary_state' => best_close ? best_close['states'].first : nil,
    'hook_segment' => hook['t'],
    'hook_signal' => hook['signal'],
    'close_segment' => best_close ? best_close['t'] : nil,
    'close_signal' => best_close ? (best_close['notes'] || best_close['signal']) : nil,
    'duration_estimate' => duration_est.round,
    'segment_count' => all_arc.size,
    'arc' => build_arc_summary(hook, best_close, body, primary_state),
    'pitch' => "Opens on #{hook['signal']&.split(' — ')&.first || 'hook'}, " \
               "#{body.size} body segments across #{fmt(duration_est)}, " \
               "closes on #{best_close ? (best_close['notes'] || 'close') : 'open end'}",
    'confidence' => total >= 80 ? 'high' : (total >= 70 ? 'medium' : 'low')
  }

  storylines << storyline
end

# --- Script-aligned candidate ---

if library_path && File.exist?(library_path)
  lib = YAML.safe_load(File.read(library_path), permitted_classes: [Date])
  if lib && lib['script_parsed']
    script_path = File.join(File.dirname(library_path), 'transcripts', lib['script_parsed'])
    if File.exist?(script_path)
      $stderr.puts "Script detected — building script-aligned candidate"
      script_data = YAML.safe_load(File.read(script_path), permitted_classes: [Date])
      # Build a script-order arc from all segments in classification order
      script_arc = segments.sort_by { |s| s['t'] }
      hook = script_arc.first
      close = script_arc.last
      body = script_arc[1..-2] || []

      scores = score_arc(hook, close, body, segments, all_t_values)
      total = scores.values.sum

      script_storyline = {
        'id' => 'script_aligned',
        'score' => total,
        'scores' => scores,
        'primary_state' => hook['states'].first,
        'secondary_states' => body.flat_map { |s| s['states'] || [] }.tally.sort_by { |_, c| -c }.map(&:first).first(3),
        'tertiary_state' => close['states'].first,
        'hook_segment' => hook['t'],
        'hook_signal' => 'Script order',
        'close_segment' => close['t'],
        'close_signal' => 'Script order',
        'duration_estimate' => script_arc.sum { |s| s['e'] - s['t'] }.round,
        'segment_count' => script_arc.size,
        'arc' => 'Script-locked beat order',
        'pitch' => "Script-aligned: #{script_arc.size} segments in beat order",
        'confidence' => 'script'
      }

      # Always include regardless of threshold
      storylines << script_storyline
    end
  end
end

# --- Rank, filter, output ---

storylines.sort_by! { |s| -s['score'] }

# Separate script-aligned (always included) from scored candidates
script_candidates = storylines.select { |s| s['confidence'] == 'script' }
scored_candidates = storylines.reject { |s| s['confidence'] == 'script' }

# Filter scored to >= 70, cap at 3
qualified = scored_candidates.select { |s| s['score'] >= 70 }.first(3)
final = qualified + script_candidates

$stderr.puts "#{scored_candidates.size} arcs scored, #{qualified.size} above threshold (>=70)"
qualified.each { |s| $stderr.puts "  #{s['id']}: #{s['score']} pts" }

# Derive source name from directory
source_name = File.basename(output_dir)

output = {
  'generated_at' => DateTime.now.iso8601,
  'source' => source_name,
  'profile' => 'best_single_longform',
  'transcript_hash' => transcript_hash,
  'storylines' => final
}

File.write(output_path, output.to_yaml)
$stderr.puts "Wrote #{output_path}"
puts output_path
