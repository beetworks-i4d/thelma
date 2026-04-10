require_relative 'editor_base'
require 'nokogiri'
require 'set'

class ButterCut
  # Final Cut Pro 7 XML Interchange Format (version 5).
  # This structure can be imported by legacy FCP as well as Adobe Premiere Pro.
  class FCP7 < EditorBase
    MARKER_COLORS = %w[blue green orange purple red yellow].freeze

    MARKER_CATEGORIES = {
      'TITLE' => 'blue',
      'B-ROLL' => 'green',
      'TRANSITION' => 'orange',
      'SFX' => 'purple',
      'MUSIC' => 'red',
      'NOTE' => 'yellow'
    }.freeze

    attr_reader :markers

    def initialize(clips, markers: [])
      super(clips)
      validate_markers!(markers)
      @markers = markers
    end

    def to_xml
      raise ArgumentError, "No clips provided" if clips.empty?

      asset_map = build_asset_map
      timeline_frame_duration = format_frame_duration
      timeline_clips, sequence_duration_fraction = build_multitrack_timeline_clips(asset_map, timeline_frame_duration)

      rate_num, rate_denom = format_frame_rate.split('/').map(&:to_i)
      timebase = format_nominal_frame_rate
      ntsc_flag = ntsc_flag_for(rate_denom)
      drop_frame = drop_frame_rate?(rate_num, rate_denom)
      display_format = drop_frame ? 'DF' : 'NDF'

      sequence_duration_frames = frames_for_fraction(sequence_duration_fraction, timeline_frame_duration)
      sequence_uuid = generate_uuid
      sequence_id = "sequence-#{sequence_uuid}"

      first_path = clips.first[:path]
      sequence_name = "#{get_basename(get_filename(first_path))} #{timestamp_suffix}"

      clip_payloads = build_clip_payloads(timeline_clips, timeline_frame_duration)
      sequence_audio_rate = format_audio_rate || '48000'

      video_tracks = group_by_video_track(clip_payloads)
      audio_tracks = group_by_audio_track(clip_payloads)

      @defined_file_ids = Set.new

      builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
        xml.doc.create_internal_subset('xmeml', nil, nil)
        xml.xmeml(version: '5') do
          xml.sequence(id: sequence_id) do
            xml.uuid sequence_uuid
            xml.name sequence_name
            xml.duration sequence_duration_frames
            xml.rate do
              xml.timebase timebase
              xml.ntsc ntsc_flag
            end
            xml.in 0
            xml.out sequence_duration_frames
            xml.timecode do
              xml.rate do
                xml.timebase timebase
                xml.ntsc ntsc_flag
              end
              xml.frame 0
              xml.displayformat display_format
            end
            xml.media do
              xml.video do
                xml.format do
                  xml.samplecharacteristics do
                    xml.rate do
                      xml.timebase timebase
                      xml.ntsc ntsc_flag
                    end
                    xml.width format_width
                    xml.height format_height
                    xml.anamorphic 'FALSE'
                    xml.pixelaspectratio 'square'
                    xml.fielddominance 'none'
                  end
                end
                video_tracks.keys.sort.each do |track_num|
                  xml.track do
                    video_tracks[track_num].each do |payload|
                      build_video_clipitem(xml, payload)
                    end
                  end
                end
              end
              xml.audio do
                xml.numOutputChannels 2
                xml.format do
                  xml.samplecharacteristics do
                    xml.samplerate sequence_audio_rate
                    xml.sampledepth 16
                  end
                end
                audio_tracks.keys.sort.each do |track_num|
                  xml.track do
                    audio_tracks[track_num].each do |payload|
                      build_audio_clipitem(xml, payload)
                    end
                  end
                end
              end
            end
            markers.each do |marker|
              build_marker(xml, marker, timeline_frame_duration)
            end
          end
        end
      end

      builder.to_xml
    end

    private

    def ntsc_flag_for(rate_denom)
      rate_denom == 1 ? 'FALSE' : 'TRUE'
    end

    def drop_frame_rate?(rate_num, rate_denom)
      (rate_num == 30000 && rate_denom == 1001) || (rate_num == 60000 && rate_denom == 1001)
    end

    def build_multitrack_timeline_clips(asset_map, timeline_frame_duration)
      # Per-track auto-offset tracking: { [track_type, track_num] => current_offset }
      track_offsets = Hash.new { |h, k| h[k] = initial_offset }
      max_end = "0s"

      timeline_clips = @clips.map do |clip_def|
        abs_path = get_absolute_path(clip_def[:path])
        asset_info = asset_map.fetch(abs_path)
        asset_frame_duration = asset_info[:frame_duration] || timeline_frame_duration

        start_at_raw = clip_def[:start_at] || DEFAULT_START_TIME
        start_at = round_to_frame_boundary(start_at_raw, asset_frame_duration)

        base_timecode = asset_info[:timecode] || "0s"
        clip_start = add_fractions(base_timecode, start_at)

        duration_info = compute_clip_duration(clip_def, asset_info, start_at, asset_frame_duration, timeline_frame_duration)

        video_track = clip_def.fetch(:video_track, 1)
        audio_track = clip_def.fetch(:audio_track, 1)
        media_type = clip_def.fetch(:media_type, :av)

        # Determine timeline offset: explicit or auto-sequential per track
        if clip_def[:timeline_offset]
          offset_fraction = round_to_frame_boundary(
            seconds_to_fraction(clip_def[:timeline_offset]),
            timeline_frame_duration
          )
        else
          # Auto-sequential: use the track that advances (video for :av, audio for :audio_only)
          primary_key = media_type == :audio_only ? [:audio, audio_track] : [:video, video_track]
          offset_fraction = track_offsets[primary_key]
        end

        clip_end = add_fractions(offset_fraction, duration_info[:timeline])

        # Update auto-offsets for all tracks this clip occupies
        unless media_type == :audio_only
          vk = [:video, video_track]
          track_offsets[vk] = clip_end if fraction_to_rational(clip_end) > fraction_to_rational(track_offsets[vk])
        end
        ak = [:audio, audio_track]
        track_offsets[ak] = clip_end if fraction_to_rational(clip_end) > fraction_to_rational(track_offsets[ak])

        max_end = clip_end if fraction_to_rational(clip_end) > fraction_to_rational(max_end)

        {
          asset: asset_info,
          asset_id: asset_info[:asset_id],
          filename: asset_info[:filename],
          start: clip_start,
          duration: duration_info[:timeline],
          source_duration: duration_info[:asset],
          timeline_offset: offset_fraction,
          source_in: start_at,
          clip_definition: clip_def,
          video_track: video_track,
          audio_track: audio_track,
          media_type: media_type
        }
      end

      [timeline_clips, max_end]
    end

    def build_clip_payloads(timeline_clips, timeline_frame_duration)
      timeline_clips.each_with_index.map do |clip, index|
        asset = clip[:asset]
        asset_rate_num, asset_rate_denom = asset[:frame_rate].split('/').map(&:to_i)
        asset_timebase = (asset_rate_num.to_f / asset_rate_denom).round
        asset_ntsc = ntsc_flag_for(asset_rate_denom)
        asset_display = drop_frame_rate?(asset_rate_num, asset_rate_denom) ? 'DF' : 'NDF'

        timeline_duration_frames = frames_for_fraction(clip[:duration], timeline_frame_duration)
        timeline_start_frames = frames_for_fraction(clip[:timeline_offset], timeline_frame_duration)
        timeline_end_frames = timeline_start_frames + timeline_duration_frames

        source_in_frames = frames_for_fraction(clip[:source_in], asset[:frame_duration])
        source_duration_frames = frames_for_fraction(clip[:source_duration], asset[:frame_duration])
        source_out_frames = source_in_frames + source_duration_frames

        asset_duration_frames = frames_for_fraction(asset[:asset_duration], asset[:frame_duration])
        asset_timecode_start = frames_for_fraction(asset[:timecode], asset[:frame_duration])

        {
          index: index + 1,
          clip: clip,
          asset: asset,
          video_clip_id: "clipitem-video-#{index + 1}",
          audio_clip_id: "clipitem-audio-#{index + 1}",
          file_id: "file-#{asset[:asset_id]}",
          timeline_start: timeline_start_frames,
          timeline_end: timeline_end_frames,
          timeline_duration: timeline_duration_frames,
          source_in: source_in_frames,
          source_out: source_out_frames,
          source_duration_frames: source_duration_frames,
          asset_timebase: asset_timebase,
          asset_ntsc: asset_ntsc,
          asset_display: asset_display,
          asset_duration_frames: asset_duration_frames,
          asset_timecode_start: asset_timecode_start,
          video_track: clip[:video_track],
          audio_track: clip[:audio_track],
          media_type: clip[:media_type]
        }
      end
    end

    def group_by_video_track(payloads)
      payloads
        .reject { |p| p[:media_type] == :audio_only }
        .group_by { |p| p[:video_track] }
    end

    def group_by_audio_track(payloads)
      payloads.group_by { |p| p[:audio_track] }
    end

    def build_video_clipitem(xml, payload)
      asset = payload[:asset]

      xml.clipitem(id: payload[:video_clip_id]) do
        xml.name asset[:basename]
        xml.enabled 'TRUE'
        xml.duration payload[:timeline_duration]
        xml.start payload[:timeline_start]
        xml.end_ payload[:timeline_end]
        xml.in_ payload[:source_in]
        xml.out payload[:source_out]
        build_file_ref(xml, payload, include_video: true)
        xml.sourcetrack do
          xml.mediatype 'video'
          xml.trackindex payload[:video_track]
        end
        build_link_entries(xml, payload)
      end
    end

    def build_audio_clipitem(xml, payload)
      asset = payload[:asset]

      xml.clipitem(id: payload[:audio_clip_id]) do
        xml.name asset[:basename]
        xml.enabled 'TRUE'
        xml.duration payload[:timeline_duration]
        xml.start payload[:timeline_start]
        xml.end_ payload[:timeline_end]
        xml.in_ payload[:source_in]
        xml.out payload[:source_out]
        build_file_ref(xml, payload, include_video: false)
        xml.sourcetrack do
          xml.mediatype 'audio'
          xml.trackindex payload[:audio_track]
        end
        xml.channelcount 2
        build_link_entries(xml, payload)
      end
    end

    def build_file_ref(xml, payload, include_video:)
      file_id = payload[:file_id]
      asset = payload[:asset]

      if @defined_file_ids.include?(file_id)
        xml.file(id: file_id)
      else
        @defined_file_ids.add(file_id)
        xml.file(id: file_id) do
          xml.name asset[:filename]
          xml.pathurl asset[:file_url]
          xml.rate do
            xml.timebase payload[:asset_timebase]
            xml.ntsc payload[:asset_ntsc]
          end
          xml.duration payload[:asset_duration_frames]
          if include_video
            xml.timecode do
              xml.rate do
                xml.timebase payload[:asset_timebase]
                xml.ntsc payload[:asset_ntsc]
              end
              xml.frame payload[:asset_timecode_start]
              xml.displayformat payload[:asset_display]
            end
          end
          xml.media do
            if include_video
              xml.video do
                xml.samplecharacteristics do
                  xml.rate do
                    xml.timebase payload[:asset_timebase]
                    xml.ntsc payload[:asset_ntsc]
                  end
                  xml.width asset[:width]
                  xml.height asset[:height]
                  xml.anamorphic 'FALSE'
                  xml.pixelaspectratio 'square'
                  xml.fielddominance 'none'
                end
              end
            end
            xml.audio do
              xml.samplecharacteristics do
                xml.samplerate asset_audio_rate(asset)
                xml.sampledepth 16
              end
            end
          end
        end
      end
    end

    def build_link_entries(xml, payload)
      unless payload[:media_type] == :audio_only
        xml.link do
          xml.linkclipref payload[:video_clip_id]
          xml.mediatype 'video'
          xml.trackindex payload[:video_track]
          xml.clipindex payload[:index]
        end
      end
      xml.link do
        xml.linkclipref payload[:audio_clip_id]
        xml.mediatype 'audio'
        xml.trackindex payload[:audio_track]
        xml.clipindex payload[:index]
        xml.groupindex 1
      end
    end

    def asset_audio_rate(asset)
      asset[:audio_rate] || format_audio_rate || '48000'
    end

    def build_marker(xml, marker, timeline_frame_duration)
      frame = marker_frame(marker, timeline_frame_duration)
      xml.marker do
        xml.name marker[:name]
        xml.comment_ marker[:comment]
        xml.in_ frame
        xml.out(-1)
        xml.color marker[:color]
      end
    end

    def marker_frame(marker, timeline_frame_duration)
      if marker[:frame]
        marker[:frame].to_i
      elsif marker[:time]
        time_fraction = seconds_to_fraction(marker[:time])
        aligned = round_to_frame_boundary(time_fraction, timeline_frame_duration)
        frames_for_fraction(aligned, timeline_frame_duration)
      else
        0
      end
    end

    def validate_markers!(markers)
      markers.each_with_index do |marker, index|
        unless marker.is_a?(Hash)
          raise ArgumentError, "Marker at index #{index} must be a hash, got #{marker.class}"
        end
        unless marker[:name]
          raise ArgumentError, "Marker at index #{index} is missing required :name"
        end
        unless marker[:comment]
          raise ArgumentError, "Marker at index #{index} is missing required :comment"
        end
        unless marker[:frame] || marker[:time]
          raise ArgumentError, "Marker at index #{index} is missing required :frame or :time"
        end
        unless marker[:color]
          raise ArgumentError, "Marker at index #{index} is missing required :color"
        end
        unless MARKER_COLORS.include?(marker[:color])
          raise ArgumentError, "Marker at index #{index} has invalid color '#{marker[:color]}'. Must be one of: #{MARKER_COLORS.join(', ')}"
        end
      end
    end
  end
end
