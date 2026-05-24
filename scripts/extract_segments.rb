#!/usr/bin/env ruby
# Deterministic segment extraction — Phase 1.4 (Session 3).
# Reads cleaned_transcript.json per source video, writes segments_classified.yaml
# with nil placeholders for enrichment by audio_emotion.rb and merge_prosody_segments.rb.
#
# Usage: ruby scripts/extract_segments.rb --library <name>
#
# Output: libraries/<name>/segments_classified.yaml

require 'yaml'
require 'json'
require 'date'
require 'digest'
require 'fileutils'
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
    abort "Unknown argument: #{args.first}\nUsage: ruby scripts/extract_segments.rb --library <name>"
  end
end
abort "Usage: ruby scripts/extract_segments.rb --library <name>" unless library_name

# ─── Load library ────────────────────────────────────────────────────────────

library_dir = LibraryResolver.resolve(library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

library_yaml_path = File.join(library_dir, 'library.yaml')
abort "library.yaml not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
videos  = library['videos'] || []
abort "PIPELINE ABORT: library.yaml has zero source videos" if videos.empty?

transcripts_dir = File.join(library_dir, 'transcripts')
output_path     = File.join(library_dir, 'segments_classified.yaml')

# ─── Resolve cleaned transcript paths ────────────────────────────────────────

transcript_paths = []
videos.each do |v|
  filename = v['cleaned_transcript'] || v['transcript']
  unless filename
    source = File.basename(v['path'].to_s)
    abort "PIPELINE ABORT: No transcript for source #{source} in library.yaml"
  end
  path = File.join(transcripts_dir, filename)
  unless File.exist?(path)
    abort "PIPELINE ABORT: Cleaned transcript not found: #{path}"
  end
  transcript_paths << path
end

# ─── Cache check ─────────────────────────────────────────────────────────────

video_list_yaml = videos.map { |v| File.basename(v['path'].to_s) }.join(':')
fingerprint_parts = [video_list_yaml]
transcript_paths.each do |tp|
  fingerprint_parts << Digest::SHA256.hexdigest(File.read(tp))
end
input_fingerprint = Digest::SHA256.hexdigest(fingerprint_parts.join(':'))

if File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date]) rescue nil
  if existing.is_a?(Hash) && existing['input_fingerprint'] == input_fingerprint
    $stderr.puts "segments_classified.yaml up to date (fingerprint match). Skipping."
    puts output_path
    exit 0
  else
    $stderr.puts "segments_classified.yaml stale — regenerating"
    # Invalidate downstream caches (parent YAMLs + LLM response files)
    %w[discovery_pass.yaml arrangement.yaml].each do |downstream|
      dp = File.join(library_dir, downstream)
      if File.exist?(dp)
        File.delete(dp)
        $stderr.puts "  Invalidated #{downstream}"
      end
    end
    pending_dir = File.join(library_dir, 'pending_llm_calls')
    %w[discovery_pass_response.yaml arrangement_response.yaml].each do |resp|
      rp = File.join(pending_dir, resp)
      if File.exist?(rp)
        File.delete(rp)
        $stderr.puts "  Invalidated #{resp}"
      end
    end
  end
end

# ─── Extract segments ────────────────────────────────────────────────────────

seg_counter = 0
all_segments = []

videos.each_with_index do |v, vi|
  source_filename = File.basename(v['path'].to_s)
  tp = transcript_paths[vi]

  data = JSON.parse(File.read(tp))
  segments = data['segments'] || []

  if segments.empty?
    abort "PIPELINE ABORT: Empty transcript (no segments) in #{tp}"
  end

  segments.each do |s|
    seg_counter += 1
    seg_id = format('seg_%03d', seg_counter)

    t = (s['start'] || s['t'] || 0).to_f
    e = (s['end']   || s['e'] || t).to_f
    text = (s['text'] || '').strip

    all_segments << {
      'id'     => seg_id,
      't'      => t.round(2),
      'e'      => e.round(2),
      'text'   => text,
      'source' => source_filename,
      # Acoustic fields — populated by Phase 1.5c (audio_emotion.rb)
      'audio_profile'           => nil,
      'audio_energy'            => nil,
      'audio_energy_variance'   => nil,
      'audio_pitch_mean'        => nil,
      'audio_pitch_range'       => nil,
      'audio_pitch_trend'       => nil,
      'audio_speaking_rate'     => nil,
      'audio_spectral_centroid' => nil,
      'acoustic_pattern'        => nil,
      # Prosody aggregates — populated by Phase 1.5d (merge_prosody_segments.rb)
      'stumble_count'                => nil,
      'mid_word_break_count'         => nil,
      'mean_trailing_pause_ms'       => nil,
      'max_within_segment_pause_ms'  => nil,
      # Visual block — reserved for P2
      'visual' => {
        'shot_type'          => nil,
        'on_screen_elements' => [],
        'camera_movement'    => nil,
        'is_broll'           => nil,
        'visual_style_tag'   => nil
      }
    }
  end

  last_id = format('seg_%03d', seg_counter)
  $stderr.puts "  #{source_filename}: #{segments.size} segments (through #{last_id})"
end

# ─── Write output ────────────────────────────────────────────────────────────

result = {
  'version'           => 1,
  'input_fingerprint' => input_fingerprint,
  'generated_at'      => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
  'segments'          => all_segments
}

File.write(output_path, YAML.dump(result))
$stderr.puts "segments_classified.yaml written: #{all_segments.size} segments from #{videos.size} source(s)"
puts output_path
