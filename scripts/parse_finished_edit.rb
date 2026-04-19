#!/usr/bin/env ruby
# Parse Finished Edit — Extracts overlay placements from a finished Premiere XML export.
# Correlates overlay elements with classified segments to build production design memory.
#
# Usage:
#   ruby scripts/parse_finished_edit.rb --library <name> --finished <exported_xml_path>
#
# NOT part of the standard pipeline. Run manually after editing in Premiere.

require 'yaml'
require 'date'
require 'nokogiri'
require 'fileutils'

ROOT_DIR = File.expand_path('..', __dir__)

# --- CLI parsing ---

library_name = nil
finished_xml_path = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'
    args.shift
    library_name = args.shift
  when '--finished'
    args.shift
    finished_xml_path = args.shift
  else
    args.shift
  end
end

unless library_name && finished_xml_path
  $stderr.puts "Usage: ruby scripts/parse_finished_edit.rb --library <name> --finished <exported_xml_path>"
  exit 1
end

unless File.exist?(finished_xml_path)
  $stderr.puts "ERROR: Finished XML not found: #{finished_xml_path}"
  exit 1
end

library_dir = File.join(ROOT_DIR, 'libraries', library_name)
unless File.directory?(library_dir)
  $stderr.puts "ERROR: Library not found: #{library_dir}"
  exit 1
end

# --- Load classified segments (optional) ---

classified_path = File.join(library_dir, 'segments_classified.yaml')
classified_segments = nil
if File.exist?(classified_path)
  data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])
  classified_segments = data['segments'] || []
  $stderr.puts "Loaded #{classified_segments.size} classified segments"
else
  $stderr.puts "WARNING: No segments_classified.yaml — overlay correlation will be skipped"
end

# --- Parse XML ---

doc = Nokogiri::XML(File.read(finished_xml_path))
sequence = doc.at_xpath('//sequence')

unless sequence
  $stderr.puts "ERROR: No <sequence> element found in XML"
  exit 1
end

sequence_name = sequence.at_xpath('name')&.text || File.basename(finished_xml_path, '.xml')

# Frame rate
timebase = sequence.at_xpath('rate/timebase')&.text&.to_f || 25.0
ntsc = sequence.at_xpath('rate/ntsc')&.text&.strip&.upcase == 'TRUE'
fps = ntsc ? timebase * 1000.0 / 1001.0 : timebase

# Sequence duration
seq_duration_frames = sequence.at_xpath('duration')&.text&.to_f || 0
duration_seconds = (seq_duration_frames / fps).round(2)

$stderr.puts "Sequence: #{sequence_name} (#{duration_seconds}s @ #{fps.round(3)}fps)"

# --- Extract clips from tracks ---

def extract_clips_from_tracks(sequence, media_type, fps)
  tracks = sequence.xpath("media/#{media_type}/track")
  all_clips = []

  tracks.each_with_index do |track, idx|
    track_num = idx + 1
    track.xpath('clipitem').each do |ci|
      start_frames = ci.at_xpath('start')&.text&.to_f
      end_frames = ci.at_xpath('end')&.text&.to_f
      next unless start_frames && end_frames
      next if start_frames < 0 || end_frames < 0  # skip invalid entries

      clip_name = ci.at_xpath('name')&.text || 'unnamed'
      duration_frames = end_frames - start_frames

      # Try to get file pathurl
      file_el = ci.at_xpath('file')
      pathurl = file_el&.at_xpath('pathurl')&.text

      all_clips << {
        'track_num' => track_num,
        'track_label' => "#{media_type == 'video' ? 'V' : 'A'}#{track_num}",
        'media_type' => media_type,
        'clip_name' => clip_name,
        'start_frames' => start_frames,
        'end_frames' => end_frames,
        'start' => (start_frames / fps).round(3),
        'end' => (end_frames / fps).round(3),
        'duration' => (duration_frames / fps).round(3),
        'pathurl' => pathurl
      }
    end
  end

  all_clips
end

video_clips = extract_clips_from_tracks(sequence, 'video', fps)
audio_clips = extract_clips_from_tracks(sequence, 'audio', fps)

# --- Classify clips ---

primary_video = video_clips.select { |c| c['track_num'] == 1 }
video_overlays = video_clips.select { |c| c['track_num'] >= 2 }
primary_audio = audio_clips.select { |c| c['track_num'] <= 2 }
audio_overlays = audio_clips.select { |c| c['track_num'] >= 3 }

$stderr.puts "V1 primary: #{primary_video.size} clips"
$stderr.puts "V2+ overlays: #{video_overlays.size} clips"
$stderr.puts "A1-A2 primary: #{primary_audio.size} clips"
$stderr.puts "A3+ overlays: #{audio_overlays.size} clips"

# --- Correlate overlays with classified segments ---

def find_underlying_segment(overlay_start, classified_segments)
  return nil unless classified_segments
  classified_segments.find do |seg|
    seg_t = seg['t'].to_f
    seg_e = seg['e'].to_f
    overlay_start >= seg_t && overlay_start < seg_e
  end
end

def build_placement(clip, classified_segments)
  type = clip['media_type'] == 'video' ? 'video_overlay' : 'audio_overlay'
  seg = find_underlying_segment(clip['start'], classified_segments)

  placement = {
    'type' => type,
    'track' => clip['track_label'],
    'start' => clip['start'],
    'end' => clip['end'],
    'duration' => clip['duration'],
    'clip_name' => clip['clip_name']
  }

  if seg
    placement['underlying_segment'] = {
      't' => seg['t'],
      'distillation' => seg['distillation'],
      'states' => seg['states'],
      'dur' => seg['dur'],
      'narrative_role' => seg['narrative_role'],
      'audio_profile' => seg['audio_profile']
    }
    dur = seg['dur'] || 'unknown'
    role = seg['narrative_role'] || 'unclassified'
    placement['context'] = "overlay on #{dur} #{role} segment"
  else
    placement['underlying_segment'] = nil
    placement['context'] = classified_segments ? 'no matching classified segment' : 'classification unavailable'
  end

  placement
end

overlay_placements = []
video_overlays.each { |c| overlay_placements << build_placement(c, classified_segments) }
audio_overlays.each { |c| overlay_placements << build_placement(c, classified_segments) }

# --- Build output ---

analysis = {
  'analyzed' => Date.today.to_s,
  'source_xml' => File.basename(finished_xml_path),
  'sequence_name' => sequence_name,
  'duration_seconds' => duration_seconds,
  'fps' => fps.round(3),
  'primary_clips' => primary_video.size,
  'overlay_elements' => {
    'video_overlays' => video_overlays.size,
    'audio_overlays' => audio_overlays.size
  },
  'overlay_placements' => overlay_placements
}

# --- Write output ---

# Find next available filename
existing = Dir.glob(File.join(library_dir, 'finished_edit_analysis*.yaml'))
if existing.empty?
  output_filename = 'finished_edit_analysis.yaml'
else
  # Check if first one exists, use numbered suffix
  base = File.join(library_dir, 'finished_edit_analysis.yaml')
  if File.exist?(base)
    n = 2
    n += 1 while File.exist?(File.join(library_dir, "finished_edit_analysis_#{n}.yaml"))
    output_filename = "finished_edit_analysis_#{n}.yaml"
  else
    output_filename = 'finished_edit_analysis.yaml'
  end
end

output_path = File.join(library_dir, output_filename)
File.write(output_path, analysis.to_yaml)

$stderr.puts "Analysis written: #{output_path}"
$stderr.puts "  #{video_overlays.size} video overlays, #{audio_overlays.size} audio overlays"
puts output_path
