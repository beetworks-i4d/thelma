#!/usr/bin/env ruby
# Cleans a WhisperX transcript JSON by removing duplicate takes, false starts,
# single-word filler segments, trailing-off patterns, and within-segment stutters.
#
# Usage: ruby scripts/transcript_cleanup.rb <transcript.json>
# Output: <transcript_basename>_cleaned.json in the same directory
#
# Cleanup rules:
#   1. Duplicate takes: consecutive segments with ≥70% normalized word overlap → drop first
#   2. False starts: segment ends mid-sentence, next starts with similar words → drop first
#   3. Single-word filler: segments <1.5s with only filler words → drop entirely
#   4. Trailing-off: repeated end words, partial words, "..." then clean restart → drop first
#   5. Within-segment de-stutter: internal phrase repeats, partial restarts, word-level repeats
#      Default: all repeats are cut (no pause analysis).
#      --protect-rhetorical: if Silero speech analysis is provided (--speech-analysis <path>),
#      phrase repeats separated by >250ms silence are treated as rhetorical repetition
#      and kept. Under 250ms or no speech data → remove first occurrence as stutter.
#
# Logs every removal to stderr. Output schema identical to input.

require 'json'

FILLER_WORDS = %w[um uh okay so right like well you\ know yeah ah oh hmm mhm].freeze
FILLER_CONNECTORS = %w[um uh like you know so well okay and but].freeze
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

# Normalize a single word for comparison: lowercase, strip punctuation
def norm(word)
  word.to_s.downcase.gsub(/[^a-z0-9']/, '')
end

# Check pause duration between two audio times using Silero speech segments.
# Returns the longest silence gap (seconds) between t1 and t2.
# If no speech data, returns 0.0 (assume no pause → allow removal).
PAUSE_THRESHOLD = 0.250

def silence_between(t1, t2, speech_segs)
  return 0.0 unless speech_segs && !speech_segs.empty?
  return 0.0 if t2 <= t1

  # Find speech segments overlapping [t1, t2]
  relevant = speech_segs.select { |s| s['end'].to_f > t1 && s['start'].to_f < t2 }

  # If no speech segments span this range, the entire range is silence
  return t2 - t1 if relevant.empty?

  relevant.sort_by! { |s| s['start'].to_f }

  max_gap = relevant.first['start'].to_f - t1
  relevant.each_cons(2) do |a, b|
    gap = b['start'].to_f - a['end'].to_f
    max_gap = gap if gap > max_gap
  end
  trailing = t2 - relevant.last['end'].to_f
  max_gap = trailing if trailing > max_gap

  [max_gap, 0.0].max
end

# Within-segment de-stutter: detect internal phrase repeats, partial restarts,
# and consecutive word repeats. Returns [modified_seg, log_message] or nil.
# When speech_segs is provided, phrase repeats separated by >250ms silence
# are treated as rhetorical repetition and kept.
def destutter_segment(seg, speech_segs = nil)
  words = seg['words']
  return nil unless words && words.size >= 4

  norms = words.map { |w| norm(w['word']) }
  keep = Array.new(words.size, true)
  reasons = []

  # --- Pass A: Phrase repeats (3+ words) ---
  # Find longest repeated phrase first, working down
  max_phrase = [norms.size / 2, 10].min
  max_phrase.downto(3) do |plen|
    i = 0
    while i <= norms.size - plen
      unless keep[i]
        i += 1
        next
      end

      phrase = norms[i, plen]
      # Skip if phrase is all filler
      if phrase.all? { |w| FILLER_CONNECTORS.include?(w) || w.empty? }
        i += 1
        next
      end

      # Look for matching phrase after position i, with gap handling:
      # - 0-gap: always match (immediate repeat)
      # - Filler-only gap (1-3 words): match any phrase >= 3
      # - Non-filler gap (1-5 words): only match phrases >= 5
      search_start = i + plen
      match_at = nil
      max_gap = [5, norms.size - search_start - plen].min
      (0..max_gap).each do |gap|
        try_start = search_start + gap
        break if try_start + plen > norms.size
        next unless norms[try_start, plen] == phrase

        # Validate gap content
        if gap == 0
          match_at = try_start
          break
        else
          gap_words = norms[search_start, gap]
          all_filler = gap_words.all? { |w| FILLER_CONNECTORS.include?(w) || w.empty? }
          if all_filler && gap <= 3
            match_at = try_start
            break
          elsif plen >= 5
            match_at = try_start
            break
          end
        end
      end

      if match_at
        # Pause-aware protection: check silence between end of first occurrence
        # (or gap) and start of second occurrence. If >250ms, it's rhetorical.
        phrase1_end = words[match_at - 1]['end'].to_f
        phrase2_start = words[match_at]['start'].to_f
        pause = silence_between(phrase1_end, phrase2_start, speech_segs)
        if pause > PAUSE_THRESHOLD
          $stderr.puts "kept #{time_range(seg)} — rhetorical repeat (#{(pause * 1000).round}ms pause): '#{words[i, plen].map { |w| w['word'] }.join(' ')}'"
          i += 1
          next
        end

        # Keep the second occurrence, remove first occurrence + gap
        removed_text = words[i...match_at].map { |w| w['word'] }.join(' ')
        reasons << "removed '#{removed_text}' (phrase repeat)"
        (i...match_at).each { |j| keep[j] = false }
        i = match_at + plen
      else
        i += 1
      end
    end
  end

  # --- Pass B: Consecutive word repeats (1-2 words) ---
  # "no no", "$850 $850", "is is is"
  i = 0
  while i < norms.size - 1
    unless keep[i] && keep[i + 1]
      i += 1
      next
    end

    if !norms[i].empty? && norms[i] == norms[i + 1]
      # Check for triple+ repeat
      run_end = i + 1
      run_end += 1 while run_end + 1 < norms.size && keep[run_end + 1] && norms[run_end + 1] == norms[i]
      # Pause-aware: check silence between first and last in run
      pause = silence_between(words[i]['end'].to_f, words[run_end]['start'].to_f, speech_segs)
      if pause > PAUSE_THRESHOLD
        $stderr.puts "kept #{time_range(seg)} — rhetorical repeat (#{(pause * 1000).round}ms pause): '#{words[i, run_end - i + 1].map { |w| w['word'] }.join(' ')}'"
        i = run_end + 1
        next
      end
      # Keep only the last one in the run
      removed = words[i...run_end].map { |w| w['word'] }.join(' ')
      reasons << "removed '#{removed}' (word repeat)"
      (i...run_end).each { |j| keep[j] = false }
      i = run_end + 1
    else
      i += 1
    end
  end

  # --- Pass C: Phrase restarts (same opening, different continuation) ---
  # Pattern: "I think it's very telling that the flood... so I think it's very telling that at the present..."
  # The speaker starts a thought, abandons it, restarts with the same opening but continues differently.
  # Distinct from rhetorical repetition where both instances have parallel complete content.
  min_restart_phrase = 3
  max_restart_phrase = [norms.size / 3, 8].min
  max_restart_phrase.downto(min_restart_phrase) do |plen|
    i = 0
    while i <= norms.size - plen
      unless keep[i]
        i += 1
        next
      end

      phrase = norms[i, plen]
      next (i += 1) if phrase.all? { |w| FILLER_CONNECTORS.include?(w) || w.empty? }

      # Search for same phrase opening later in the segment
      search_from = i + plen
      match_at = nil
      # Allow up to 15 words between first and second occurrence (the abandoned continuation)
      max_search = [search_from + 15 + plen, norms.size - plen].min
      (search_from..max_search).each do |j|
        next unless keep[j]
        if norms[j, plen] == phrase
          match_at = j
          break
        end
      end

      unless match_at
        i += 1
        next
      end

      # Pause-aware protection
      phrase1_last_kept = (i...match_at).select { |j| keep[j] }.last || i
      pause = silence_between(words[phrase1_last_kept]['end'].to_f, words[match_at]['start'].to_f, speech_segs)
      if pause > PAUSE_THRESHOLD
        i += 1
        next
      end

      # Determine if this is a restart vs rhetorical parallel:
      # - Restart: first instance has short/incomplete tail after the phrase (< phrase length words)
      # - Rhetorical: both instances have substantial unique content after the phrase
      first_tail_end = match_at
      first_tail_words = (i + plen...first_tail_end).count { |j| keep[j] }
      second_tail_end = [match_at + plen + 20, norms.size].min
      second_tail_words = (match_at + plen...second_tail_end).count { |j| keep[j] }

      # Check for parallel structure: if first tail has real content words (not just filler)
      # AND second tail has similar amount, it's likely rhetorical
      first_tail_content = (i + plen...first_tail_end).select { |j| keep[j] }
                            .map { |j| norms[j] }
                            .reject { |w| FILLER_CONNECTORS.include?(w) || w.empty? }
      second_tail_content = (match_at + plen...[match_at + plen + first_tail_words + 5, norms.size].min).select { |j| keep[j] }
                             .map { |j| norms[j] }
                             .reject { |w| FILLER_CONNECTORS.include?(w) || w.empty? }

      # Rhetorical if: both tails have 2+ content words AND low overlap (different content)
      if first_tail_content.size >= 2 && second_tail_content.size >= 2
        tail_overlap = (first_tail_content & second_tail_content).size.to_f /
                       [first_tail_content.size, second_tail_content.size].min
        if tail_overlap < 0.5
          $stderr.puts "kept #{time_range(seg)} — rhetorical parallel: '#{words[i, plen].map { |w| w['word'] }.join(' ')}' (tails differ)"
          i += 1
          next
        end
      end

      # It's a restart — remove everything from the first occurrence up to the second
      removed_text = (i...match_at).select { |j| keep[j] }.map { |j| words[j]['word'] }.join(' ')
      reasons << "removed '#{removed_text}' (phrase restart)"
      (i...match_at).each { |j| keep[j] = false }
      i = match_at + plen
    end
  end

  return nil if reasons.empty?

  # Rebuild segment from kept words
  kept_words = words.each_with_index.select { |_, j| keep[j] }.map(&:first)
  return nil if kept_words.empty?

  new_seg = seg.dup
  new_seg['words'] = kept_words
  new_seg['text'] = kept_words.map { |w| w['word'] }.join(' ')
  new_seg['start'] = kept_words.first['start'].to_f if kept_words.first['start']
  new_seg['end'] = kept_words.last['end'].to_f if kept_words.last['end']

  [new_seg, reasons]
end

# Parse arguments: transcript path + optional flags
args = ARGV.dup
speech_analysis_path = nil
protect_rhetorical = false

if (sa_idx = args.index('--speech-analysis'))
  speech_analysis_path = args[sa_idx + 1]
  args.slice!(sa_idx, 2)
end

if (pr_idx = args.index('--protect-rhetorical'))
  protect_rhetorical = true
  args.slice!(pr_idx, 1)
end

path = args[0]
abort "Usage: ruby scripts/transcript_cleanup.rb <transcript.json> [--speech-analysis <path>] [--protect-rhetorical]" unless path
abort "File not found: #{path}" unless File.exist?(path)

speech_segs = nil
if speech_analysis_path && protect_rhetorical
  abort "Speech analysis not found: #{speech_analysis_path}" unless File.exist?(speech_analysis_path)
  sa_data = JSON.parse(File.read(speech_analysis_path))
  speech_segs = sa_data['speech_segments'] || []
  $stderr.puts "Loaded speech analysis: #{speech_segs.size} segments (rhetorical protection enabled)"
elsif speech_analysis_path && !protect_rhetorical
  $stderr.puts "Speech analysis provided but --protect-rhetorical not set — all repeats will be cut"
end

data = JSON.parse(File.read(path))
segments = data['segments'] || []
if segments.empty?
  # No speech segments — write pass-through output and exit cleanly
  dir = File.dirname(path)
  base = File.basename(path, '.json')
  output_path = File.join(dir, "#{base}_cleaned.json")
  File.write(output_path, JSON.pretty_generate(data))
  $stderr.puts "No segments found — pass-through (no cleanup needed)"
  $stderr.puts "Saved: #{output_path}"
  puts output_path
  exit 0
end

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

# Rule 5: Within-segment de-stutter (pause-aware when speech analysis provided)
destutter_count = 0
cleaned_segments = cleaned_segments.map do |seg|
  result = destutter_segment(seg, speech_segs)
  if result
    new_seg, reasons = result
    destutter_count += 1
    reasons.each do |reason|
      $stderr.puts "trimmed #{time_range(seg)} — #{reason}"
    end
    new_seg
  else
    seg
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
$stderr.puts "Input: #{segments.size} segments → Output: #{cleaned_segments.size} segments (#{drops.size} dropped, #{destutter_count} de-stuttered)"
$stderr.puts "Saved: #{output_path}"
puts output_path
