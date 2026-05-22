#!/usr/bin/env ruby
# DEPRECATED — replaced by discovery_pass.rb / arrange.rb / register_pool_sources.rb in Session 3 (v4.1).
# Displays arc candidate summary from arc_candidates.yaml.
# Called by orchestrate.rb before interactive selection, or run standalone.
#
# Usage:
#   ruby scripts/present_candidates.rb --library <name>

require 'yaml'
require 'date'
require_relative 'library_resolver'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

library_name = nil
args = ARGV.dup
while args.any?
  case args.first
  when '--library' then args.shift; library_name = args.shift
  else
    abort "Unknown argument: #{args.first}\nUsage: ruby scripts/present_candidates.rb --library <name>"
  end
end
abort "Usage: ruby scripts/present_candidates.rb --library <name>" unless library_name

library_dir = LibraryResolver.resolve(library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

candidates_path = File.join(library_dir, 'arc_candidates.yaml')
abort "arc_candidates.yaml not found — run arc discovery first" unless File.exist?(candidates_path)

data       = YAML.safe_load(File.read(candidates_path), permitted_classes: [Date])
candidates = data['candidates'] || []
abort "No candidates in arc_candidates.yaml" if candidates.empty?

context = data['discovery_context'] || {}

puts ''
puts '=' * 68
puts "  ARC CANDIDATES — #{library_name.tr('-', ' ').upcase}"
if context['topic'] || context['template'] || context['target_format']
  meta = []
  meta << "topic: #{context['topic']}" if context['topic']
  meta << "template: #{context['template']}" if context['template']
  meta << "format: #{context['target_format']}" if context['target_format']
  puts "  #{meta.join('  |  ')}"
end
puts '=' * 68

candidates.each_with_index do |c, i|
  dur       = c['estimated_duration'] || '?'
  conf      = c['confidence'] || '?'
  hook      = c['hook_strength']    ? format('%.2f', c['hook_strength'].to_f)    : '?'
  coherence = c['coherence_score']  ? format('%.2f', c['coherence_score'].to_f)  : '?'
  type      = c['structure_type']   || 'unknown'
  clips_n   = (c['clip_sequence']         || []).size
  bridges   = (c['missing_bridge_clips']  || []).size

  puts ''
  puts "  #{i + 1}. #{c['title']} (#{c['id']})"
  puts "     #{dur}  |  #{type}  |  hook #{hook}  coherence #{coherence}  |  #{conf} confidence"
  puts "     #{clips_n} clip(s)#{bridges > 0 ? "  |  #{bridges} missing bridge(s)" : ''}"

  if c['arc_summary']
    summary = c['arc_summary'].to_s.strip.split(/\.[\s\n]/).first.to_s.strip
    summary = summary[0, 100] + '...' if summary.length > 100
    puts "     \"#{summary}\""
  end
end

unused = data['unused_clips'] || []
puts ''
puts "  Unused pool clips: #{unused.size}"
puts '=' * 68
puts ''
