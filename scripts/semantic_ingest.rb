#!/usr/bin/env ruby
# Phase 1.5 — Semantic Ingest Pass (R1)
# Replaces per-segment classification with a unified directorial understanding.
# One LLM call reads the full transcript + audio emotion + visual analysis and
# outputs: core understanding, clip groupings, open loops, central tension.
#
# Usage:
#   ruby scripts/semantic_ingest.rb --library <name> [--profile <name>] [--no-review]
#
# Input (all cached from existing pipeline):
#   - Cleaned transcript(s) (per video in library.yaml)
#   - Audio features (librosa output per segment)
#   - Visual analysis (scene detection + Claude Vision frames)
#   - Script/outline document if present
#   - Profile settings
#
# Output: libraries/<name>/semantic_ingest.yaml
# Review gate: prints core_understanding + central_tension, asks user to confirm.

require 'yaml'
require 'date'
require 'json'
require 'digest'
require_relative 'load_profile'
require_relative 'llm_client'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR = File.expand_path('..', SCRIPTS_DIR)

# --- CLI parsing ---

library_name = nil
profile_name = nil
skip_review = false
llm_mode = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'
    args.shift
    library_name = args.shift
  when '--profile'
    args.shift
    profile_name = args.shift
  when '--no-review'
    args.shift
    skip_review = true
  when '--llm-mode'
    args.shift
    llm_mode = args.shift
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/semantic_ingest.rb --library <name> [--profile <name>] [--no-review] [--llm-mode api|claude_code]"
  end
end

abort "Usage: ruby scripts/semantic_ingest.rb --library <name>" unless library_name

LLMClient.mode = llm_mode.to_sym if llm_mode

# --- Load library ---

library_dir = File.join(ROOT_DIR, 'libraries', library_name)
library_yaml_path = File.join(library_dir, 'library.yaml')
abort "Library not found: #{library_dir}" unless File.exist?(library_yaml_path)

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
videos = library['videos'] || []
abort "No videos in library.yaml" if videos.empty?

transcripts_dir = File.join(library_dir, 'transcripts')
profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)
tone_guide = load_tone_guide(profile)
tone_context = build_tone_context(profile, tone_guide)

output_path = File.join(library_dir, 'semantic_ingest.yaml')

# --- Cache check ---

input_fingerprints = []
videos.each do |v|
  ct = v['cleaned_transcript'] || v['transcript']
  next unless ct
  path = File.join(transcripts_dir, ct)
  input_fingerprints << Digest::MD5.hexdigest(File.read(path)) if File.exist?(path)
end
cache_hash = Digest::MD5.hexdigest(input_fingerprints.join(':'))

if File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date])
  if existing && existing['cache_hash'] == cache_hash
    $stderr.puts "semantic_ingest.yaml up to date (hash #{cache_hash[0..7]})"
    puts output_path
    exit 0
  end
end

# ============================================================
# GATHER INPUTS
# ============================================================

$stderr.puts "=" * 60
$stderr.puts "SEMANTIC INGEST — #{library_name}"
$stderr.puts "=" * 60

# --- 1. Concatenate all cleaned transcripts with source markers ---

transcript_block = ""
all_segment_count = 0

videos.each_with_index do |v, idx|
  ct = v['cleaned_transcript'] || v['transcript']
  unless ct
    $stderr.puts "  WARNING: Video #{idx + 1} (#{File.basename(v['path'])}) has no transcript, skipping"
    next
  end

  t_path = File.join(transcripts_dir, ct)
  unless File.exist?(t_path)
    $stderr.puts "  WARNING: Transcript not found: #{t_path}, skipping"
    next
  end

  data = JSON.parse(File.read(t_path))
  segs = data['segments'] || []
  source_name = File.basename(v['path'])
  all_segment_count += segs.size

  transcript_block << "\n--- SOURCE: #{source_name} (#{v['duration']}) ---\n"
  segs.each do |s|
    t_start = s['start'].round(2)
    t_end = s['end'].round(2)
    transcript_block << "[#{t_start}-#{t_end}] #{s['text'].strip}\n"
  end
end

abort "ABORT: No transcript segments found across #{videos.size} video(s)" if all_segment_count == 0

$stderr.puts "  Transcripts: #{all_segment_count} segments from #{videos.size} video(s)"

# --- 2. Compress audio features ---

audio_summary = ""
videos.each do |v|
  af_name = v['audio_features']
  af_path = nil

  if af_name
    # Try explicit audio_features field
    af_path = File.join(transcripts_dir, af_name)
    af_path = File.join(library_dir, af_name) unless File.exist?(af_path)
  end

  # Fallback: look for *_audio_features.yaml by convention
  unless af_path && File.exist?(af_path)
    basename = File.basename(v['path'], File.extname(v['path']))
    candidates = Dir.glob(File.join(transcripts_dir, "*audio_features.yaml"))
    af_path = candidates.find { |p| p.include?(basename) } || candidates.first
  end

  next unless af_path && File.exist?(af_path)

  af = if af_path.end_with?('.yaml')
    YAML.safe_load(File.read(af_path))
  else
    JSON.parse(File.read(af_path))
  end

  source_name = File.basename(v['path'])
  baseline = af['baseline'] || {}
  dist = af['profile_distribution'] || {}
  af_segs = af['segments'] || []

  audio_summary << "\n--- AUDIO: #{source_name} ---\n"
  audio_summary << "Baseline: speaking_rate=#{baseline['speaking_rate']&.round(2)}, " \
                   "f0_mean=#{baseline['f0_mean']&.round(0)}Hz\n"
  audio_summary << "Profile distribution: #{dist.map { |k, v| "#{k}=#{v}" }.join(', ')}\n"

  # Only include emphatic/urgent segments (notable delivery moments)
  notable = af_segs.select { |s| %w[emphatic urgent].include?(s['audio_profile']) }
  if notable.any?
    audio_summary << "Notable delivery moments:\n"
    notable.each do |s|
      audio_summary << "  [#{s['t']}-#{s['e']}] #{s['audio_profile']} " \
                       "(energy=#{s['energy']&.round(2)}, pitch_trend=#{s['pitch_trend']})\n"
    end
  else
    audio_summary << "Delivery: consistently #{dist.max_by { |_, c| c }&.first || 'casual'} throughout\n"
  end
end

$stderr.puts "  Audio features: #{audio_summary.empty? ? 'none available' : 'compressed'}"

# --- 3. Visual analysis summary ---

visual_summary = ""
scene_path = File.join(library_dir, 'scene_changes.yaml')
frames_path = File.join(library_dir, 'visual_frames.yaml')

if File.exist?(scene_path)
  scenes = YAML.safe_load(File.read(scene_path))
  visual_summary << "Scene changes: #{scenes['total_scenes']} scenes detected\n"
  if scenes['sources'] && scenes['sources'].size > 1
    # Multi-source: show per-source scene counts
    scenes['sources'].each do |src|
      visual_summary << "  #{src['source']}: #{src['total_scenes']} scenes\n"
    end
  else
    visual_summary << "Timestamps: #{(scenes['timestamps'] || []).map { |t| "#{t.round(1)}s" }.join(', ')}\n"
  end
end

# Visual transcript descriptions (from analyze-video skill)
videos.each do |v|
  vt_name = v['visual_transcript']
  next unless vt_name && !vt_name.to_s.strip.empty?

  vt_path = File.join(transcripts_dir, vt_name)
  next unless File.exist?(vt_path)

  vt = YAML.safe_load(File.read(vt_path)) rescue JSON.parse(File.read(vt_path)) rescue nil
  next unless vt

  source_name = File.basename(v['path'])
  visual_summary << "\n--- VISUAL: #{source_name} ---\n"
  descriptions = vt['descriptions'] || vt['frames'] || []
  descriptions.each do |d|
    ts = d['timestamp'] || d['t'] || d['time']
    desc = d['description'] || d['text'] || d['content']
    visual_summary << "  [#{ts}s] #{desc}\n" if desc
  end
end

$stderr.puts "  Visual analysis: #{visual_summary.empty? ? 'none available' : 'included'}"

# --- 4. Script/outline ---

script_block = ""
script_present = false
script_type_hint = 'none'

if library['script_parsed']
  sp_path = File.join(library_dir, 'transcripts', library['script_parsed'])
  sp_path = File.join(library_dir, library['script_parsed']) unless File.exist?(sp_path)

  if File.exist?(sp_path)
    script_present = true
    script_data = YAML.safe_load(File.read(sp_path), permitted_classes: [Date]) rescue nil
    if script_data
      script_block = "\n--- SCRIPT/OUTLINE ---\n"
      if script_data['beats']
        script_type_hint = 'outline'
        script_data['beats'].each_with_index do |b, i|
          script_block << "#{i + 1}. #{b['label'] || b['text']}\n"
        end
      elsif script_data['sections']
        script_type_hint = 'full_script'
        script_data['sections'].each do |s|
          script_block << "## #{s['heading']}\n#{s['text']}\n\n"
        end
      else
        script_block << script_data.to_yaml
      end
    end
  end
end

# Also check project folder for raw script files
videos.each do |v|
  break if script_present
  project_dir = File.dirname(v['path'])
  script_files = Dir.glob(File.join(project_dir, '*.{txt,md}'))
                     .reject { |f| f.include?('output/') || f.include?('_treated') }
  if script_files.any?
    script_present = true
    script_type_hint = 'full_script'
    script_block = "\n--- SCRIPT/OUTLINE ---\n"
    script_block << File.read(script_files.first)[0..3000] # Cap at 3k chars
    script_block << "\n[...truncated]\n" if File.size(script_files.first) > 3000
  end
end

$stderr.puts "  Script: #{script_present ? script_type_hint : 'none'}"

# ============================================================
# BUILD PROMPT
# ============================================================

prompt = <<~PROMPT
  You are a senior video editor doing the first pass on raw footage. Read all the material below and produce a comprehensive directorial understanding of this content.

  Your job is NOT to edit — it's to understand. What is this video about? What's the argument or narrative? How does the speaker organize their thoughts? Where are the retakes? What's unusable?

  ## Transcript
  #{transcript_block}

  #{audio_summary.empty? ? '' : "## Audio Delivery Analysis\n#{audio_summary}\n"}
  #{visual_summary.empty? ? '' : "## Visual Analysis\n#{visual_summary}\n"}
  #{script_block.empty? ? '' : "## Script/Outline (provided by creator)\n#{script_block}\n"}
  ## Output Format

  Respond with ONLY valid YAML. Use the exact schema below. Do not wrap in markdown code fences.

  core_understanding: |
    2-3 paragraph description of what this video is about, its central argument
    or narrative, intended audience, and tone. Write as if briefing another editor.

  central_tension: |
    1-2 sentence statement of the core tension, thesis, or question the video
    explores and resolves.

  script_or_outline_present: #{script_present}
  script_type: #{script_type_hint}

  clip_groups:
    - id: group_001
      label: "short descriptive label for this section"
      description: "What this group covers and its role in the narrative"
      clips:
        - t: <start_time_seconds>
          source: "<filename>"
          usability: fine
          content_summary: "What the speaker says/does"
        - t: <start_time>
          source: "<filename>"
          usability: unusable
          content_summary: "Abandoned take — trails off"
        - t: <start_time>
          source: "<filename>"
          usability: fine
          cluster: topic_name
          content_summary: "Near-duplicate retake of same content"
          trim_in: <seconds>
          mid_cuts:
            - [<cut_start>, <cut_end>]

  open_loops:
    structural:
      - opened_at: group_NNN
        description: "What question/tension is opened"
        closes_at: group_NNN
    local:
      - within: group_NNN
        opened_at: <t_value>
        closes_at: <t_value>
        description: "Setup and payoff within one section"

  ## Rules

  - clip_groups: Group by SEMANTIC topic, not chronology. A group = one idea/argument/section.
  - Each transcript segment [start-end] becomes one clip. Use the start time as `t`.
  - usability: `fine` = clean, usable as-is. `marginal` = serviceable but has minor issues (stumble, low energy, rough phrasing). `unusable` = abandoned take, unintelligible, pure filler.
  - cluster: When two or more clips cover the same content (retakes), assign the SAME cluster name (short lowercase label like `opening_hook` or `ai_fear_thesis`). Leave null for unique clips.
  - trim_in: If the speaker stumbles or false-starts at the beginning of a clip, set trim_in to the timestamp where clean speech begins. Only set when there's a clear restart within the first few seconds. Omit otherwise.
  - mid_cuts: If the speaker abandons a phrase mid-clip then restarts, list the abandoned ranges as [[start, end], ...] to be cut out. Only for clear mid-clip false starts. Omit otherwise.
  - open_loops: Structural = big arcs across the video. Local = setup-payoff within one group.
  - Use actual t-values from the transcript. Do not invent timestamps.
  - Every transcript segment must appear in exactly one clip_group (no orphans, no duplicates).
  - IDs are sequential: group_001, group_002, etc.
PROMPT

# P3: Tone context goes to system message with prompt caching (API mode only)
cached_system = tone_context.empty? ? nil : tone_context
prompt_total = prompt.length + (cached_system&.length || 0)
$stderr.puts "\n  Prompt: #{prompt.length} chars + #{cached_system&.length || 0} system (~#{(prompt_total / 4.0).ceil} tokens)"

# ============================================================
# LLM CALL
# ============================================================

$stderr.puts "\n  Calling LLM (semantic_ingest)..."
pending_dir = File.join(library_dir, 'pending_llm_calls')
begin
  response = LLMClient.call(prompt, call_type: 'semantic_ingest', profile: profile, max_tokens: 8192,
                            pending_dir: pending_dir, call_name: 'semantic_ingest',
                            cached_system_prompt: cached_system)
rescue LLMClient::Pending => e
  $stderr.puts e.message
  exit 2
end

# Parse YAML response — strip code fences if present
yaml_text = response.gsub(/\A```ya?ml\s*/, '').gsub(/```\s*\z/, '').strip

begin
  result = YAML.safe_load(yaml_text, permitted_classes: [Date])
rescue Psych::SyntaxError => e
  # Try to salvage — sometimes the LLM produces minor YAML issues
  $stderr.puts "  WARNING: YAML parse error: #{e.message}"
  $stderr.puts "  Attempting recovery..."

  # Common fix: unescaped colons in strings
  fixed = yaml_text.gsub(/: ([^|>\n"'{].*:)/) { |m| ": \"#{$1.gsub('"', '\\"')}\"" }
  begin
    result = YAML.safe_load(fixed, permitted_classes: [Date])
    $stderr.puts "  Recovery successful"
  rescue Psych::SyntaxError => e2
    abort "ABORT: LLM returned invalid YAML that could not be recovered.\n" \
          "Error: #{e2.message}\n\nResponse (first 500 chars):\n#{yaml_text[0..500]}"
  end
end

# ============================================================
# VALIDATE + ENRICH OUTPUT
# ============================================================

# Validate required fields
%w[core_understanding central_tension clip_groups].each do |field|
  abort "ABORT: LLM response missing required field: #{field}" unless result[field]
end

clip_groups = result['clip_groups'] || []
abort "ABORT: No clip groups in LLM response" if clip_groups.empty?

total_clips = clip_groups.sum { |g| (g['clips'] || []).size }
$stderr.puts "  Parsed: #{clip_groups.size} clip groups, #{total_clips} total clips"

# Enrich with metadata
result['generated_at'] = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
result['source'] = library_name
result['cache_hash'] = cache_hash
result['video_count'] = videos.size
result['transcript_segments'] = all_segment_count
result['llm_model'] = profile.dig('llm_routing', 'semantic_ingest') || LLMClient::DEFAULT_MODEL

# Ensure defaults for optional fields
result['open_loops'] ||= { 'structural' => [], 'local' => [] }
result['open_loops']['structural'] ||= []
result['open_loops']['local'] ||= []
result['script_or_outline_present'] = script_present
result['script_type'] ||= script_type_hint

# Normalize per-clip usability fields
(result['clip_groups'] || []).each do |g|
  (g['clips'] || []).each do |c|
    c['usability'] ||= 'fine'
    # Ensure trim_in/mid_cuts/cluster are nil-safe (don't add if not present)
  end
end

# ============================================================
# WRITE OUTPUT
# ============================================================

File.write(output_path, result.to_yaml)
$stderr.puts "\n  Output: #{output_path}"

# ============================================================
# REVIEW GATE
# ============================================================

unless skip_review
  $stderr.puts "\n#{'=' * 60}"
  $stderr.puts "REVIEW GATE — Does this match your intent?"
  $stderr.puts '=' * 60
  $stderr.puts "\n## Core Understanding\n\n"
  $stderr.puts result['core_understanding']
  $stderr.puts "\n## Central Tension\n\n"
  $stderr.puts result['central_tension']
  all_clips = clip_groups.flat_map { |g| g['clips'] || [] }
  fine_count = all_clips.count { |c| c['usability'] == 'fine' }
  marginal_count = all_clips.count { |c| c['usability'] == 'marginal' }
  unusable_count = all_clips.count { |c| c['usability'] == 'unusable' }
  cluster_count = all_clips.map { |c| c['cluster'] }.compact.uniq.size
  $stderr.puts "\n#{clip_groups.size} clip groups | #{total_clips} clips | " \
               "#{fine_count} fine, #{marginal_count} marginal, #{unusable_count} unusable | " \
               "#{cluster_count} clusters"
  $stderr.puts "\n(y) Continue  (r) Show full output  (n) Abort"
  $stderr.print "> "

  answer = $stdin.gets&.strip&.downcase
  answer = 'y' if answer.nil? || answer.empty?

  case answer
  when 'r'
    $stderr.puts "\n#{File.read(output_path)}"
    $stderr.puts "\nContinue? (y/n)"
    $stderr.print "> "
    answer2 = $stdin.gets&.strip&.downcase
    answer2 = 'y' if answer2.nil? || answer2.empty?
    abort "Aborted by user." if answer2 == 'n'
  when 'n'
    abort "Aborted by user. Re-run with corrections."
  end
end

$stderr.puts "\nSemantic ingest complete."
puts output_path
