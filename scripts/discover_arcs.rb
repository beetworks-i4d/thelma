#!/usr/bin/env ruby
# Discovers narrative arc candidates in a pool library.
# Reads pool index + all transcripts, calls LLM (Opus) to find up to 5
# self-contained video arcs that could be cut from the pool.
#
# Usage:
#   ruby scripts/discover_arcs.rb --library <name> [options]
#   Options:
#     --topic "brand strategy"         Semantic topic filter
#     --template contrarian_argument   Story structure template name
#     --format longform|shorts         Target duration class (default: longform)
#     --profile <name>                 Creator profile for tone guidance
#     --force-rediscover               Bypass cache and re-run LLM
#     --llm-mode api|claude_code       Override LLM mode
#
# Output: libraries/<name>/arc_candidates.yaml

require 'yaml'
require 'json'
require 'date'
require 'digest'
require 'fileutils'
require_relative 'pool_index'
require_relative 'load_profile'
require_relative 'llm_client'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

# ─── CLI ─────────────────────────────────────────────────────────────────────

library_name     = nil
profile_name     = nil
topic_filter     = nil
template_name    = nil
target_format    = nil
force_rediscover = false
llm_mode         = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'          then args.shift; library_name  = args.shift
  when '--profile'          then args.shift; profile_name  = args.shift
  when '--topic'            then args.shift; topic_filter  = args.shift
  when '--template'         then args.shift; template_name = args.shift
  when '--format'           then args.shift; target_format = args.shift
  when '--force-rediscover' then args.shift; force_rediscover = true
  when '--llm-mode'         then args.shift; llm_mode      = args.shift
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/discover_arcs.rb --library <name> " \
          "[--topic <topic>] [--template <name>] [--format longform|shorts] " \
          "[--profile <name>] [--force-rediscover] [--llm-mode api|claude_code]"
  end
end

abort "Usage: ruby scripts/discover_arcs.rb --library <name>" unless library_name

LLMClient.mode = llm_mode.to_sym if llm_mode

# ─── Load library + index ────────────────────────────────────────────────────

library_dir = File.join(ROOT_DIR, 'libraries', library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

library_yaml_path = File.join(library_dir, 'library.yaml')
abort "library.yaml not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)
library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])

index   = PoolIndex.load(library_dir)
sources = index['sources'] || {}
abort "Pool index is empty — run --mode mine first to ingest sources" if sources.empty?

transcripts_dir = File.join(library_dir, 'transcripts')
output_path     = File.join(library_dir, 'arc_candidates.yaml')
pending_dir     = File.join(library_dir, 'pending_llm_calls')

# ─── Load profile ────────────────────────────────────────────────────────────

profile = if profile_name
  load_profile_by_name(profile_name)
else
  load_profile(library_name)
end

# ─── Resolve template ────────────────────────────────────────────────────────

template_data         = nil
template_path_resolved = nil

if template_name
  patterns = [
    File.join(ROOT_DIR, 'templates', 'story_structures', '**', "#{template_name}.yaml"),
    File.join(ROOT_DIR, 'templates', 'story_structures', '**', "*#{template_name}*.yaml")
  ]
  patterns.each do |pat|
    matches = Dir.glob(pat)
    next unless matches.any?
    template_path_resolved = matches.first
    template_data = YAML.safe_load(File.read(template_path_resolved), permitted_classes: [Date]) rescue nil
    break if template_data
  end
  $stderr.puts "  WARNING: Template '#{template_name}' not found in templates/story_structures/" unless template_data
end

# ─── Load transcripts ────────────────────────────────────────────────────────

transcripts_by_source = {}
sources.each do |filename, entry|
  next unless entry['transcript_file']
  t_path = File.join(transcripts_dir, entry['transcript_file'])
  next unless File.exist?(t_path)
  data = JSON.parse(File.read(t_path)) rescue nil
  transcripts_by_source[filename] = data if data
end

# ─── Load audio features ─────────────────────────────────────────────────────

audio_features_by_source = {}
sources.each do |filename, entry|
  next unless entry['audio_features']
  af_path = File.join(transcripts_dir, entry['audio_features'])
  next unless File.exist?(af_path)
  data = YAML.safe_load(File.read(af_path), permitted_classes: [Date]) rescue nil
  audio_features_by_source[filename] = data if data
end

$stderr.puts "Pool: #{sources.size} source(s), " \
             "#{transcripts_by_source.size} with transcripts, " \
             "#{audio_features_by_source.size} with audio features"

# ─── Cache check ─────────────────────────────────────────────────────────────

fingerprints = transcripts_by_source.keys.sort.map do |fn|
  t_path = File.join(transcripts_dir, sources[fn]['transcript_file'])
  Digest::MD5.file(t_path).hexdigest
end
cache_input = (fingerprints + [topic_filter.to_s, template_name.to_s, target_format.to_s]).join(':')
cache_hash  = Digest::MD5.hexdigest(cache_input)

if !force_rediscover && File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date]) rescue {}
  if existing.is_a?(Hash) && existing['cache_hash'] == cache_hash
    $stderr.puts "Arc candidates up to date (cache hit). Use --force-rediscover to regenerate."
    puts output_path
    exit 0
  end
end

# ─── Build prompt ────────────────────────────────────────────────────────────

# Pool overview
video_count  = sources.count { |_, v| v['media_type'] == 'video_with_audio' }
audio_count  = sources.count { |_, v| v['media_type'] == 'audio_only' }
broll_count  = sources.count { |_, v| v['media_type'] == 'broll' }
total_secs   = sources.values.sum { |v| v['duration'].to_f }
total_dur_str = format('%d:%02d:%02d', (total_secs / 3600).to_i, ((total_secs % 3600) / 60).to_i, (total_secs % 60).to_i)

pool_overview = <<~SECTION
  ## Pool Overview
  Sources: #{sources.size} total — #{video_count} video, #{audio_count} audio-only, #{broll_count} broll
  Total pool duration: #{total_dur_str}
SECTION

# Source transcripts block
transcript_block = +"## Source Transcripts\n\n"
transcripts_by_source.sort_by { |fn, _| fn }.each do |filename, data|
  entry   = sources[filename]
  dur_s   = entry['duration'] ? format('%.1fs', entry['duration']) : '?'
  mtype   = entry['media_type'] || 'unknown'
  segments = data['segments'] || []
  transcript_block << "--- SOURCE: #{filename} (#{dur_s}) [#{mtype}] ---\n"
  segments.each do |seg|
    t    = (seg['start'] || seg['t'] || 0).to_f
    e    = (seg['end']   || seg['e'] || t).to_f
    text = (seg['text']  || seg['content'] || '').strip
    transcript_block << "[#{format('%.2f', t)}-#{format('%.2f', e)}] #{text}\n"
  end
  transcript_block << "\n"
end

# Audio delivery block
audio_block = nil
if audio_features_by_source.any?
  buf = +"## Audio Delivery Summary\n\n"
  audio_features_by_source.sort_by { |fn, _| fn }.each do |filename, data|
    buf << "--- SOURCE: #{filename} ---\n"
    bl = data['baseline'] || {}
    buf << "Baseline: speaking_rate=#{bl['speaking_rate']&.round} wpm, f0_mean=#{bl['f0_mean']&.round}Hz\n"
    dist = data['profile_distribution'] || {}
    buf << "Profile: #{dist.map { |k, v| "#{k}=#{v}%" }.join(', ')}\n" if dist.any?
    notable = (data['segments'] || []).select { |s| %w[emphatic urgent].include?(s['audio_profile']) }
    if notable.any?
      buf << "Notable delivery:\n"
      notable.first(8).each do |s|
        buf << "  [#{s['t']&.round(1)}-#{s['e']&.round(1)}] #{s['audio_profile']} " \
               "(energy=#{s['energy']&.round(2)}, pitch=#{s['pitch_trend']})\n"
      end
    end
    buf << "\n"
  end
  audio_block = buf
end

# Creator tone context
tone_block = nil
if profile && profile['tone_profile']
  tone_guide = load_tone_guide(profile)
  ctx = build_tone_context(profile, tone_guide)
  tone_block = ctx unless ctx.empty?
end

# Format requirement
format_block = if target_format == 'shorts'
  "## Format Requirement\nTarget: **shorts** (30–90 seconds per candidate)\n" \
  "Keep clip sequences tight. Prioritize hook strength. One strong insight per candidate.\n"
else
  "## Format Requirement\nTarget: **longform** (6–10 minutes per candidate)\n" \
  "Develop the full arc. Use substantial portions of the pool. Complete argument or story.\n"
end

# Topic filter
topic_block = nil
if topic_filter
  topic_block = "## Topic Focus\nFind arcs related to: \"#{topic_filter}\"\n" \
                "Semantic matching: a metaphor or analogy about the topic counts as on-topic.\n"
end

# Template structure
template_block = nil
if template_data
  buf = +"## Template Structure: #{template_data['name']}\n"
  buf << "#{template_data['description']}\n\n"
  buf << "Required beats (in order):\n"
  (template_data['beats'] || []).each_with_index do |beat, i|
    buf << "  #{i + 1}. **#{beat['id']}** [#{beat['position']}]: #{beat['description']}\n"
  end
  template_block = buf
end

# LLM model routing
arc_model = profile&.dig('llm_routing', 'arc_discovery') || 'claude-opus-4-6'

prompt = <<~PROMPT
  You are a creative documentary editor with deep narrative intelligence.
  Analyze this content pool and discover up to 5 candidate video arcs that could each
  become a complete, self-contained video produced from clips in this pool.

  #{pool_overview}
  #{transcript_block}
  #{audio_block || ''}
  #{tone_block || ''}
  #{format_block}
  #{topic_block || ''}
  #{template_block || ''}
  ## Discovery Principles

  SELF-CONTAINMENT: Each candidate must have a clear hook, development, and payoff.
  Open loops must close. Flag clips that attempt but don't complete a thought as optional.

  CLIP ROLES:
  - hook: Opens the video; creates immediate curiosity or stakes
  - setup: Context or backstory needed before the thesis lands
  - development: Core argument or story progression
  - payoff: Emotional or intellectual resolution; the "so what"
  - transition: Connective tissue between ideas

  DELIVERY QUALITY: Use audio features to prefer emphatic/urgent clips for hook and payoff.
  Casual delivery is fine for setup and development.

  CROSS-SOURCE ARCS: Look for arcs spanning multiple source files. Audio-only sources
  (voice memos, HQ audio recordings) should participate where their content is relevant.

  MISSING BRIDGES: When a semantic leap between clips weakens the arc, flag it in
  missing_bridge_clips. Describe what the creator should record as a pickup shot and why.
  Format: between_clips is a list of [preceding_clip_index, following_clip_index] (0-based).

  HOOK STRENGTH (0.0–1.0): How immediately engaging is the opening? Does it create a
  question the viewer must answer? Is delivery energetic?

  COHERENCE SCORE (0.0–1.0): Does the arc flow logically? Do ideas connect? Does it resolve?

  FIT SCORES: Provide fit_to_topic and fit_to_template only when those options are specified.

  UNUSED CLIPS: At the end, list any pool clips that didn't fit any top candidate and why.

  ## Output Format
  Respond with ONLY valid YAML using this exact schema — no markdown fences, no prose:

  candidates:
    - id: candidate_001
      title: "Concise draft title"
      estimated_duration: "M:SS"
      structure_type: contrarian|explainer|journey|tier_ranking|transformation|argument|other
      hook_strength: 0.00
      coherence_score: 0.00
      arc_summary: |
        3–5 sentences. Opens with X, pivots to Y, resolves with Z.
      central_tension: |
        1–2 sentences. The core question this video answers.
      clip_sequence:
        - source: filename.ext
          t_in: 0.0
          t_out: 0.0
          role: hook|setup|development|payoff|transition
          content_summary: "what the speaker says or does in this clip"
      missing_bridge_clips: []
      confidence: high|medium|low
      fit_to_template: null
      fit_to_topic: null

  unused_clips:
    - source: filename.ext
      t_in: 0.0
      t_out: 0.0
      reason: "Why this clip didn't fit any candidate"
PROMPT

# ─── LLM call ────────────────────────────────────────────────────────────────

$stderr.puts "Calling LLM (#{arc_model}) for arc discovery..."

begin
  response = LLMClient.call(
    prompt,
    call_type: 'arc_discovery',
    profile:   profile,
    model:     arc_model,
    max_tokens: 8192,
    pending_dir: pending_dir,
    call_name:   'discover_arcs'
  )
rescue LLMClient::Pending => e
  $stderr.puts e.message
  exit 2
end

# ─── Parse response ──────────────────────────────────────────────────────────

parsed = YAML.safe_load(response, permitted_classes: [Date]) rescue nil

# Fallback: strip markdown code fences if present
if parsed.nil? || !parsed.is_a?(Hash)
  stripped = response.gsub(/\A```(?:yaml)?\n/, '').gsub(/\n```\z/, '')
  parsed = YAML.safe_load(stripped, permitted_classes: [Date]) rescue nil
end

abort "ERROR: LLM response did not contain valid YAML with 'candidates' key.\n#{response[0, 500]}" \
  unless parsed.is_a?(Hash) && parsed.key?('candidates')

candidates  = parsed['candidates']  || []
unused_clips = parsed['unused_clips'] || []

$stderr.puts "Discovered #{candidates.size} candidate arc(s):"
candidates.each_with_index do |c, i|
  dur  = c['estimated_duration'] || '?'
  conf = c['confidence'] || '?'
  $stderr.puts "  #{i + 1}. \"#{c['title']}\" (#{dur}, #{conf} confidence)"
end

# ─── Write output ────────────────────────────────────────────────────────────

result = {
  'pool_version' => 1,
  'generated_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'cache_hash'   => cache_hash,
  'llm_model'    => arc_model,
  'discovery_context' => {
    'topic'         => topic_filter,
    'template'      => template_path_resolved ? File.basename(template_path_resolved) : nil,
    'target_format' => target_format || 'longform'
  },
  'candidates'   => candidates,
  'unused_clips' => unused_clips
}

File.write(output_path, result.to_yaml)
$stderr.puts "Arc candidates written to #{output_path}"
puts output_path
