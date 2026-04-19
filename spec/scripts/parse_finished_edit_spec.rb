require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'
require 'fileutils'
require 'nokogiri'

PARSE_EDIT_SCRIPT = File.expand_path('../../scripts/parse_finished_edit.rb', __dir__)
ROOT_FOR_PARSE = File.expand_path('../..', __dir__)

def build_xmeml(options = {})
  timebase = options[:timebase] || 25
  ntsc = options[:ntsc] || 'FALSE'
  seq_name = options[:sequence_name] || 'Test Sequence'
  duration = options[:duration] || 500  # frames

  v1_clips = options[:v1_clips] || [
    { name: 'clip_a.mov', start: 0, end: 125 },
    { name: 'clip_b.mov', start: 125, end: 250 }
  ]
  v2_clips = options[:v2_clips] || []
  a1_clips = options[:a1_clips] || [
    { name: 'clip_a.mov', start: 0, end: 250 }
  ]
  a3_clips = options[:a3_clips] || []

  builder = Nokogiri::XML::Builder.new(encoding: 'UTF-8') do |xml|
    xml.xmeml(version: '5') do
      xml.sequence do
        xml.name seq_name
        xml.duration duration
        xml.rate do
          xml.timebase timebase
          xml.ntsc ntsc
        end
        xml.media do
          xml.video do
            xml.format do
              xml.samplecharacteristics do
                xml.rate { xml.timebase timebase; xml.ntsc ntsc }
                xml.width 1920
                xml.height 1080
              end
            end
            # V1 track
            xml.track do
              v1_clips.each do |c|
                xml.clipitem do
                  xml.name c[:name]
                  xml.start c[:start]
                  xml.end_ c[:end]
                  xml.duration(c[:end] - c[:start])
                  xml.file(id: "file-#{c[:name]}") { xml.pathurl "file:///#{c[:name]}" }
                end
              end
            end
            # V2+ tracks
            unless v2_clips.empty?
              xml.track do
                v2_clips.each do |c|
                  xml.clipitem do
                    xml.name c[:name]
                    xml.start c[:start]
                    xml.end_ c[:end]
                    xml.duration(c[:end] - c[:start])
                    xml.file(id: "file-#{c[:name]}") { xml.pathurl "file:///#{c[:name]}" }
                  end
                end
              end
            end
          end
          xml.audio do
            xml.numOutputChannels 2
            xml.format do
              xml.samplecharacteristics { xml.samplerate 48000; xml.sampledepth 16 }
            end
            # A1 track
            xml.track do
              a1_clips.each do |c|
                xml.clipitem do
                  xml.name c[:name]
                  xml.start c[:start]
                  xml.end_ c[:end]
                  xml.duration(c[:end] - c[:start])
                end
              end
            end
            # A2 track (empty)
            xml.track {}
            # A3+ tracks
            unless a3_clips.empty?
              xml.track do
                a3_clips.each do |c|
                  xml.clipitem do
                    xml.name c[:name]
                    xml.start c[:start]
                    xml.end_ c[:end]
                    xml.duration(c[:end] - c[:start])
                  end
                end
              end
            end
          end
        end
      end
    end
  end

  builder.to_xml
end

def setup_parse_library(lib_name, classified_segments: nil)
  lib_dir = File.join(ROOT_FOR_PARSE, 'libraries', lib_name)
  FileUtils.mkdir_p(lib_dir)

  library = {
    'library_name' => lib_name,
    'editor' => 'fcp7',
    'videos' => [{ 'path' => '/tmp/test.mp4', 'duration' => '10:00' }]
  }
  File.write(File.join(lib_dir, 'library.yaml'), library.to_yaml)

  if classified_segments
    File.write(File.join(lib_dir, 'segments_classified.yaml'),
      { 'segments' => classified_segments }.to_yaml)
  end

  lib_dir
end

def cleanup_parse_library(lib_name)
  lib_dir = File.join(ROOT_FOR_PARSE, 'libraries', lib_name)
  FileUtils.rm_rf(lib_dir)
end

def run_parse(lib_name, xml_path)
  stdout, stderr, status = Open3.capture3(
    'ruby', PARSE_EDIT_SCRIPT,
    '--library', lib_name,
    '--finished', xml_path
  )
  result = nil
  if status.success? && !stdout.strip.empty?
    result_path = stdout.strip
    result = YAML.safe_load(File.read(result_path), permitted_classes: [Date]) if File.exist?(result_path)
  end
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result }
end

RSpec.describe 'parse_finished_edit.rb' do
  let(:test_lib) { "_test_parse_edit_#{$$}" }

  after { cleanup_parse_library(test_lib) }

  describe 'CLI validation' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', PARSE_EDIT_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when finished XML does not exist' do
      setup_parse_library(test_lib)
      _, stderr, status = Open3.capture3(
        'ruby', PARSE_EDIT_SCRIPT,
        '--library', test_lib, '--finished', '/nonexistent/file.xml'
      )
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('not found')
    end

    it 'exits 1 when library does not exist' do
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml)
        _, stderr, status = Open3.capture3(
          'ruby', PARSE_EDIT_SCRIPT,
          '--library', '_nonexistent_lib_999', '--finished', xml_path
        )
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('not found')
      end
    end
  end

  describe 'multi-track parsing' do
    it 'identifies V1 clips as primary' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml(
          v1_clips: [
            { name: 'talk_a.mov', start: 0, end: 125 },
            { name: 'talk_b.mov', start: 125, end: 250 }
          ]
        ))
        r = run_parse(test_lib, xml_path)
        expect(r[:exit_code]).to eq(0)
        expect(r[:result]['primary_clips']).to eq(2)
      end
    end

    it 'identifies V2+ clips as video overlays' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml(
          v2_clips: [
            { name: 'broll_1.mp4', start: 50, end: 100 },
            { name: 'graphic_1.png', start: 200, end: 225 }
          ]
        ))
        r = run_parse(test_lib, xml_path)
        expect(r[:result]['overlay_elements']['video_overlays']).to eq(2)
        types = r[:result]['overlay_placements'].map { |p| p['type'] }
        expect(types).to all(eq('video_overlay'))
      end
    end

    it 'identifies A3+ clips as audio overlays' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml(
          a3_clips: [{ name: 'music_bed.mp3', start: 0, end: 500 }]
        ))
        r = run_parse(test_lib, xml_path)
        expect(r[:result]['overlay_elements']['audio_overlays']).to eq(1)
        p = r[:result]['overlay_placements'].first
        expect(p['type']).to eq('audio_overlay')
        expect(p['track']).to eq('A3')
      end
    end

    it 'handles single-track XML with no overlays' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml)
        r = run_parse(test_lib, xml_path)
        expect(r[:exit_code]).to eq(0)
        expect(r[:result]['overlay_elements']['video_overlays']).to eq(0)
        expect(r[:result]['overlay_elements']['audio_overlays']).to eq(0)
        expect(r[:result]['overlay_placements']).to be_empty
      end
    end
  end

  describe 'frame-to-seconds conversion' do
    it 'converts correctly at 25fps' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml(
          timebase: 25, ntsc: 'FALSE',
          v2_clips: [{ name: 'overlay.mp4', start: 50, end: 100 }]
        ))
        r = run_parse(test_lib, xml_path)
        p = r[:result]['overlay_placements'].first
        expect(p['start']).to eq(2.0)   # 50/25
        expect(p['end']).to eq(4.0)     # 100/25
        expect(p['duration']).to eq(2.0)
      end
    end

    it 'converts correctly at 29.97fps (NTSC)' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml(
          timebase: 30, ntsc: 'TRUE',
          v2_clips: [{ name: 'overlay.mp4', start: 30, end: 60 }]
        ))
        r = run_parse(test_lib, xml_path)
        p = r[:result]['overlay_placements'].first
        # 30fps NTSC = 29.97fps → 30/29.97 ≈ 1.001
        expect(p['start']).to be_within(0.01).of(1.001)
        expect(p['duration']).to be_within(0.01).of(1.001)
      end
    end
  end

  describe 'segment correlation' do
    it 'matches overlay to correct classified segment by time range' do
      segments = [
        { 't' => 1.0, 'e' => 4.0, 'states' => %w[aspiration], 'distillation' => 'opening hook',
          'dur' => 'spike', 'narrative_role' => 'claim', 'audio_profile' => 'emphatic' },
        { 't' => 5.0, 'e' => 9.0, 'states' => %w[competence], 'distillation' => 'framework explained',
          'dur' => 'mood', 'narrative_role' => 'evidence', 'audio_profile' => 'authoritative' }
      ]
      setup_parse_library(test_lib, classified_segments: segments)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        # Overlay at 2.0s should match first segment (t=1.0, e=4.0)
        File.write(xml_path, build_xmeml(
          v2_clips: [{ name: 'broll.mp4', start: 50, end: 75 }]  # 50/25=2.0s
        ))
        r = run_parse(test_lib, xml_path)
        p = r[:result]['overlay_placements'].first
        expect(p['underlying_segment']).not_to be_nil
        expect(p['underlying_segment']['t']).to eq(1.0)
        expect(p['underlying_segment']['distillation']).to eq('opening hook')
        expect(p['underlying_segment']['narrative_role']).to eq('claim')
        expect(p['context']).to include('claim')
      end
    end

    it 'sets underlying_segment to nil when no segment matches' do
      segments = [
        { 't' => 10.0, 'e' => 15.0, 'states' => %w[competence], 'distillation' => 'later segment',
          'dur' => 'mood', 'narrative_role' => 'evidence' }
      ]
      setup_parse_library(test_lib, classified_segments: segments)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        # Overlay at 2.0s — no segment covers this time
        File.write(xml_path, build_xmeml(
          v2_clips: [{ name: 'broll.mp4', start: 50, end: 75 }]
        ))
        r = run_parse(test_lib, xml_path)
        p = r[:result]['overlay_placements'].first
        expect(p['underlying_segment']).to be_nil
        expect(p['context']).to include('no matching')
      end
    end

    it 'works without segments_classified.yaml' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml(
          v2_clips: [{ name: 'broll.mp4', start: 50, end: 75 }]
        ))
        r = run_parse(test_lib, xml_path)
        expect(r[:exit_code]).to eq(0)
        p = r[:result]['overlay_placements'].first
        expect(p['underlying_segment']).to be_nil
        expect(p['context']).to include('classification unavailable')
      end
    end
  end

  describe 'output format' do
    it 'includes all required top-level fields' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml)
        r = run_parse(test_lib, xml_path)

        expect(r[:result]).to have_key('analyzed')
        expect(r[:result]).to have_key('source_xml')
        expect(r[:result]).to have_key('sequence_name')
        expect(r[:result]).to have_key('duration_seconds')
        expect(r[:result]).to have_key('fps')
        expect(r[:result]).to have_key('primary_clips')
        expect(r[:result]).to have_key('overlay_elements')
        expect(r[:result]).to have_key('overlay_placements')
      end
    end

    it 'writes output file to library directory' do
      lib_dir = setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml)
        r = run_parse(test_lib, xml_path)
        expect(r[:stdout]).to start_with(lib_dir)
        expect(File.exist?(r[:stdout])).to be true
      end
    end

    it 'records clip names in placements' do
      setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml(
          v2_clips: [{ name: 'city_aerial.mp4', start: 50, end: 100 }]
        ))
        r = run_parse(test_lib, xml_path)
        p = r[:result]['overlay_placements'].first
        expect(p['clip_name']).to eq('city_aerial.mp4')
      end
    end
  end

  describe 'multiple parses' do
    it 'creates numbered files for subsequent parses' do
      lib_dir = setup_parse_library(test_lib)
      Dir.mktmpdir do |dir|
        xml_path = File.join(dir, 'test.xml')
        File.write(xml_path, build_xmeml)

        # First parse
        r1 = run_parse(test_lib, xml_path)
        expect(r1[:stdout]).to include('finished_edit_analysis.yaml')

        # Second parse
        r2 = run_parse(test_lib, xml_path)
        expect(r2[:stdout]).to include('finished_edit_analysis_2.yaml')
      end
    end
  end
end
