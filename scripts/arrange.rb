#!/usr/bin/env ruby
# Phase 2 — Arrangement Script (R3)
# Converts semantic understanding into a proposed cut. One LLM call that produces
# arrangement.yaml with chapter ordering, clip selection, take decisions, B-roll
# matching, and editorial reasoning.
#
# Usage:
#   ruby scripts/arrange.rb --library <name> [--profile <name>] [--format longform|shorts]
#                           [--no-review] [--llm-mode api|claude_code]
#
# Input:
#   - semantic_ingest.yaml (REQUIRED) — clip groups, open loops, best-take hints
#   - segments_classified.yaml (OPTIONAL) — enrichment: end times, roles, durations
#   - asset_pool.yaml (OPTIONAL) — B-roll assets with semantic tags
#   - Script/outline if library['script_parsed'] is set
#
# Output: libraries/<name>/arrangement.yaml

require 'yaml'
require 'date'
require 'json'
require 'digest'
require_relative 'load_profile'
require_relative 'llm_client'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR = File.expand_path('..', SCRIPTS_DIR)

ROLE_COLORS = {
  'hook'       => 4279486782,  # Green
  'setup'      => 4280578025,  # Orange
  'argument'   => 4294153761,  # Blue
  'body'       => 4294153761,  # Blue
  'evidence'   => 4294153761,  # Blue
  'example'    => 4292131840,  # Cyan
  'quote'      => 4292131840,  # Cyan
  'anecdote'   => 4292131840,  # Cyan
  'payoff'     => 4289734556,  # Purple
  'resolution' => 4289734556,  # Purple
  'conclusion' => 4289734556,  # Purple
  'transition' => 4281719037,  # Yellow
  'bridge'     => 4281719037,  # Yellow
}.freeze

# --- CLI parsing ---

library_name = nil
profile_name = nil
target_format = 'longform'
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
  when '--format'
    args.shift
    target_format = args.shift
  when '--no-review'
    args.shift
    skip_review = true
  when '--llm-mode'
    args.shift
    llm_mode = args.shift
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/arrange.rb --library <name> [--profile <name>] [--format longform|shorts] [--no-review] [--llm-mode api|claude_code]"
  end
end

abort "Usage: ruby scripts/arrange.rb --library <name>" unless library_name

unless %w[longform shorts].include?(target_format)
  abort "Invalid format: #{target_format}. Must be 'longform' or 'shorts'."
end

LLMClient.mode = llm_mode.to_sym if llm_mode

# --- Load library ---

library_dir = File.join(ROOT_DIR, 'libraries', library_name)
library_yaml_path = File.join(library_dir, 'library.yaml')
abort "Library not found: #{library_dir}" unless File.exist?(library_yaml_path)

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)

output_path = File.join(library_dir, 'arrangement.yaml')

# --- Load semantic_ingest.yaml (REQUIRED) ---

ingest_path = File.join(library_dir, 'semantic_ingest.yaml')
abort "ABORT: semantic_ingest.yaml not found at #{ingest_path}\nRun semantic_ingest.rb first." unless File.exist?(ingest_path)

ingest = YAML.safe_load(File.read(ingest_path), permitted_classes: [Date])
abort "ABORT: semantic_ingest.yaml is empty or invalid" unless ingest && ingest['clip_groups']

# --- Cache check ---

cache_hash = Digest::MD5.hexdigest(File.read(ingest_path) + target_format)

if File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date])
  if existing && existing['cache_hash'] == cache_hash
    $stderr.puts "arrangement.yaml up to date (hash #{cache_hash[0..7]})"
    puts output_path
    exit 0
  end
end

# ============================================================
# GATHER INPUTS
# ============================================================

$stderr.puts "=" * 60
$stderr.puts "ARRANGEMENT — #{library_name}"
$stderr.puts "=" * 60

# --- 1. Semantic ingest data ---

clip_groups = ingest['clip_groups'] || []
open_loops = ingest['open_loops'] || {}

all_ingest_clips = clip_groups.flat_map { |g| g['clips'] || [] }
fine_count = all_ingest_clips.count { |c| c['usability'] == 'fine' || c['usability'].nil? }
marginal_count = all_ingest_clips.count { |c| c['usability'] == 'marginal' }
unusable_count = all_ingest_clips.count { |c| c['usability'] == 'unusable' }
cluster_names = all_ingest_clips.map { |c| c['cluster'] }.compact.uniq

$stderr.puts "  Ingest: #{clip_groups.size} groups, #{all_ingest_clips.size} clips"
$stderr.puts "  Usability: #{fine_count} fine, #{marginal_count} marginal, #{unusable_count} unusable"
$stderr.puts "  Clusters: #{cluster_names.size} (#{cluster_names.join(', ')})" if cluster_names.any?

# --- 2. Segments classified (OPTIONAL enrichment) ---

classified_path = File.join(library_dir, 'segments_classified.yaml')
t_lookup = {}  # t_value → enrichment hash

if File.exist?(classified_path)
  classified = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])
  segments = classified['segments'] || []
  segments.each do |s|
    t_val = s['t'].to_f
    t_lookup[t_val] = {
      'e' => s['e']&.to_f,
      'narrative_role' => s['narrative_role'],
      'dur' => s['dur'],
      'confidence' => s['confidence'],
      'audio_profile' => s['audio_profile'],
      'states' => s['states'],
      'distillation' => s['distillation']
    }
  end
  $stderr.puts "  Classification: #{segments.size} segments enriched"
else
  # Fallback: try to build t→e lookup from transcript JSON segments
  transcripts_dir = File.join(library_dir, 'transcripts')
  (library['videos'] || []).each do |v|
    ct = v['cleaned_transcript'] || v['transcript']
    next unless ct
    t_path = File.join(transcripts_dir, ct)
    next unless File.exist?(t_path)
    data = JSON.parse(File.read(t_path)) rescue next
    (data['segments'] || []).each do |s|
      t_val = s['start'].to_f
      t_lookup[t_val] = { 'e' => s['end'].to_f } unless t_lookup.key?(t_val)
    end
  end
  $stderr.puts "  Classification: not available (using transcript end times)"
end

# --- 3. Asset pool (OPTIONAL) ---

asset_pool_path = File.join(library_dir, 'asset_pool.yaml')
asset_pool = nil
if File.exist?(asset_pool_path)
  asset_pool = YAML.safe_load(File.read(asset_pool_path), permitted_classes: [Date])
  $stderr.puts "  Asset pool: #{(asset_pool['assets'] || []).size} assets"
else
  $stderr.puts "  Asset pool: not available"
end

# --- 4. Script/outline (determines branch) ---

script_block = ""
branch = 'B'  # default: semantic judgment

if library['script_parsed']
  sp_path = File.join(library_dir, 'transcripts', library['script_parsed'])
  sp_path = File.join(library_dir, library['script_parsed']) unless File.exist?(sp_path)

  if File.exist?(sp_path)
    branch = 'A'  # script-faithful
    script_data = YAML.safe_load(File.read(sp_path), permitted_classes: [Date]) rescue nil
    if script_data
      script_block = "\n## Script/Outline\n"
      if script_data['beats']
        script_data['beats'].each_with_index do |b, i|
          script_block << "#{i + 1}. #{b['label'] || b['text']}\n"
        end
      elsif script_data['sections']
        script_data['sections'].each do |s|
          script_block << "## #{s['heading']}\n#{s['text']}\n\n"
        end
      else
        script_block << script_data.to_yaml
      end
    end
  end
end

$stderr.puts "  Branch: #{branch} (#{branch == 'A' ? 'script-faithful' : 'semantic judgment'})"

# --- Build enriched clip groups for prompt ---

enriched_groups = clip_groups.map do |g|
  enriched_clips = (g['clips'] || []).map do |c|
    t_val = c['t'].to_f
    enrichment = t_lookup[t_val] || {}
    entry = { 't' => c['t'], 'source' => c['source'], 'usability' => c['usability'] || 'fine',
              'content_summary' => c['content_summary'] }
    entry['cluster'] = c['cluster'] if c['cluster']
    entry['trim_in'] = c['trim_in'] if c['trim_in']
    entry['mid_cuts'] = c['mid_cuts'] if c['mid_cuts']
    entry['e'] = enrichment['e'] if enrichment['e']
    entry['narrative_role'] = enrichment['narrative_role'] if enrichment['narrative_role']
    entry['dur'] = enrichment['dur'] if enrichment['dur']
    entry['confidence'] = enrichment['confidence'] if enrichment['confidence']
    entry['audio_profile'] = enrichment['audio_profile'] if enrichment['audio_profile']
    entry
  end
  { 'id' => g['id'], 'label' => g['label'], 'description' => g['description'], 'clips' => enriched_clips }
end

# --- Format constraints ---

format_defaults = profile.dig('format_defaults', target_format) || {}
target_duration_range = format_defaults['target_duration'] || (target_format == 'shorts' ? '30-60' : '480-900')
content_type = effective_content_type(profile, library)

# ============================================================
# BUILD PROMPT
# ============================================================

prompt = <<~PROMPT
  You are a senior video editor creating a proposed cut for a video.

  ## Directorial Understanding

  ### Core Understanding
  #{ingest['core_understanding']}

  ### Central Tension
  #{ingest['central_tension']}

  ## Clip Groups (with enrichment)
  #{enriched_groups.to_yaml}

  ## Open Loops
  #{open_loops.to_yaml}

  #{script_block}
  #{asset_pool ? "## Asset Pool\n#{asset_pool.to_yaml}\n" : ''}
  ## Constraints
  target_format: #{target_format}
  target_duration_range: #{target_duration_range} seconds
  branch: #{branch}
  include_ctas: #{profile['include_ctas'] || true}
  content_type: #{content_type}

  ## Rules

  1. **Chapter ordering**: Group clips into narrative chapters (ch_01, ch_02, ...). Order for maximum engagement — hook first, then build tension, resolve, conclude.
  2. **Usability filtering**: Exclude all clips marked `unusable`. Prefer `fine` clips. Use `marginal` clips only when no `fine` alternative exists in the same cluster.
  3. **Cluster take selection**: When clips share a `cluster` name, pick the best `fine` clip for V1. Put a second `fine` take on V2 only when it adds genuine value. Never use `marginal` if a `fine` exists in the same cluster.
  4. **V2 stacking**: Only use track V2 for: (a) alternate cluster takes worth preserving, (b) cutaway/reaction shots, (c) B-roll overlays. Never put primary narrative on V2.
  5. **Keep logic**: Every `fine` clip should appear unless explicitly dropped with reasoning in key_decisions.
  6. **B-roll matching**: If asset_pool is available, match assets to clips by semantic relevance. If no pool, suggest B-roll in broll_suggestions.
  7. **Chapter assignment**: Every clip must belong to exactly one chapter.
  8. **t_in / t_out**: Use the `t` value as t_in (or `trim_in` if set — it overrides the in-point). Use the `e` value (if available) as t_out. If `e` is not available, estimate from content.
  9. **trim_in**: If a clip has `trim_in`, use that as the effective t_in instead of `t`. Pass `trim_in` through to the output clip.
  10. **mid_cuts**: If a clip has `mid_cuts`, pass them through to the output clip unchanged. They represent internal ranges to excise.
  11. **Duration**: Estimate total duration from sum of (t_out - t_in) for all V1 clips. Warn if outside target range.
  12. **Narrative roles**: Assign a narrative_role to each clip from: hook, setup, argument, body, evidence, example, quote, anecdote, payoff, resolution, conclusion, transition, bridge.

  ## Output Schema

  Respond with ONLY valid YAML. Do not wrap in markdown code fences.

  cut_summary: |
    2-3 sentence summary of the proposed cut — what story it tells,
    key editorial choices, and overall approach.

  target_format: #{target_format}
  estimated_duration: "<M:SS format>"
  branch: #{branch}

  chapters:
    - id: ch_01
      label: "Chapter label"
      clips:
        - t_in: <start_seconds>
          t_out: <end_seconds>
          source: "<filename>"
          track: V1
          narrative_role: hook
          content_summary: "What happens in this clip"
        - t_in: <start_seconds>
          t_out: <end_seconds>
          source: "<filename>"
          track: V2
          narrative_role: evidence
          content_summary: "Alternate take or B-roll"
          trim_in: <seconds>
          mid_cuts:
            - [<cut_start>, <cut_end>]

  broll_placements: []
  broll_suggestions:
    - at_chapter: ch_01
      after_t: <seconds>
      suggestion: "What B-roll would work here and why"

  key_decisions:
    - "Dropped group_003 (false start, content repeated better in group_005)"
    - "Used alternate take at t=21.30 for punchier delivery"
PROMPT

$stderr.puts "\n  Prompt: #{prompt.length} chars (~#{(prompt.length / 4.0).ceil} tokens)"

# ============================================================
# LLM CALL
# ============================================================

$stderr.puts "\n  Calling LLM (arrangement)..."
pending_dir = File.join(library_dir, 'pending_llm_calls')
begin
  response = LLMClient.call(prompt, call_type: 'arrangement', profile: profile, max_tokens: 16384,
                            pending_dir: pending_dir, call_name: 'arrangement')
rescue LLMClient::Pending => e
  $stderr.puts e.message
  exit 2
end

# Parse YAML response — strip code fences if present
yaml_text = response.gsub(/\A```ya?ml\s*/, '').gsub(/```\s*\z/, '').strip

begin
  result = YAML.safe_load(yaml_text, permitted_classes: [Date])
rescue Psych::SyntaxError => e
  $stderr.puts "  WARNING: YAML parse error: #{e.message}"
  $stderr.puts "  Attempting recovery..."

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

# Required fields
%w[cut_summary target_format estimated_duration branch chapters].each do |field|
  abort "ABORT: LLM response missing required field: #{field}" unless result[field]
end

chapters = result['chapters'] || []
abort "ABORT: No chapters in LLM response" if chapters.empty?

# Validate chapter structure
chapters.each_with_index do |ch, i|
  expected_id = "ch_#{(i + 1).to_s.rjust(2, '0')}"
  %w[id label clips].each do |field|
    abort "ABORT: Chapter #{i + 1} missing '#{field}'" unless ch[field]
  end
  abort "ABORT: Chapter #{ch['id']} has no clips" if ch['clips'].empty?
end

# Validate clip structure
all_clips = chapters.flat_map { |ch| ch['clips'] || [] }

# Build set of unusable t-values from ingest
unusable_t_values = all_ingest_clips
  .select { |c| c['usability'] == 'unusable' }
  .map { |c| c['t'].to_f }

all_clips.each do |clip|
  %w[t_in t_out source track narrative_role].each do |field|
    abort "ABORT: Clip missing '#{field}': #{clip.inspect}" unless clip[field]
  end
  t_in = clip['t_in'].to_f
  t_out = clip['t_out'].to_f
  abort "ABORT: Clip t_out (#{t_out}) must be > t_in (#{t_in})" unless t_out > t_in

  if unusable_t_values.include?(t_in)
    abort "ABORT: Clip at t_in=#{t_in} references an unusable clip"
  end
end

v1_clips = all_clips.select { |c| c['track'] == 'V1' }
v2_clips = all_clips.select { |c| c['track'] == 'V2' }

# Parse estimated duration
est_dur_str = result['estimated_duration'].to_s
if est_dur_str =~ /(\d+):(\d+)/
  est_dur_seconds = $1.to_i * 60 + $2.to_i
else
  est_dur_seconds = est_dur_str.to_f
end

# Warn if outside target range
if target_duration_range =~ /(\d+)-(\d+)/
  range_min, range_max = $1.to_i, $2.to_i
  if est_dur_seconds < range_min || est_dur_seconds > range_max
    $stderr.puts "  WARNING: Estimated duration #{est_dur_str} (#{est_dur_seconds}s) outside target range #{target_duration_range}s"
  end
end

# Default missing optional fields
result['broll_placements'] ||= []
result['broll_suggestions'] ||= []
result['key_decisions'] ||= []

# Enrich with metadata
result['generated_at'] = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
result['source'] = library_name
result['cache_hash'] = cache_hash
result['llm_model'] = profile.dig('llm_routing', 'arrangement') || LLMClient::DEFAULT_MODEL

$stderr.puts "  Parsed: #{chapters.size} chapters, #{all_clips.size} clips (V1: #{v1_clips.size}, V2: #{v2_clips.size})"

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
  $stderr.puts "PROPOSED CUT: #{library_name}"
  $stderr.puts '=' * 60
  $stderr.puts "\nTarget: #{target_format} (#{result['estimated_duration']} estimated)"
  $stderr.puts "Branch: #{result['branch']}"
  $stderr.puts "\nSummary:"
  $stderr.puts result['cut_summary']
  if result['key_decisions'].any?
    $stderr.puts "\nKey decisions:"
    result['key_decisions'].each { |d| $stderr.puts "  - #{d}" }
  end
  broll_matched = result['broll_placements'].size
  broll_suggested = result['broll_suggestions'].size
  $stderr.puts "\nB-roll: #{broll_matched} matched, #{broll_suggested} suggestions for missing"
  $stderr.puts "Chapters: #{chapters.size} | Clips: #{all_clips.size} (V1: #{v1_clips.size}, V2: #{v2_clips.size})"
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

$stderr.puts "\nArrangement complete."
puts output_path
