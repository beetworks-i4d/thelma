#!/usr/bin/env ruby
# Profile loader utility for Thelma.
# Loads client profiles from profiles/ directory, merges with _default.yaml.
#
# Usage:
#   require_relative 'load_profile'
#   profile = load_profile("dylan-shorts-batch-1")  # auto-match by name
#   profile = load_profile_by_name("ivan")           # explicit load
#
# Auto-match: folder/library name checked against profile filenames (case-insensitive partial match).
# Merge: client values override _default, nested hashes deep-merged.

require 'yaml'
require 'date'

PROFILES_DIR = File.expand_path('../../profiles', __FILE__)
CREATORS_DIR = File.join(PROFILES_DIR, 'creators')

def deep_merge(base, override)
  result = base.dup
  override.each do |key, value|
    if result[key].is_a?(Hash) && value.is_a?(Hash)
      result[key] = deep_merge(result[key], value)
    else
      result[key] = value
    end
  end
  result
end

def find_profile_match(library_name)
  return nil unless Dir.exist?(PROFILES_DIR)

  normalized = library_name.to_s.downcase.gsub(/[^a-z0-9]/, ' ')

  # Search creators/ subdirectory first, then profiles/ root
  search_dirs = []
  search_dirs << File.join(CREATORS_DIR, '*.yaml') if Dir.exist?(CREATORS_DIR)
  search_dirs << File.join(PROFILES_DIR, '*.yaml')

  search_dirs.each do |pattern|
    Dir.glob(pattern).each do |path|
      name = File.basename(path, '.yaml')
      next if name == '_default'
      if normalized.include?(name.downcase)
        return name
      end
    end
  end
  nil
end

def load_profile_by_name(name)
  unless Dir.exist?(PROFILES_DIR)
    $stderr.puts "WARNING: profiles directory not found: #{PROFILES_DIR}"
    return {}
  end

  default_path = File.join(PROFILES_DIR, '_default.yaml')
  unless File.exist?(default_path)
    $stderr.puts "WARNING: _default.yaml not found in #{PROFILES_DIR}"
    return {}
  end

  base = YAML.safe_load(File.read(default_path), permitted_classes: [Date]) || {}

  if name && name != '_default'
    # Check creators/ subdirectory first, then profiles/ root
    creators_path = File.join(CREATORS_DIR, "#{name}.yaml")
    root_path = File.join(PROFILES_DIR, "#{name}.yaml")
    client_path = if File.exist?(creators_path)
                    creators_path
                  elsif File.exist?(root_path)
                    root_path
                  end

    if client_path
      client = YAML.safe_load(File.read(client_path), permitted_classes: [Date]) || {}
      base = deep_merge(base, client)
      $stderr.puts "Profile: #{name} (merged with defaults)"
    else
      $stderr.puts "WARNING: profile not found: #{name}.yaml, using defaults"
    end
  else
    $stderr.puts "Profile: _default"
  end

  base
end

def load_profile(library_name_or_folder)
  normalized = File.basename(library_name_or_folder.to_s)
  match = find_profile_match(normalized)

  if match
    load_profile_by_name(match)
  else
    load_profile_by_name('_default')
  end
end

# Content type mapping: content_type → default template categories
CONTENT_TYPE_TEMPLATE_MAP = {
  'talking_head_business'   => %w[argumentative explainer],
  'talking_head_personal'   => %w[narrative explainer],
  'tutorial_screencast'     => %w[explainer],
  'tutorial_demonstration'  => %w[explainer],
  'interview'               => %w[narrative],
  'podcast'                 => %w[narrative],
  'vlog'                    => %w[narrative],
  'commentary'              => %w[argumentative],
  'narrative'               => %w[narrative],
  'unknown'                 => []
}.freeze

# Returns effective content type given a profile and library data.
# Profile explicit type wins; otherwise uses library's detected type; falls back to 'auto'.
def effective_content_type(profile, library = nil)
  profile_ct = profile['content_type']
  return profile_ct if profile_ct && profile_ct != 'auto'

  if library && library['content_type'].is_a?(Hash)
    return library['content_type']['detected']
  end

  'auto'
end

# Returns template categories for a content type.
# Profile-level template_categories override content-type defaults.
def template_categories_for(profile, library = nil)
  profile_cats = profile['template_categories'] || []
  return profile_cats unless profile_cats.empty?

  ct = effective_content_type(profile, library)
  CONTENT_TYPE_TEMPLATE_MAP[ct] || []
end

# Loads the tone guide markdown for a profile, if tone_profile.guide_doc is set.
# Returns the markdown string, or nil if not configured or file not found.
def load_tone_guide(profile)
  guide_path = profile.dig('tone_profile', 'guide_doc')
  return nil unless guide_path

  root = File.expand_path('../..', __FILE__)
  full_path = File.join(root, guide_path)
  return nil unless File.exist?(full_path)

  content = File.read(full_path)
  $stderr.puts "  Tone guide: #{guide_path} (#{content.length} chars)"
  content
end

# Builds a compact tone context block for LLM prompts from profile tone_profile fields.
# Returns a string suitable for embedding in a prompt, or empty string if no tone_profile.
def build_tone_context(profile, tone_guide = nil)
  tp = profile['tone_profile']
  return '' unless tp

  parts = []
  parts << "## Creator Tone Profile\n"

  if tone_guide
    parts << "### Voice Guide\n"
    parts << tone_guide
    parts << "\n"
  end

  parts << "### Structured Tone Parameters\n"
  parts << "- Humor register: #{Array(tp['humor_register']).join(', ')}\n" if tp['humor_register']
  parts << "- Profanity limit: #{tp['profanity_limit']}\n" if tp['profanity_limit']
  parts << "- Tangent tolerance: #{tp['tangent_tolerance']}\n" if tp['tangent_tolerance']
  parts << "- Formality: #{tp['formality']}\n" if tp['formality']

  if tp['preserve_strongly']
    parts << "\n**Preserve strongly** (these are signature voice features — do NOT mark as issues):\n"
    tp['preserve_strongly'].each { |tag| parts << "- #{tag.tr('_', ' ')}\n" }
  end

  if tp['cut_preferentially']
    parts << "\n**Cut preferentially** (these are known failure modes — flag or trim):\n"
    tp['cut_preferentially'].each { |tag| parts << "- #{tag.tr('_', ' ')}\n" }
  end

  parts.join
end

# CLI mode: ruby scripts/load_profile.rb <library_name_or_folder>
if __FILE__ == $PROGRAM_NAME
  name = ARGV[0]
  abort "Usage: ruby scripts/load_profile.rb <library_name_or_folder>" unless name
  profile = load_profile(name)
  puts profile.to_yaml
end
