#!/usr/bin/env ruby
# Phase 1.35 — Semantic Segmentation (Session 5).
# LLM-powered, per-source-video. Reads raw word-level transcript + VAD pauses,
# produces coherent editorial segments (usable) and a discarded audit file.
#
# Replaces transcript_cleanup.rb. Atoms produced here are inviolate — no
# downstream script modifies their boundaries (D5.10).
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
  source_filename
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

# ─── Build prompt ────────────────────────────────────────────────────────────

$stderr.puts '=' * 60
$stderr.puts "SEMANTIC SEGMENTATION — #{source_filename}"
$stderr.puts '=' * 60
$stderr.puts "  Words: #{all_words.size}, VAD pauses: #{long_pauses.size}, Duration: #{duration_mm}:#{format('%02d', duration_ss)}"

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

# Build word-level transcript block (compact: one line per word)
words_block = +""
all_words.each_with_index do |w, i|
  words_block << "#{i}: #{w['word']} [#{format('%.3f', w['start'])} - #{format('%.3f', w['end'])}]\n"
end

# Build VAD pauses block
pauses_block = +""
if long_pauses.any?
  long_pauses.each do |p|
    pauses_block << "#{format('%.3f', p['start'])} - #{format('%.3f', p['end'])} (#{format('%.1f', p['duration'])}s)\n"
  end
else
  pauses_block << "(no VAD data available)\n"
end

user_prompt = <<~PROMPT
Source: #{source_filename}
Duration: #{duration_mm}:#{format('%02d', duration_ss)}
Language: #{language}
Total words: #{all_words.size}

## VAD Long Pauses (silence regions)

#{pauses_block}
## Word-Level Transcript

#{words_block}
Segment the above transcript into usable and discarded groups.
Output YAML with `segments` and `discarded` arrays per the system prompt spec.
Respond with ONLY valid YAML. No markdown code fences.
PROMPT

prompt_total = user_prompt.length + system_prompt.length
$stderr.puts "  Prompt: #{user_prompt.length} chars user + #{system_prompt.length} chars system (~#{(prompt_total / 4.0).ceil} tokens)"

# ─── LLM call ───────────────────────────────────────────────────────────────

seg_model = profile.dig('llm_routing', 'semantic_segment') || 'claude-opus-4-6'
$stderr.puts "  Calling LLM (#{seg_model}) for segmentation..."

pending_dir = File.join(library_dir, 'pending_llm_calls')
call_name = "semantic_segment_#{source_basename}"

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

# ─── Parse response ──────────────────────────────────────────────────────────

yaml_text = response.gsub(/\A```ya?ml\s*/, '').gsub(/```\s*\z/, '').strip

begin
  parsed = YAML.safe_load(yaml_text, permitted_classes: [Date])
rescue Psych::SyntaxError => e
  $stderr.puts "  WARNING: YAML parse error: #{e.message}"
  $stderr.puts "  Attempting recovery..."

  # Try fixing unquoted colons in strings
  fixed = yaml_text.gsub(/: ([^|>\n"'{].*:)/) { |m| ": \"#{$1.gsub('"', '\\"')}\"" }
  begin
    parsed = YAML.safe_load(fixed, permitted_classes: [Date])
    $stderr.puts "  Recovery successful"
  rescue Psych::SyntaxError => e2
    raw_path = File.join(library_dir, "semantic_segment_#{source_basename}_raw.txt")
    File.write(raw_path, response)
    abort "PIPELINE ABORT: LLM returned invalid YAML that could not be recovered.\n" \
          "Error: #{e2.message}\nRaw response saved: #{raw_path}\n\n" \
          "Response (first 500 chars):\n#{yaml_text[0..500]}"
  end
end

unless parsed.is_a?(Hash)
  raw_path = File.join(library_dir, "semantic_segment_#{source_basename}_raw.txt")
  File.write(raw_path, response)
  abort "PIPELINE ABORT: LLM response is not a YAML hash. Raw saved: #{raw_path}"
end

segments = parsed['segments'] || []
discarded = parsed['discarded'] || []

# ─── Validate word coverage ──────────────────────────────────────────────────

output_word_count = 0
segments.each { |s| output_word_count += (s['words'] || []).size }
discarded.each { |d| output_word_count += (d['words'] || []).size }

if output_word_count != all_words.size
  diff = all_words.size - output_word_count
  raw_path = File.join(library_dir, "semantic_segment_#{source_basename}_raw.txt")
  File.write(raw_path, response)
  abort "SEGMENTATION ABORT: Word count mismatch — input #{all_words.size}, output #{output_word_count}. " \
        "#{diff.abs} words #{diff > 0 ? 'lost' : 'added'}. Raw saved: #{raw_path}"
end

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
