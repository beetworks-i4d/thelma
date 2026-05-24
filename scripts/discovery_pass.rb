#!/usr/bin/env ruby
# Phase 2 — Discovery Pass (Session 3).
# Single LLM call. Reads enriched segments_classified.yaml, emits discovery_pass.yaml
# with ranked thesis candidates, clip_groups, throughlines, and reserved visual_context.
# Replaces classify() + semantic_ingest.rb.
#
# Usage: ruby scripts/discovery_pass.rb --library <name> [options]
# Output: libraries/<name>/discovery_pass.yaml

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
profile_name = nil
skip_review  = false
llm_mode     = nil
duration_target = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'   then args.shift; library_name    = args.shift
  when '--profile'   then args.shift; profile_name    = args.shift
  when '--no-review' then args.shift; skip_review     = true
  when '--llm-mode'  then args.shift; llm_mode        = args.shift
  when '--duration'  then args.shift; duration_target  = args.shift
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/discovery_pass.rb --library <name> [--profile <name>] " \
          "[--no-review] [--llm-mode api|claude_code] [--duration mm:ss]"
  end
end
abort "Usage: ruby scripts/discovery_pass.rb --library <name>" unless library_name

LLMClient.mode = llm_mode.to_sym if llm_mode

# ─── Load library + profile ─────────────────────────────────────────────────

library_dir = LibraryResolver.resolve(library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

library_yaml_path = File.join(library_dir, 'library.yaml')
abort "library.yaml not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
videos  = library['videos'] || []

profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)
tone_guide = load_tone_guide(profile)
tone_context = build_tone_context(profile, tone_guide)

segments_path = File.join(library_dir, 'segments_classified.yaml')
output_path   = File.join(library_dir, 'discovery_pass.yaml')
pending_dir   = File.join(library_dir, 'pending_llm_calls')

# ─── Load segments ──────────────────────────────────────────────────────────

abort "PIPELINE ABORT: segments_classified.yaml not found — run extract_segments.rb first" unless File.exist?(segments_path)

segments_data = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])
segments = segments_data['segments'] || []
abort "PIPELINE ABORT: No segments in segments_classified.yaml" if segments.empty?

# Validate enrichment: acoustic fields should be populated after Phase 1.5c
unenriched = segments.select { |s| s['audio_profile'].nil? && s['acoustic_pattern'].nil? }
if unenriched.size == segments.size
  abort "PIPELINE ABORT: No segments have acoustic features — run audio_emotion.rb (Phase 1.5c) first"
end

profile_name_resolved = profile_name || find_profile_match(library_name) || '_default'

# ─── Cache check ─────────────────────────────────────────────────────────────

cache_parts = [
  Digest::SHA256.hexdigest(File.read(segments_path)),
  profile_name_resolved,
  duration_target.to_s
]
input_fingerprint = Digest::SHA256.hexdigest(cache_parts.join(':'))

if File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date]) rescue nil
  if existing.is_a?(Hash) && existing['input_fingerprint'] == input_fingerprint
    if existing['selected_thesis']
      $stderr.puts "discovery_pass.yaml up to date with selected thesis. Skipping."
      puts output_path
      exit 0
    else
      # Cache valid but no thesis selected — run review gate only
      $stderr.puts "discovery_pass.yaml cached but no thesis selected — running review gate"
      # Jump to review gate (loaded from existing)
      result = existing
      goto_review = true
    end
  end
end

goto_review ||= false

unless goto_review
  # ─── Build prompt ────────────────────────────────────────────────────────────

  $stderr.puts '=' * 60
  $stderr.puts "DISCOVERY PASS — #{library_name}"
  $stderr.puts '=' * 60

  # Library metadata
  source_count = videos.size
  total_raw_secs = segments.last ? segments.last['e'].to_f : 0
  # Better: sum per-source durations
  sources = segments.map { |s| s['source'] }.uniq
  per_source_dur = {}
  segments.each do |s|
    per_source_dur[s['source']] ||= 0
    dur = s['e'].to_f - s['t'].to_f
    per_source_dur[s['source']] = [per_source_dur[s['source']], s['e'].to_f].max
  end
  total_raw_secs = per_source_dur.values.sum
  total_dur_str = format('%d:%02d', (total_raw_secs / 60).to_i, (total_raw_secs % 60).to_i)

  # Enriched segments table
  segments_block = +""
  segments.each do |s|
    dur = (s['e'].to_f - s['t'].to_f).round(1)
    line = "#{s['id']} | #{s['source']} | #{s['t']}-#{s['e']} (#{dur}s)"
    line << " | #{s['acoustic_pattern']}" if s['acoustic_pattern']
    line << " | energy=#{s['audio_energy']}" if s['audio_energy']
    line << " | pitch=#{s['audio_pitch_trend']}" if s['audio_pitch_trend']
    line << " | rate=#{s['audio_speaking_rate']}" if s['audio_speaking_rate']
    # Prosody
    line << " | stumbles=#{s['stumble_count']}" if s['stumble_count'] && s['stumble_count'] > 0
    line << " | max_pause=#{s['max_within_segment_pause_ms']}ms" if s['max_within_segment_pause_ms'] && s['max_within_segment_pause_ms'] > 300
    line << "\n  #{s['text']}"
    segments_block << line << "\n\n"
  end

  # Duration constraint
  duration_block = if duration_target
    "## Duration Target\nTarget runtime: #{duration_target} (±30 seconds).\n" \
    "ONLY return theses whose estimated runtime falls within this window.\n" \
    "If no thesis qualifies, return an empty theses list and a one-line `theses_filtered_note` explaining why.\n"
  else
    ""
  end

  # Editorial bias (D9)
  editorial_frame = <<~EDITORIAL
    ## Editorial Frame
    Aim for the tightest, most engaging cut the material supports. Err shorter when possible.
    Texture, asides, and examples earn their place when they meaningfully advance OR meaningfully
    enrich the video AND are engaging on their own merits. Bar is "earns its seconds," not
    "serves the thesis exclusively."
  EDITORIAL

  prompt = <<~PROMPT
    You are a senior video editor doing a discovery pass on raw footage. Your job is to understand
    the material and identify the strongest possible videos that could be cut from it.

    ## Library
    Sources: #{sources.size} video(s), #{segments.size} segments, ~#{total_dur_str} raw footage
    Profile: #{profile_name_resolved}

    #{editorial_frame}
    #{duration_block}
    ## Enriched Segments

    #{segments_block}

    ## Task

    Analyze all segments and produce:

    1. **Theses** (up to 5, ranked by strength, minimum 1):
       Each thesis is a potential video that could be cut from this material.
       - `id`: thesis_001, thesis_002, etc.
       - `logline`: 2-3 sentences — a condensed claim + arc-in-motion. Not a summary; a claim with story shape.
       - `duration`: estimated runtime (e.g. "7:20")#{duration_target ? ". Annotate fit vs target: \"7:20, within #{duration_target} target\"" : ''}
       - `shape_and_risk`: one line — emotional arc + failure mode of this cut.

    2. **Clip groups** — relational segment groupings. Five types:
       - `alternate_takes`: same content said multiple times; include `selection_guidance` with `recommended` seg_id and `reason`
       - `setup_payoff`: segments that must travel together (setup → payoff pair)
       - `tangent`: asides that humanize or enrich but aren't core thesis
       - `bridge`: connective tissue between ideas
       - `run-on`: segments that bleed into each other and should be kept contiguous
       Express ONLY relationships the material actually exhibits. Don't invent.
       Each clip_group has: `id` (cg_001...), `type`, `segments` (list of seg_ids), `theme`, `selection_guidance` (or null), `trim_notes` (or null).

    3. **Throughlines** — narrative loops that open and close across the video:
       - `id`: tl_001, tl_002, etc.
       - `theme`: what question/tension this loop tracks
       - `open`: seg_id where it opens
       - `middle`: ordered list of seg_ids that develop it
       - `close`: seg_id where it resolves
       - `distance_guidance`: how far apart open and close should be in the final cut
       - `notes`: any nesting or special handling
       Nested sub-loops get their own throughline entry referenced by id.

    4. **Visual context**: set `mode: null`, `summary: null`, `visual_groups: []` (reserved for future).

    ## Output Format

    Respond with ONLY valid YAML. No markdown code fences. Use this exact schema:

    theses:
      - id: thesis_001
        logline: |
          [2-3 sentences]
        duration: "M:SS"
        shape_and_risk: |
          [one line]

    clip_groups:
      - id: cg_001
        type: alternate_takes
        segments: [seg_004, seg_007, seg_011]
        theme: "short description"
        selection_guidance:
          recommended: seg_011
          reason: "why this take"
        trim_notes: "any trim notes or null"

    throughlines:
      - id: tl_001
        theme: "what this loop tracks"
        open: seg_023
        middle: [seg_031, seg_044]
        close: seg_058
        distance_guidance: "timing guidance"
        notes: "any notes"

    visual_context:
      mode: null
      summary: null
      visual_groups: []
  PROMPT

  # Tone context goes to system message with prompt caching
  cached_system = tone_context.empty? ? nil : tone_context
  prompt_total = prompt.length + (cached_system&.length || 0)
  $stderr.puts "  Prompt: #{prompt.length} chars + #{cached_system&.length || 0} system (~#{(prompt_total / 4.0).ceil} tokens)"

  # ─── LLM call ──────────────────────────────────────────────────────────────

  discovery_model = profile.dig('llm_routing', 'discovery_pass') || 'claude-opus-4-6'
  $stderr.puts "  Calling LLM (#{discovery_model}) for discovery pass..."

  begin
    response = LLMClient.call(prompt, call_type: 'discovery_pass', profile: profile,
                              model: discovery_model, max_tokens: 32768,
                              pending_dir: pending_dir, call_name: 'discovery_pass',
                              cached_system_prompt: cached_system,
                              input_fingerprint: input_fingerprint)
  rescue LLMClient::Pending => e
    $stderr.puts e.message
    exit 2
  end

  # ─── Parse response ────────────────────────────────────────────────────────

  yaml_text = response.gsub(/\A```ya?ml\s*/, '').gsub(/```\s*\z/, '').strip

  begin
    result = YAML.safe_load(yaml_text, permitted_classes: [Date])
  rescue Psych::SyntaxError => e
    $stderr.puts "  WARNING: YAML parse error: #{e.message}"
    $stderr.puts "  Attempting recovery..."

    # Common fix: unescaped colons in strings
    fixed = yaml_text.gsub(/: ([^|>\n"'{].*:)/) { |m| ": \"#{$1.gsub('"', '\\"')}\"" }
    begin
      result = YAML.safe_load(fixed, permitted_classes: [Date])
      $stderr.puts "  Recovery successful"
    rescue Psych::SyntaxError => e2
      # Save raw response for debugging
      raw_path = File.join(library_dir, 'discovery_pass_raw_response.txt')
      File.write(raw_path, response)
      abort "PIPELINE ABORT: LLM returned invalid YAML that could not be recovered.\n" \
            "Error: #{e2.message}\nRaw response saved: #{raw_path}\n\n" \
            "Response (first 500 chars):\n#{yaml_text[0..500]}"
    end
  end

  abort "PIPELINE ABORT: LLM response is not a Hash" unless result.is_a?(Hash)

  # ─── Validate output structure ─────────────────────────────────────────────

  theses = result['theses'] || []

  if duration_target && theses.empty?
    unless result['theses_filtered_note']
      abort "PIPELINE ABORT: --duration set, theses empty, but no theses_filtered_note — schema violation"
    end
    $stderr.puts "  No theses within ±30s of #{duration_target}: #{result['theses_filtered_note']}"
  elsif theses.empty?
    abort "PIPELINE ABORT: LLM returned zero theses"
  end

  if theses.size > 5
    $stderr.puts "  WARNING: LLM returned #{theses.size} theses, capping at 5"
    theses = theses[0..4]
    result['theses'] = theses
  end

  # Validate thesis fields
  theses.each_with_index do |t, i|
    %w[id logline duration shape_and_risk].each do |field|
      unless t[field]
        abort "PIPELINE ABORT: thesis #{i + 1} missing required field: #{field}"
      end
    end
  end

  # Ensure clip_groups and throughlines exist (may be empty)
  result['clip_groups']  ||= []
  result['throughlines'] ||= []

  # Ensure visual_context reserved block
  result['visual_context'] = { 'mode' => nil, 'summary' => nil, 'visual_groups' => [] }

  # Enrich with metadata
  result['version']           = 1
  result['input_fingerprint'] = input_fingerprint
  result['generated_at']      = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
  result['model']             = discovery_model

  $stderr.puts "  Parsed: #{theses.size} theses, #{result['clip_groups'].size} clip_groups, #{result['throughlines'].size} throughlines"

  # Write output (before review gate — file is inspectable even if user aborts)
  File.write(output_path, YAML.dump(result))
  $stderr.puts "  Written: #{output_path}"
end

# ─── Review gate ─────────────────────────────────────────────────────────────

result ||= YAML.safe_load(File.read(output_path), permitted_classes: [Date])
theses = result['theses'] || []

if theses.empty?
  # Duration-filtered empty — nothing to select
  puts output_path
  exit 0
end

if skip_review
  selected = theses[0]['id']
  result['selected_thesis'] = selected
  File.write(output_path, YAML.dump(result))
  $stderr.puts "  Auto-selected: #{selected} (--no-review)"
  puts output_path
  exit 0
end

regeneration_count = 0
max_regenerations = 3

loop do
  $stderr.puts "\n#{'=' * 68}"
  $stderr.puts "  DISCOVERY PASS — THESIS CANDIDATES"
  $stderr.puts '=' * 68

  theses.each_with_index do |t, i|
    $stderr.puts "\n  #{i + 1}. #{t['id']}"
    $stderr.puts "     Logline: #{t['logline'].to_s.strip}"
    $stderr.puts "     Duration: #{t['duration']}"
    $stderr.puts "     Shape & Risk: #{t['shape_and_risk'].to_s.strip}"
  end

  cg = result['clip_groups'] || []
  tl = result['throughlines'] || []
  cg_by_type = cg.group_by { |g| g['type'] }
  $stderr.puts "\n  Clip groups: #{cg_by_type.map { |t, gs| "#{t} (#{gs.size})" }.join(', ')}" if cg.any?
  $stderr.puts "  Throughlines: #{tl.size}" if tl.any?

  $stderr.puts "\n  Pick thesis (id or number), or 'r' to regenerate, or 'q' to abort."
  $stderr.print "  > "

  input = $stdin.gets&.strip
  if input.nil? || input.downcase == 'q'
    $stderr.puts "  Aborted. discovery_pass.yaml left in place for inspection."
    exit 0
  end

  if input.downcase == 'r'
    regeneration_count += 1
    if regeneration_count >= max_regenerations
      abort "PIPELINE ABORT: Regeneration cap (#{max_regenerations}) reached. " \
            "Consider revisiting footage or adjusting --duration target."
    end
    $stderr.puts "  Regenerating (attempt #{regeneration_count + 1}/#{max_regenerations + 1})..."
    # Re-exec this script to regenerate (will skip cache since we delete the file)
    File.delete(output_path) if File.exist?(output_path)
    exec('ruby', __FILE__, *ARGV)
  end

  # Parse selection
  selected = if input.match?(/^thesis_\d+$/)
    input
  elsif input.match?(/^\d+$/)
    idx = input.to_i - 1
    if idx >= 0 && idx < theses.size
      theses[idx]['id']
    end
  end

  unless selected && theses.any? { |t| t['id'] == selected }
    $stderr.puts "  Invalid selection: #{input}. Try again."
    next
  end

  result['selected_thesis'] = selected
  File.write(output_path, YAML.dump(result))
  $stderr.puts "  Selected: #{selected}"
  break
end

puts output_path
