#!/usr/bin/env ruby
# Content Mining Mode — Inventory raw footage without editorial intent.
# Reads classified segments (Branch B), filters high-signal, clusters by
# thematic similarity, and produces a content inventory for assessment.
#
# Usage:
#   ruby scripts/mine_content.rb <segments_classified.yaml>
#   ruby scripts/mine_content.rb --library <name>
#
# --library: resolves segments_classified.yaml from libraries/<name>/ (cwd-relative)
#
# Output: content_inventory.yaml in same directory as input. Path to stdout.
# The theme field is nil — agent fills it after reading distillations + theme_prompt.

require 'yaml'
require 'date'
require 'set'

# --- Constants ---

STOP_WORDS = Set.new(%w[
  a an the and or but in on at to for of is it that this with from by as
  be was were been being have has had do does did will would could should
  may might can shall not no just very also than then so
]).freeze

CONFIDENCE_WEIGHT = { 'high' => 1.0, 'medium' => 0.7 }.freeze
DURABILITY_WEIGHT = { 'identity' => 1.0, 'mood' => 0.8 }.freeze

ADJACENCY_THRESHOLD = 30.0  # seconds — max gap to merge into same cluster
MIN_DISTILLATION_LENGTH = 6 # chars — filter filler
SHORT_MIN_DURATION = 30.0   # seconds
SHORT_MAX_DURATION = 90.0   # seconds

# --- Flag parsing ---

library_name = nil
if (idx = ARGV.index('--library'))
  library_name = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end

segments_path = if library_name
  lib_dir = File.join('libraries', library_name)
  abort "Library not found: #{library_name}" unless File.directory?(lib_dir)
  found = Dir.glob(File.join(lib_dir, '**/segments_classified.yaml')).first
  found || abort("No segments_classified.yaml found in library '#{library_name}'")
else
  ARGV[0] || abort("Usage: ruby scripts/mine_content.rb <segments_classified.yaml> OR --library <name>")
end

abort "File not found: #{segments_path}" unless File.exist?(segments_path)

# --- Load data ---

data = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])

if data.key?('segments_used')
  abort "Branch A (script-locked) classification not supported — mine_content requires Branch B segments."
end

segments = data['segments'] || []
abort "No segments found in #{segments_path}" if segments.empty?

# --- Helpers ---

def high_signal?(seg)
  confidence = seg['confidence'] || 'low'
  dur = seg['dur'] || 'spike'
  distillation = seg['distillation'] || ''

  %w[high medium].include?(confidence) &&
    %w[identity mood].include?(dur) &&
    distillation.strip.length >= MIN_DISTILLATION_LENGTH
end

def content_words(text)
  text.to_s.downcase.gsub(/[^a-z0-9\s]/, '').split.reject { |w| STOP_WORDS.include?(w) }
end

def theme_overlap?(cluster_words, seg_words)
  return false if cluster_words.empty? || seg_words.empty?
  (Set.new(cluster_words) & Set.new(seg_words)).any?
end

def segment_quality(seg)
  conf = CONFIDENCE_WEIGHT[seg['confidence']] || 0.5
  dur = DURABILITY_WEIGHT[seg['dur']] || 0.5
  conf * dur
end

def cluster_quality(segs)
  return 0.0 if segs.empty?
  total = segs.sum { |s| segment_quality(s) }
  (total / segs.size).round(2)
end

def cluster_duration(segs)
  return 0.0 if segs.empty?
  (segs.last['e'].to_f - segs.first['t'].to_f).round(1)
end

def self_contained?(segs)
  return false if segs.size < 2
  first_dur = segs.first['dur'] || 'spike'
  last_dur = segs.last['dur'] || 'spike'
  first_dur == 'identity' && last_dur == 'identity'
end

def standalone_short?(segs, is_self_contained)
  return false unless is_self_contained
  dur = cluster_duration(segs)
  dur >= SHORT_MIN_DURATION && dur <= SHORT_MAX_DURATION
end

def build_theme_prompt(distillations)
  lines = distillations.each_with_index.map { |d, i| "#{i + 1}. #{d}" }.join("\n")
  <<~PROMPT.strip
    Read these distilled segment summaries from a thematic cluster. Write a 3-5 word theme label describing what this cluster is ABOUT.

    Focus on: the specific topic, claim, story, or insight.
    Do NOT describe: emotional states, durability, or structural properties.

    Example: "failed models before drop servicing"
    Example: "platform dependency critique"

    Distilled segments:
    #{lines}
  PROMPT
end

def fmt_time(seconds)
  m = (seconds / 60).to_i
  s = (seconds % 60).to_i
  format("%d:%02d", m, s)
end

# --- Filter high-signal ---

high_signal = segments.select { |s| high_signal?(s) }.sort_by { |s| s['t'].to_f }

if high_signal.empty?
  output_dir = File.dirname(segments_path)
  output_path = File.join(output_dir, 'content_inventory.yaml')
  source_name = library_name || File.basename(output_dir)

  output = {
    'generated_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
    'source' => source_name,
    'total_classified_segments' => segments.size,
    'high_signal_segments' => 0,
    'clusters_found' => 0,
    'clusters' => []
  }
  File.write(output_path, output.to_yaml)

  $stderr.puts "CONTENT INVENTORY: #{source_name}"
  $stderr.puts "#{segments.size} segments classified, 0 high-signal. No clusters to report."
  $stderr.puts ""
  $stderr.puts "Output: #{output_path}"
  puts output_path
  exit 0
end

# --- Cluster by adjacency + thematic similarity ---

clusters = []
current = { segs: [high_signal.first], words: content_words(high_signal.first['distillation']) }

high_signal[1..].each do |seg|
  gap = seg['t'].to_f - current[:segs].last['e'].to_f
  seg_words = content_words(seg['distillation'])

  if gap <= ADJACENCY_THRESHOLD && theme_overlap?(current[:words], seg_words)
    current[:segs] << seg
    current[:words] |= seg_words
  else
    clusters << current
    current = { segs: [seg], words: seg_words }
  end
end
clusters << current

# --- Compute per-cluster metrics ---

cluster_records = clusters.each_with_index.map do |c, i|
  segs = c[:segs]
  distillations = segs.map { |s| s['distillation'] }.compact.uniq
  sc = self_contained?(segs)

  {
    'id' => "cluster_#{i}",
    'theme' => nil,
    'theme_prompt' => build_theme_prompt(distillations),
    'segments' => segs.map { |s| s['t'].to_f },
    'duration' => cluster_duration(segs),
    'segment_count' => segs.size,
    'quality' => cluster_quality(segs),
    'self_contained' => sc,
    'standalone_short_candidate' => standalone_short?(segs, sc),
    'distillations' => distillations
  }
end

# --- Sort by quality descending ---

cluster_records.sort_by! { |c| -c['quality'] }

# Re-index after sort
cluster_records.each_with_index { |c, i| c['id'] = "cluster_#{i}" }

# --- Output ---

output_dir = File.dirname(segments_path)
output_path = File.join(output_dir, 'content_inventory.yaml')
source_name = library_name || File.basename(output_dir)

output = {
  'generated_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'source' => source_name,
  'total_classified_segments' => segments.size,
  'high_signal_segments' => high_signal.size,
  'clusters_found' => cluster_records.size,
  'clusters' => cluster_records
}

File.write(output_path, output.to_yaml)

# --- Report ---

$stderr.puts "=" * 60
$stderr.puts "CONTENT INVENTORY: #{source_name}"
$stderr.puts "#{segments.size} segments classified, #{high_signal.size} high-signal, #{cluster_records.size} thematic clusters"
$stderr.puts "=" * 60

cluster_records.each_with_index do |c, i|
  dur_str = fmt_time(c['duration'])
  $stderr.puts ""
  $stderr.puts "#{i + 1}. [theme pending] — #{dur_str}, #{c['segment_count']} segments, quality #{c['quality']}"
  sc_label = c['self_contained'] ? 'yes' : 'no'
  short_label = c['standalone_short_candidate'] ? 'yes' : 'no'
  reasons = []
  reasons << "too short" if c['self_contained'] && c['duration'] < SHORT_MIN_DURATION
  reasons << "too long" if c['self_contained'] && c['duration'] > SHORT_MAX_DURATION
  reasons << "not self-contained" unless c['self_contained']
  short_detail = reasons.empty? ? short_label : "#{short_label} (#{reasons.join(', ')})"
  $stderr.puts "   Self-contained: #{sc_label} | Standalone short: #{short_detail}"
  $stderr.puts "   Distillations: #{c['distillations'].first(3).map { |d| "\"#{d}\"" }.join(', ')}"
end

$stderr.puts ""
$stderr.puts "Actions: [Generate review reels] [Run discovery on cluster N] [Export inventory report]"
$stderr.puts ""
$stderr.puts "Output: #{output_path}"
puts output_path
