#!/usr/bin/env ruby
# Repackages existing Silero VAD speech_analysis + cleaned transcript data
# into per-word prosody signals for downstream LLM prompts.
#
# Usage: ruby scripts/audio_prosody.rb --library <name>
# Output: <library_dir>/prosody.yaml

require 'yaml'
require 'json'
require 'date'

require_relative 'library_resolver'

# --- Parse args ---
library_name = nil
if (idx = ARGV.index('--library'))
  library_name = ARGV[idx + 1]
end
abort "Usage: ruby scripts/audio_prosody.rb --library <name>" unless library_name

lib_dir = LibraryResolver.resolve(library_name)
lib_yaml_path = File.join(lib_dir, 'library.yaml')
abort "library.yaml not found in #{lib_dir}" unless File.exist?(lib_yaml_path)

lib = YAML.safe_load(File.read(lib_yaml_path), permitted_classes: [Date])
videos = lib['videos'] || []
transcripts_dir = File.join(lib_dir, 'transcripts')

prosody = {}
videos.each do |video|
  source_path = video['path']
  sa_name = video['speech_analysis']
  next unless sa_name

  sa_path = File.join(transcripts_dir, sa_name)
  unless File.exist?(sa_path)
    $stderr.puts "WARN: speech analysis not found: #{sa_path}, skipping #{File.basename(source_path)}"
    next
  end

  # Find cleaned transcript (prefer cleaned, fall back to raw)
  tr_name = video['cleaned_transcript'] || video['transcript']
  unless tr_name
    $stderr.puts "WARN: no transcript for #{File.basename(source_path)}, skipping"
    next
  end
  tr_path = File.join(transcripts_dir, tr_name)
  unless File.exist?(tr_path)
    $stderr.puts "WARN: transcript not found: #{tr_path}, skipping"
    next
  end

  sa = JSON.parse(File.read(sa_path))
  tr = JSON.parse(File.read(tr_path))

  speech_segments = sa['speech_segments'] || []
  words = tr['segments'].flat_map { |s| s['words'] || [] }

  # Precompute silence gaps (spaces between speech segments)
  silence_gaps = []
  speech_segments.each_cons(2) do |a, b|
    silence_gaps << { 'start' => a['end'], 'end' => b['start'] } if b['start'] > a['end']
  end

  word_entries = []
  words.each_with_index do |w, i|
    next unless w['start'] && w['end']
    w_start = w['start'].to_f
    w_end = w['end'].to_f

    # mid_word_break: any silence gap overlaps the word span
    mid_break = silence_gaps.any? { |g| g['start'] < w_end && g['end'] > w_start }

    # trailing_pause_ms: silence gap after the speech segment containing this word
    containing = speech_segments.find { |s| s['start'] <= w_end && s['end'] >= w_end }
    if containing
      next_seg = speech_segments.find { |s| s['start'] > containing['end'] }
      trailing_ms = next_seg ? ((next_seg['start'] - containing['end']) * 1000).round : nil
    else
      # Word ends in silence — gap to next speech
      next_seg = speech_segments.find { |s| s['start'] > w_end }
      trailing_ms = next_seg ? ((next_seg['start'] - w_end) * 1000).round : nil
    end

    # stumble_marker: short gap (<100ms) to next word + next word repeats this word
    stumble = false
    if i + 1 < words.size
      nw = words[i + 1]
      if nw['start']
        gap = nw['start'].to_f - w_end
        if gap < 0.100 && gap >= 0
          norm_cur = w['word'].downcase.gsub(/[^a-z]/, '')
          norm_nxt = nw['word'].downcase.gsub(/[^a-z]/, '')
          stumble = true if norm_cur == norm_nxt && !norm_cur.empty?
        end
      end
    end

    word_entries << {
      'word_idx' => i,
      'text' => w['word'],
      'start' => w_start,
      'end' => w_end,
      'stumble_marker' => stumble,
      'mid_word_break' => mid_break,
      'trailing_pause_ms' => trailing_ms
    }
  end

  prosody[source_path] = { 'words' => word_entries }
  $stderr.puts "#{File.basename(source_path)}: #{word_entries.size} words processed"
end

if prosody.empty?
  $stderr.puts "No speech analysis found for any video. Nothing to do."
  exit 0
end

output_path = File.join(lib_dir, 'prosody.yaml')
File.write(output_path, YAML.dump(prosody))
$stderr.puts "Wrote #{output_path}"
puts output_path
