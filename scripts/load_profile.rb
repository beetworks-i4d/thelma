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

  Dir.glob(File.join(PROFILES_DIR, '*.yaml')).each do |path|
    name = File.basename(path, '.yaml')
    next if name == '_default'
    if normalized.include?(name.downcase)
      return name
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
    client_path = File.join(PROFILES_DIR, "#{name}.yaml")
    if File.exist?(client_path)
      client = YAML.safe_load(File.read(client_path), permitted_classes: [Date]) || {}
      base = deep_merge(base, client)
      $stderr.puts "Profile: #{name} (merged with defaults)"
    else
      $stderr.puts "WARNING: profile not found: #{client_path}, using defaults"
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

# CLI mode: ruby scripts/load_profile.rb <library_name_or_folder>
if __FILE__ == $PROGRAM_NAME
  name = ARGV[0]
  abort "Usage: ruby scripts/load_profile.rb <library_name_or_folder>" unless name
  profile = load_profile(name)
  puts profile.to_yaml
end
