#!/usr/bin/env ruby
# Script-driven arrangement: matches script beats to transcript regions,
# picks cleanest take, outputs arrangement YAML in beat order.
#
# Usage: ruby scripts/arrange_to_script.rb --library <name> --short <short_id> [options]
#
# Options:
#   --profile <name>     Override profile (default: auto-detect from library name)
#   --no-review          Skip interactive review gate
#   --llm-mode api|claude_code  (default: api)

require 'yaml'
require 'json'
require 'date'
require 'fileutils'

require_relative 'library_resolver'
require_relative 'load_profile'
require_relative 'llm_client'

# --- Parse args ---

library_name = nil
short_id = nil
profile_name = nil
no_review = false

i = 0
while i < ARGV.size
  case ARGV[i]
  when '--library'  then library_name = ARGV[i += 1]
  when '--short'    then short_id = ARGV[i += 1]
  when '--profile'  then profile_name = ARGV[i += 1]
  when '--no-review' then no_review = true
  when '--llm-mode' then LLMClient.mode = ARGV[i += 1]
  end
  i += 1
end

abort "Usage: ruby scripts/arrange_to_script.rb --library <name> --short <short_id> [--profile <name>] [--no-review] [--llm-mode api|claude_code]" unless library_name && short_id

# --- Resolve library ---

lib_dir = LibraryResolver.resolve(library_name)
lib_yaml_path = File.join(lib_dir, 'library.yaml')
abort "library.yaml not found in #{lib_dir}" unless File.exist?(lib_yaml_path)

lib = YAML.safe_load(File.read(lib_yaml_path), permitted_classes: [Date])
videos = lib['videos'] || []

# Multi-source guard
if videos.size > 1
  abort "Multi-source script arrangement not yet supported in lean Branch A — use --short to target one short at a time, ensure script_parsed.yaml has source per short."
end

video = videos.first
abort "No videos found in library.yaml" unless video

source_path = video['path']
sync_offset = video.dig('sync_audio', 'offset')&.to_f || 0.0
source_duration = video['duration']&.to_f

# --- Load profile ---

profile = if profile_name
            load_profile_by_name(profile_name)
          else
            load_profile(lib['library_name'] || library_name)
          end

# --- Load script_parsed.yaml ---

transcripts_dir = File.join(lib_dir, 'transcripts')
script_parsed_path = File.join(transcripts_dir, 'script_parsed.yaml')
abort "script_parsed.yaml not found at #{script_parsed_path}" unless File.exist?(script_parsed_path)

script_parsed = YAML.safe_load(File.read(script_parsed_path), permitted_classes: [Date])

# Find the target short's beats
beats = nil
if script_parsed['format'] == 'multi_short' && script_parsed['shorts']
  # Match by number (short_01 → 1, short_3 → 3, or bare "3")
  target_num = short_id.gsub(/\D/, '').to_i
  target_short = script_parsed['shorts'].find { |s| s['number'] == target_num }
  if target_short
    beats = target_short['beats']
    $stderr.puts "Short: ##{target_short['number']} — #{target_short['title']}"
  end
elsif script_parsed['format'] == 'single' && script_parsed['beats']
  # Single format: short_id selects a section by label match or index
  beats = script_parsed['beats']
  $stderr.puts "Script format: single (all beats)"
end

abort "No beats found for short '#{short_id}' in script_parsed.yaml" unless beats && !beats.empty?

# --- Load transcript ---

tr_name = video['cleaned_transcript'] || video['transcript']
abort "No transcript found for #{File.basename(source_path)}" unless tr_name

tr_path = File.join(transcripts_dir, tr_name)
abort "Transcript file not found: #{tr_path}" unless File.exist?(tr_path)

transcript = JSON.parse(File.read(tr_path))
words = transcript['segments'].flat_map { |s| s['words'] || [] }
$stderr.puts "Transcript: #{words.size} words"

# --- Load prosody (optional) ---

prosody_path = File.join(lib_dir, 'prosody.yaml')
prosody_words = nil
if File.exist?(prosody_path)
  prosody = YAML.safe_load(File.read(prosody_path))
  prosody_words = prosody.dig(source_path, 'words')
  $stderr.puts "Prosody: #{prosody_words.size} words" if prosody_words
else
  $stderr.puts "Prosody: not found (skipping prosody annotations)"
end

# --- Build transcript block with prosody annotations ---

def build_annotated_transcript(words, prosody_words)
  # Build index by word_idx for O(1) lookup
  prosody_idx = {}
  if prosody_words
    prosody_words.each { |pw| prosody_idx[pw['word_idx']] = pw }
  end

  lines = []
  words.each_with_index do |w, i|
    next unless w['start'] && w['end']
    text = w['word']
    ts = "[#{format('%.2f', w['start'])}-#{format('%.2f', w['end'])}]"

    annotations = []
    pw = prosody_idx[i]
    if pw
      annotations << 'STUMBLE' if pw['stumble_marker']
      annotations << 'MID_BREAK' if pw['mid_word_break']
      if pw['trailing_pause_ms'] && pw['trailing_pause_ms'] > 300
        annotations << "PAUSE:#{pw['trailing_pause_ms']}ms"
      end
    end

    ann_str = annotations.empty? ? '' : " {#{annotations.join(',')}}"
    lines << "#{ts} #{text}#{ann_str}"
  end
  lines.join("\n")
end

annotated_transcript = build_annotated_transcript(words, prosody_words)

# --- Build tone context ---

tone_context = build_compact_tone_context(profile)

# --- Build LLM prompt ---

beats_block = beats.each_with_index.map do |b, i|
  "Beat #{i + 1} (#{b['role']}): #{b['text']}"
end.join("\n\n")

prompt = <<~PROMPT
You are a Branch A script-driven video editor. Your job: match script beats to
transcript regions. Beat order is fixed by the script. Within each beat, pick
the cleanest take. Multi-clip stitching is allowed within a beat when a single
line was delivered across two takes.

## Take Selection Priority (when multiple candidates exist)
1. Fewest stumble_markers (STUMBLE annotations) in the span
2. No mid_word_break (MID_BREAK annotations) inside the chosen span
3. Clean trailing pause (PAUSE:>200ms) at span end — natural breath point

## Script Beats (target short: #{short_id})

#{beats_block}

## Transcript (word-level timestamps + prosody)

#{annotated_transcript}

## Output

Return STRICT JSON (no markdown fences, no prose). Schema:

{
  "beats": [
    {
      "beat_id": "hook",
      "type": "hook",
      "script_text": "...",
      "clips": [
        {
          "source": "#{File.basename(source_path)}",
          "t_in": 0.0,
          "t_out": 0.0,
          "transcript_match": "actual words from transcript",
          "take_id": null,
          "notes": null
        }
      ]
    }
  ]
}

Rules:
- t_in and t_out are in transcript/WAV time domain (use timestamps from the transcript directly)
- Every beat from the script MUST appear in output, in script order
- beat_id = role (hook, talking_point, close) with suffix if duplicates (talking_point_2, etc.)
- If a beat cannot be matched, include it with empty clips array and notes explaining why
- Prefer a single clip per beat; only stitch if the speaker genuinely split the line across takes
PROMPT

cached_system = tone_context.empty? ? nil : tone_context
prompt_total = prompt.length + (cached_system&.length || 0)
$stderr.puts "Prompt: #{prompt.length} chars + #{cached_system&.length || 0} system (~#{(prompt_total / 4.0).ceil} tokens)"

# --- LLM call ---

$stderr.puts "\nCalling LLM (arrangement)..."
pending_dir = File.join(lib_dir, 'pending_llm_calls')

begin
  response = LLMClient.call(prompt, call_type: 'arrangement', profile: profile, max_tokens: 16384,
                            pending_dir: pending_dir, call_name: "arrange_#{short_id}",
                            cached_system_prompt: cached_system)
rescue LLMClient::Pending => e
  $stderr.puts e.message
  exit 2
end

# --- Parse JSON response ---

json_text = response.gsub(/\A```json?\s*/, '').gsub(/```\s*\z/, '').strip
begin
  result = JSON.parse(json_text)
rescue JSON::ParserError => e
  abort "JSON parse error in LLM response: #{e.message}\nRaw response (first 500 chars):\n#{response[0..500]}"
end

result_beats = result['beats']
abort "LLM response missing 'beats' array" unless result_beats.is_a?(Array)

# --- Validate ---

errors = []
result_beats.each_with_index do |rb, i|
  (rb['clips'] || []).each_with_index do |clip, j|
    t_in = clip['t_in'].to_f
    t_out = clip['t_out'].to_f

    if t_in >= t_out
      errors << "Beat #{i + 1} clip #{j + 1}: t_in (#{t_in}) >= t_out (#{t_out})"
    end
    if t_in < 0
      errors << "Beat #{i + 1} clip #{j + 1}: t_in (#{t_in}) is negative"
    end
    if source_duration && t_out > source_duration + sync_offset + 1.0
      errors << "Beat #{i + 1} clip #{j + 1}: t_out (#{t_out}) exceeds source duration (#{source_duration + sync_offset})"
    end
  end
end

unless errors.empty?
  abort "Validation errors in LLM response:\n  #{errors.join("\n  ")}"
end

$stderr.puts "Validated: #{result_beats.size} beats, #{result_beats.sum { |b| (b['clips'] || []).size }} clips"

# --- Review gate ---

unless no_review
  $stderr.puts "\n=== ARRANGEMENT REVIEW ==="
  result_beats.each_with_index do |rb, i|
    clips = rb['clips'] || []
    clip_summary = clips.map { |c| "#{format('%.1f', c['t_in'])}–#{format('%.1f', c['t_out'])}s" }.join(' + ')
    first_words = clips.first&.dig('transcript_match')&.split&.first(5)&.join(' ')
    last_words = clips.last&.dig('transcript_match')&.split&.last(5)&.join(' ')
    $stderr.puts "  #{i + 1}. [#{rb['type']}] #{clip_summary}"
    $stderr.puts "     First: \"#{first_words}...\"" if first_words
    $stderr.puts "     Last:  \"...#{last_words}\"" if last_words
    $stderr.puts "     Notes: #{clips.map { |c| c['notes'] }.compact.join('; ')}" if clips.any? { |c| c['notes'] }
  end

  $stderr.print "\nAccept? (y/n): "
  answer = $stdin.gets&.strip&.downcase
  abort "Arrangement rejected." unless answer == 'y' || answer == 'yes'
end

# --- Write output ---

output = {
  'short_id' => short_id,
  'source_video' => source_path,
  'sync_offset' => sync_offset,
  'beats' => result_beats
}

output_path = File.join(lib_dir, "arrangement_#{short_id}.yaml")
File.write(output_path, YAML.dump(output))
$stderr.puts "Wrote #{output_path}"
puts output_path
