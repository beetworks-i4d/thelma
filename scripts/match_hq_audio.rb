#!/usr/bin/env ruby
# Detects HQ audio / video transcript pairs in a pool library.
#
# Compares transcripts pairwise for word overlap. If two sources share > 80% word
# overlap AND one is audio_only while the other is video_with_audio, treats them as
# a matched pair (same recording, HQ mic + camera scratch audio).
#
# Then runs waveform alignment (audio_sync_offset.rb) to find exact sync offset.
# Updates index.yaml with hq_audio_source / hq_audio_offset on the video entry
# and role: hq_audio_for on the audio entry.
#
# Usage:
#   ruby scripts/match_hq_audio.rb --library <name> [--overlap-threshold 0.8]

require 'yaml'
require 'json'
require 'date'
require 'open3'
require_relative 'pool_index'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

# --- CLI ---

overlap_threshold = 0.80
library_name      = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'
    args.shift
    library_name = args.shift
  when '--overlap-threshold'
    args.shift
    overlap_threshold = args.shift.to_f
  else
    abort "Unknown argument: #{args.first}\nUsage: ruby scripts/match_hq_audio.rb --library <name> [--overlap-threshold 0.8]"
  end
end

abort "Usage: ruby scripts/match_hq_audio.rb --library <name>" unless library_name

library_dir = File.join(ROOT_DIR, 'libraries', library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

library_yaml_path = File.join(library_dir, 'library.yaml')
abort "library.yaml not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

library   = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
pool_dir  = library['pool_dir']
index     = PoolIndex.load(library_dir)
sources   = index['sources'] || {}

transcripts_dir = File.join(library_dir, 'transcripts')

# --- Load word list from transcript ---

def load_words(filename, transcripts_dir)
  path = File.join(transcripts_dir, filename.to_s)
  return [] unless File.exist?(path)
  data = JSON.parse(File.read(path)) rescue nil
  return [] unless data
  (data['segments'] || [])
    .flat_map { |s| (s['words'] || []).map { |w| w['word']&.downcase&.gsub(/[^a-z0-9]/, '') } }
    .reject(&:empty?)
end

# --- Jaccard similarity on first N shared words ---
# Uses a prefix of N words to avoid penalising shorter audio-only recordings.

def word_overlap(words_a, words_b, prefix_n: 200)
  a = words_a.first(prefix_n).to_set
  b = words_b.first(prefix_n).to_set
  union = (a | b)
  return 0.0 if union.empty?
  (a & b).size.to_f / union.size
end

# --- Collect sources with transcripts ---

video_sources = sources.select { |_, v| v['media_type'] == 'video_with_audio' && v['transcript_file'] }
audio_sources = sources.select { |_, v| v['media_type'] == 'audio_only'       && v['transcript_file'] }

$stderr.puts "Checking pairs: #{video_sources.size} video source(s), #{audio_sources.size} audio-only source(s)"

if video_sources.empty? || audio_sources.empty?
  $stderr.puts "Nothing to match."
  exit 0
end

# --- Pairwise transcript comparison ---

pairs = []

video_sources.each do |v_filename, v_entry|
  # Skip already-matched video sources
  next if v_entry['hq_audio_source']

  v_words = load_words(v_entry['transcript_file'], transcripts_dir)
  next if v_words.size < 20

  audio_sources.each do |a_filename, a_entry|
    # Skip already-matched audio sources
    next if a_entry['role'] == 'hq_audio_for'

    a_words = load_words(a_entry['transcript_file'], transcripts_dir)
    next if a_words.size < 20

    score = word_overlap(v_words, a_words)
    $stderr.puts "  #{v_filename} ↔ #{a_filename}: #{(score * 100).round}% overlap" if score >= 0.40

    if score >= overlap_threshold
      pairs << { video: v_filename, audio: a_filename, overlap: score }
      $stderr.puts "  → MATCH: #{v_filename} ↔ #{a_filename} (#{(score * 100).round}%)"
    end
  end
end

if pairs.empty?
  $stderr.puts "No HQ audio pairs found above #{(overlap_threshold * 100).round}% overlap threshold."
  exit 0
end

# --- Waveform alignment ---

pairs.each do |pair|
  unless pool_dir && File.directory?(pool_dir)
    $stderr.puts "  WARNING: pool_dir not configured in library.yaml — skipping waveform sync for #{pair[:video]}"
    PoolIndex.set_hq_pair(index, pair[:video], pair[:audio], 0.0)
    next
  end

  video_path = Dir.glob(File.join(pool_dir, '**', pair[:video])).first
  audio_path = Dir.glob(File.join(pool_dir, '**', pair[:audio])).first

  unless video_path && File.exist?(video_path) && audio_path && File.exist?(audio_path)
    $stderr.puts "  WARNING: Could not locate files for pair #{pair[:video]} ↔ #{pair[:audio]}"
    next
  end

  $stderr.puts "  Aligning waveforms: #{pair[:video]} ↔ #{pair[:audio]}..."
  stdout, stderr, status = Open3.capture3(
    'ruby', File.join(SCRIPTS_DIR, 'audio_sync_offset.rb'),
    video_path, audio_path
  )

  unless status.success?
    $stderr.puts "  WARNING: Waveform sync failed: #{stderr.strip}"
    next
  end

  offset = stdout.strip.to_f
  $stderr.puts "  Offset: #{offset.round(3)}s (#{offset > 0 ? 'HQ leads' : 'HQ lags'} video)"
  PoolIndex.set_hq_pair(index, pair[:video], pair[:audio], offset)
end

PoolIndex.save(library_dir, index)
$stderr.puts "HQ matching complete: #{pairs.size} pair(s) recorded in index.yaml"
puts pairs.size
