#!/usr/bin/env ruby
# Phase 1.35 — Semantic Segmentation (Session 5).
# LLM-powered, per-source-video. Reads raw word-level transcript + VAD pauses,
# produces coherent editorial segments (usable) and a discarded audit file.
#
# Replaces transcript_cleanup.rb. Atoms produced here are inviolate — no
# downstream script modifies their boundaries (D5.10).
#
# Sources >3500 words are chunked per D5.12. Chunks process serially in
# claude_code mode (one pending file at a time). Parallel processing is a
# future api-mode optimization.
#
# Usage: ruby scripts/semantic_segment.rb --library <name> --source <filename>
#        [--profile <name>] [--llm-mode api|claude_code] [--force]
#
# Output:
#   transcripts/{source_basename}_semantic_segments.yaml  (usable segments)
#   transcripts/{source_basename}_discarded_segments.yaml (audit)

require 'yaml'
require 'date'
require 'json'
require 'digest'
require 'fileutils'
require_relative 'load_profile'
require_relative 'llm_client'
require_relative 'library_resolver'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

# Prompt version — included in fingerprint. Bump when system/user prompt changes.
PROMPT_VERSION = '1.0.0'

# Chunking constants (D5.12)
CHUNK_THRESHOLD = 3500
CHUNK_OVERLAP   = 250

# ─── CLI ─────────────────────────────────────────────────────────────────────

library_name = nil
source_filename = nil
profile_name = nil
llm_mode = nil
force = false

args = ARGV.dup
while args.any?
  case args.first
  when '--library'  then args.shift; library_name    = args.shift
  when '--source'   then args.shift; source_filename  = args.shift
  when '--profile'  then args.shift; profile_name     = args.shift
  when '--llm-mode' then args.shift; llm_mode         = args.shift
  when '--force'    then args.shift; force            = true
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/semantic_segment.rb --library <name> --source <filename> " \
          "[--profile <name>] [--llm-mode api|claude_code] [--force]"
  end
end
abort "Usage: ruby scripts/semantic_segment.rb --library <name> --source <filename>" unless library_name && source_filename

LLMClient.mode = llm_mode.to_sym if llm_mode

# ─── Load library + profile ─────────────────────────────────────────────────

library_dir = LibraryResolver.resolve(library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

library_yaml_path = File.join(library_dir, 'library.yaml')
abort "library.yaml not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
videos  = library['videos'] || []

# Find matching video entry
video = videos.find { |v| File.basename(v['path']) == source_filename }
abort "PIPELINE ABORT: Source '#{source_filename}' not found in library.yaml" unless video

profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)
profile_name_resolved = profile_name || find_profile_match(library_name) || '_default'
tone_context = build_compact_tone_context(profile)

transcripts_dir = File.join(library_dir, 'transcripts')
language = library['language'] || 'english'

# ─── Resolve inputs ──────────────────────────────────────────────────────────

# Raw transcript (WhisperX output — NOT cleaned)
transcript_name = video['transcript']
abort "PIPELINE ABORT: No transcript for source #{source_filename}" unless transcript_name
transcript_path = File.join(transcripts_dir, transcript_name)
abort "PIPELINE ABORT: Transcript not found: #{transcript_path}" unless File.exist?(transcript_path)

# Speech analysis (VAD) — optional, degrade gracefully
speech_analysis_name = video['speech_analysis']
speech_analysis_path = speech_analysis_name ? File.join(transcripts_dir, speech_analysis_name) : nil
has_vad = speech_analysis_path && File.exist?(speech_analysis_path)
unless has_vad
  $stderr.puts "WARNING: No speech analysis for #{source_filename} — segmenting without VAD pauses"
end

# Output paths
source_basename = File.basename(video['path'], File.extname(video['path']))
output_path = File.join(transcripts_dir, "#{source_basename}_semantic_segments.yaml")
discarded_path = File.join(transcripts_dir, "#{source_basename}_discarded_segments.yaml")

# ─── Cache check ─────────────────────────────────────────────────────────────

fingerprint_parts = [
  Digest::SHA256.hexdigest(File.read(transcript_path)),
  has_vad ? Digest::SHA256.hexdigest(File.read(speech_analysis_path)) : 'no_vad',
  profile_name_resolved,
  source_filename,
  Digest::SHA256.hexdigest(PROMPT_VERSION)
]
input_fingerprint = Digest::SHA256.hexdigest(fingerprint_parts.join(':'))

if !force && File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date]) rescue nil
  if existing.is_a?(Hash) && existing['input_fingerprint'] == input_fingerprint
    $stderr.puts "Semantic segments up to date for #{source_filename} (fingerprint match). Skipping."
    puts output_path
    exit 0
  else
    $stderr.puts "Semantic segments stale for #{source_filename} — regenerating"
  end
end

# ─── Load transcript words ───────────────────────────────────────────────────

transcript_data = JSON.parse(File.read(transcript_path))
whisper_segments = transcript_data['segments'] || []

all_words = []
whisper_segments.each do |seg|
  words = seg['words'] || []
  words.each do |w|
    all_words << {
      'word'  => w['word'].to_s,
      'start' => w['start'].to_f,
      'end'   => w['end'].to_f
    }
  end
end

if all_words.size < 10
  $stderr.puts "Source #{source_filename} has #{all_words.size} words — passing through as single segment."
  single_seg = {
    'start'      => all_words.first['start'],
    'end'        => all_words.last['end'],
    'text'       => all_words.map { |w| w['word'] }.join(' '),
    'word_count' => all_words.size,
    'words'      => all_words
  }
  result = {
    'version'           => 1,
    'input_fingerprint' => input_fingerprint,
    'generated_at'      => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
    'model'             => 'passthrough',
    'source'            => source_filename,
    'language'          => language,
    'segments'          => [single_seg]
  }
  File.write(output_path, YAML.dump(result))
  discarded_result = {
    'version'           => 1,
    'input_fingerprint' => input_fingerprint,
    'generated_at'      => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
    'source'            => source_filename,
    'discarded'         => []
  }
  File.write(discarded_path, YAML.dump(discarded_result))
  puts output_path
  exit 0
end

# ─── Load VAD pauses ─────────────────────────────────────────────────────────

long_pauses = []
if has_vad
  sa_data = JSON.parse(File.read(speech_analysis_path))
  long_pauses = sa_data['long_pauses'] || []
end

# ─── Format duration ─────────────────────────────────────────────────────────

total_duration_s = all_words.last['end'] - all_words.first['start']
duration_mm = (total_duration_s / 60).floor
duration_ss = (total_duration_s % 60).round

# ─── System prompt (shared across chunks) ────────────────────────────────────

system_prompt = <<~SYSTEM
You are an editorial segmentation engine for video post-production.

Your job: read a word-level transcript with precise timestamps and identify
coherent editorial units — continuous stretches of speech an editor would
consider as a candidate clip for the final cut.

#{tone_context}

Editorial rules:
- A segment is "usable" if an editor would consider it for the cut. The bar
  is editorial viability, not perfection — a slightly rough delivery that
  contains a good point IS usable.
- A segment is "not-usable" if it's a restart, false start, aside to crew,
  mumble, reading notes to self, equipment check, or garbled speech that
  carries no editorial value.
- When the speaker restarts a thought, collapse to the final clean take.
  The earlier attempts go to discarded. If NO clean take exists (all attempts
  are partial), discard all of them.
- False starts: if a few words begin a thought that is immediately abandoned
  and restarted more completely, the false start goes to discarded and the
  complete version is one segment.
- Filler words (um, uh, like, you know, so) WITHIN an otherwise usable
  segment are KEPT in the segment — they are the speaker's natural speech
  pattern. Do not strip fillers. Segmentation decides boundaries, not word
  content.
- Single-word utterances that are not part of a sentence (e.g., "Cool.",
  "Hold.", stray "And.") go to discarded unless they serve a clear editorial
  function (e.g., a deliberate one-word close: "Period.").
- Segment boundaries must align exactly to word timestamps. segment.start =
  first_word.start, segment.end = last_word.end. Every word in the source
  must appear in exactly one segment (usable) or one discarded entry. No
  words may be dropped or invented.
- Use VAD long_pauses as hints for natural segment boundaries. A pause ≥1s
  between words is a strong signal for a segment break. But a pause alone
  does not determine usability — a 2-second pause followed by a clean
  thought is a segment boundary, not a discard.
- Preserve the speaker's rhetorical repetition. "No no no, listen" is
  intentional emphasis, not a stutter. When in doubt about whether repetition
  is rhetorical vs. disfluent, keep it (err toward usable).
- When a long pause (≥2s) occurs WITHIN an otherwise coherent thought, prefer
  to split into separate segments at the pause boundary rather than producing
  one very long segment. This gives the downstream editor finer-grained atoms
  to work with. A good target atom length is 5-30 seconds of speech.

Output format: YAML with two top-level keys:
- segments: array of usable segments, each with start, end, text, word_count, words[]
- discarded: array of not-usable segments, same shape plus a "reason" field

Each words[] entry has: word, start, end (matching the input exactly).

Every word from the input must appear in exactly one entry (segment or
discarded). This is a hard constraint — the output is invalid if any word
is missing or duplicated.
SYSTEM

seg_model = profile.dig('llm_routing', 'semantic_segment') || 'claude-opus-4-6'
pending_dir = File.join(library_dir, 'pending_llm_calls')

$stderr.puts '=' * 60
$stderr.puts "SEMANTIC SEGMENTATION — #{source_filename}"
$stderr.puts '=' * 60
$stderr.puts "  Words: #{all_words.size}, VAD pauses: #{long_pauses.size}, Duration: #{duration_mm}:#{format('%02d', duration_ss)}"

# ─── Helper: build user prompt for a word range ─────────────────────────────

def build_user_prompt(chunk_words, chunk_pauses, source_filename, language,
                      chunk_num: nil, chunk_total: nil, overlap: 0)
  chunk_duration_s = chunk_words.last['end'] - chunk_words.first['start']
  dur_mm = (chunk_duration_s / 60).floor
  dur_ss = (chunk_duration_s % 60).round

  words_block = +""
  chunk_words.each_with_index do |w, i|
    words_block << "#{i}: #{w['word']} [#{format('%.3f', w['start'])} - #{format('%.3f', w['end'])}]\n"
  end

  pauses_block = +""
  if chunk_pauses.any?
    chunk_pauses.each do |p|
      pauses_block << "#{format('%.3f', p['start'])} - #{format('%.3f', p['end'])} (#{format('%.1f', p['duration'])}s)\n"
    end
  else
    pauses_block << "(no VAD data available)\n"
  end

  chunk_context = ""
  if chunk_num && chunk_total && chunk_total > 1
    chunk_context = "Chunk: #{chunk_num} of #{chunk_total}\n"
    if chunk_num > 1
      chunk_context += "The first #{overlap} words of this chunk overlap with the previous chunk.\n"
    end
    if chunk_num < chunk_total
      chunk_context += "The last #{overlap} words of this chunk overlap with the next chunk.\n"
    end
    chunk_context += "Chunk boundaries are NOT source boundaries — apply normal editorial rules.\n\n"
  end

  <<~PROMPT
Source: #{source_filename}
Duration: #{dur_mm}:#{format('%02d', dur_ss)}
Language: #{language}
Total words: #{chunk_words.size}
#{chunk_context}
## VAD Long Pauses (silence regions)

#{pauses_block}
## Word-Level Transcript

#{words_block}
Segment the above transcript into usable and discarded groups.
Output YAML with `segments` and `discarded` arrays per the system prompt spec.
Respond with ONLY valid YAML. No markdown code fences.
PROMPT
end

# ─── Helper: call LLM and parse YAML response ───────────────────────────────

def call_and_parse(user_prompt, system_prompt, seg_model, pending_dir, call_name,
                   input_fingerprint, profile, library_dir, source_basename)
  prompt_total = user_prompt.length + system_prompt.length
  $stderr.puts "  Prompt: #{user_prompt.length} chars user + #{system_prompt.length} chars system (~#{(prompt_total / 4.0).ceil} tokens)"
  $stderr.puts "  Calling LLM (#{seg_model}) for #{call_name}..."

  begin
    response = LLMClient.call(user_prompt, call_type: 'semantic_segment', profile: profile,
                              model: seg_model, max_tokens: 65536,
                              pending_dir: pending_dir, call_name: call_name,
                              cached_system_prompt: system_prompt,
                              input_fingerprint: input_fingerprint)
  rescue LLMClient::Pending => e
    $stderr.puts e.message
    exit 2
  end

  yaml_text = response.gsub(/\A```ya?ml\s*/, '').gsub(/```\s*\z/, '').strip

  begin
    parsed = YAML.safe_load(yaml_text, permitted_classes: [Date])
  rescue Psych::SyntaxError => e
    $stderr.puts "  WARNING: YAML parse error: #{e.message}"
    $stderr.puts "  Attempting recovery..."
    fixed = yaml_text.gsub(/: ([^|>\n"'{].*:)/) { |m| ": \"#{$1.gsub('"', '\\"')}\"" }
    begin
      parsed = YAML.safe_load(fixed, permitted_classes: [Date])
      $stderr.puts "  Recovery successful"
    rescue Psych::SyntaxError => e2
      raw_path = File.join(library_dir, "#{call_name}_raw.txt")
      File.write(raw_path, response)
      abort "PIPELINE ABORT: LLM returned invalid YAML for #{call_name}.\n" \
            "Error: #{e2.message}\nRaw response saved: #{raw_path}"
    end
  end

  unless parsed.is_a?(Hash)
    raw_path = File.join(library_dir, "#{call_name}_raw.txt")
    File.write(raw_path, response)
    abort "PIPELINE ABORT: LLM response for #{call_name} is not a YAML hash. Raw saved: #{raw_path}"
  end

  { 'segments' => parsed['segments'] || [], 'discarded' => parsed['discarded'] || [], 'raw' => response }
end

# ─── Helper: find best VAD pause near target word index ──────────────────────

def find_split_pause(target_idx, all_words, long_pauses, search_radius: 500)
  min_idx = [target_idx - search_radius, 0].max
  max_idx = [target_idx + search_radius, all_words.size - 1].min
  time_min = all_words[min_idx]['start']
  time_max = all_words[max_idx]['end']

  # Find pauses in the time range, prefer ≥3s
  candidates = long_pauses.select { |p| p['start'] >= time_min && p['end'] <= time_max }
  big_pauses = candidates.select { |p| p['duration'] >= 3.0 }
  pool = big_pauses.any? ? big_pauses : candidates

  if pool.any?
    # Pick the one closest to target time
    target_time = all_words[target_idx]['start']
    best = pool.min_by { |p| (p['start'] - target_time).abs }
    # Find word index just after this pause
    split_idx = all_words.index { |w| w['start'] >= best['end'] }
    return split_idx || target_idx
  end

  # No pauses found — check inter-word gaps
  best_gap = 0
  best_idx = target_idx
  (min_idx...[max_idx, all_words.size - 1].min).each do |i|
    gap = all_words[i + 1]['start'] - all_words[i]['end']
    if gap > best_gap
      best_gap = gap
      best_idx = i + 1
    end
  end
  best_idx
end

# ─── Helper: compute chunk boundaries ────────────────────────────────────────

def compute_chunks(total_words, all_words, long_pauses)
  chunk_count = [2, ((total_words - CHUNK_OVERLAP) / 2000.0).ceil].max
  target_size = (total_words + (chunk_count - 1) * CHUNK_OVERLAP) / chunk_count

  # Compute split points (word indices where chunks divide)
  split_points = []
  (1...chunk_count).each do |i|
    # Target split at the boundary between chunk i-1 and chunk i
    target_idx = (target_size * i).round
    target_idx = [target_idx, total_words - 1].min
    split_idx = find_split_pause(target_idx, all_words, long_pauses)
    split_points << split_idx
  end

  # Build chunk word ranges with overlap
  chunks = []
  (0...chunk_count).each do |i|
    start_idx = i == 0 ? 0 : [split_points[i - 1] - CHUNK_OVERLAP, 0].max
    end_idx = i == chunk_count - 1 ? total_words - 1 : [split_points[i] - 1, total_words - 1].min
    chunks << { start: start_idx, end: end_idx, chunk_num: i + 1 }
  end

  $stderr.puts "  Chunking: #{chunk_count} chunks, target ~#{target_size} words each"
  chunks.each_with_index do |c, i|
    $stderr.puts "    Chunk #{i + 1}: words #{c[:start]}-#{c[:end]} (#{c[:end] - c[:start] + 1} words)"
  end

  { chunks: chunks, split_points: split_points, chunk_count: chunk_count }
end

# ─── Helper: merge chunk results ─────────────────────────────────────────────

def merge_chunks(chunk_results, chunk_info, all_words)
  split_points = chunk_info[:split_points]
  chunks = chunk_info[:chunks]
  disagreements = []

  # For each word, determine which chunk's judgment to use.
  # Words exclusive to a chunk: use that chunk.
  # Words in overlap region: use chunk whose interior is closer (midpoint rule).
  word_chunk_assignment = Array.new(all_words.size)

  chunks.each_with_index do |c, ci|
    (c[:start]..c[:end]).each do |wi|
      if word_chunk_assignment[wi].nil?
        word_chunk_assignment[wi] = ci
      else
        # Word is in overlap — determine which chunk gets it
        # Find the split point between the two chunks
        prev_ci = word_chunk_assignment[wi]
        sp = split_points[[prev_ci, ci].max - 1]
        midpoint = sp - CHUNK_OVERLAP / 2
        word_chunk_assignment[wi] = wi < midpoint ? prev_ci : ci
      end
    end
  end

  # Build per-word assignment: for each word, which chunk and what kind (segment/discarded)
  # First, build a lookup: for each chunk, which local word index maps to which entry
  chunk_word_entries = []
  chunk_results.each_with_index do |result, ci|
    chunk = chunks[ci]
    chunk_offset = chunk[:start]  # global index = local index + offset
    entry_map = {}  # local_word_idx => { type: :segment/:discarded, entry: ... }

    (result['segments'] || []).each do |seg|
      (seg['words'] || []).each_with_index do |w, wi|
        # Find local index by position
        local_idx = nil
        seg_words = seg['words']
        # The entry covers a contiguous range; find local index from word timing
      end
    end

    # Simpler approach: build entries with global word indices
    entries = []
    local_idx = 0

    # Map all entries (segments + discarded) with their global word ranges
    all_entries = []
    (result['segments'] || []).each { |s| all_entries << { entry: s, type: :segment } }
    (result['discarded'] || []).each { |d| all_entries << { entry: d, type: :discarded } }
    all_entries.sort_by! { |e| e[:entry]['start'] }

    # Assign global indices to each entry's words
    global_idx = chunk_offset
    all_entries.each do |ae|
      entry_words = ae[:entry]['words'] || []
      ae[:global_start] = global_idx
      ae[:global_end] = global_idx + entry_words.size - 1
      ae[:center] = (ae[:global_start] + ae[:global_end]) / 2.0
      global_idx += entry_words.size
    end

    chunk_word_entries << all_entries
  end

  # Now merge: for each chunk pair's overlap, resolve entries
  merged_entries = []

  chunks.each_with_index do |c, ci|
    entries = chunk_word_entries[ci]
    entries.each do |ae|
      # Determine if this entry's words are all assigned to this chunk
      center_word = ae[:center].round
      center_word = [[center_word, 0].max, all_words.size - 1].min
      assigned_chunk = word_chunk_assignment[center_word]

      if assigned_chunk == ci
        merged_entries << ae
      else
        # This entry's center word is assigned to a different chunk — skip it
        # Check if the other chunk has matching coverage (disagreement detection)
        other_entries = chunk_word_entries[assigned_chunk]
        other_covering = other_entries.select { |oe|
          oe[:global_start] <= ae[:global_start] && oe[:global_end] >= ae[:global_end]
        }
        if other_covering.any? && other_covering.first[:type] != ae[:type]
          disagreements << {
            words: "#{ae[:global_start]}-#{ae[:global_end]}",
            chunk_a: ci + 1, type_a: ae[:type],
            chunk_b: assigned_chunk + 1, type_b: other_covering.first[:type],
            winner: assigned_chunk + 1
          }
        end
      end
    end
  end

  # Sort merged entries chronologically
  merged_entries.sort_by! { |e| e[:entry]['start'] }

  # Separate into segments and discarded
  segments = merged_entries.select { |e| e[:type] == :segment }.map { |e| e[:entry] }
  discarded = merged_entries.select { |e| e[:type] == :discarded }.map { |e| e[:entry] }

  # Log disagreements
  if disagreements.any?
    $stderr.puts "  CHUNK DISAGREEMENTS: #{disagreements.size} overlap regions had conflicting judgments"
    disagreements.each do |d|
      $stderr.puts "    Words #{d[:words]}: chunk #{d[:chunk_a]} says #{d[:type_a]}, " \
                   "chunk #{d[:chunk_b]} says #{d[:type_b]}. Using chunk #{d[:winner]} (interior)."
    end
  end

  { 'segments' => segments, 'discarded' => discarded, 'disagreements' => disagreements.size }
end

# ─── Determine chunking strategy ─────────────────────────────────────────────

needs_chunking = all_words.size > CHUNK_THRESHOLD
segments = nil
discarded = nil
response_for_debug = nil

if needs_chunking
  # ─── Chunked path (D5.12) ─────────────────────────────────────────────────
  chunk_info = compute_chunks(all_words.size, all_words, long_pauses)
  chunk_results = []

  chunk_info[:chunks].each_with_index do |c, ci|
    chunk_words = all_words[c[:start]..c[:end]]
    chunk_time_start = chunk_words.first['start']
    chunk_time_end = chunk_words.last['end']
    chunk_pauses = long_pauses.select { |p| p['start'] >= chunk_time_start && p['end'] <= chunk_time_end }

    call_name = "semantic_segment_#{source_basename}_chunk#{ci + 1}"
    user_prompt = build_user_prompt(chunk_words, chunk_pauses, source_filename, language,
                                    chunk_num: ci + 1, chunk_total: chunk_info[:chunk_count],
                                    overlap: CHUNK_OVERLAP)

    result = call_and_parse(user_prompt, system_prompt, seg_model, pending_dir, call_name,
                            input_fingerprint, profile, library_dir, source_basename)

    # Per-chunk word count validation
    chunk_word_count = 0
    (result['segments'] || []).each { |s| chunk_word_count += (s['words'] || []).size }
    (result['discarded'] || []).each { |d| chunk_word_count += (d['words'] || []).size }

    if chunk_word_count != chunk_words.size
      diff = chunk_words.size - chunk_word_count
      raw_path = File.join(library_dir, "#{call_name}_raw.txt")
      File.write(raw_path, result['raw'])
      abort "SEGMENTATION ABORT: Chunk #{ci + 1} word count mismatch — " \
            "input #{chunk_words.size}, output #{chunk_word_count}. " \
            "#{diff.abs} words #{diff > 0 ? 'lost' : 'added'}. Raw saved: #{raw_path}"
    end

    $stderr.puts "  Chunk #{ci + 1}: #{(result['segments'] || []).size} usable, #{(result['discarded'] || []).size} discarded"
    chunk_results << result
  end

  # Merge chunks
  $stderr.puts "  Merging #{chunk_results.size} chunks..."
  merged = merge_chunks(chunk_results, chunk_info, all_words)
  segments = merged['segments']
  discarded = merged['discarded']
  response_for_debug = chunk_results.map { |r| r['raw'] }.join("\n---CHUNK_BOUNDARY---\n")
else
  # ─── Single-call path (≤3500 words) ───────────────────────────────────────
  call_name = "semantic_segment_#{source_basename}"
  user_prompt = build_user_prompt(all_words, long_pauses, source_filename, language)

  result = call_and_parse(user_prompt, system_prompt, seg_model, pending_dir, call_name,
                          input_fingerprint, profile, library_dir, source_basename)
  segments = result['segments']
  discarded = result['discarded']
  response_for_debug = result['raw']
end

# ─── Strict output validation (D5.15) ────────────────────────────────────────
# All checks run before any file is written. Failure = abort loud, no partial output.

def validation_abort(msg, response, library_dir, source_basename)
  raw_path = File.join(library_dir, "semantic_segment_#{source_basename}_raw.txt")
  File.write(raw_path, response)
  abort "SEGMENTATION ABORT: #{msg}\nRaw response saved: #{raw_path}"
end

# 1. Word coverage exact match
output_word_count = 0
segments.each { |s| output_word_count += (s['words'] || []).size }
discarded.each { |d| output_word_count += (d['words'] || []).size }

if output_word_count != all_words.size
  diff = all_words.size - output_word_count
  validation_abort(
    "Word count mismatch — input #{all_words.size}, output #{output_word_count}. " \
    "#{diff.abs} words #{diff > 0 ? 'lost' : 'added'}.",
    response_for_debug, library_dir, source_basename
  )
end

# 2. Segment boundary consistency (start = first word start, end = last word end)
(segments + discarded).each_with_index do |entry, i|
  words = entry['words'] || []
  next if words.empty?
  label = entry.key?('reason') ? "discarded[#{i - segments.size}]" : "segment[#{i}]"
  expected_start = words.first['start']
  expected_end = words.last['end']
  if entry['start'] != expected_start
    validation_abort(
      "#{label} start=#{entry['start']} but first word start=#{expected_start}",
      response_for_debug, library_dir, source_basename
    )
  end
  if entry['end'] != expected_end
    validation_abort(
      "#{label} end=#{entry['end']} but last word end=#{expected_end}",
      response_for_debug, library_dir, source_basename
    )
  end
end

# 3. Chronological ordering within segments
segments.each_cons(2) do |a, b|
  if a['end'] > b['start']
    validation_abort(
      "Segments not chronological: segment ending at #{a['end']} overlaps segment starting at #{b['start']}. " \
      "Texts: '#{a['text'][0..60]}...' / '#{b['text'][0..60]}...'",
      response_for_debug, library_dir, source_basename
    )
  end
end

# 4. Chronological ordering within discarded
discarded.each_cons(2) do |a, b|
  if a['end'] > b['start']
    validation_abort(
      "Discarded not chronological: entry ending at #{a['end']} overlaps entry starting at #{b['start']}.",
      response_for_debug, library_dir, source_basename
    )
  end
end

# 5. Non-overlapping between segments and discarded (interleaved check)
all_entries = (segments.map { |s| { start: s['start'], end: s['end'], type: 'segment' } } +
               discarded.map { |d| { start: d['start'], end: d['end'], type: 'discarded' } })
              .sort_by { |e| e[:start] }

all_entries.each_cons(2) do |a, b|
  if a[:end] > b[:start]
    validation_abort(
      "Overlap between #{a[:type]} (end=#{a[:end]}) and #{b[:type]} (start=#{b[:start]})",
      response_for_debug, library_dir, source_basename
    )
  end
end

$stderr.puts "  Validation: all checks passed (word coverage, boundaries, ordering, no overlaps)"

# ─── Warn if over-discard ────────────────────────────────────────────────────

discarded_word_count = 0
discarded.each { |d| discarded_word_count += (d['words'] || []).size }
discard_pct = (discarded_word_count.to_f / all_words.size * 100).round(1)

if discard_pct > 80
  $stderr.puts "WARNING: #{discard_pct}% of source #{source_filename} marked not-usable " \
               "(#{discarded_word_count}/#{all_words.size} words). Review discarded_segments.yaml."
end

# ─── Write output files ─────────────────────────────────────────────────────

result = {
  'version'           => 1,
  'input_fingerprint' => input_fingerprint,
  'generated_at'      => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'model'             => seg_model,
  'source'            => source_filename,
  'language'          => language,
  'segments'          => segments
}

File.write(output_path, YAML.dump(result))

discarded_result = {
  'version'           => 1,
  'input_fingerprint' => input_fingerprint,
  'generated_at'      => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'source'            => source_filename,
  'discarded'         => discarded
}

File.write(discarded_path, YAML.dump(discarded_result))

$stderr.puts "---"
$stderr.puts "Segmentation complete: #{segments.size} usable segments, #{discarded.size} discarded"
$stderr.puts "  Usable words: #{all_words.size - discarded_word_count} (#{(100 - discard_pct).round(1)}%)"
$stderr.puts "  Discarded words: #{discarded_word_count} (#{discard_pct}%)"
$stderr.puts "  Output: #{output_path}"
puts output_path
