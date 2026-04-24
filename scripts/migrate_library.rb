#!/usr/bin/env ruby
# Migrates a library from ~/thelma/libraries/<name>/ to <pool_dir>/.thelma/
# and registers it in libraries_registry.yaml.
#
# Usage:
#   ruby scripts/migrate_library.rb --library <name> [--dry-run]

require 'yaml'
require 'fileutils'
require_relative 'library_resolver'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR    = File.expand_path('..', SCRIPTS_DIR)

library_name = nil
dry_run      = false

args = ARGV.dup
while args.any?
  case args.first
  when '--library'  then args.shift; library_name = args.shift
  when '--dry-run'  then args.shift; dry_run = true
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/migrate_library.rb --library <name> [--dry-run]"
  end
end

abort "Usage: ruby scripts/migrate_library.rb --library <name>" unless library_name

old_dir      = File.join(ROOT_DIR, 'libraries', library_name)
library_yaml = File.join(old_dir, 'library.yaml')
abort "Library not found: #{old_dir}" unless File.exist?(library_yaml)

library  = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date]) rescue {}
pool_dir = library['pool_dir']

if pool_dir.nil? || pool_dir.to_s.strip.empty?
  $stderr.print "pool_dir not set in library.yaml. Enter footage folder path:\n> "
  pool_dir = $stdin.gets&.strip
  abort "No pool_dir provided — aborting." if pool_dir.nil? || pool_dir.empty?
end

pool_dir = File.expand_path(pool_dir)
abort "Pool directory not found: #{pool_dir}" unless File.directory?(pool_dir)

new_dir = File.join(pool_dir, '.thelma')
abort "Target already exists: #{new_dir}" if File.exist?(new_dir)

puts "Migration plan:"
puts "  From: #{old_dir}"
puts "  To:   #{new_dir}"
puts "  Register as: #{library_name}"

if dry_run
  puts "\n[DRY RUN] No files moved."
  exit 0
end

# Copy library to new location
FileUtils.cp_r(old_dir, new_dir)

# Update pool_dir in library.yaml at new location
new_library_yaml = File.join(new_dir, 'library.yaml')
lib = YAML.safe_load(File.read(new_library_yaml), permitted_classes: [Date]) rescue {}
lib['pool_dir'] = pool_dir
File.write(new_library_yaml, lib.to_yaml)

# Register in registry
LibraryResolver.register(library_name, new_dir)
puts "Registered: #{library_name} → #{new_dir}"

# Optionally remove old directory
$stderr.print "\nRemove old directory at #{old_dir}? [y/N] "
answer = $stdin.gets&.strip
if answer&.downcase == 'y'
  FileUtils.rm_rf(old_dir)
  puts "Removed: #{old_dir}"
else
  puts "Old directory kept: #{old_dir}"
end

puts "\nMigration complete."
