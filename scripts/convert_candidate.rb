#!/usr/bin/env ruby
# Converts an arc candidate from arc_candidates.yaml into arrangement.yaml.
# Updates library.yaml['videos'] with the pool sources required for export.
# Generates pickup_recording_suggestions.md if missing_bridge_clips are present.
#
# Usage:
#   ruby scripts/convert_candidate.rb --library <name> --candidate <id> [--profile <name>] [--force]
#
# Output: libraries/<name>/arrangement.yaml

require 'yaml'
require 'date'
require 'fileutils'
require_relative 'pool_index'
require_relative 'library_resolver'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

# ─── CLI ─────────────────────────────────────────────────────────────────────

library_name = nil
candidate_id = nil
profile_name = nil
force        = false

args = ARGV.dup
while args.any?
  case args.first
  when '--library'   then args.shift; library_name = args.shift
  when '--candidate' then args.shift; candidate_id = args.shift
  when '--profile'   then args.shift; profile_name = args.shift
  when '--force'     then args.shift; force = true
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/convert_candidate.rb --library <name> --candidate <id> [--profile <name>] [--force]"
  end
end
abort "Usage: ruby scripts/convert_candidate.rb --library <name> --candidate <id>" \
  unless library_name && candidate_id

# ─── Load library ────────────────────────────────────────────────────────────

library_dir       = LibraryResolver.resolve(library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

library_yaml_path = File.join(library_dir, 'library.yaml')
library           = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])

# ─── Cache check ─────────────────────────────────────────────────────────────

arrangement_path = File.join(library_dir, 'arrangement.yaml')
if !force && File.exist?(arrangement_path) && File.size(arrangement_path) > 0
  existing = YAML.safe_load(File.read(arrangement_path), permitted_classes: [Date]) rescue {}
  if existing.is_a?(Hash) && existing['source_candidate'] == candidate_id
    $stderr.puts "Arrangement already exists for #{candidate_id} (use --force to regenerate)."
    puts arrangement_path
    exit 0
  end
end

# ─── Load arc candidates ─────────────────────────────────────────────────────

candidates_path = File.join(library_dir, 'arc_candidates.yaml')
abort "arc_candidates.yaml not found — run arc discovery first" unless File.exist?(candidates_path)

arc_data   = YAML.safe_load(File.read(candidates_path), permitted_classes: [Date])
candidates = arc_data['candidates'] || []
candidate  = candidates.find { |c| c['id'] == candidate_id }
abort "Candidate '#{candidate_id}' not found in arc_candidates.yaml" unless candidate

# ─── Load pool ───────────────────────────────────────────────────────────────

pool_dir = library['pool_dir']
abort "pool_dir not set in library.yaml" unless pool_dir && !pool_dir.to_s.strip.empty?
pool_dir = File.expand_path(pool_dir)
abort "pool_dir not found: #{pool_dir}" unless File.directory?(pool_dir)

index   = PoolIndex.load(library_dir)
sources = index['sources'] || {}

# ─── Resolve source file paths ───────────────────────────────────────────────

def find_in_pool(pool_dir, filename)
  Dir.glob(File.join(pool_dir, '**', filename)).first
end

clip_sequence   = candidate['clip_sequence'] || []
unique_sources  = clip_sequence.map { |c| c['source'] }.compact.uniq

source_paths = {}
source_durations = {}
unique_sources.each do |filename|
  abs = find_in_pool(pool_dir, filename)
  if abs
    source_paths[filename] = abs
    dur_str = `ffprobe -v error -show_entries format=duration -of csv=p=0 "#{abs}" 2>/dev/null`.strip
    source_durations[filename] = dur_str.empty? ? nil : dur_str.to_f
  else
    $stderr.puts "  WARNING: Source file not found in pool: #{filename}"
  end
end

# ─── Chapter building ────────────────────────────────────────────────────────
# Role transitions between major roles (hook/setup/development/payoff) create
# new chapter boundaries. Transition clips stay with the current chapter.

MAJOR_ROLES = %w[hook setup development payoff].freeze
ROLE_LABELS = {
  'hook'        => 'Hook',
  'setup'       => 'Setup',
  'development' => 'Development',
  'payoff'      => 'Payoff',
  'transition'  => 'Transition'
}.freeze

def build_chapters(clip_sequence, source_durations)
  chapters           = []
  current_chapter    = nil
  current_major_role = nil

  clip_sequence.each do |clip|
    role     = clip['role']
    is_major = MAJOR_ROLES.include?(role)

    if is_major && role != current_major_role && current_chapter
      chapters << current_chapter
      current_chapter    = nil
      current_major_role = nil
    end

    unless current_chapter
      label = ROLE_LABELS[role] || role&.capitalize || 'Content'
      current_chapter = {
        'id'    => "chapter_#{chapters.size + 1}",
        'label' => label,
        'clips' => []
      }
      current_major_role = role if is_major
    end

    t_in  = clip['t_in'].to_f
    t_out = clip['t_out'].to_f
    src   = clip['source']
    if source_durations[src]
      clamped = [t_out, source_durations[src]].min
      if clamped < t_out
        $stderr.puts "  CLAMP: #{src} t_out #{t_out} → #{clamped} (file duration #{source_durations[src]})"
        t_out = clamped
      end
    end
    clip_entry = {
      'source'         => src,
      't_in'           => t_in,
      't_out'          => t_out,
      'track'          => 'V1',
      'narrative_role' => role
    }
    clip_entry['speaker'] = clip['speaker'] if clip['speaker']
    current_chapter['clips'] << clip_entry
  end

  chapters << current_chapter if current_chapter
  chapters
end

chapters = build_chapters(clip_sequence, source_durations)

# ─── Broll suggestions ───────────────────────────────────────────────────────

missing_bridges  = candidate['missing_bridge_clips'] || []
broll_suggestions = missing_bridges.map do |bridge|
  {
    'between_clips' => bridge['between_clips'] || bridge,
    'description'   => bridge['description'] || bridge['why'].to_s
  }
end

# ─── Write arrangement.yaml ──────────────────────────────────────────────────

arrangement = {
  'branch'             => 'D',
  'library_name'       => library_name,
  'source_candidate'   => candidate_id,
  'generated_at'       => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'candidate_title'    => candidate['title'],
  'structure_type'     => candidate['structure_type'],
  'estimated_duration' => candidate['estimated_duration'],
  'hook_strength'      => candidate['hook_strength'],
  'coherence_score'    => candidate['coherence_score'],
  'arc_summary'        => candidate['arc_summary'],
  'chapters'           => chapters,
  'broll_suggestions'  => broll_suggestions,
  'key_decisions'      => []
}

File.write(arrangement_path, arrangement.to_yaml)
$stderr.puts "Arrangement written: #{arrangement_path}"
$stderr.puts "  #{chapters.size} chapter(s), #{clip_sequence.size} clip(s)"

# ─── Update library.yaml['videos'] ───────────────────────────────────────────

transcripts_dir = File.join(library_dir, 'transcripts')

video_entries = unique_sources.filter_map do |filename|
  abs_path = source_paths[filename]
  next unless abs_path

  entry     = { 'path' => abs_path }
  idx_entry = sources[filename]
  entry['transcript']     = idx_entry['transcript_file'] if idx_entry&.fetch('transcript_file', nil)
  entry['speech_analysis'] = idx_entry['speech_analysis'] if idx_entry&.fetch('speech_analysis', nil)
  entry
end

if video_entries.any?
  library['videos'] = video_entries
  File.write(library_yaml_path, library.to_yaml)
  $stderr.puts "  library.yaml['videos'] updated with #{video_entries.size} pool source(s)"
else
  $stderr.puts "  WARNING: No source paths resolved — library.yaml['videos'] not updated"
end

# ─── Pickup recording suggestions ────────────────────────────────────────────

if missing_bridges.any?
  pickup_path = File.join(library_dir, 'pickup_recording_suggestions.md')
  lines = []
  lines << '# Pickup Recording Suggestions'
  lines << ''
  lines << "Generated from candidate: **#{candidate['title']}** (`#{candidate_id}`)"
  lines << ''
  lines << 'These gaps were identified by arc discovery. Recording these pickups'
  lines << 'will strengthen the arc\'s transitions before re-running the pipeline.'
  lines << ''

  missing_bridges.each_with_index do |bridge, i|
    between = bridge['between_clips'] || []
    desc    = bridge['description'] || ''
    why     = bridge['why'].to_s

    lines << '---'
    lines << ''
    lines << "## Gap #{i + 1} — Between clips #{between.first} and #{between.last}"
    lines << ''
    lines << "**What to record:** #{desc}"
    lines << "**Why it matters:** #{why}" unless why.empty?
    lines << ''
    lines << '**Re-run after recording:**'
    lines << '```'
    rerun = ["--mode mine", "--library #{library_name}", "--candidate #{candidate_id}", '--force-cascade']
    rerun << "--profile #{profile_name}" if profile_name
    lines << "ruby scripts/orchestrate.rb #{rerun.join(' ')}"
    lines << '```'
    lines << ''
  end

  File.write(pickup_path, lines.join("\n") + "\n")
  $stderr.puts "  Pickup suggestions: #{pickup_path}"
end

puts arrangement_path
