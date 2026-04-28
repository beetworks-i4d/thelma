require 'securerandom'
require 'pathname'
require 'cgi'
require 'json'
require 'digest'

class ButterCut
  # Shared functionality for editor-specific generators.
  class EditorBase
    AUDIO_ONLY_EXTENSIONS = %w[.m4a .mp3 .wav .aac .flac].freeze
    DEFAULT_START_TIME = "0s"
    DEFAULT_INITIAL_OFFSET = "0s"
    DEFAULT_VOLUME_ADJUSTMENT = "-13.100000000000001db"

    attr_reader :clips, :initial_offset, :volume_adjustment

    def initialize(clips)
      raise ArgumentError, "No clips provided" if clips.nil? || clips.empty?

      clips.each_with_index do |clip, index|
        unless clip.is_a?(Hash)
          raise ArgumentError, "Clip at index #{index} must be a hash, got #{clip.class}"
        end
        unless clip.key?(:path)
          raise ArgumentError, "Clip at index #{index} must have a 'path' key"
        end
      end

      relative_paths = clips.select { |clip| !Pathname.new(clip[:path]).absolute? }
      unless relative_paths.empty?
        paths = relative_paths.map { |clip| clip[:path] }.join(', ')
        raise ArgumentError, "All video file paths must be absolute paths. Relative paths found: #{paths}"
      end

      @clips = clips
      @initial_offset = DEFAULT_INITIAL_OFFSET
      @volume_adjustment = DEFAULT_VOLUME_ADJUSTMENT

      @metadata_cache = {}
      @clips.each do |clip|
        path = clip[:path]
        @metadata_cache[path] = extract_metadata_from_ffprobe(path)
      end
    end

    def save(filename)
      File.write(filename, to_xml)
    end

    def generate_uuid
      SecureRandom.uuid
    end

    def extract_metadata(video_path)
      @metadata_cache[video_path]
    end

    def video_width(video_path)
      metadata = extract_metadata(video_path)
      video_stream = metadata['streams'].find { |s| s['codec_type'] == 'video' }
      video_stream['width']
    end

    def video_height(video_path)
      metadata = extract_metadata(video_path)
      video_stream = metadata['streams'].find { |s| s['codec_type'] == 'video' }
      video_stream['height']
    end

    def video_duration(video_path)
      metadata = extract_metadata(video_path)
      metadata['format']['duration'].to_f
    end

    def frame_rate(video_path)
      metadata = extract_metadata(video_path)
      video_stream = metadata['streams'].find { |s| s['codec_type'] == 'video' }
      video_stream['r_frame_rate']
    end

    def frame_duration(video_path)
      rate = frame_rate(video_path)
      numerator, denominator = rate.split('/').map(&:to_i)
      "#{denominator}/#{numerator}s"
    end

    def audio_sample_rate(video_path)
      metadata = extract_metadata(video_path)
      audio_stream = metadata['streams'].find { |s| s['codec_type'] == 'audio' }
      audio_stream['sample_rate']
    end

    def nominal_frame_rate(video_path)
      rate_num, rate_denom = frame_rate(video_path).split('/').map(&:to_i)
      return 0 if rate_denom.zero?

      (rate_num.to_f / rate_denom).round
    end

    def clip_timecode_string(video_path)
      metadata = extract_metadata(video_path)

      if metadata['streams']
        metadata['streams'].each do |stream|
          tags = stream['tags']
          next unless tags && tags['timecode'] && !tags['timecode'].empty?

          return tags['timecode']
        end
      end

      format_tags = metadata.dig('format', 'tags')
      if format_tags
        tc = format_tags['timecode']
        return tc unless tc.nil? || tc.empty?

        panasonic_xml = format_tags['com.panasonic.Semi-Pro.metadata.xml']
        if panasonic_xml
          match = panasonic_xml.match(/<StartTimecode>([^<]+)<\/StartTimecode>/)
          return match[1].strip if match
        end
      end

      nil
    end

    def clip_timecode_fraction(video_path)
      timecode = clip_timecode_string(video_path)
      return "0s" if timecode.nil? || timecode.strip.empty?

      parts = timecode.strip.tr(';', ':').split(':').map(&:to_i)
      return "0s" unless parts.length == 4

      hours, minutes, seconds, frames = parts
      fps_nominal = nominal_frame_rate(video_path)
      return "0s" if fps_nominal <= 0

      rate_num, rate_denom = frame_rate(video_path).split('/').map(&:to_i)
      return "0s" if rate_denom.zero? || rate_num.zero?

      drop_frame = drop_frame_timecode?(timecode, rate_num, rate_denom, fps_nominal)

      total_frames = if drop_frame
        drop_frames_per_minute = drop_frames_for_rate(fps_nominal)
        total_minutes = hours * 60 + minutes
        dropped_frames = drop_frames_per_minute * (total_minutes - (total_minutes / 10))
        (((hours * 3600 + minutes * 60 + seconds) * fps_nominal) + frames) - dropped_frames
      else
        ((hours * 3600 + minutes * 60 + seconds) * fps_nominal) + frames
      end

      return "0s" if total_frames.negative?

      start_num = total_frames * rate_denom
      start_denom = rate_num

      divisor = gcd(start_num, start_denom)
      "#{start_num / divisor}/#{start_denom / divisor}s"
    end

    def drop_frame_timecode?(timecode, rate_num, rate_denom, fps_nominal)
      return false unless timecode.include?(';')
      return false unless fps_nominal == 30 || fps_nominal == 60
      (rate_num == 30000 && rate_denom == 1001) || (rate_num == 60000 && rate_denom == 1001)
    end

    def drop_frames_for_rate(fps_nominal)
      case fps_nominal
      when 60 then 4
      when 30 then 2
      else 0
      end
    end

    def color_space(video_path)
      metadata = extract_metadata(video_path)
      video_stream = metadata['streams'].find { |s| s['codec_type'] == 'video' }

      cs = video_stream['color_space']
      cp = video_stream['color_primaries']
      ct = video_stream['color_transfer']

      if cs == 'bt709' || cp == 'bt709' || ct == 'bt709'
        "1-1-1 (Rec. 709)"
      else
        "1-1-1 (Rec. 709)"
      end
    end

    def duration_to_fraction(video_path)
      duration_seconds = video_duration(video_path)
      rate = frame_rate(video_path)
      numerator, denominator = rate.split('/').map(&:to_i)

      total_frames = (duration_seconds * numerator / denominator).round

      duration_num = total_frames * denominator
      duration_denom = numerator

      divisor = gcd(duration_num, duration_denom)
      "#{duration_num / divisor}/#{duration_denom / divisor}s"
    end

    # Returns true when the path has an audio-only file extension (no video stream).
    def audio_only_file?(path)
      AUDIO_ONLY_EXTENSIONS.include?(File.extname(path.to_s).downcase)
    end

    # Returns the first clip path that has a video stream.
    # Falls back to the first clip if all are audio-only.
    def first_video_clip_path
      video_clip = @clips.find { |c| !audio_only_file?(c[:path]) }
      video_clip ? video_clip[:path] : @clips.first[:path]
    end

    def format_width
      video_width(first_video_clip_path)
    end

    def format_height
      video_height(first_video_clip_path)
    end

    def format_frame_duration
      frame_duration(first_video_clip_path)
    end

    def format_frame_rate
      frame_rate(first_video_clip_path)
    end

    def format_nominal_frame_rate
      nominal_frame_rate(first_video_clip_path)
    end

    def format_color_space
      color_space(first_video_clip_path)
    end

    def format_audio_rate
      audio_sample_rate(@clips.first[:path])
    end

    def gcd(a, b)
      while b != 0
        a, b = b, a % b
      end
      a
    end

    def add_fractions(frac1, frac2)
      return frac2 if frac1 == "0s"
      return frac1 if frac2 == "0s"

      num1, denom1 = frac1.match(/(\d+)\/(\d+)/).captures.map(&:to_i)
      num2, denom2 = frac2.match(/(\d+)\/(\d+)/).captures.map(&:to_i)

      result_num = num1 * denom2 + num2 * denom1
      result_denom = denom1 * denom2

      divisor = gcd(result_num, result_denom)
      result_num /= divisor
      result_denom /= divisor

      "#{result_num}/#{result_denom}s"
    end

    def time_value_zero?(value)
      return true if value.nil?
      return true if value == 0 || value == 0.0
      return true if value == "0s"
      false
    end

    def seconds_to_fraction(seconds)
      return "0s" if seconds == 0 || seconds == "0s"
      return seconds if seconds.is_a?(String)
      seconds = seconds.to_f if seconds.is_a?(Integer)

      denominator = 10000
      numerator = (seconds * denominator).round
      divisor = gcd(numerator, denominator)
      "#{numerator / divisor}/#{denominator / divisor}s"
    end

    def round_to_frame_boundary(time_value, frame_duration)
      return "0s" if time_value == "0s" || time_value == 0
      time_value = seconds_to_fraction(time_value) if time_value.is_a?(Numeric)

      if time_value.match(/^(\d+)s$/)
        time_num = Regexp.last_match(1).to_i
        time_denom = 1
      else
        time_num, time_denom = time_value.match(/(\d+)\/(\d+)/).captures.map(&:to_i)
      end

      frame_num, frame_denom = frame_duration.match(/(\d+)\/(\d+)/).captures.map(&:to_i)

      frames_exact = (time_num * frame_denom).to_f / (time_denom * frame_num)
      frames_rounded = frames_exact.round

      result_num = frames_rounded * frame_num
      result_denom = frame_denom

      divisor = gcd(result_num, result_denom)
      "#{result_num / divisor}/#{result_denom / divisor}s"
    end

    def subtract_fractions(frac1, frac2)
      frac1 = seconds_to_fraction(frac1) if frac1.is_a?(Numeric)
      frac2 = seconds_to_fraction(frac2) if frac2.is_a?(Numeric)

      return frac1 if frac2 == "0s"
      return "0s" if frac1 == frac2

      if frac1.match(/^(\d+)s$/)
        num1 = Regexp.last_match(1).to_i
        denom1 = 1
      else
        num1, denom1 = frac1.match(/(\d+)\/(\d+)/).captures.map(&:to_i)
      end

      if frac2.match(/^(\d+)s$/)
        num2 = Regexp.last_match(1).to_i
        denom2 = 1
      else
        num2, denom2 = frac2.match(/(\d+)\/(\d+)/).captures.map(&:to_i)
      end

      result_num = num1 * denom2 - num2 * denom1
      result_denom = denom1 * denom2

      return "0s" if result_num <= 0

      divisor = gcd(result_num, result_denom)
      result_num /= divisor
      result_denom /= divisor

      "#{result_num}/#{result_denom}s"
    end

    def get_filename(path)
      File.basename(path)
    end

    def get_basename(filename)
      File.basename(filename, File.extname(filename))
    end

    def get_absolute_path(path)
      File.expand_path(path)
    end

    def path_to_file_url(path)
      abs_path = get_absolute_path(path)
      "file://#{abs_path.gsub(' ', '%20')}"
    end

    def escape_xml(str)
      return "" if str.nil?
      CGI.escapeHTML(str).gsub("&#39;", "&apos;")
    end

    def build_asset_map
      file_to_asset = {}
      @clips.each do |clip_def|
        video_file_path = clip_def[:path]
        abs_path = get_absolute_path(video_file_path)
        next if file_to_asset.key?(abs_path)

        asset_id = deterministic_asset_id(abs_path)
        asset_uid = deterministic_asset_uid(abs_path)
        filename = get_filename(video_file_path)
        file_url = path_to_file_url(video_file_path)

        if audio_only_file?(video_file_path)
          # Audio-only: no video stream. Use the sequence's frame rate so
          # Premiere interprets in/out frame values correctly. Audio has no
          # inherent frame rate — a mismatched timebase causes EOF clips to
          # show silence+striping because Premiere reads in/out at the
          # sequence rate, not the file's declared rate.
          metadata    = extract_metadata(video_file_path)
          audio_dur   = metadata.dig('format', 'duration').to_f
          audio_str   = metadata['streams']&.find { |s| s['codec_type'] == 'audio' }

          seq_rate = format_frame_rate
          rate_num, rate_denom = seq_rate.split('/').map(&:to_i)
          if rate_num > 0 && rate_denom > 0
            total_frames = (audio_dur * rate_num.to_f / rate_denom).round
            dur_num = total_frames * rate_denom
            dur_denom = rate_num
            d = gcd(dur_num, dur_denom)
            asset_dur_fraction = "#{dur_num / d}/#{dur_denom / d}s"
            fd_fraction = "#{rate_denom}/#{rate_num}s"
          else
            # Fallback when all clips are audio-only (no video to derive rate)
            total_frames = (audio_dur * 30).round
            asset_dur_fraction = "#{total_frames}/30s"
            fd_fraction = '1/30s'
            seq_rate = '30/1'
          end

          file_to_asset[abs_path] = {
            asset_id:       asset_id,
            asset_uid:      asset_uid,
            abs_path:       abs_path,
            filename:       filename,
            basename:       get_basename(filename),
            file_url:       file_url,
            asset_duration: asset_dur_fraction,
            audio_rate:     audio_str&.dig('sample_rate') || '48000',
            timecode:       '0s',
            frame_duration: fd_fraction,
            frame_rate:     seq_rate,
            width:          1920,
            height:         1080,
            color_space:    '1-1-1 (Rec. 709)',
            audio_only:     true
          }
        else
          file_to_asset[abs_path] = {
            asset_id:       asset_id,
            asset_uid:      asset_uid,
            abs_path:       abs_path,
            filename:       filename,
            basename:       get_basename(filename),
            file_url:       file_url,
            asset_duration: duration_to_fraction(video_file_path),
            audio_rate:     audio_sample_rate(video_file_path),
            timecode:       clip_timecode_fraction(video_file_path),
            frame_duration: frame_duration(video_file_path),
            frame_rate:     frame_rate(video_file_path),
            width:          video_width(video_file_path),
            height:         video_height(video_file_path),
            color_space:    color_space(video_file_path)
          }
        end
      end
      file_to_asset
    end

    def build_timeline_clips(asset_map, timeline_frame_duration)
      current_offset = initial_offset
      clips = @clips.map do |clip_def|
        abs_path = get_absolute_path(clip_def[:path])
        asset_info = asset_map.fetch(abs_path)
        asset_frame_duration = asset_info[:frame_duration] || timeline_frame_duration

        start_at_raw = clip_def[:start_at] || DEFAULT_START_TIME
        start_at = round_to_frame_boundary(start_at_raw, asset_frame_duration)

        base_timecode = asset_info[:timecode] || "0s"
        clip_start = add_fractions(base_timecode, start_at)

        duration_info = compute_clip_duration(clip_def, asset_info, start_at, asset_frame_duration, timeline_frame_duration)

        clip_data = {
          asset: asset_info,
          asset_id: asset_info[:asset_id],
          filename: asset_info[:filename],
          start: clip_start,
          duration: duration_info[:timeline],
          source_duration: duration_info[:asset],
          timeline_offset: current_offset,
          source_in: start_at,
          clip_definition: clip_def
        }

        current_offset = add_fractions(current_offset, clip_data[:duration])
        clip_data
      end

      [clips, current_offset]
    end

    def fraction_to_rational(value)
      value = seconds_to_fraction(value) if value.is_a?(Numeric)
      return Rational(0, 1) if value == "0s"

      if (match = value.match(%r{\A(\d+)\/(\d+)s\z}))
        Rational(match[1].to_i, match[2].to_i)
      elsif (match = value.match(%r{\A(\d+)s\z}))
        Rational(match[1].to_i, 1)
      else
        raise ArgumentError, "Unsupported time format: #{value.inspect}"
      end
    end

    def frames_for_fraction(duration_fraction, frame_duration_fraction)
      duration_rational = fraction_to_rational(duration_fraction)
      frame_rational = fraction_to_rational(frame_duration_fraction)
      ((duration_rational / frame_rational).round).to_i
    end

    def frame_duration_rational_for(frame_duration_fraction)
      fraction_to_rational(frame_duration_fraction)
    end

    protected

    def extract_metadata_from_ffprobe(video_path)
      json_output = `ffprobe -v quiet -print_format json -show_format -show_streams "#{video_path}" 2>&1`

      if $?.exitstatus != 0
        raise "Failed to extract metadata from #{video_path}: #{json_output}"
      end

      JSON.parse(json_output)
    end

    def compute_clip_duration(clip_def, asset_info, start_at, asset_frame_duration, timeline_frame_duration)
      duration = if clip_def[:duration]
        clip_def[:duration]
      elsif clip_def[:start_at] && !time_value_zero?(clip_def[:start_at])
        subtract_fractions(asset_info[:asset_duration], start_at)
      else
        asset_info[:asset_duration]
      end

      asset_aligned = round_to_frame_boundary(duration, asset_frame_duration)
      timeline_aligned = round_to_frame_boundary(asset_aligned, timeline_frame_duration)

      {
        asset: asset_aligned,
        timeline: timeline_aligned
      }
    end

    def timestamp_suffix
      @timestamp_suffix ||= Time.now.utc.strftime("%Y%m%d-%H%M%S")
    end

    def deterministic_asset_id(abs_path)
      digest = Digest::MD5.hexdigest(abs_path)
      "r#{digest}"
    end

    def deterministic_asset_uid(abs_path)
      digest = Digest::MD5.hexdigest(abs_path)
      [
        digest[0, 8],
        digest[8, 4],
        digest[12, 4],
        digest[16, 4],
        digest[20, 12]
      ].join('-')
    end
  end
end
