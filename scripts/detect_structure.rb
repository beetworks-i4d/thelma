#!/usr/bin/env ruby
# Phase 1.9.4 — Adaptive Structure Detection
# Detects narrative structure when no existing template scores above threshold.
# Two-pass design: viability check (is there a story?) then ad-hoc template synthesis.
#
# Usage:
#   ruby scripts/detect_structure.rb <segments_classified.yaml>
#   ruby scripts/detect_structure.rb <segments_classified.yaml> --best-fit-score 52
#   ruby scripts/detect_structure.rb <segments_classified.yaml> --save-template <structure_detected.yaml>
#
# --best-fit-score N:  Best existing template fit score (context for reporting).
#                      Triggers automatically when this is below 60 (FIT_THRESHOLD).
# --save-template:     Reads a completed structure_detected.yaml and writes the
#                      synthesized template to templates/story_structures/.
#
# Output: structure_detected.yaml in same directory as input. Path to stdout.
# The viability and synthesized_template fields contain prompts — agent fills
# the actual values after running LLM.

require 'yaml'
require 'date'
require 'set'
require 'fileutils'

FIT_THRESHOLD = 60  # Below this, no existing template is considered a good match

# --- Flag parsing ---

save_template_path = nil
if (idx = ARGV.index('--save-template'))
  save_template_path = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end

category = nil
if (idx = ARGV.index('--category'))
  category = ARGV.delete_at(idx + 1)
  ARGV.delete_at(idx)
end

best_fit_score = nil
if (idx = ARGV.index('--best-fit-score'))
  best_fit_score = ARGV.delete_at(idx + 1).to_i
  ARGV.delete_at(idx)
end

segments_path = ARGV[0]

# --- Save template mode ---

if save_template_path
  abort "File not found: #{save_template_path}" unless File.exist?(save_template_path)
  detected = YAML.safe_load(File.read(save_template_path), permitted_classes: [Date])
  template = detected['synthesized_template']
  abort "No synthesized_template found in #{save_template_path}" unless template
  abort "synthesized_template has no name" unless template['name'] && !template['name'].empty?
  abort "synthesized_template has no beats" unless template['beats'] && !template['beats'].empty?

  templates_dir = File.join(File.dirname(__FILE__), '..', 'templates', 'story_structures')
  templates_dir = File.join(templates_dir, category) if category
  FileUtils.mkdir_p(templates_dir)

  filename = template['name'].downcase.gsub(/[^a-z0-9]+/, '_').gsub(/^_|_$/, '') + '.yaml'
  output_path = File.join(templates_dir, filename)

  if File.exist?(output_path)
    abort "Template already exists: #{output_path}. Remove it first or choose a different name."
  end

  # Write template in library format (compatible with match_templates.rb)
  library_template = {
    'name' => template['name'],
    'description' => template['description'],
    'beats' => template['beats'].map { |b|
      {
        'id' => b['id'],
        'description' => b['description'],
        'keywords' => b['keywords'] || [],
        'position' => b['position']
      }
    }
  }

  File.write(output_path, library_template.to_yaml)
  $stderr.puts "Template saved: #{output_path}"
  puts output_path
  exit 0
end

# --- Normal mode: detect structure ---

abort "Usage: ruby scripts/detect_structure.rb <segments_classified.yaml>" unless segments_path
abort "File not found: #{segments_path}" unless File.exist?(segments_path)

data = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])

if data.key?('segments_used')
  abort "Branch A (script-locked) classification — structure detection not needed."
end

segments = data['segments'] || []
abort "No segments found in #{segments_path}" if segments.empty?

# --- Build distillation sequence ---

sorted = segments.sort_by { |s| s['t'].to_f }
distillation_list = sorted.map { |s|
  {
    't' => s['t'].to_f,
    'e' => s['e'].to_f,
    'distillation' => s['distillation'],
    'states' => s['states'],
    'dur' => s['dur'],
    'confidence' => s['confidence']
  }
}

# Filter to substantive segments for prompt (skip filler)
substantive = distillation_list.select { |d|
  d['distillation'] && d['distillation'].strip.length >= 6
}

if substantive.empty?
  output_dir = File.dirname(segments_path)
  output_path = File.join(output_dir, 'structure_detected.yaml')
  output = {
    'generated_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
    'source' => File.basename(output_dir),
    'total_segments' => segments.size,
    'substantive_segments' => 0,
    'viability' => 'NO',
    'viability_reason' => 'No substantive distillations found.',
    'viability_prompt' => nil,
    'synthesis_prompt' => nil,
    'synthesized_template' => nil,
    'best_fit_score' => best_fit_score
  }
  File.write(output_path, output.to_yaml)
  $stderr.puts "STRUCTURE DETECTION: No substantive segments. Viability: NO"
  $stderr.puts "Output: #{output_path}"
  puts output_path
  exit 0
end

# --- Pass 1: Viability prompt ---

distillation_lines = substantive.each_with_index.map { |d, i|
  "#{i + 1}. [#{d['dur']}] #{d['distillation']}"
}.join("\n")

viability_prompt = <<~PROMPT.strip
  Read these distilled segment summaries in transcript order. Each is a 1-5 word summary of a segment from raw video footage. The [tag] indicates durability (identity = lasting impact, mood = emotional tone, spike = momentary).

  Determine if this footage contains a coherent through-line — an argument, narrative, framework, comparison, or any intentional structure.

  Respond with exactly one of:
  YES — transcript has a coherent through-line
  PARTIAL — some structured sections but also significant unstructured material
  NO — rambly, fragmented, no through-line

  Then on the next line, write a 1-sentence reason.

  If PARTIAL, on a third line write which segment numbers contain the structured sections (e.g., "Structured: 1-8, 15-22").

  Distilled segments:
  #{distillation_lines}
PROMPT

# --- Pass 2: Synthesis prompt ---
# Builds a richer prompt with state + durability data for template synthesis

synthesis_lines = substantive.each_with_index.map { |d, i|
  states_str = (d['states'] || []).join(', ')
  conf = d['confidence'] || 'unknown'
  pos = (d['t'] / (substantive.last['e'] - substantive.first['t'])).clamp(0.0, 1.0).round(2)
  "#{i + 1}. [#{d['dur']}/#{conf}] #{d['distillation']} — states: #{states_str} — position: #{pos}"
}.join("\n")

# Valid position values for templates
position_labels = %w[early early_mid mid late_mid late]

synthesis_prompt = <<~PROMPT.strip
  You are analyzing distilled segment summaries from video footage to identify its narrative structure. Each line shows durability, confidence, the distilled content, emotional states, and normalized position (0.0=start, 1.0=end).

  Produce a template that describes this content's structure. The template must be compatible with the ButterCut story structure format:

  ```yaml
  name: snake_case_name
  description: "One sentence describing the structure"
  beats:
    - id: beat_name          # snake_case, unique
      description: "What this beat does in the narrative"
      keywords: [word1, word2, ...]  # lowercase words from distillations that identify this beat
      position: early        # one of: early, early_mid, mid, late_mid, late
  ```

  Position ranges: early=[0.0-0.2], early_mid=[0.2-0.4], mid=[0.4-0.6], late_mid=[0.6-0.8], late=[0.8-1.0]

  Rules:
  - 4-8 beats (enough to capture structure, not so many it overfits)
  - Extract keywords directly from the distillation text (lowercase)
  - First beat should be at position "early", last at "late" or "late_mid"
  - Include a confidence score (0.0-1.0) and reasoning

  Also provide:
  - confidence: 0.0-1.0 (how certain you are this structure is real vs. coincidental)
  - reasoning: 1-2 sentences explaining why you identified this structure

  Distilled segments:
  #{synthesis_lines}
PROMPT

# --- Output ---

output_dir = File.dirname(segments_path)
output_path = File.join(output_dir, 'structure_detected.yaml')
source_name = File.basename(output_dir)

output = {
  'generated_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'source' => source_name,
  'total_segments' => segments.size,
  'substantive_segments' => substantive.size,
  'best_fit_score' => best_fit_score,

  # Pass 1 — agent fills viability + viability_reason after running LLM
  'viability' => nil,
  'viability_reason' => nil,
  'viability_prompt' => viability_prompt,

  # Pass 2 — agent fills synthesized_template after running LLM
  'synthesis_prompt' => synthesis_prompt,
  'synthesized_template' => nil,

  # Distillation data for reference
  'distillation_sequence' => substantive.map { |d|
    { 't' => d['t'], 'distillation' => d['distillation'], 'dur' => d['dur'], 'states' => d['states'] }
  }
}

File.write(output_path, output.to_yaml)

# --- Report ---

$stderr.puts "=" * 60
$stderr.puts "STRUCTURE DETECTION"
$stderr.puts "=" * 60
$stderr.puts "Source: #{source_name}"
$stderr.puts "Total segments: #{segments.size} | Substantive: #{substantive.size}"
if best_fit_score
  $stderr.puts "Best existing template fit: #{best_fit_score}% (threshold: #{FIT_THRESHOLD}%)"
end
$stderr.puts ""
$stderr.puts "Viability prompt generated (#{viability_prompt.length} chars, ~#{(viability_prompt.length / 4.0).ceil} tokens)"
$stderr.puts "Synthesis prompt generated (#{synthesis_prompt.length} chars, ~#{(synthesis_prompt.length / 4.0).ceil} tokens)"
$stderr.puts ""
$stderr.puts "Agent action required:"
$stderr.puts "  1. Run viability prompt → fill viability + viability_reason"
$stderr.puts "  2. If YES/PARTIAL: run synthesis prompt → fill synthesized_template"
$stderr.puts "  3. Optionally: --save-template to persist to library"
$stderr.puts ""
$stderr.puts "Output: #{output_path}"
puts output_path
