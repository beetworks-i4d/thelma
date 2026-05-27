#!/usr/bin/env ruby
# Phase 3 — Thesis-Driven Candidate Arrangement
# Reads discovery_pass.yaml and editorial_candidates.yaml.
# Produces arrangement.yaml v4 using candidate_id / trim_choice_id selections.
#
# Usage:
#   ruby scripts/arrange.rb --library <name> [--profile <name>]
#                           [--no-review] [--llm-mode api|claude_code]
#
# Input:
#   - discovery_pass.yaml (REQUIRED) — must contain selected_thesis
#   - editorial_candidates.yaml (REQUIRED) — validated editorial candidates
#   - library.yaml
#   - Profile YAML
#
# Output: libraries/<name>/arrangement.yaml (v4)

require 'yaml'
require 'date'
require 'json'
require 'digest'
require_relative 'load_profile'
require_relative 'llm_client'
require_relative 'library_resolver'
require_relative 'arrangement_validator'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR = File.expand_path('..', SCRIPTS_DIR)

# ─── CLI ─────────────────────────────────────────────────────────────────────

library_name = nil
profile_name = nil
skip_review  = false
llm_mode     = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'   then args.shift; library_name = args.shift
  when '--profile'   then args.shift; profile_name = args.shift
  when '--no-review' then args.shift; skip_review  = true
  when '--llm-mode'  then args.shift; llm_mode     = args.shift
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/arrange.rb --library <name> [--profile <name>] " \
          "[--no-review] [--llm-mode api|claude_code]"
  end
end
abort "Usage: ruby scripts/arrange.rb --library <name>" unless library_name

LLMClient.mode = llm_mode.to_sym if llm_mode

# ─── Load library + profile ─────────────────────────────────────────────────

library_dir = LibraryResolver.resolve(library_name)
library_yaml_path = File.join(library_dir, 'library.yaml')
abort "Library not found: #{library_dir}" unless File.exist?(library_yaml_path)

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)
tone_guide = load_tone_guide(profile)
tone_context = build_tone_context(profile, tone_guide)

output_path = File.join(library_dir, 'arrangement.yaml')

# ─── Load discovery_pass.yaml (REQUIRED) ────────────────────────────────────

discovery_path = File.join(library_dir, 'discovery_pass.yaml')
abort "PIPELINE ABORT: discovery_pass.yaml not found — run discovery_pass.rb (Phase 2) first" unless File.exist?(discovery_path)

discovery = YAML.safe_load(File.read(discovery_path), permitted_classes: [Date])
abort "PIPELINE ABORT: discovery_pass.yaml is empty or invalid" unless discovery.is_a?(Hash)

selected_thesis_id = discovery['selected_thesis']
abort "PIPELINE ABORT: No selected_thesis in discovery_pass.yaml — run Phase 2 review gate first" unless selected_thesis_id

theses = discovery['theses'] || []
chosen_thesis = theses.find { |t| t['id'] == selected_thesis_id }
abort "PIPELINE ABORT: selected_thesis '#{selected_thesis_id}' not found in theses list" unless chosen_thesis

clip_groups  = discovery['clip_groups']  || []
throughlines = discovery['throughlines'] || []

# ─── Load editorial_candidates.yaml (REQUIRED) ──────────────────────────────

candidates_path = File.join(library_dir, 'editorial_candidates.yaml')
abort "PIPELINE ABORT: editorial_candidates.yaml not found" unless File.exist?(candidates_path)

candidates_data = YAML.safe_load(File.read(candidates_path), permitted_classes: [Date])
candidates = candidates_data['candidates'] || []
abort "PIPELINE ABORT: No candidates in editorial_candidates.yaml" if candidates.empty?

profile_name_resolved = profile_name || find_profile_match(library_name) || '_default'

# ─── Cache check ─────────────────────────────────────────────────────────────

cache_parts = [
  Digest::SHA256.hexdigest(File.read(discovery_path)),
  Digest::SHA256.hexdigest(File.read(candidates_path)),
  profile_name_resolved
]
input_fingerprint = Digest::SHA256.hexdigest(cache_parts.join(':'))

if File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date]) rescue nil
  if existing.is_a?(Hash) && existing['input_fingerprint'] == input_fingerprint
    $stderr.puts "arrangement.yaml up to date (fingerprint match). Skipping."
    puts output_path
    exit 0
  end
end

# ─── Build prompt ────────────────────────────────────────────────────────────

$stderr.puts '=' * 60
$stderr.puts "ARRANGEMENT — #{library_name}"
$stderr.puts '=' * 60

# Compact candidate table
candidates_block = +""
candidates.each do |c|
  candidates_block << "#{c['id']} | priority=#{c['candidate_priority']} | usability=#{c['usability']} | confidence=#{c['confidence']}\n"
  candidates_block << "  text: #{c['text']}\n"
  candidates_block << "  summary: #{c['summary']}\n" if c['summary']
  candidates_block << "  distillation: #{c['distillation']}\n" if c['distillation']
  candidates_block << "  suggested_roles: #{(c['suggested_narrative_roles'] || []).map { |r| r['role'] }.join(', ')}\n"
  candidates_block << "  states: #{(c['states'] || []).join(', ')}\n"
  candidates_block << "  durability: #{c['durability']}\n" if c['durability']
  candidates_block << "  prosody: #{(c['prosody'] || {}).to_yaml.gsub(/^---\n/, '').lines.map { |l| '    ' + l }.join}"
  candidates_block << "  trim_choices:\n"
  (c['trim_choices'] || []).each do |t|
    candidates_block << "    - #{t['id']} | safe=#{t['mechanical_boundary_safe']} | preserves_content=#{t['content_preserved']} | label=#{t['label']}\n"
  end
  candidates_block << "  exclusion_choices:\n"
  (c['exclusion_choices'] || []).each do |e|
    candidates_block << "    - #{e['id']} | type=#{e['type']} | recommended=#{e['recommended']} | reason=#{e['reason']}\n"
  end
  candidates_block << "\n"
end

$stderr.puts "  Thesis: #{selected_thesis_id} — #{chosen_thesis['logline'].to_s.strip[0..80]}"
$stderr.puts "  Segments: #{segments.size}, Clip groups: #{clip_groups.size}, Throughlines: #{throughlines.size}"

# Editorial bias (D9)
editorial_frame = <<~EDITORIAL
  ## Editorial Frame
  You have been given a chosen thesis. Your job is to select and order segments from the material
  that serve this thesis as the tightest, most engaging cut possible.

  Aim for the tightest, most engaging cut the material supports. Err shorter when possible.
  Texture, asides, and examples earn their place when they meaningfully advance OR meaningfully
  enrich the video AND are engaging on their own merits. Bar is "earns its seconds," not
  "serves the thesis exclusively."

  You must honor declared relationships:
  - alternate_takes: pick one; you may override selection_guidance.recommended when the thesis
    specifically demands a different take, but you must state why in arrangement_reasoning.
  - setup_payoff: segments travel together; if one is in the cut, the other must be too.
  - throughline open/close pairs must both appear with the specified distance between them.
  - bridge and run-on groupings preserve their internal coherence.
  - tangents are evaluated against the editorial bias — include only if they earn their seconds.
EDITORIAL

prompt = <<~PROMPT
  You are a senior video editor creating a thesis-driven cut.

  #{editorial_frame}

  ## Chosen Thesis

  ID: #{chosen_thesis['id']}
  Logline: #{chosen_thesis['logline']}
  Target Duration: #{chosen_thesis['duration']}
  Shape & Risk: #{chosen_thesis['shape_and_risk']}

  ## Clip Groups
  #{clip_groups.to_yaml}

  ## Throughlines
  #{throughlines.to_yaml}

  ## Editorial Candidates

  #{candidates_block}

  ## Task

  Produce arrangement.yaml v4 selecting and ordering editorial candidates that serve the chosen thesis.
  Each candidate is an editorial unit. Select by candidate_id, choose exactly one trim_choice_id, and choose zero or more exclusion_choice_ids.

  For each chapter:
  - Select segments that advance the thesis
  - Order them for maximum engagement and narrative coherence
  - Reference clip_group_ref when a segment belongs to a clip_group
  - Add notes for any editorial decisions (take overrides, ordering rationale)

  For throughlines:
  - Track which chapters contain open/middle/close segments
  - Note whether distance_guidance was honored

  For unused segments:
  - Categorize why each unused segment was excluded:
    cut_by_thesis, alternate_take_not_chosen, cut_for_pacing, bridge_dropped

  ## Output Schema

  Respond with ONLY valid YAML. No markdown code fences.

  arrangement_reasoning: |
    [How this cut serves the chosen thesis, key trade-offs made,
    why alternate-take overrides happened if any, how throughlines were honored.]

  chapters:
    - id: chapter_001
      title: "Chapter title"
      segments:
        - candidate_id: cand_NNN
          trim_choice_id: trim_NNN
          exclusion_choice_ids: []
          narrative_role: hook
          clip_group_ref: cg_NNN       # optional, if honoring a clip_group
          notes: "editorial note"       # optional

  throughline_honoring:
    - throughline_id: tl_NNN
      open_chapter: chapter_NNN
      middle_chapters: [chapter_NNN, ...]
      close_chapter: chapter_NNN
      notes: "within/outside distance_guidance"

  unused_candidate_audit:
    cut_by_thesis: [cand_NNN, ...]
    alternate_take_not_chosen: [cand_NNN, ...]
    cut_for_pacing: [cand_NNN, ...]
    bridge_dropped: [cand_NNN, ...]
PROMPT

# Tone context goes to system message with prompt caching
cached_system = tone_context.empty? ? nil : tone_context
prompt_total = prompt.length + (cached_system&.length || 0)
$stderr.puts "  Prompt: #{prompt.length} chars + #{cached_system&.length || 0} system (~#{(prompt_total / 4.0).ceil} tokens)"

# ─── LLM call ───────────────────────────────────────────────────────────────

arrange_model = profile.dig('llm_routing', 'arrangement') || 'claude-opus-4-6'
$stderr.puts "  Calling LLM (#{arrange_model}) for arrangement..."

pending_dir = File.join(library_dir, 'pending_llm_calls')
begin
  response = LLMClient.call(prompt, call_type: 'arrangement', profile: profile,
                            model: arrange_model, max_tokens: 32768,
                            pending_dir: pending_dir, call_name: 'arrangement',
                            cached_system_prompt: cached_system,
                            input_fingerprint: input_fingerprint)
rescue LLMClient::Pending => e
  $stderr.puts e.message
  exit 2
end

# ─── Parse response ──────────────────────────────────────────────────────────

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
    raw_path = File.join(library_dir, 'arrangement_raw_response.txt')
    File.write(raw_path, response)
    abort "PIPELINE ABORT: LLM returned invalid YAML that could not be recovered.\n" \
          "Error: #{e2.message}\nRaw response saved: #{raw_path}\n\n" \
          "Response (first 500 chars):\n#{yaml_text[0..500]}"
  end
end

abort "PIPELINE ABORT: LLM response is not a Hash" unless result.is_a?(Hash)

# Enrich with metadata
result['version']           = '4'
result['branch']            = 'B'
result['input_fingerprint'] = input_fingerprint
result['generated_at']      = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
result['selected_thesis']   = selected_thesis_id
result['model']             = arrange_model

# Ensure optional blocks exist
result['arrangement_reasoning']  ||= ''
result['throughline_honoring']   ||= []
result['unused_candidate_audit']   ||= {
  'cut_by_thesis' => [], 'alternate_take_not_chosen' => [],
  'cut_for_pacing' => [], 'bridge_dropped' => []
}

validation = ArrangementValidator.validate(result, candidates_data, discovery_data: discovery)
validation[:warnings].each { |w| $stderr.puts "  #{w}" }
if validation[:errors].any?
  validation[:errors].each { |e| $stderr.puts "  ERROR: #{e}" }
  abort "PIPELINE ABORT: arrangement.yaml v4 validation failed"
end

chapters = result['chapters'] || []
total_candidates = chapters.sum { |ch| (ch['segments'] || []).size }
$stderr.puts "  Parsed: #{chapters.size} chapters, #{total_candidates} candidates arranged"

# ─── Write output ────────────────────────────────────────────────────────────

File.write(output_path, YAML.dump(result))
$stderr.puts "  Written: #{output_path}"

# ─── Review gate ─────────────────────────────────────────────────────────────

unless skip_review
  $stderr.puts "\n#{'=' * 68}"
  $stderr.puts "  PROPOSED CUT: #{library_name}"
  $stderr.puts "  Thesis: #{selected_thesis_id}"
  $stderr.puts '=' * 68

  $stderr.puts "\n  Reasoning:"
  $stderr.puts "  #{result['arrangement_reasoning'].to_s.strip}"

  $stderr.puts "\n  Chapters:"
  chapters.each do |ch|
    seg_count = (ch['segments'] || []).size
    $stderr.puts "    #{ch['id']}: #{ch['title']} (#{seg_count} segments)"
  end

  unused = result['unused_candidate_audit'] || {}
  unused_total = unused.values.flatten.size
  $stderr.puts "\n  Unused candidates: #{unused_total}"
  $stderr.puts "    cut_by_thesis: #{(unused['cut_by_thesis'] || []).size}"
  $stderr.puts "    alternate_take_not_chosen: #{(unused['alternate_take_not_chosen'] || []).size}"
  $stderr.puts "    cut_for_pacing: #{(unused['cut_for_pacing'] || []).size}"
  $stderr.puts "    bridge_dropped: #{(unused['bridge_dropped'] || []).size}"

  $stderr.puts "\n  (y) Continue  (r) Show full output  (n) Abort"
  $stderr.print "  > "

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
