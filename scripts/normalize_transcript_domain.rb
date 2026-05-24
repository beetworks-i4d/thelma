#!/usr/bin/env ruby
# normalize_transcript_domain.rb
# Converts transcript timestamps to WAV time (canonical per-source audio time).
#
# Sources WITH sync_audio: applies +offset to convert video-time → WAV time.
# Sources WITHOUT sync_audio: labels only (MP4 audio time IS canonical).
#
# Skips sources that already have transcript_domain set in library.yaml.
# Pre-label sources known to be in WAV time before running to prevent double-conversion.
#
# Usage: ruby scripts/normalize_transcript_domain.rb --library <name> [--dry-run]

require 'yaml'
require 'json'
require 'date'
require_relative 'library_resolver'

# Apply a constant time offset to all timestamp fields in a transcript hash.
# Clamps results to >= 0.
def shift_timestamps!(data, offset)
  (data['segments'] || []).each do |seg|
    %w[start end t e].each do |f|
      next unless seg.key?(f) && seg[f]
      seg[f] = [(seg[f].to_f + offset).round(3), 0.0].max
    end
    (seg['words'] || []).each do |w|
      %w[start end].each do |f|
        next unless w.key?(f) && w[f]
        w[f] = [(w[f].to_f + offset).round(3), 0.0].max
      end
    end
  end
  (data['word_segments'] || []).each do |w|
    %w[start end].each do |f|
      next unless w.key?(f) && w[f]
      w[f] = [(w[f].to_f + offset).round(3), 0.0].max
    end
  end
end

# ─── CLI ──────────────────────────────────────────────────────────────────────

library_name = nil
dry_run = false

args = ARGV.dup
while args.any?
  case args.first
  when '--library' then args.shift; library_name = args.shift
  when '--dry-run' then args.shift; dry_run = true
  else abort "Unknown argument: #{args.first}\nUsage: ruby scripts/normalize_transcript_domain.rb --library <name> [--dry-run]"
  end
end
abort "Usage: ruby scripts/normalize_transcript_domain.rb --library <name> [--dry-run]" unless library_name

# ─── Load library ─────────────────────────────────────────────────────────────

library_dir = LibraryResolver.resolve(library_name)
abort "Library not found: #{library_dir}" unless File.directory?(library_dir)

library_yaml_path = File.join(library_dir, 'library.yaml')
abort "library.yaml not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
videos = library['videos'] || []
abort "No videos in library.yaml" if videos.empty?

transcripts_dir = File.join(library_dir, 'transcripts')

# ─── Process each video ───────────────────────────────────────────────────────

converted = 0
labeled = 0

videos.each_with_index do |video, vi|
  source = File.basename(video['path'].to_s)

  if video['transcript_domain']
    $stderr.puts "  #{source}: transcript_domain=#{video['transcript_domain']} already set, skipping"
    next
  end

  has_sync = video.key?('sync_audio') && video['sync_audio'] && video['sync_audio']['offset']

  if has_sync
    offset = video['sync_audio']['offset'].to_f
    $stderr.puts "  #{source}: sync_audio present, offset=#{offset} — converting video→WAV time"

    %w[transcript cleaned_transcript].each do |field|
      name = video[field]
      next unless name
      path = File.join(transcripts_dir, name)
      unless File.exist?(path)
        $stderr.puts "    WARNING: #{field} not found: #{path}"
        next
      end

      data = JSON.parse(File.read(path))
      segs = data['segments'] || []

      if segs.any?
        first_t = segs.first['start'] || segs.first['t']
        last_e  = segs.last['end']   || segs.last['e']
        $stderr.puts "    #{File.basename(path)}: #{segs.size} segments [#{first_t}..#{last_e}]"
      end

      shift_timestamps!(data, offset)

      if segs.any?
        new_first = segs.first['start'] || segs.first['t']
        new_last  = segs.last['end']   || segs.last['e']
        $stderr.puts "      → converted: [#{new_first}..#{new_last}]"
      end

      unless dry_run
        File.write(path, JSON.pretty_generate(data))
      end
    end

    converted += 1
  else
    $stderr.puts "  #{source}: no sync_audio — labeling only (MP4 audio time is canonical)"
  end

  video['transcript_domain'] = 'wav'
  labeled += 1
end

# ─── Write library.yaml ──────────────────────────────────────────────────────

unless dry_run
  File.write(library_yaml_path, YAML.dump(library))
  $stderr.puts "\nDone: #{labeled} source(s) labeled transcript_domain=wav, #{converted} source(s) converted"
else
  $stderr.puts "\n[DRY RUN] Would label #{labeled} source(s), convert #{converted} source(s)"
end
