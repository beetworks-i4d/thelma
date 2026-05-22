#!/usr/bin/env ruby
# Phase D.2.5 — Register Pool Sources (Session 3, Branch D only).
# Reads chosen thesis from discovery_pass.yaml, identifies which pool sources
# are referenced by segments in clip_groups + throughlines, and registers
# those source paths in library.yaml so arrange.rb and export can find them.
#
# Usage: ruby scripts/register_pool_sources.rb --library <name>

require 'yaml'
require 'date'
require_relative 'pool_index'
require_relative 'library_resolver'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

# ─── CLI ─────────────────────────────────────────────────────────────────────

library_name = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library' then args.shift; library_name = args.shift
  else
    abort "Unknown argument: #{args.first}\nUsage: ruby scripts/register_pool_sources.rb --library <name>"
  end
end
abort "Usage: ruby scripts/register_pool_sources.rb --library <name>" unless library_name

# ─── Load library ────────────────────────────────────────────────────────────

library_dir = LibraryResolver.resolve(library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

library_yaml_path = File.join(library_dir, 'library.yaml')
abort "library.yaml not found" unless File.exist?(library_yaml_path)
library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])

# ─── Load discovery_pass.yaml ───────────────────────────────────────────────

discovery_path = File.join(library_dir, 'discovery_pass.yaml')
abort "PIPELINE ABORT: discovery_pass.yaml not found — run discovery_pass.rb first" unless File.exist?(discovery_path)

discovery = YAML.safe_load(File.read(discovery_path), permitted_classes: [Date])
abort "PIPELINE ABORT: No selected_thesis in discovery_pass.yaml" unless discovery['selected_thesis']

# ─── Load segments_classified.yaml ──────────────────────────────────────────

segments_path = File.join(library_dir, 'segments_classified.yaml')
abort "PIPELINE ABORT: segments_classified.yaml not found" unless File.exist?(segments_path)

segments_data = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])
segments = segments_data['segments'] || []

# Build id → source lookup
seg_source = {}
segments.each { |s| seg_source[s['id']] = s['source'] }

# ─── Collect all referenced segment IDs ─────────────────────────────────────
# Over-registration is intentional: register everything discovery_pass mentioned,
# not just what arrange will pick. This ensures arrange has access to all material.

referenced_seg_ids = []

(discovery['clip_groups'] || []).each do |cg|
  referenced_seg_ids.concat(cg['segments'] || [])
end

(discovery['throughlines'] || []).each do |tl|
  referenced_seg_ids << tl['open'] if tl['open']
  referenced_seg_ids.concat(tl['middle'] || [])
  referenced_seg_ids << tl['close'] if tl['close']
end

referenced_seg_ids.uniq!

# Resolve to unique source filenames
referenced_sources = referenced_seg_ids.filter_map { |sid| seg_source[sid] }.uniq

$stderr.puts "  Referenced segments: #{referenced_seg_ids.size}"
$stderr.puts "  Unique sources: #{referenced_sources.size}"

# ─── Load pool index ────────────────────────────────────────────────────────

pool_dir = library['pool_dir']
abort "PIPELINE ABORT: pool_dir not set in library.yaml — Branch D requires pool indexing" unless pool_dir && !pool_dir.to_s.strip.empty?
pool_dir = File.expand_path(pool_dir)
abort "PIPELINE ABORT: pool_dir not found: #{pool_dir}" unless File.directory?(pool_dir)

index = PoolIndex.load(library_dir)
pool_sources = index['sources'] || {}

# ─── Resolve source paths and register ──────────────────────────────────────

def find_in_pool(pool_dir, filename)
  Dir.glob(File.join(pool_dir, '**', filename)).first
end

transcripts_dir = File.join(library_dir, 'transcripts')
video_entries = []
registered = 0

referenced_sources.each do |filename|
  abs_path = find_in_pool(pool_dir, filename)
  unless abs_path
    abort "PIPELINE ABORT: Source '#{filename}' not found in pool at #{pool_dir}"
  end

  # Check if already registered with same path
  existing = (library['videos'] || []).find { |v| File.basename(v['path'].to_s) == filename }
  if existing && existing['path'] == abs_path
    video_entries << existing
    next
  end

  entry = { 'path' => abs_path }

  # Pull transcript and analysis info from pool index
  idx_entry = pool_sources[filename]
  if idx_entry
    entry['transcript']     = idx_entry['transcript_file'] if idx_entry['transcript_file']
    entry['speech_analysis'] = idx_entry['speech_analysis'] if idx_entry['speech_analysis']
    entry['audio_features']  = idx_entry['audio_features']  if idx_entry['audio_features']

    # Get duration via ffprobe
    dur_str = `ffprobe -v error -show_entries format=duration -of csv=p=0 "#{abs_path}" 2>/dev/null`.strip
    entry['duration'] = dur_str unless dur_str.empty?
  end

  video_entries << entry
  registered += 1
end

if video_entries.any?
  library['videos'] = video_entries
  File.write(library_yaml_path, YAML.dump(library))
  $stderr.puts "  library.yaml['videos'] updated: #{video_entries.size} source(s) (#{registered} newly registered)"
else
  $stderr.puts "  WARNING: No source paths resolved — library.yaml['videos'] not updated"
end
