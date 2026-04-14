#!/usr/bin/env ruby
# Phase 1.1 — Classification Output Validator
# Validates segments_classified.yaml against the 15-state taxonomy and
# structural rules from Content Psychopharmacology.
#
# Usage: ruby scripts/validate_classification.rb <segments_classified.yaml>
# Output: JSON report to stdout, progress to stderr.
#
# Exit codes:
#   0 — all valid
#   1 — structural errors (required field missing, wrong type)
#   2 — taxonomy violations (invalid state names, out-of-range values)
#   3 — data errors (time ranges overlap, t >= e)

require 'yaml'
require 'json'
require 'date'
require 'digest'

VALID_STATES = %w[
  vindication outrage awe competence fear schadenfreude amusement
  catharsis nostalgia belonging escape calm aspiration sensual curiosity
].freeze

VALID_DURABILITY = %w[spike mood identity].freeze
VALID_ROLES = %w[primary secondary tertiary].freeze
VALID_CONFIDENCE = %w[high medium low].freeze
VALID_NARRATIVE_ROLES = %w[claim evidence setup payoff definition aside transition].freeze
VALID_BEATS = %w[hook close talking_point_1 talking_point_2 talking_point_3
                 talking_point_4 talking_point_5 talking_point_6].freeze

# Detect Branch A (script-locked) vs Branch B (state-architected)
def detect_branch(data)
  return :a if data.key?('segments_used')
  :b
end

def seg_label(seg, idx, branch)
  key = branch == :a ? 'segments_used' : 'segments'
  t_val = seg['t'].is_a?(Numeric) ? seg['t'] : '?'
  "#{key}[#{idx}] (t=#{t_val})"
end

def validate_branch_b(seg, idx, has_scopes, violations)
  prefix = seg_label(seg, idx, :b)

  # Required fields
  %w[t e states distillation dur roles confidence].each do |field|
    violations[:structural] << "#{prefix}: missing required field '#{field}'" unless seg.key?(field)
  end

  # Type checks
  violations[:structural] << "#{prefix}: 't' must be numeric" unless seg['t'].is_a?(Numeric)
  violations[:structural] << "#{prefix}: 'e' must be numeric" unless seg['e'].is_a?(Numeric)
  violations[:structural] << "#{prefix}: 'states' must be array" unless seg['states'].is_a?(Array)
  violations[:structural] << "#{prefix}: 'roles' must be array" unless seg['roles'].is_a?(Array)
  violations[:structural] << "#{prefix}: 'dur' must be string" unless seg['dur'].is_a?(String)
  violations[:structural] << "#{prefix}: 'confidence' must be string" unless seg['confidence'].is_a?(String)

  # Scope requirement
  if has_scopes && !seg.key?('scope')
    violations[:structural] << "#{prefix}: missing 'scope' (required when scopes defined)"
  end

  # Taxonomy: states
  if seg['states'].is_a?(Array)
    violations[:taxonomy] << "#{prefix}: states array is empty" if seg['states'].empty?
    violations[:taxonomy] << "#{prefix}: too many states (#{seg['states'].size}, max 3)" if seg['states'].size > 3
    seg['states'].each do |st|
      violations[:taxonomy] << "#{prefix}: invalid state '#{st}'" unless VALID_STATES.include?(st)
    end
  end

  # Taxonomy: dur
  if seg['dur'].is_a?(String) && !VALID_DURABILITY.include?(seg['dur'])
    violations[:taxonomy] << "#{prefix}: invalid durability '#{seg['dur']}'"
  end

  # Taxonomy: roles
  if seg['roles'].is_a?(Array)
    seg['roles'].each do |r|
      violations[:taxonomy] << "#{prefix}: invalid role '#{r}'" unless VALID_ROLES.include?(r)
    end
  end

  # Taxonomy: confidence
  if seg['confidence'].is_a?(String) && !VALID_CONFIDENCE.include?(seg['confidence'])
    violations[:taxonomy] << "#{prefix}: invalid confidence '#{seg['confidence']}'"
  end

  # Taxonomy: narrative_role (optional but validated when present)
  if seg.key?('narrative_role') && !VALID_NARRATIVE_ROLES.include?(seg['narrative_role'])
    violations[:taxonomy] << "#{prefix}: invalid narrative_role '#{seg['narrative_role']}'"
  end

  # Taxonomy: distillation length
  if seg['distillation'].is_a?(String) && seg['distillation'].split.size > 5
    violations[:taxonomy] << "#{prefix}: distillation too long (#{seg['distillation'].split.size} words, max 5)"
  end

  # Data: time range
  if seg['t'].is_a?(Numeric) && seg['e'].is_a?(Numeric) && seg['t'] >= seg['e']
    violations[:data] << "#{prefix}: t (#{seg['t']}) >= e (#{seg['e']})"
  end
end

def validate_branch_a(seg, idx, violations)
  prefix = seg_label(seg, idx, :a)

  %w[t e beat states confidence].each do |field|
    violations[:structural] << "#{prefix}: missing required field '#{field}'" unless seg.key?(field)
  end

  violations[:structural] << "#{prefix}: 't' must be numeric" unless seg['t'].is_a?(Numeric)
  violations[:structural] << "#{prefix}: 'e' must be numeric" unless seg['e'].is_a?(Numeric)
  violations[:structural] << "#{prefix}: 'states' must be array" unless seg['states'].is_a?(Array)
  violations[:structural] << "#{prefix}: 'confidence' must be string" unless seg['confidence'].is_a?(String)

  if seg['states'].is_a?(Array)
    violations[:taxonomy] << "#{prefix}: states array is empty" if seg['states'].empty?
    violations[:taxonomy] << "#{prefix}: too many states (#{seg['states'].size}, max 3)" if seg['states'].size > 3
    seg['states'].each do |st|
      violations[:taxonomy] << "#{prefix}: invalid state '#{st}'" unless VALID_STATES.include?(st)
    end
  end

  if seg['confidence'].is_a?(String) && !VALID_CONFIDENCE.include?(seg['confidence'])
    violations[:taxonomy] << "#{prefix}: invalid confidence '#{seg['confidence']}'"
  end

  if seg['beat'].is_a?(String) && !VALID_BEATS.include?(seg['beat'])
    violations[:taxonomy] << "#{prefix}: invalid beat '#{seg['beat']}'"
  end

  if seg['t'].is_a?(Numeric) && seg['e'].is_a?(Numeric) && seg['t'] >= seg['e']
    violations[:data] << "#{prefix}: t (#{seg['t']}) >= e (#{seg['e']})"
  end
end

def check_overlaps(segments, violations)
  # Group by scope if scoped, otherwise check all together
  groups = segments.group_by { |s| s['scope'] || '__global__' }

  groups.each do |_scope, segs|
    sorted = segs.select { |s| s['t'].is_a?(Numeric) && s['e'].is_a?(Numeric) }
                 .sort_by { |s| s['t'] }

    sorted.each_cons(2) do |a, b|
      if a['e'] > b['t'] + 0.01 # 10ms tolerance for float rounding
        violations[:data] << "overlap: segment ending at #{a['e']} overlaps segment starting at #{b['t']}"
      end
    end
  end
end

# --- Main ---

path = ARGV[0]
abort "Usage: ruby scripts/validate_classification.rb <segments_classified.yaml>" unless path
abort "File not found: #{path}" unless File.exist?(path)

$stderr.puts "Validating: #{path}"

begin
  data = YAML.safe_load(File.read(path), permitted_classes: [Date])
rescue Psych::SyntaxError => e
  report = { file: path, valid: false, exit_code: 1,
             violations: { structural: ["YAML parse error: #{e.message}"] } }
  puts JSON.pretty_generate(report)
  exit 1
end

unless data.is_a?(Hash)
  report = { file: path, valid: false, exit_code: 1,
             violations: { structural: ["Top level must be a YAML mapping, got #{data.class}"] } }
  puts JSON.pretty_generate(report)
  exit 1
end

violations = { structural: [], taxonomy: [], data: [] }
branch = detect_branch(data)

$stderr.puts "  Branch: #{branch == :a ? 'A (script-locked)' : 'B (state-architected)'}"

if branch == :b
  segments = data['segments']
  unless segments.is_a?(Array)
    violations[:structural] << "missing or invalid 'segments' array"
    segments = []
  end
  violations[:structural] << "missing 'transcript_hash'" unless data.key?('transcript_hash')

  has_scopes = data.key?('scopes') && data['scopes'].is_a?(Hash)
  $stderr.puts "  Segments: #{segments.size}#{has_scopes ? " (scoped)" : ''}"

  segments.each_with_index { |seg, idx| validate_branch_b(seg, idx, has_scopes, violations) }
  check_overlaps(segments, violations)
else
  segments = data['segments_used']
  unless segments.is_a?(Array)
    violations[:structural] << "missing or invalid 'segments_used' array"
    segments = []
  end
  violations[:structural] << "missing 'scope' (Branch A requires scope)" unless data.key?('scope')
  $stderr.puts "  Segments: #{segments.size}"

  segments.each_with_index { |seg, idx| validate_branch_a(seg, idx, violations) }
  check_overlaps(segments, violations)
end

# Determine exit code: structural > taxonomy > data
total = violations.values.map(&:size).sum
exit_code = if violations[:structural].any? then 1
            elsif violations[:taxonomy].any? then 2
            elsif violations[:data].any? then 3
            else 0
            end

$stderr.puts "  Result: #{total == 0 ? 'PASS' : "#{total} violation(s)"}"

report = {
  file: path,
  file_hash: Digest::MD5.hexdigest(File.read(path)),
  branch: branch == :a ? 'A' : 'B',
  segment_count: segments.size,
  valid: total == 0,
  exit_code: exit_code,
  violation_counts: { structural: violations[:structural].size,
                      taxonomy: violations[:taxonomy].size,
                      data: violations[:data].size,
                      total: total }
}
report[:violations] = violations.reject { |_, v| v.empty? } if total > 0

puts JSON.pretty_generate(report)
exit exit_code
