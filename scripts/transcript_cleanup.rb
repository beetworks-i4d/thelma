#!/usr/bin/env ruby
# Cleans a WhisperX transcript JSON by removing duplicate takes, false starts,
# single-word filler segments, and trailing-off patterns.
#
# Usage: ruby scripts/transcript_cleanup.rb <transcript.json>
# Output: <transcript_basename>_cleaned.json in the same directory
#
# Cleanup rules:
#   1. Duplicate takes: consecutive segments with ≥70% normalized word overlap → drop first
#   2. False starts: segment ends mid-sentence, next starts with similar words → drop first
#   3. Single-word filler: segments <1.5s with only filler words → drop entirely
#   4. Trailing-off: repeated end words, partial words, "..." then clean restart → drop first
#
# Logs every removal to stderr. Output schema identical to input.

require 'json'

FILLER_WORDS = %w[um uh okay so right like well you\ know yeah ah oh hmm mhm].freeze
CONJUNCTIONS_TRAILING = %w[and but the so or a an if that which when because].freeze
TERMINAL_PUNCTUATION = /[.!?]$/

def fmt(seconds)
  m = (seconds / 60).floor
  s = seconds % 60
  format("%02d:%05.2f", m, s)
end

def time_range(seg)
  "#{fmt(seg['start'].to_f)}-#{fmt(seg['end'].to_f)}"
end

# Normalize text for comparison: lowercase, strip punctuation, remove filler words
def normalize_words(text)
  words = text.to_s.downcase.gsub(/[^a-z0-9'\s]/, '').split
  words.reject { |w| FILLER_WORDS.include?(w) }
end

# Jaccard-style overlap: shared words / union of words
def word_overlap(words_a, words_b)
  return 0.0 if words_a.empty? || words_b.empty?
  shared = (words_a & words_b).size.to_f
  union = (words_a | words_b).size.to_f
  shared / union
end

# Ordered overlap: what fraction of words_a's sequence appears at the start of words_b
def opening_overlap(words_a, words_b, count = 3)
  return 0.0 if words_a.empty? || words_b.empty?
  check = [count, words_a.size, words_b.size].min
  return 0.0 if check == 0
  matches = (0...check).count { |i| words_a[i] == words_b[i] }
  matches.to_f / check
end

path = ARGV[0]
abort "Usage: ruby scripts/transcript_cleanup.rb <transcript.json>" unless path
abort "File not found: #{path}" unless File.exist?(path)

data = JSON.parse(File.read(path))
segments = data['segments'] || []
abort "No segments found in transcript" if segments.empty?

# Track which indices to drop and why
drops = {}  # index => reason string

segments.each_with_index do |seg, i|
  next if drops.key?(i)

  text = seg['text'].to_s.strip
  duration = seg['end'].to_f - seg['start'].to_f
  words = normalize_words(text)

  # Rule 3: Single-word filler — segments <1.5s with only filler
  if duration < 1.5
    raw_words = text.downcase.gsub(/[^a-z0-9'\s]/, '').split
    if raw_words.all? { |w| FILLER_WORDS.include?(w) }
      drops[i] = "single-word filler (#{duration.round(2)}s: \"#{text}\")"
      next
    end
  end

  # Rules that compare consecutive pairs — need a next segment
  next_idx = (i + 1..segments.size - 1).find { |j| !drops.key?(j) }
  next unless next_idx

  next_seg = segments[next_idx]
  next_text = next_seg['text'].to_s.strip
  next_words = normalize_words(next_text)

  # Rule 1: Duplicate takes — ≥70% word overlap, drop first
  overlap = word_overlap(words, next_words)
  if overlap >= 0.70
    drops[i] = "duplicate take of #{time_range(next_seg)} (#{(overlap * 100).round}% overlap)"
    next
  end

  # Rule 2: False starts — ends mid-sentence, next starts with similar opening words
  unless text.match?(TERMINAL_PUNCTUATION)
    last_word = words.last.to_s
    if CONJUNCTIONS_TRAILING.include?(last_word) || words.size <= 4
      if opening_overlap(words, next_words) >= 0.5
        drops[i] = "false start before #{time_range(next_seg)} (ends on \"#{last_word}\", similar opening)"
        next
      end
    end
  end

  # Rule 4: Trailing-off — repeated end words, partial words, or "..." then clean restart
  raw_words_current = text.split
  if raw_words_current.size >= 2
    last_two = raw_words_current.last(2).map { |w| w.downcase.gsub(/[^a-z]/, '') }
    # Repeated end words ("the the", "is is")
    if last_two[0] == last_two[1] && !last_two[0].empty?
      if next_text.match?(TERMINAL_PUNCTUATION) || next_words.size > words.size
        drops[i] = "trailing-off (repeated \"#{last_two[0]}\") before clean restart #{time_range(next_seg)}"
        next
      end
    end
  end

  # Trailing "..." pattern
  if text.match?(/\.{2,}\s*$/) || text.match?(/[–—-]\s*$/)
    if next_text.match?(TERMINAL_PUNCTUATION) || next_words.size > words.size
      drops[i] = "trailing-off (ellipsis/dash) before clean restart #{time_range(next_seg)}"
      next
    end
  end
end

# Build cleaned output
cleaned_segments = []
segments.each_with_index do |seg, i|
  if drops.key?(i)
    $stderr.puts "dropped #{time_range(seg)} — #{drops[i]}"
  else
    cleaned_segments << seg
  end
end

# Rebuild output with same schema
output = data.dup
output['segments'] = cleaned_segments

# Rebuild word_segments from remaining segments if present
if data['word_segments']
  kept_words = cleaned_segments.flat_map { |s| s['words'] || [] }
  output['word_segments'] = kept_words
end

# Write cleaned file
dir = File.dirname(path)
base = File.basename(path, '.json')
output_path = File.join(dir, "#{base}_cleaned.json")
File.write(output_path, JSON.pretty_generate(output))

$stderr.puts "---"
$stderr.puts "Input: #{segments.size} segments → Output: #{cleaned_segments.size} segments (#{drops.size} removed)"
$stderr.puts "Saved: #{output_path}"
puts output_path
