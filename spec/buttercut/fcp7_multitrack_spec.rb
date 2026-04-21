require 'spec_helper'
require 'nokogiri'

RSpec.describe ButterCut::FCP7, 'multi-track' do
  let(:clip_a_path) { '/tmp/mt_clip_a.mov' }
  let(:clip_b_path) { '/tmp/mt_clip_b.mov' }
  let(:sfx_path) { '/tmp/mt_sfx.wav' }

  def build_metadata(duration_seconds:, frame_rate:, width: 1920, height: 1080, sample_rate: '48000')
    {
      'streams' => [
        { 'codec_type' => 'video', 'width' => width, 'height' => height,
          'r_frame_rate' => frame_rate, 'color_space' => 'bt709',
          'color_primaries' => 'bt709', 'color_transfer' => 'bt709' },
        { 'codec_type' => 'audio', 'sample_rate' => sample_rate }
      ],
      'format' => { 'duration' => duration_seconds.to_s, 'tags' => {} }
    }
  end

  def build_audio_only_metadata(duration_seconds:, sample_rate: '48000')
    {
      'streams' => [
        # Audio-only files still need a video stream stub for metadata probing;
        # in practice ffprobe would return only audio, but EditorBase requires
        # a video stream for width/height. We include a dummy one.
        { 'codec_type' => 'video', 'width' => 1920, 'height' => 1080,
          'r_frame_rate' => '25/1', 'color_space' => 'bt709',
          'color_primaries' => 'bt709', 'color_transfer' => 'bt709' },
        { 'codec_type' => 'audio', 'sample_rate' => sample_rate }
      ],
      'format' => { 'duration' => duration_seconds.to_s, 'tags' => {} }
    }
  end

  let(:metadata_by_path) do
    {
      clip_a_path => build_metadata(duration_seconds: 20.0, frame_rate: '25/1'),
      clip_b_path => build_metadata(duration_seconds: 15.0, frame_rate: '25/1'),
      sfx_path => build_audio_only_metadata(duration_seconds: 3.0)
    }
  end

  before do
    allow_any_instance_of(described_class).to receive(:extract_metadata_from_ffprobe) do |_instance, path|
      metadata_by_path.fetch(path)
    end
  end

  describe 'default single-track behavior' do
    let(:generator) do
      described_class.new([
        { path: clip_a_path, duration: 10.0 },
        { path: clip_b_path, duration: 5.0 }
      ])
    end

    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'produces one video track and one audio track' do
      expect(doc.xpath('//media/video/track').size).to eq(1)
      expect(doc.xpath('//media/audio/track').size).to eq(1)
    end

    it 'places clips sequentially on track 1' do
      starts = doc.xpath('//media/video/track/clipitem/start').map { |e| e.text.to_i }
      # 10s @ 25fps = 250 frames; 5s = 125 frames
      expect(starts).to eq([0, 250])
    end
  end

  describe 'multiple video and audio tracks' do
    let(:generator) do
      described_class.new([
        { path: clip_a_path, duration: 10.0, video_track: 1, audio_track: 1 },
        { path: clip_b_path, duration: 5.0, video_track: 2, audio_track: 2, timeline_offset: 3.0 }
      ])
    end

    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'creates two video tracks' do
      expect(doc.xpath('//media/video/track').size).to eq(2)
    end

    it 'creates two audio tracks' do
      expect(doc.xpath('//media/audio/track').size).to eq(2)
    end

    it 'places track 1 clip at start' do
      track1_clips = doc.xpath('//media/video/track[1]/clipitem')
      expect(track1_clips.size).to eq(1)
      expect(track1_clips.first.at_xpath('start').text.to_i).to eq(0)
    end

    it 'places track 2 clip at the specified timeline_offset' do
      track2_clips = doc.xpath('//media/video/track[2]/clipitem')
      expect(track2_clips.size).to eq(1)
      # 3.0s @ 25fps = 75 frames
      expect(track2_clips.first.at_xpath('start').text.to_i).to eq(75)
    end

    it 'sets sourcetrack trackindex to 1 (source stream) regardless of timeline track' do
      track_indices = doc.xpath('//media/video/track/clipitem/sourcetrack/trackindex').map { |e| e.text.to_i }
      expect(track_indices).to eq([1, 1])
    end

    it 'sets audio sourcetrack trackindex to 1 (source stream) regardless of timeline track' do
      track_indices = doc.xpath('//media/audio/track/clipitem/sourcetrack/trackindex').map { |e| e.text.to_i }
      expect(track_indices).to eq([1, 1])
    end

    it 'sets correct link trackindex values' do
      # First clip: video_track=1, audio_track=1
      clip1_links = doc.xpath('//media/video/track[1]/clipitem/link')
      video_link_idx = clip1_links[0].at_xpath('trackindex').text.to_i
      audio_link_idx = clip1_links[1].at_xpath('trackindex').text.to_i
      expect(video_link_idx).to eq(1)
      expect(audio_link_idx).to eq(1)

      # Second clip: video_track=2, audio_track=2
      clip2_links = doc.xpath('//media/video/track[2]/clipitem/link')
      video_link_idx2 = clip2_links[0].at_xpath('trackindex').text.to_i
      audio_link_idx2 = clip2_links[1].at_xpath('trackindex').text.to_i
      expect(video_link_idx2).to eq(2)
      expect(audio_link_idx2).to eq(2)
    end
  end

  describe 'explicit source_stream_index' do
    let(:generator) do
      described_class.new([
        { path: clip_a_path, duration: 10.0, video_track: 1, audio_track: 1 },
        { path: clip_b_path, duration: 5.0, video_track: 2, audio_track: 2,
          timeline_offset: 3.0, source_stream_index: 2 }
      ])
    end

    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'uses explicit source_stream_index for sourcetrack when set' do
      track_indices = doc.xpath('//media/video/track/clipitem/sourcetrack/trackindex').map { |e| e.text.to_i }
      expect(track_indices).to eq([1, 2])
    end
  end

  describe 'per-track independent timeline offsets' do
    let(:generator) do
      described_class.new([
        { path: clip_a_path, duration: 10.0, video_track: 1 },
        { path: clip_a_path, duration: 5.0, video_track: 1 },
        { path: clip_b_path, duration: 5.0, video_track: 2, timeline_offset: 2.0 },
        { path: clip_b_path, duration: 5.0, video_track: 2 }
      ])
    end

    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'auto-sequences clips on track 1' do
      track1 = doc.xpath('//media/video/track[1]/clipitem')
      starts = track1.map { |c| c.at_xpath('start').text.to_i }
      # 10s=250, then 250
      expect(starts).to eq([0, 250])
    end

    it 'starts track 2 at explicit offset then auto-sequences' do
      track2 = doc.xpath('//media/video/track[2]/clipitem')
      starts = track2.map { |c| c.at_xpath('start').text.to_i }
      # 2s=50, then 50+125=175
      expect(starts).to eq([50, 175])
    end

    it 'computes sequence duration from the longest track' do
      duration = doc.at_xpath('//sequence/duration').text.to_i
      # Track 1: 10+5=15s=375 frames; Track 2: 2+5+5=12s=300 frames
      expect(duration).to eq(375)
    end
  end

  describe 'audio-only clips' do
    let(:generator) do
      described_class.new([
        { path: clip_a_path, duration: 10.0, video_track: 1, audio_track: 1 },
        { path: sfx_path, duration: 3.0, media_type: :audio_only, audio_track: 2, timeline_offset: 5.0 }
      ])
    end

    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'creates one video track (audio-only clips excluded from video)' do
      expect(doc.xpath('//media/video/track').size).to eq(1)
      expect(doc.xpath('//media/video/track[1]/clipitem').size).to eq(1)
    end

    it 'creates two audio tracks' do
      expect(doc.xpath('//media/audio/track').size).to eq(2)
    end

    it 'places audio-only clip on audio track 2 at specified offset' do
      track2 = doc.xpath('//media/audio/track[2]/clipitem')
      expect(track2.size).to eq(1)
      # 5s @ 25fps = 125 frames
      expect(track2.first.at_xpath('start').text.to_i).to eq(125)
    end

    it 'does not include video link for audio-only clip' do
      track2_clip = doc.at_xpath('//media/audio/track[2]/clipitem')
      link_types = track2_clip.xpath('link/mediatype').map(&:text)
      expect(link_types).to eq(['audio'])
    end
  end

  describe 'mixed tracks with markers' do
    let(:generator) do
      described_class.new(
        [
          { path: clip_a_path, duration: 10.0, video_track: 1, audio_track: 1 },
          { path: clip_b_path, duration: 5.0, video_track: 2, audio_track: 2, timeline_offset: 2.0 }
        ],
        markers: [
          { name: 'TITLE', comment: 'Lower third', frame: 50, color: 'blue' }
        ]
      )
    end

    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'includes markers alongside multi-track media' do
      expect(doc.xpath('//sequence/marker').size).to eq(1)
      expect(doc.xpath('//media/video/track').size).to eq(2)
    end
  end

  describe 'file deduplication across tracks' do
    let(:generator) do
      described_class.new([
        { path: clip_a_path, duration: 10.0, video_track: 1, audio_track: 1 },
        { path: clip_a_path, duration: 5.0, video_track: 2, audio_track: 2, timeline_offset: 2.0 },
        { path: clip_a_path, duration: 3.0, video_track: 1, audio_track: 1 }
      ])
    end

    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'defines the full file element only once across all clipitems' do
      all_files = doc.xpath('//clipitem/file')
      full_defs = all_files.select { |f| f.at_xpath('pathurl') }
      refs_only = all_files.reject { |f| f.at_xpath('pathurl') }

      expect(full_defs.size).to eq(1)
      expect(refs_only.size).to eq(all_files.size - 1)
    end

    it 'uses the same file id for all references to the same asset' do
      file_ids = doc.xpath('//clipitem/file').map { |f| f['id'] }.uniq
      expect(file_ids.size).to eq(1)
    end

    it 'emits empty file references with only the id attribute' do
      all_files = doc.xpath('//clipitem/file')
      refs_only = all_files.reject { |f| f.at_xpath('pathurl') }
      refs_only.each do |f|
        expect(f['id']).not_to be_nil
        expect(f.element_children).to be_empty
      end
    end
  end
end
