#!/usr/bin/env ruby
# Runs Silero VAD speech analysis on an audio or video file.
# Caches results in library.yaml if provided.
#
# Usage: ruby scripts/audio_analysis.rb <audio_or_video_path> [library.yaml]
# Output: prints the analysis JSON path to stdout.
#
# If library.yaml is provided and has a cached speech_analysis for this file,
# returns the cached path immediately without re-running.

require 'yaml'
require 'date'
require 'fileutils'
require 'shellwords'

input_path = ARGV[0]
library_yaml = ARGV[1]

abort "Usage: ruby scripts/audio_analysis.rb <audio_or_video_path> [library.yaml]" unless input_path
abort "File not found: #{input_path}" unless File.exist?(input_path)

# Check library.yaml cache
if library_yaml && File.exist?(library_yaml)
  lib = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date])
  if lib && lib['videos']
    entry = lib['videos'].find { |v| v['path'] == input_path }
    # Also check sync_audio path for dual-system setups
    entry ||= lib['videos'].find { |v| v.dig('sync_audio', 'path') == input_path }

    if entry && entry['speech_analysis']
      cached = entry['speech_analysis']
      # Resolve relative to library transcripts dir
      if library_yaml && !File.absolute_path?(cached.to_s)
        lib_dir = File.dirname(library_yaml)
        cached = File.join(lib_dir, 'transcripts', cached)
      end
      if File.exist?(cached)
        $stderr.puts "Using cached speech analysis: #{cached}"
        puts cached
        exit 0
      else
        $stderr.puts "Cached path not found, re-running: #{cached}"
      end
    end
  end
end

# Determine output path
basename = File.basename(input_path, File.extname(input_path))
if library_yaml && File.exist?(library_yaml)
  output_dir = File.join(File.dirname(library_yaml), 'transcripts')
else
  output_dir = File.dirname(input_path)
end
FileUtils.mkdir_p(output_dir)
output_json = File.join(output_dir, "#{basename}_speech_analysis.json")

# Run Python script
script_dir = File.expand_path(File.dirname(__FILE__))
python_script = File.join(script_dir, 'audio_analysis.py')

$stderr.puts "Running speech analysis on #{File.basename(input_path)}..."
result = system("python3", python_script, input_path, output_json)
abort "Speech analysis failed" unless result && File.exist?(output_json)

# Cache in library.yaml if provided
if library_yaml && File.exist?(library_yaml)
  lib = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date])
  if lib && lib['videos']
    # Find matching entry by video path or sync_audio path
    entry = lib['videos'].find { |v| v['path'] == input_path }
    entry ||= lib['videos'].find { |v| v.dig('sync_audio', 'path') == input_path }

    if entry
      # Store filename only (relative to transcripts dir)
      entry['speech_analysis'] = File.basename(output_json)
      lib['last_updated'] = Date.today.to_s
      File.write(library_yaml, YAML.dump(lib))
      $stderr.puts "Cached speech analysis in library.yaml"
    end
  end
end

puts output_json
