require 'spec_helper'
require 'nokogiri'

RSpec.describe ButterCut::FCP7, 'markers' do
  let(:clip_a_path) { '/tmp/fcp7_marker_clip_a.mov' }
  let(:clip_b_path) { '/tmp/fcp7_marker_clip_b.mov' }

  def build_metadata(duration_seconds:, frame_rate:, width: 1920, height: 1080, sample_rate: '48000', timecode: nil)
    video_stream = {
      'codec_type' => 'video',
      'width' => width,
      'height' => height,
      'r_frame_rate' => frame_rate,
      'color_space' => 'bt709',
      'color_primaries' => 'bt709',
      'color_transfer' => 'bt709'
    }

    audio_stream = {
      'codec_type' => 'audio',
      'sample_rate' => sample_rate
    }

    {
      'streams' => [video_stream, audio_stream],
      'format' => {
        'duration' => duration_seconds.to_s,
        'tags' => timecode ? { 'timecode' => timecode } : {}
      }
    }
  end

  let(:metadata_by_path) do
    {
      clip_a_path => build_metadata(duration_seconds: 10.0, frame_rate: '25/1'),
      clip_b_path => build_metadata(duration_seconds: 10.0, frame_rate: '25/1')
    }
  end

  before do
    allow_any_instance_of(described_class).to receive(:extract_metadata_from_ffprobe) do |_instance, path|
      metadata_by_path.fetch(path)
    end
  end

  let(:clips) do
    [
      { path: clip_a_path, duration: 10.0 },
      { path: clip_b_path, duration: 10.0 }
    ]
  end

  let(:markers) do
    [
      { name: 'TITLE', comment: 'Insert lower third: Speaker Name', frame: 50, color: 'blue' },
      { name: 'B-ROLL', comment: 'Insert city_aerial.mp4 for 3 seconds', frame: 300, color: 'green' },
      { name: 'TRANSITION', comment: 'Cross dissolve 15 frames', frame: 245, color: 'orange' },
      { name: 'SFX', comment: 'Play whoosh_in.wav at -6dB', frame: 300, color: 'purple' },
      { name: 'MUSIC', comment: 'Fade in bg_track.mp3 to -18dB over 2 seconds', frame: 0, color: 'red' },
      { name: 'NOTE', comment: 'Color grade this section warmer', frame: 100, color: 'yellow' }
    ]
  end

  describe 'initialization' do
    it 'accepts an optional markers parameter' do
      gen = described_class.new(clips, markers: markers)
      expect(gen.markers).to eq(markers)
    end

    it 'defaults markers to empty array' do
      gen = described_class.new(clips)
      expect(gen.markers).to eq([])
    end

    it 'raises ArgumentError when marker is missing :name' do
      bad = [{ comment: 'test', frame: 10, color: 'blue' }]
      expect { described_class.new(clips, markers: bad) }.to raise_error(ArgumentError, /name/)
    end

    it 'raises ArgumentError when marker is missing :comment' do
      bad = [{ name: 'TITLE', frame: 10, color: 'blue' }]
      expect { described_class.new(clips, markers: bad) }.to raise_error(ArgumentError, /comment/)
    end

    it 'raises ArgumentError when marker is missing :frame and :time' do
      bad = [{ name: 'TITLE', comment: 'test', color: 'blue' }]
      expect { described_class.new(clips, markers: bad) }.to raise_error(ArgumentError, /frame or :time/)
    end

    it 'raises ArgumentError when marker is missing :color' do
      bad = [{ name: 'TITLE', comment: 'test', frame: 10 }]
      expect { described_class.new(clips, markers: bad) }.to raise_error(ArgumentError, /color/)
    end

    it 'raises ArgumentError for invalid marker color' do
      bad = [{ name: 'TITLE', comment: 'test', frame: 10, color: 'pink' }]
      expect { described_class.new(clips, markers: bad) }.to raise_error(ArgumentError, /invalid color.*pink/i)
    end
  end

  describe 'XML generation with markers' do
    let(:generator) { described_class.new(clips, markers: markers) }
    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'includes all six markers in the output' do
      expect(doc.xpath('//sequence/marker').size).to eq(6)
    end

    it 'places markers after the media element' do
      seq = doc.at_xpath('//sequence')
      children = seq.element_children.map(&:name)
      media_idx = children.index('media')
      marker_indices = children.each_index.select { |i| children[i] == 'marker' }

      marker_indices.each do |idx|
        expect(idx).to be > media_idx
      end
    end

    it 'sets correct marker names' do
      names = doc.xpath('//sequence/marker/name').map(&:text)
      expect(names).to eq(['TITLE', 'B-ROLL', 'TRANSITION', 'SFX', 'MUSIC', 'NOTE'])
    end

    it 'sets correct marker comments' do
      comments = doc.xpath('//sequence/marker/comment').map(&:text)
      expect(comments).to eq([
        'Insert lower third: Speaker Name',
        'Insert city_aerial.mp4 for 3 seconds',
        'Cross dissolve 15 frames',
        'Play whoosh_in.wav at -6dB',
        'Fade in bg_track.mp3 to -18dB over 2 seconds',
        'Color grade this section warmer'
      ])
    end

    it 'sets correct frame positions from :frame parameter' do
      ins = doc.xpath('//sequence/marker/in').map { |e| e.text.to_i }
      expect(ins).to eq([50, 300, 245, 300, 0, 100])
    end

    it 'sets marker out to -1 for point markers' do
      outs = doc.xpath('//sequence/marker/out').map { |e| e.text.to_i }
      expect(outs).to all(eq(-1))
    end

    it 'assigns correct colors as RGBA sub-elements' do
      color_map = doc.xpath('//sequence/marker').each_with_object({}) do |m, hash|
        c = m.at_xpath('color')
        hash[m.at_xpath('name').text] = {
          red: c.at_xpath('red').text.to_i,
          green: c.at_xpath('green').text.to_i,
          blue: c.at_xpath('blue').text.to_i,
          alpha: c.at_xpath('alpha').text.to_i
        }
      end

      expect(color_map).to eq(
        'TITLE'      => { red: 0,   green: 63,  blue: 255, alpha: 255 },
        'B-ROLL'     => { red: 0,   green: 196, blue: 0,   alpha: 255 },
        'TRANSITION' => { red: 255, green: 132, blue: 0,   alpha: 255 },
        'SFX'        => { red: 190, green: 73,  blue: 255, alpha: 255 },
        'MUSIC'      => { red: 255, green: 38,  blue: 38,  alpha: 255 },
        'NOTE'       => { red: 255, green: 255, blue: 0,   alpha: 255 }
      )
    end
  end

  describe 'markers with :time parameter' do
    let(:time_markers) do
      [
        { name: 'TITLE', comment: 'At 2 seconds', time: 2.0, color: 'blue' },
        { name: 'NOTE', comment: 'At 10 seconds', time: 10.0, color: 'yellow' }
      ]
    end

    let(:generator) { described_class.new(clips, markers: time_markers) }
    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'converts :time in seconds to frame position' do
      # 25fps: 2.0s => 50 frames, 10.0s => 250 frames
      ins = doc.xpath('//sequence/marker/in').map { |e| e.text.to_i }
      expect(ins).to eq([50, 250])
    end
  end

  describe 'XML generation without markers' do
    let(:generator) { described_class.new(clips) }
    let(:doc) { Nokogiri::XML(generator.to_xml) }

    it 'produces valid XML with no marker elements' do
      expect(doc.xpath('//sequence/marker')).to be_empty
      expect(doc.at_xpath('//xmeml')['version']).to eq('5')
    end
  end

  describe 'MARKER_CATEGORIES constant' do
    it 'maps all six categories to correct colors' do
      expect(ButterCut::FCP7::MARKER_CATEGORIES).to eq(
        'TITLE' => 'blue',
        'B-ROLL' => 'green',
        'TRANSITION' => 'orange',
        'SFX' => 'purple',
        'MUSIC' => 'red',
        'NOTE' => 'yellow'
      )
    end
  end

  describe 'factory integration' do
    before do
      allow_any_instance_of(ButterCut::FCP7).to receive(:extract_metadata_from_ffprobe) do |_instance, path|
        metadata_by_path.fetch(path)
      end
    end

    it 'passes markers through ButterCut.new to FCP7 generator' do
      gen = ButterCut.new(clips, editor: :fcp7, markers: markers)
      expect(gen).to be_a(ButterCut::FCP7)
      expect(gen.markers).to eq(markers)
    end

    it 'defaults markers to empty when not provided' do
      gen = ButterCut.new(clips, editor: :fcp7)
      expect(gen.markers).to eq([])
    end
  end
end
