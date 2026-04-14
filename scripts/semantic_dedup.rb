#!/usr/bin/env ruby
# frozen_string_literal: true

# Phase 1.5b: Semantic Dedup
# Compares consecutive segments by distillation overlap to detect retakes.
# Preserves rhetorical repetition and flags ambiguous pairs for review.
#
# Usage: ruby scripts/semantic_dedup.rb <segments_classified.yaml>
# Output: segments_deduped.yaml + semantic_dedup_log.yaml (same directory)

require 'yaml'
require 'date'
require 'digest'
require 'set'

PAUSE_THRESHOLD = 0.500
HIGH_OVERLAP    = 0.80
LOW_OVERLAP     = 0.60

STOP_WORDS = Set.new(%w[
  a an the is are was were be been being
  do does did have has had
  i me my we our you your he him his she her it its they them their
  and but or so if then than that this these those
  in on at to for of with by from as into about
  um uh like just really very actually basically
  okay ok well so yeah yes no not
])

def normalize(distillation)
  distillation
    .downcase
    .gsub(/[^a-z0-9\s]/, '')
    .split
    .reject { |w| STOP_WORDS.include?(w) }
end

def jaccard(words_a, words_b)
  return 0.0 if words_a.empty? && words_b.empty?
  set_a = Set.new(words_a)
  set_b = Set.new(words_b)
  intersection = (set_a & set_b).size.to_f
  union = (set_a | set_b).size.to_f
  union.zero? ? 0.0 : intersection / union
end

def fmt(seconds)
  m = (seconds / 60).to_i
  s = seconds - m * 60
  format("%d:%05.2f", m, s)
end

# --- CLI ---

path = ARGV[0]
abort "Usage: ruby scripts/semantic_dedup.rb <segments_classified.yaml>" unless path
abort "File not found: #{path}" unless File.exist?(path)

data = YAML.safe_load(File.read(path), permitted_classes: [Date])

# Branch A detection
if data.key?('segments_used')
  abort "Branch A input detected (segments_used). Semantic dedup requires Branch B classification with distillations."
end

segments = data['segments']
abort "No segments found in input." unless segments && !segments.empty?

# Check distillations exist
missing = segments.count { |s| !s.key?('distillation') || s['distillation'].nil? || s['distillation'].to_s.strip.empty? }
if missing == segments.size
  abort "No distillation fields found. Run classification (Phase 1.5) first to generate distillations."
end

# Cache check
output_dir = File.dirname(path)
output_path = File.join(output_dir, 'segments_deduped.yaml')
log_path = File.join(output_dir, 'semantic_dedup_log.yaml')
transcript_hash = data['transcript_hash']

if File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date])
  if existing && existing['transcript_hash'] == transcript_hash
    $stderr.puts "segments_deduped.yaml up to date (hash #{transcript_hash.to_s[0..7]})"
    puts output_path
    exit 0
  end
end

# --- Dedup pass ---

kept = []
dropped = []
log_entries = []
skip_next = false

segments.each_with_index do |seg, i|
  if skip_next
    skip_next = false
    next
  end

  nxt = segments[i + 1]

  # Last segment or no next — keep
  unless nxt
    kept << seg
    next
  end

  words_a = normalize(seg['distillation'].to_s)
  words_b = normalize(nxt['distillation'].to_s)
  overlap = jaccard(words_a, words_b)

  if overlap >= HIGH_OVERLAP
    pause = nxt['t'] - seg['e']
    same_states = (seg['states'] || []).sort == (nxt['states'] || []).sort

    if pause < PAUSE_THRESHOLD && same_states
      # Retake — drop first (current), keep second (next)
      dropped << seg
      log_entries << {
        'action' => 'dropped_retake',
        'dropped_t' => seg['t'],
        'kept_t' => nxt['t'],
        'overlap' => overlap.round(3),
        'pause' => pause.round(3),
        'distillation_a' => seg['distillation'],
        'distillation_b' => nxt['distillation']
      }
      # Don't skip_next — the kept segment (nxt) will be processed normally
      next
    elsif pause >= PAUSE_THRESHOLD
      # Rhetorical emphasis — keep both
      kept << seg
      log_entries << {
        'action' => 'kept_rhetorical_emphasis',
        'segment_a_t' => seg['t'],
        'segment_b_t' => nxt['t'],
        'overlap' => overlap.round(3),
        'pause' => pause.round(3),
        'distillation_a' => seg['distillation'],
        'distillation_b' => nxt['distillation']
      }
    else
      # Short pause but different states — new emotional info
      kept << seg
      log_entries << {
        'action' => 'kept_different_states',
        'segment_a_t' => seg['t'],
        'segment_b_t' => nxt['t'],
        'overlap' => overlap.round(3),
        'pause' => pause.round(3),
        'states_a' => seg['states'],
        'states_b' => nxt['states'],
        'distillation_a' => seg['distillation'],
        'distillation_b' => nxt['distillation']
      }
    end
  elsif overlap >= LOW_OVERLAP
    # Ambiguous — keep both, flag for review
    kept << seg
    log_entries << {
      'action' => 'review_recommended',
      'review_recommended' => true,
      'segment_a_t' => seg['t'],
      'segment_b_t' => nxt['t'],
      'overlap' => overlap.round(3),
      'distillation_a' => seg['distillation'],
      'distillation_b' => nxt['distillation']
    }
  else
    # Different content — keep, no log
    kept << seg
  end
end

# --- Output ---

output = data.dup
output['segments'] = kept
output['dedup_meta'] = {
  'source' => File.basename(path),
  'original_count' => segments.size,
  'kept_count' => kept.size,
  'dropped_count' => dropped.size,
  'timestamp' => Time.now.utc.strftime('%Y-%m-%dT%H:%M:%SZ')
}

log = {
  'transcript_hash' => transcript_hash,
  'summary' => {
    'original_count' => segments.size,
    'kept_count' => kept.size,
    'dropped_count' => dropped.size,
    'review_recommended_count' => log_entries.count { |e| e['review_recommended'] }
  },
  'entries' => log_entries
}

File.write(output_path, output.to_yaml)
File.write(log_path, log.to_yaml)

# --- Report ---

$stderr.puts "=" * 50
$stderr.puts "SEMANTIC DEDUP REPORT"
$stderr.puts "=" * 50
$stderr.puts "Segments: #{segments.size} → #{kept.size} (#{dropped.size} dropped)"
if log_entries.any?
  $stderr.puts "Log entries:"
  log_entries.each do |entry|
    case entry['action']
    when 'dropped_retake'
      $stderr.puts "  DROP retake at #{fmt(entry['dropped_t'])} (kept #{fmt(entry['kept_t'])}), overlap=#{entry['overlap']}"
    when 'kept_rhetorical_emphasis'
      $stderr.puts "  KEEP rhetorical at #{fmt(entry['segment_a_t'])}/#{fmt(entry['segment_b_t'])}, pause=#{entry['pause']}s"
    when 'kept_different_states'
      $stderr.puts "  KEEP diff-states at #{fmt(entry['segment_a_t'])}/#{fmt(entry['segment_b_t'])}, overlap=#{entry['overlap']}"
    when 'review_recommended'
      $stderr.puts "  REVIEW at #{fmt(entry['segment_a_t'])}/#{fmt(entry['segment_b_t'])}, overlap=#{entry['overlap']}"
    end
  end
end
$stderr.puts "Output: #{output_path}"
puts output_path
