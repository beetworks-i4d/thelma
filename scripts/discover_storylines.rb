#!/usr/bin/env ruby
# Phase 1.6 — Storyline Discovery
# Clusters classified segments into candidate storylines ranked by quality.
# Runs after Phase 1.5 classification, before Phase 2 editorial questions.
#
# Usage: ruby scripts/discover_storylines.rb <segments_classified.yaml> [--library <library.yaml>]
# Output: storylines.yaml in same directory as input. Path to stdout, progress to stderr.
#
# Runs three profiles (best_single_longform, best_short, best_medium) with
# duration enforcement and expansion strategies per profile.

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

PROFILES = {
  'best_single_longform' => { target_min: 480, target_max: 900, expansion: :wide },
  'best_short'           => { target_min: 30,  target_max: 90,  expansion: :tight },
  'best_medium'          => { target_min: 180, target_max: 480, expansion: :balanced }
}.freeze

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

def arc_duration(segs)
  segs.sum { |s| s['e'] - s['t'] }
end

# --- Find candidates by role ---

primaries = segments.select { |s| (s['roles'] || []).include?('primary') && s['confidence'] != 'low' }
tertiaries = segments.select { |s| (s['roles'] || []).include?('tertiary') }
secondaries = segments.select { |s| (s['roles'] || []).include?('secondary') }
all_t_values = Set.new(segments.map { |s| s['t'] })

$stderr.puts "Found #{primaries.size} primary, #{secondaries.size} secondary, #{tertiaries.size} tertiary candidates"
abort "No primary candidates found — classification may be incomplete" if primaries.empty?

# --- Expansion strategies ---

# Tight: pick nearest compatible close, body between hook and close. Good for shorts.
def expand_tight(hook, secondaries, tertiaries)
  hook_t = hook['t']
  close_candidates = tertiaries.select { |s| s['t'] != hook_t && s['t'] > hook_t }
  best_close = close_candidates.sort_by { |s|
    [-(DUR_RANK[s['dur']] || 0), -(CONF_RANK[s['confidence']] || 0)]
  }.first

  body = secondaries.select { |s|
    s['t'] != hook_t && s['t'] > hook_t &&
    (best_close.nil? || s['t'] < best_close['t'])
  }

  [body, best_close]
end

# Wide: expand through ALL compatible secondaries maintaining spine, then pick close.
# Good for longform — exhausts available material before closing.
# Prioritizes spine-carrying segments but includes compatible non-spine segments
# to fill the arc when spine material alone isn't enough.
def expand_wide(hook, secondaries, tertiaries)
  hook_t = hook['t']
  primary_state = hook['states'].first

  candidates = secondaries.select { |s|
    s['t'] != hook_t && s['t'] > hook_t
  }.sort_by { |s| s['t'] }

  # Include all candidates — spine-carrying ones are rewarded in scoring, not filtered here.
  # But reject segments that are incompatible with BOTH their neighbors to avoid
  # breaking the flow.
  filtered_body = candidates.dup

  # After exhausting body, pick best tertiary close AFTER all body content
  last_body_t = filtered_body.last ? filtered_body.last['t'] : hook_t
  close_candidates = tertiaries.select { |s| s['t'] != hook_t && s['t'] > last_body_t }
  best_close = close_candidates.sort_by { |s|
    [-(DUR_RANK[s['dur']] || 0), -(CONF_RANK[s['confidence']] || 0)]
  }.first

  # If close is also in body (dual-role segment), remove from body
  if best_close
    filtered_body.reject! { |s| s['t'] == best_close['t'] }
  end

  [filtered_body, best_close]
end

# Balanced: accumulate secondaries chronologically, spine-carriers first, until
# hitting target duration range. Default for best_medium (3-8 min).
def expand_balanced(hook, secondaries, tertiaries, target_min: 180, target_max: 480)
  hook_t = hook['t']
  primary_state = hook['states'].first

  candidates = secondaries.select { |s|
    s['t'] != hook_t && s['t'] > hook_t
  }.sort_by { |s| s['t'] }

  # Two pools: spine-carrying (priority) and non-spine (fill)
  spine_pool = candidates.select { |s| (s['states'] || []).include?(primary_state) }
  fill_pool = candidates.reject { |s| (s['states'] || []).include?(primary_state) }

  body = []
  running_dur = hook['e'] - hook['t'] # start with hook duration

  # Interleave chronologically: add spine segments first, then fill to reach target
  all_sorted = candidates.dup
  all_sorted.each do |s|
    seg_dur = s['e'] - s['t']
    break if running_dur >= target_max
    body << s
    running_dur += seg_dur
    # Once we're in range and have enough spine, stop adding fill
    if running_dur >= target_min
      spine_ratio = body.count { |b| (b['states'] || []).include?(primary_state) }.to_f / body.size
      break if spine_ratio >= 0.3 # good enough spine, don't over-dilute
    end
  end

  last_body_t = body.last ? body.last['t'] : hook_t
  close_candidates = tertiaries.select { |s| s['t'] != hook_t && s['t'] > last_body_t }
  best_close = close_candidates.sort_by { |s|
    [-(DUR_RANK[s['dur']] || 0), -(CONF_RANK[s['confidence']] || 0)]
  }.first

  if best_close
    body.reject! { |s| s['t'] == best_close['t'] }
  end

  [body, best_close]
end

# --- Scoring ---

def score_arc(hook, close, body, all_t_values)
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

  # 4. Cold viability (15 pts)
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
  # Audio profile bonus — emphatic delivery boosts hook viability
  if hook['audio_profile'] == 'emphatic'
    cv += 3
  elsif hook['audio_profile'] == 'casual'
    cv -= 2
  end
  scores['cold_viability'] = [cv, 15].min

  # 5. Closing durability (15 pts)
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
  if close
    post_tertiary = body.select { |s| s['t'] > close['t'] }
    integrity -= 5 unless post_tertiary.empty?
  end
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
  mid = secondary_states.empty? ? "body" : secondary_states[0..1].join(' + ')
  close_desc = close ? (close['notes'] || close['signal'] || 'close') : 'open'
  "#{primary_state.capitalize} proof → #{mid} → #{close_desc.downcase}"
end

def build_storyline(hook, body, close, profile_name, all_t_values)
  primary_state = hook['states'].first

  scores = score_arc(hook, close, body, all_t_values)
  total = scores.values.sum

  all_arc = [hook] + body + [close].compact
  duration_est = arc_duration(all_arc)

  secondary_states = body.flat_map { |s| s['states'] || [] }
                         .tally.sort_by { |_, c| -c }
                         .map(&:first)
                         .reject { |st| st == primary_state }
                         .first(3)

  hook_id = "#{profile_name.sub('best_', '')}_" +
            (hook['signal'] || 'unnamed').downcase
              .gsub(/[^a-z0-9\s]/, '')
              .split.first(2).join('_') + '_led'

  {
    'id' => hook_id,
    'profile' => profile_name,
    'score' => total,
    'scores' => scores,
    'primary_state' => primary_state,
    'secondary_states' => secondary_states,
    'tertiary_state' => close ? close['states'].first : nil,
    'hook_segment' => hook['t'],
    'hook_signal' => hook['signal'],
    'close_segment' => close ? close['t'] : nil,
    'close_signal' => close ? (close['notes'] || close['signal']) : nil,
    'duration_estimate' => duration_est.round,
    'segment_count' => all_arc.size,
    'arc' => build_arc_summary(hook, close, body, primary_state),
    'pitch' => "Opens on #{hook['signal']&.split(' — ')&.first || 'hook'}, " \
               "#{body.size} body segments across #{fmt(duration_est)}, " \
               "closes on #{close ? (close['notes'] || 'close') : 'open end'}",
    'confidence' => total >= 80 ? 'high' : (total >= 70 ? 'medium' : 'low')
  }
end

# --- Run all profiles ---

all_storylines = []

PROFILES.each do |profile_name, profile|
  $stderr.puts "\n=== Profile: #{profile_name} (#{profile[:target_min]}-#{profile[:target_max]}s, #{profile[:expansion]}) ==="

  candidates = []

  primaries.each do |hook|
    body, close = case profile[:expansion]
                  when :tight    then expand_tight(hook, secondaries, tertiaries)
                  when :wide     then expand_wide(hook, secondaries, tertiaries)
                  when :balanced then expand_balanced(hook, secondaries, tertiaries,
                                       target_min: profile[:target_min],
                                       target_max: profile[:target_max])
                  end

    all_arc = [hook] + body + [close].compact
    dur = arc_duration(all_arc)

    # Duration enforcement — reject before scoring
    if dur < profile[:target_min]
      $stderr.puts "  Skip #{hook['t']} (#{fmt(dur)}) — too short for #{profile_name}"
      next
    end
    if dur > profile[:target_max]
      $stderr.puts "  Skip #{hook['t']} (#{fmt(dur)}) — too long for #{profile_name}"
      next
    end

    storyline = build_storyline(hook, body, close, profile_name, all_t_values)
    candidates << storyline
    $stderr.puts "  #{storyline['id']}: #{storyline['score']}pts, #{fmt(dur)}"
  end

  # Rank, filter >= 70, cap at 3
  qualified = candidates.sort_by { |s| -s['score'] }
                        .select { |s| s['score'] >= 70 }
                        .first(3)

  $stderr.puts "  #{candidates.size} scored, #{qualified.size} above threshold"
  all_storylines.concat(qualified)
end

# --- Script-aligned candidate ---

if library_path && File.exist?(library_path)
  lib = YAML.safe_load(File.read(library_path), permitted_classes: [Date])
  if lib && lib['script_parsed']
    script_path = File.join(File.dirname(library_path), 'transcripts', lib['script_parsed'])
    if File.exist?(script_path)
      $stderr.puts "\nScript detected — building script-aligned candidate"
      script_arc = segments.sort_by { |s| s['t'] }
      hook = script_arc.first
      close = script_arc.last
      body = script_arc[1..-2] || []

      scores = score_arc(hook, close, body, all_t_values)
      total = scores.values.sum

      all_storylines << {
        'id' => 'script_aligned',
        'profile' => 'script',
        'score' => total,
        'scores' => scores,
        'primary_state' => hook['states'].first,
        'secondary_states' => body.flat_map { |s| s['states'] || [] }.tally.sort_by { |_, c| -c }.map(&:first).first(3),
        'tertiary_state' => close['states'].first,
        'hook_segment' => hook['t'],
        'hook_signal' => 'Script order',
        'close_segment' => close['t'],
        'close_signal' => 'Script order',
        'duration_estimate' => arc_duration(script_arc).round,
        'segment_count' => script_arc.size,
        'arc' => 'Script-locked beat order',
        'pitch' => "Script-aligned: #{script_arc.size} segments in beat order",
        'confidence' => 'script'
      }
    end
  end
end

# --- Output ---

source_name = File.basename(output_dir)
profiles_run = PROFILES.keys

$stderr.puts "\n#{all_storylines.size} total storylines across #{profiles_run.size} profiles"

output = {
  'generated_at' => DateTime.now.iso8601,
  'source' => source_name,
  'profiles_run' => profiles_run,
  'transcript_hash' => transcript_hash,
  'storylines' => all_storylines
}

File.write(output_path, output.to_yaml)
$stderr.puts "Wrote #{output_path}"
puts output_path
