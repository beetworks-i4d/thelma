#!/usr/bin/env ruby
# Pool Index — lifecycle module for Mode D (mining).
# Manages libraries/<pool>/index.yaml: source files, sha256 fingerprints, processing state.
#
# Used as a required module; not run directly.
#
# Index schema (index.yaml):
#   pool_version: 1
#   last_updated: 2026-01-15T14:30:00Z
#   sources:
#     20241227_145452.mp4:
#       sha256: <hex>
#       added_at: <iso8601>
#       ingested_at: <iso8601>|null
#       media_type: video_with_audio|audio_only|broll
#       duration: 144.3
#       transcript_file: null|filename
#       speech_analysis: null|filename
#       audio_features: null|filename
#       scene_changes: null|filename
#       visual_analysis: null|filename   # per-source visual_analysis.yaml (Phase 2)
#       speakers_detected: null|[list]   # speaker labels from diarization (e.g. ["SPEAKER_00", "SPEAKER_01"])
#       speaker_count: 1                 # number of detected speakers (default 1)
#       diarization_enabled: false       # whether diarization ran for this source
#       hq_audio_source: null|filename   # matched HQ audio file (video sources only)
#       hq_audio_offset: null|float      # waveform sync offset in seconds
#       role: null|hq_audio_for          # 'hq_audio_for' on matched audio-only sources
#       hq_audio_for: null|filename      # the video this audio is matched to

require 'yaml'
require 'date'
require 'digest'
require 'shellwords'

module PoolIndex
  AUDIO_EXTENSIONS = %w[.m4a .mp3 .wav .aac].freeze
  VIDEO_EXTENSIONS = %w[.mp4 .mov .avi .mkv .mts .m2ts .webm .mp4v].freeze
  ALL_EXTENSIONS   = (AUDIO_EXTENSIONS + VIDEO_EXTENSIONS).freeze

  # Folder name patterns that indicate B-roll (case-insensitive, basename only)
  BROLL_FOLDER_PATTERNS = ['b roll', 'broll', 'b-roll', 'b_roll'].freeze

  # --- Load / Save ---

  def self.load(library_dir)
    path = index_path(library_dir)
    return empty_index unless File.exist?(path)
    data = YAML.safe_load(File.read(path), permitted_classes: [Date, Time]) || {}
    empty_index.merge(data) { |_key, old, new_val| new_val.nil? ? old : new_val }
  end

  def self.save(library_dir, index)
    index['last_updated'] = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
    File.write(index_path(library_dir), index.to_yaml)
  end

  def self.index_path(library_dir)
    File.join(library_dir, 'index.yaml')
  end

  def self.empty_index
    { 'pool_version' => 1, 'last_updated' => nil, 'sources' => {} }
  end

  # --- SHA256 fingerprinting ---

  def self.compute_sha256(path)
    Digest::SHA256.file(path).hexdigest
  end

  # --- Media type detection ---

  # Returns 'audio_only', 'broll', or 'video_with_audio'.
  def self.detect_media_type(path)
    ext = File.extname(path).downcase
    return 'audio_only' if AUDIO_EXTENSIONS.include?(ext)

    parent = File.basename(File.dirname(path)).downcase
    return 'broll' if BROLL_FOLDER_PATTERNS.include?(parent)

    'video_with_audio'
  end

  # Returns true for audio-only file extensions.
  def self.audio_only?(path)
    AUDIO_EXTENSIONS.include?(File.extname(path.to_s).downcase)
  end

  # --- Pool scanning ---

  # Scan pool_dir for all media files and compare against index.
  # Returns { new: [...], changed: [...], unchanged: [...], removed: [...] }
  # Each value is an array of absolute file paths (except :removed, which is filenames).
  # force: true — treat all found files as new regardless of sha256.
  def self.scan_pool(pool_dir, index, force: false)
    sources = index['sources'] || {}

    found_paths = Dir.glob(File.join(pool_dir, '**', '*'))
      .select { |f| File.file?(f) && ALL_EXTENSIONS.include?(File.extname(f).downcase) }
      .sort

    found_basenames = found_paths.map { |f| File.basename(f) }

    new_files       = []
    changed_files   = []
    unchanged_files = []

    found_paths.each do |full_path|
      filename = File.basename(full_path)
      if force || !sources.key?(filename)
        new_files << full_path
      else
        cached_sha  = sources[filename]['sha256']
        current_sha = compute_sha256(full_path)
        if cached_sha != current_sha
          changed_files << full_path
        else
          unchanged_files << full_path
        end
      end
    end

    removed = sources.keys - found_basenames

    { new: new_files, changed: changed_files, unchanged: unchanged_files, removed: removed }
  end

  # --- Source entry management ---

  # Add or initialise a source entry. Preserves existing ingestion metadata
  # (transcript_file, speech_analysis, etc.) when updating sha256 only.
  # attrs: additional fields to merge in (e.g. transcript_file: 'foo.json').
  def self.add_source(index, full_path, attrs = {})
    filename = File.basename(full_path)
    index['sources'] ||= {}
    existing = index['sources'][filename] || {}

    base = {
      'sha256'          => compute_sha256(full_path),
      'added_at'        => existing['added_at'] || Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
      'ingested_at'     => existing['ingested_at'],
      'media_type'      => detect_media_type(full_path),
      'duration'        => probe_duration(full_path),
      'transcript_file' => nil,
      'speech_analysis' => nil,
      'audio_features'  => nil,
      'scene_changes'   => nil,
      'visual_analysis' => nil,
      'speakers_detected' => nil,
      'speaker_count' => 1,
      'diarization_enabled' => false,
      'hq_audio_source' => nil,
      'hq_audio_offset' => nil,
      'role'            => nil,
      'hq_audio_for'    => nil
    }

    index['sources'][filename] = base.merge(existing).merge(
      'sha256'     => base['sha256'],
      'media_type' => base['media_type'],
      'duration'   => base['duration']
    ).merge(attrs.transform_keys(&:to_s))

    index['sources'][filename]
  end

  # Mark a source as fully ingested. Records ingested_at and merges output filenames.
  # attrs: hash of output fields, e.g. { transcript_file: 'foo.json', speech_analysis: 'foo_speech.json' }
  def self.mark_ingested(index, filename, attrs = {})
    index['sources'] ||= {}
    entry = index['sources'][filename] || {}
    entry['ingested_at'] = Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
    attrs.each { |k, v| entry[k.to_s] = v }
    index['sources'][filename] = entry
  end

  # Record an HQ audio / video pair match with sync offset.
  # Both entries are updated: video gets hq_audio_source/offset, audio gets role/hq_audio_for.
  def self.set_hq_pair(index, video_filename, audio_filename, offset)
    index['sources'] ||= {}
    index['sources'][video_filename] ||= {}
    index['sources'][video_filename]['hq_audio_source'] = audio_filename
    index['sources'][video_filename]['hq_audio_offset'] = offset.round(6)

    index['sources'][audio_filename] ||= {}
    index['sources'][audio_filename]['role']         = 'hq_audio_for'
    index['sources'][audio_filename]['hq_audio_for'] = video_filename
  end

  private

  def self.probe_duration(path)
    cmd = ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
           '-of', 'csv=p=0', path]
    result = `#{cmd.map { |c| Shellwords.escape(c) }.join(' ')} 2>/dev/null`.strip
    val = result.to_f
    val > 0 ? val.round(3) : nil
  rescue StandardError
    nil
  end
end
