#!/usr/bin/env ruby
# Builds a structure cut XML from a YAML definition file.
#
# Usage: ruby scripts/build_structure_cut.rb <yaml_path>
#
# YAML format:
#   video_path: /absolute/path/to/video.mp4
#   output_dir: /absolute/path/to/output/
#   editor: fcp7
#   name: "My Structure Cut"          # optional, defaults to video basename
#   breathing_room_frames: 3          # optional, default 3
#   fps: 25                           # optional, auto-detected from video
#
#   sync_audio:                       # optional
#     path: /absolute/path/to/audio.wav
#     offset: 50.41                   # positive=audio before video
#
#   time_domain: video               # optional: "audio" or "video" (default: "video")
#                                    # "video" = clip times are video-relative (normal case)
#                                    # "audio" = clip times are WAV-relative, converted using sync_offset
#                                    # Only use "audio" if transcript was generated from the production WAV,
#                                    # not the video's audio track. WhisperX on video → use "video".
#
#   clips:
#     - start: 121.73                 # source time in the specified time_domain (seconds)
#       end: 127.11
#
#   auto_remove_pauses_above: 500    # optional, milliseconds (default 500)
#                                    # Silero long pauses above this threshold inside a clip
#                                    # are removed by splitting the clip into sub-clips.
#                                    # Set to 0 or false to disable.
#
#   markers:
#     - name: TITLE
#       comment: "Insert title card"
#       time: 0.0                     # timeline position (seconds)
#       color: blue

require_relative '../lib/buttercut'
require 'yaml'
require 'date'
require 'json'
require 'nokogiri'
require 'fileutils'
require 'shellwords'

yaml_path = ARGV[0]
abort "Usage: ruby scripts/build_structure_cut.rb <yaml_path>" unless yaml_path
abort "YAML not found: #{yaml_path}" unless File.exist?(yaml_path)

config = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])

# === Validate required fields ===
%w[video_path output_dir clips].each do |key|
  abort "Missing required field: #{key}" unless config[key]
end

video_path = config['video_path']
abort "Video not found: #{video_path}" unless File.exist?(video_path)

output_dir = config['output_dir']
editor = (config['editor'] || 'fcp7').to_sym

# Auto-detect FPS from video if not specified
if config['fps']
  fps = config['fps'].to_f
else
  rate_str = `ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 #{Shellwords.escape(video_path)}`.strip
  num, denom = rate_str.split('/').map(&:to_f)
  fps = (num / denom).round
  $stderr.puts "Auto-detected FPS: #{fps}"
end

breathing_room_frames = config['breathing_room_frames'] || 3
buffer = breathing_room_frames.to_f / fps

# === Build clips ===
has_sync = config['sync_audio'] && config['sync_audio']['path']
sync_offset = has_sync ? config['sync_audio']['offset'].to_f : 0.0
sync_path = has_sync ? config['sync_audio']['path'] : nil

if has_sync && !File.exist?(sync_path)
  abort "Sync audio not found: #{sync_path}"
end

# === Load speech analysis for snap-to-boundary ===
speech_segments = nil
long_pauses = nil
if config['speech_analysis']
  sa_path = config['speech_analysis']
  abort "Speech analysis not found: #{sa_path}" unless File.exist?(sa_path)
  sa_data = JSON.parse(File.read(sa_path))
  speech_segments = sa_data['speech_segments']
  long_pauses = sa_data['long_pauses']
  $stderr.puts "Loaded speech analysis: #{speech_segments.size} segments, #{long_pauses.size} long pauses"
end

# === Parse auto_remove_pauses_above ===
pause_removal_threshold = nil
if config.key?('auto_remove_pauses_above')
  val = config['auto_remove_pauses_above']
  if val && val != false && val.to_i > 0
    pause_removal_threshold = val.to_i / 1000.0
  end
else
  pause_removal_threshold = 0.5  # default 500ms
end

if pause_removal_threshold && long_pauses
  $stderr.puts "Pause removal: enabled (threshold #{(pause_removal_threshold * 1000).round}ms)"
end

# Snap a time to the nearest speech boundary within tolerance.
# boundary_type: :start snaps to segment starts, :end snaps to segment ends.
# Returns [snapped_time, adjustment] or [original_time, 0.0] if no match.
SNAP_TOLERANCE = 0.200  # ±200ms
END_BUFFER = 0.100      # 100ms after speech end for breathing room

def snap_to_boundary(time, segments, boundary_type, tolerance = SNAP_TOLERANCE)
  return [time, 0.0] unless segments

  best = nil
  best_dist = tolerance

  segments.each do |seg|
    target = boundary_type == :start ? seg['start'] : seg['end']
    dist = (time - target).abs
    if dist < best_dist
      best = target
      best_dist = dist
    end
  end

  if best
    snapped = boundary_type == :end ? best + END_BUFFER : best
    [(snapped * 1000).round / 1000.0, (snapped - time).round(3)]
  else
    [time, 0.0]
  end
end

clips = []
wav_clip_info = []
# Track source WAV-time ranges for each output clip (for below-threshold pause markers)
clip_source_ranges = []
# Markers generated during pause removal (timeline positions computed after all clips built)
pause_removal_markers = []
removed_pause_count = 0
total_removed_ms = 0

# === Time domain conversion ===
# When time_domain is "audio", clip start/end are audio times from the transcript/classification.
# Convert to video time before all downstream processing.
# Conversion: video_time = audio_time - sync_offset (offset sign: positive=audio before video, negative=audio after)
audio_time_domain = config['time_domain'] == 'audio' && has_sync

if audio_time_domain
  $stderr.puts "Time domain: audio → converting to video time (offset: #{sync_offset}s)"
end

config['clips'].each_with_index do |c, idx|
  start_time = c['start'].to_f
  end_time = c['end'].to_f

  # Convert audio time → video time if needed
  if audio_time_domain
    start_time = start_time - sync_offset
    end_time = end_time - sync_offset
    $stderr.puts "Clip #{idx + 1}: audio #{c['start']} → video #{'%.2f' % start_time}, audio #{c['end']} → video #{'%.2f' % end_time}"
  end

  abort "Clip end (#{end_time}) must be after start (#{start_time})" if end_time <= start_time

  # Snap-to-boundary if speech analysis is available
  if speech_segments
    if has_sync
      wav_start = start_time + sync_offset
      wav_end = end_time + sync_offset

      snapped_start, adj_s = snap_to_boundary(wav_start, speech_segments, :start)
      snapped_end, adj_e = snap_to_boundary(wav_end, speech_segments, :end)

      start_time = snapped_start - sync_offset
      end_time = snapped_end - sync_offset
    else
      start_time, adj_s = snap_to_boundary(start_time, speech_segments, :start)
      end_time, adj_e = snap_to_boundary(end_time, speech_segments, :end)
    end

    if adj_s != 0.0 || adj_e != 0.0
      $stderr.puts "Clip #{idx + 1}: snapped start #{'%+.3f' % adj_s}s, end #{'%+.3f' % adj_e}s"
    end
  end

  # === Find internal pauses to remove ===
  removable_pauses = []
  if pause_removal_threshold && long_pauses
    wav_check_start = has_sync ? start_time + sync_offset : start_time
    wav_check_end = has_sync ? end_time + sync_offset : end_time

    long_pauses.each do |p|
      if p['start'] > wav_check_start + 0.5 && p['end'] < wav_check_end - 0.5 &&
         p['duration'] >= pause_removal_threshold
        removable_pauses << p
      end
    end
    removable_pauses.sort_by! { |p| p['start'] }
  end

  # === Build sub-clips (or single clip if no pauses to remove) ===
  if removable_pauses.any?
    # Split at pause boundaries — work in video time
    sub_ranges = []
    current_v = start_time
    removable_pauses.each do |p|
      p_start_v = has_sync ? p['start'] - sync_offset : p['start']
      p_end_v = has_sync ? p['end'] - sync_offset : p['end']
      sub_ranges << { start: current_v, end: p_start_v }
      current_v = p_end_v
    end
    sub_ranges << { start: current_v, end: end_time }

    removed_ms = removable_pauses.sum { |p| (p['duration'] * 1000).round }
    $stderr.puts "  Clip #{idx + 1}: removing #{removable_pauses.size} pauses (#{removed_ms}ms) → #{sub_ranges.size} sub-clips"

    sub_ranges.each_with_index do |sr, si|
      is_first = si == 0
      is_last = si == sub_ranges.size - 1
      # Breathing room only at outer edges, not at internal split points
      start_buf = is_first ? buffer : 0.0
      end_buf = is_last ? buffer : 0.0

      buffered_start = sr[:start] - start_buf
      buffered_start = 0.0 if buffered_start < 0
      dur = (sr[:end] - sr[:start]) + start_buf + end_buf

      clips << { path: video_path, start_at: buffered_start, duration: dur }

      wav_range_start = has_sync ? sr[:start] + sync_offset : sr[:start]
      wav_range_end = has_sync ? sr[:end] + sync_offset : sr[:end]
      clip_source_ranges << { wav_start: wav_range_start, wav_end: wav_range_end }

      if has_sync
        ws = (sr[:start] + sync_offset) - start_buf
        ws = 0.0 if ws < 0
        wav_clip_info << { wav_start: ws, wav_duration: dur }
      end

      # Record join-point marker (not for first sub-clip)
      if si > 0
        pause = removable_pauses[si - 1]
        pause_ms = (pause['duration'] * 1000).round
        removed_pause_count += 1
        total_removed_ms += pause_ms
        pause_removal_markers << { clip_index: clips.size - 1, pause_ms: pause_ms }
      end
    end
  else
    # Single clip — no pauses to remove
    buffered_start = start_time - buffer
    buffered_start = 0.0 if buffered_start < 0
    duration = (end_time - start_time) + (buffer * 2)

    clips << { path: video_path, start_at: buffered_start, duration: duration }

    wav_range_start = has_sync ? start_time + sync_offset : start_time
    wav_range_end = has_sync ? end_time + sync_offset : end_time
    clip_source_ranges << { wav_start: wav_range_start, wav_end: wav_range_end }

    if has_sync
      wav_start = (start_time + sync_offset) - buffer
      wav_start = 0.0 if wav_start < 0
      wav_clip_info << { wav_start: wav_start, wav_duration: duration }
    end
  end
end

# === Build markers (convert string keys to symbols) ===
markers = (config['markers'] || []).map do |m|
  {
    name: m['name'],
    comment: m['comment'],
    time: m['time'].to_f,
    color: m['color']
  }
end

# === Compute timeline positions ===
timeline_positions = []
cumulative = 0.0
clips.each do |c|
  timeline_positions << cumulative
  cumulative += c[:duration]
end

# === Add "Auto-removed" markers at split join points ===
pause_removal_markers.each do |prm|
  tl_time = timeline_positions[prm[:clip_index]].round(2)
  markers << {
    name: 'NOTE',
    comment: "Auto-removed #{prm[:pause_ms]}ms pause",
    time: tl_time,
    color: 'yellow'
  }
  $stderr.puts "  Auto-removed: #{prm[:pause_ms]}ms pause at timeline #{tl_time}s"
end

# === Add "tighten manually" markers for below-threshold internal pauses ===
if long_pauses && speech_segments
  clip_source_ranges.each_with_index do |csr, i|
    long_pauses.each do |p|
      next unless p['start'] > csr[:wav_start] + 0.5 && p['end'] < csr[:wav_end] - 0.5
      # Skip pauses that were already removed
      next if pause_removal_threshold && p['duration'] >= pause_removal_threshold

      pause_ms = (p['duration'] * 1000).round
      pause_offset = p['start'] - csr[:wav_start]
      tl_time = (timeline_positions[i] + pause_offset).round(2)

      markers << {
        name: 'NOTE',
        comment: "Internal pause \u2014 tighten manually (#{pause_ms}ms)",
        time: tl_time,
        color: 'yellow'
      }
    end
  end
end

if removed_pause_count > 0
  $stderr.puts "Pause removal: #{removed_pause_count} pauses removed (#{(total_removed_ms / 1000.0).round(1)}s total)"
end

# === Generate base XML ===
FileUtils.mkdir_p(output_dir)
generator = ButterCut.new(clips, editor: editor, markers: markers)
base_xml = generator.to_xml

# === Post-process: add sync audio track if present ===
if has_sync
  doc = Nokogiri::XML(base_xml)

  # Get WAV properties via ffprobe
  wav_info_raw = `ffprobe -v error -show_entries format=duration -show_entries stream=sample_rate,bits_per_sample,channels -of json #{Shellwords.escape(sync_path)}`
  wav_meta = JSON.parse(wav_info_raw)
  wav_duration_s = wav_meta['format']['duration'].to_f
  wav_duration_frames = (wav_duration_s * fps).round

  wav_stream = wav_meta['streams']&.find { |s| s['codec_type'] == 'audio' } || {}
  wav_sample_rate = wav_stream['sample_rate'] || '48000'
  wav_bit_depth = wav_stream['bits_per_sample'] || 16
  wav_channels = wav_stream['channels'] || 2

  wav_pathurl = "file://#{sync_path.gsub(' ', '%20')}"
  wav_basename = File.basename(sync_path, File.extname(sync_path))
  wav_filename = File.basename(sync_path)

  audio_node = doc.at_xpath('//sequence/media/audio')
  track_node = Nokogiri::XML::Node.new('track', doc)
  wav_file_id = "file-wav-production"
  first_clip = true

  # Compute timeline positions
  timeline_pos = []
  cumulative = 0.0
  clips.each do |c|
    timeline_pos << cumulative
    cumulative += c[:duration]
  end

  wav_clip_info.each_with_index do |wi, i|
    tl_start_frames = (timeline_pos[i] * fps).round
    tl_duration_frames = (wi[:wav_duration] * fps).round
    tl_end_frames = tl_start_frames + tl_duration_frames
    src_in_frames = (wi[:wav_start] * fps).round
    src_in_frames = 0 if src_in_frames < 0
    src_out_frames = src_in_frames + tl_duration_frames

    clip_node = Nokogiri::XML::Node.new('clipitem', doc)
    clip_node['id'] = "clipitem-wav-#{i + 1}"
    clip_node.add_child("<name>#{wav_basename}</name>")
    clip_node.add_child("<enabled>TRUE</enabled>")
    clip_node.add_child("<duration>#{tl_duration_frames}</duration>")
    clip_node.add_child("<start>#{tl_start_frames}</start>")
    clip_node.add_child("<end>#{tl_end_frames}</end>")
    clip_node.add_child("<in>#{src_in_frames}</in>")
    clip_node.add_child("<out>#{src_out_frames}</out>")

    if first_clip
      file_xml = <<~XML
        <file id="#{wav_file_id}">
          <name>#{wav_filename}</name>
          <pathurl>#{wav_pathurl}</pathurl>
          <rate><timebase>#{fps}</timebase><ntsc>FALSE</ntsc></rate>
          <duration>#{wav_duration_frames}</duration>
          <media>
            <audio>
              <samplecharacteristics>
                <samplerate>#{wav_sample_rate}</samplerate>
                <sampledepth>#{wav_bit_depth}</sampledepth>
              </samplecharacteristics>
            </audio>
          </media>
        </file>
      XML
      first_clip = false
    else
      file_xml = "<file id=\"#{wav_file_id}\"/>"
    end
    clip_node.add_child(file_xml)
    clip_node.add_child("<sourcetrack><mediatype>audio</mediatype><trackindex>1</trackindex></sourcetrack>")
    clip_node.add_child("<channelcount>#{wav_channels}</channelcount>")
    track_node.add_child(clip_node)
  end

  audio_node.add_child(track_node)
  final_xml = doc.to_xml
else
  final_xml = base_xml
end

# === Save with timestamp ===
cut_name = config['name'] || File.basename(video_path, File.extname(video_path))
timestamp = Time.now.strftime('%Y%m%d-%H%M%S')
safe_name = cut_name.gsub(/[^a-zA-Z0-9_\-]/, '_')
output_path = File.join(output_dir, "#{safe_name}_#{timestamp}.xml")
File.write(output_path, final_xml)

# === Summary ===
total_duration = clips.sum { |c| c[:duration] }
mins = (total_duration / 60).floor
secs = (total_duration % 60).round

puts output_path
$stderr.puts "Structure cut generated: #{output_path}"
summary = "Duration: #{mins}:#{format('%02d', secs)} | Clips: #{clips.length} | Markers: #{markers.length}"
summary += " | Pauses removed: #{removed_pause_count} (#{(total_removed_ms / 1000.0).round(1)}s)" if removed_pause_count > 0
$stderr.puts summary
if has_sync
  $stderr.puts "Sync audio: #{File.basename(sync_path)} (offset: #{sync_offset}s)"
  $stderr.puts "Track 1: scratch audio (mute) | Track 2: production audio"
end
