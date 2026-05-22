#!/usr/bin/env ruby
# Extracts vocal emotion features from a WAV file using librosa (via Python).
# Merges audio_profile and acoustic features into segments_classified.yaml.
# Caches results in library.yaml if provided.
#
# Usage: ruby scripts/audio_emotion.rb <wav_path> <segments_classified.yaml> [library.yaml]
# Output: prints the audio_features.yaml path to stdout.

require 'yaml'
require 'date'
require 'fileutils'

wav_path = ARGV[0]
segments_yaml = ARGV[1]
library_yaml = ARGV[2]

abort "Usage: ruby scripts/audio_emotion.rb <wav_path> <segments_classified.yaml> [library.yaml]" unless wav_path && segments_yaml
abort "WAV not found: #{wav_path}" unless File.exist?(wav_path)
abort "Segments not found: #{segments_yaml}" unless File.exist?(segments_yaml)

# Check library.yaml cache
if library_yaml && File.exist?(library_yaml)
  lib = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date])
  if lib && lib['videos']
    entry = lib['videos'].find { |v| v['path'] == wav_path }
    entry ||= lib['videos'].find { |v| v.dig('sync_audio', 'path') == wav_path }

    if entry && entry['audio_features']
      cached = entry['audio_features']
      if library_yaml && !File.absolute_path?(cached.to_s)
        lib_dir = File.dirname(library_yaml)
        cached = File.join(lib_dir, 'transcripts', cached)
      end
      if File.exist?(cached)
        $stderr.puts "Using cached audio features: #{cached}"
        puts cached
        exit 0
      else
        $stderr.puts "Cached path not found, re-running: #{cached}"
      end
    end
  end
end

# Determine output path
basename = File.basename(wav_path, File.extname(wav_path))
if library_yaml && File.exist?(library_yaml)
  output_dir = File.join(File.dirname(library_yaml), 'transcripts')
else
  output_dir = File.dirname(segments_yaml)
end
FileUtils.mkdir_p(output_dir)
output_yaml = File.join(output_dir, "#{basename}_audio_features.yaml")

# Run Python script
script_dir = File.expand_path(File.dirname(__FILE__))
python_script = File.join(script_dir, 'audio_emotion.py')

$stderr.puts "Running audio emotion analysis on #{File.basename(wav_path)}..."
result = system("python3", python_script, wav_path, segments_yaml, output_yaml)
abort "Audio emotion analysis failed" unless result && File.exist?(output_yaml)

# Merge audio features into segments_classified.yaml
features_data = YAML.safe_load(File.read(output_yaml), permitted_classes: [Date])
classified_data = YAML.safe_load(File.read(segments_yaml), permitted_classes: [Date])

if features_data['segments'] && classified_data['segments']
  merged_count = 0
  features_data['segments'].each do |feat|
    seg = classified_data['segments'].find { |s| (s['t'].to_f - feat['t'].to_f).abs < 0.01 }
    next unless seg
    seg['audio_profile'] = feat['audio_profile']
    seg['audio_energy'] = feat['energy']
    seg['audio_energy_variance'] = feat['energy_variance']
    seg['audio_pitch_mean'] = feat['pitch_mean']
    seg['audio_pitch_trend'] = feat['pitch_trend']
    seg['audio_pitch_range'] = feat['pitch_range']
    seg['audio_speaking_rate'] = feat['speaking_rate']
    seg['audio_spectral_centroid'] = feat['spectral_centroid']
    seg['acoustic_pattern'] = feat['acoustic_pattern']
    merged_count += 1
  end
  File.write(segments_yaml, YAML.dump(classified_data))
  $stderr.puts "Merged audio features into #{merged_count} segments"
end

# Cache in library.yaml if provided
if library_yaml && File.exist?(library_yaml)
  lib = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date])
  if lib && lib['videos']
    entry = lib['videos'].find { |v| v['path'] == wav_path }
    entry ||= lib['videos'].find { |v| v.dig('sync_audio', 'path') == wav_path }

    if entry
      entry['audio_features'] = File.basename(output_yaml)
      lib['last_updated'] = Date.today.to_s
      File.write(library_yaml, YAML.dump(lib))
      $stderr.puts "Cached audio features in library.yaml"
    end
  end
end

puts output_yaml
