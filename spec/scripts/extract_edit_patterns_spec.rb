require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'
require 'fileutils'

EXTRACT_PATTERNS_SCRIPT = File.expand_path('../../scripts/extract_edit_patterns.rb', __dir__)
ROOT_FOR_EXTRACT = File.expand_path('../..', __dir__)

def setup_extract_library(lib_name, classified_segments: nil)
  lib_dir = File.join(ROOT_FOR_EXTRACT, 'libraries', lib_name)
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

def write_analysis(lib_dir, analysis, filename: 'finished_edit_analysis.yaml')
  File.write(File.join(lib_dir, filename), analysis.to_yaml)
end

def cleanup_extract_library(lib_name)
  lib_dir = File.join(ROOT_FOR_EXTRACT, 'libraries', lib_name)
  FileUtils.rm_rf(lib_dir)
end

def run_extract_patterns(lib_name)
  stdout, stderr, status = Open3.capture3(
    'ruby', EXTRACT_PATTERNS_SCRIPT,
    '--library', lib_name
  )
  result = nil
  if status.success? && !stdout.strip.empty?
    result_path = stdout.strip
    result = YAML.safe_load(File.read(result_path), permitted_classes: [Date]) if File.exist?(result_path)
  end
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result }
end

def base_analysis(overrides = {})
  {
    'analyzed' => '2026-04-19',
    'source_xml' => 'test_final.xml',
    'sequence_name' => 'Test Sequence',
    'duration_seconds' => 600.0,
    'fps' => 25.0,
    'primary_clips' => 30,
    'overlay_elements' => { 'video_overlays' => 5, 'audio_overlays' => 1 },
    'overlay_placements' => []
  }.merge(overrides)
end

def video_placement(start:, end_t:, role: nil, dur: nil, clip_name: 'broll.mp4')
  p = {
    'type' => 'video_overlay',
    'track' => 'V2',
    'start' => start,
    'end' => end_t,
    'duration' => (end_t - start).round(1),
    'clip_name' => clip_name
  }
  if role || dur
    p['underlying_segment'] = {
      't' => start - 1.0,
      'distillation' => 'test segment',
      'states' => ['competence'],
      'dur' => dur || 'mood',
      'narrative_role' => role || 'evidence'
    }
    p['context'] = "overlay on #{dur || 'mood'} #{role || 'evidence'} segment"
  else
    p['underlying_segment'] = nil
    p['context'] = 'no matching classified segment'
  end
  p
end

def audio_placement(start:, end_t:, clip_name: 'music.mp3')
  {
    'type' => 'audio_overlay',
    'track' => 'A3',
    'start' => start,
    'end' => end_t,
    'duration' => (end_t - start).round(1),
    'clip_name' => clip_name,
    'underlying_segment' => nil,
    'context' => 'no matching classified segment'
  }
end

RSpec.describe 'extract_edit_patterns.rb' do
  let(:test_lib) { "_test_extract_patterns_#{$$}" }

  after { cleanup_extract_library(test_lib) }

  describe 'CLI validation' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', EXTRACT_PATTERNS_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when no analysis files exist' do
      setup_extract_library(test_lib)
      r = run_extract_patterns(test_lib)
      expect(r[:exit_code]).to eq(1)
      expect(r[:stderr]).to include('No finished_edit_analysis')
    end
  end

  describe 'pattern aggregation' do
    it 'counts narrative_role overlay frequencies' do
      segments = [
        { 't' => 4.0, 'e' => 9.0, 'dur' => 'mood', 'narrative_role' => 'claim', 'states' => %w[aspiration] },
        { 't' => 14.0, 'e' => 19.0, 'dur' => 'mood', 'narrative_role' => 'claim', 'states' => %w[aspiration] },
        { 't' => 24.0, 'e' => 29.0, 'dur' => 'mood', 'narrative_role' => 'claim', 'states' => %w[aspiration] },
        { 't' => 34.0, 'e' => 39.0, 'dur' => 'mood', 'narrative_role' => 'evidence', 'states' => %w[competence] },
        { 't' => 44.0, 'e' => 49.0, 'dur' => 'mood', 'narrative_role' => 'evidence', 'states' => %w[competence] }
      ]
      lib_dir = setup_extract_library(test_lib, classified_segments: segments)

      analysis = base_analysis(
        'overlay_placements' => [
          video_placement(start: 5.0, end_t: 8.0, role: 'claim', dur: 'mood'),
          video_placement(start: 15.0, end_t: 18.0, role: 'claim', dur: 'mood'),
          video_placement(start: 35.0, end_t: 38.0, role: 'evidence', dur: 'mood')
        ]
      )
      write_analysis(lib_dir, analysis)

      r = run_extract_patterns(test_lib)
      expect(r[:exit_code]).to eq(0)

      claim_pattern = r[:result]['video_overlay_patterns'].find { |p| p['trigger'] == 'narrative_role = claim' }
      expect(claim_pattern).not_to be_nil
      expect(claim_pattern['frequency']).to eq('2/3')

      evidence_pattern = r[:result]['video_overlay_patterns'].find { |p| p['trigger'] == 'narrative_role = evidence' }
      expect(evidence_pattern).not_to be_nil
      expect(evidence_pattern['frequency']).to eq('1/2')
    end

    it 'counts durability overlay frequencies' do
      segments = [
        { 't' => 4.0, 'e' => 9.0, 'dur' => 'identity', 'narrative_role' => 'claim', 'states' => %w[vindication] },
        { 't' => 14.0, 'e' => 19.0, 'dur' => 'identity', 'narrative_role' => 'evidence', 'states' => %w[vindication] },
        { 't' => 24.0, 'e' => 29.0, 'dur' => 'spike', 'narrative_role' => 'claim', 'states' => %w[aspiration] }
      ]
      lib_dir = setup_extract_library(test_lib, classified_segments: segments)

      analysis = base_analysis(
        'overlay_placements' => [
          video_placement(start: 5.0, end_t: 8.0, role: 'claim', dur: 'identity'),
          video_placement(start: 15.0, end_t: 18.0, role: 'evidence', dur: 'identity')
        ]
      )
      write_analysis(lib_dir, analysis)

      r = run_extract_patterns(test_lib)
      identity_pattern = r[:result]['video_overlay_patterns'].find { |p| p['trigger'] == 'dur = identity' }
      expect(identity_pattern).not_to be_nil
      expect(identity_pattern['frequency']).to eq('2/2')
    end

    it 'calculates typical overlay duration' do
      segments = [
        { 't' => 4.0, 'e' => 9.0, 'dur' => 'mood', 'narrative_role' => 'claim', 'states' => %w[aspiration] },
        { 't' => 14.0, 'e' => 19.0, 'dur' => 'mood', 'narrative_role' => 'claim', 'states' => %w[aspiration] }
      ]
      lib_dir = setup_extract_library(test_lib, classified_segments: segments)

      analysis = base_analysis(
        'overlay_placements' => [
          video_placement(start: 5.0, end_t: 8.0, role: 'claim', dur: 'mood'),   # 3.0s
          video_placement(start: 15.0, end_t: 20.0, role: 'claim', dur: 'mood')   # 5.0s
        ]
      )
      write_analysis(lib_dir, analysis)

      r = run_extract_patterns(test_lib)
      claim_pattern = r[:result]['video_overlay_patterns'].find { |p| p['trigger'] == 'narrative_role = claim' }
      expect(claim_pattern['typical_duration']).to eq(4.0)  # avg of 3.0 and 5.0
    end
  end

  describe 'multiple analyses' do
    it 'reads multiple finished_edit_analysis files' do
      segments = [
        { 't' => 4.0, 'e' => 9.0, 'dur' => 'mood', 'narrative_role' => 'claim', 'states' => %w[aspiration] }
      ]
      lib_dir = setup_extract_library(test_lib, classified_segments: segments)

      a1 = base_analysis('overlay_placements' => [
        video_placement(start: 5.0, end_t: 8.0, role: 'claim', dur: 'mood')
      ])
      a2 = base_analysis('overlay_placements' => [
        video_placement(start: 5.0, end_t: 9.0, role: 'claim', dur: 'mood')
      ])
      write_analysis(lib_dir, a1, filename: 'finished_edit_analysis.yaml')
      write_analysis(lib_dir, a2, filename: 'finished_edit_analysis_2.yaml')

      r = run_extract_patterns(test_lib)
      expect(r[:exit_code]).to eq(0)
      expect(r[:result]['patterns_from']).to eq(2)
    end
  end

  describe 'audio patterns' do
    it 'detects full-length music bed' do
      lib_dir = setup_extract_library(test_lib)
      analysis = base_analysis(
        'duration_seconds' => 600.0,
        'overlay_placements' => [
          audio_placement(start: 0.0, end_t: 580.0)  # 96% of 600s → full bed
        ]
      )
      write_analysis(lib_dir, analysis)

      r = run_extract_patterns(test_lib)
      bed_pattern = r[:result]['audio_overlay_patterns'].find { |p| p['trigger'] == 'full_length_bed' }
      expect(bed_pattern).not_to be_nil
      expect(bed_pattern['note']).to include('music bed')
    end

    it 'detects short audio overlays as SFX' do
      lib_dir = setup_extract_library(test_lib)
      analysis = base_analysis(
        'duration_seconds' => 600.0,
        'overlay_placements' => [
          audio_placement(start: 50.0, end_t: 52.0, clip_name: 'whoosh.wav'),
          audio_placement(start: 120.0, end_t: 123.0, clip_name: 'ding.wav')
        ]
      )
      write_analysis(lib_dir, analysis)

      r = run_extract_patterns(test_lib)
      sfx_pattern = r[:result]['audio_overlay_patterns'].find { |p| p['trigger'] == 'short_audio_overlay' }
      expect(sfx_pattern).not_to be_nil
    end
  end

  describe 'pacing observations' do
    it 'calculates overlays per minute' do
      lib_dir = setup_extract_library(test_lib)
      analysis = base_analysis(
        'duration_seconds' => 600.0,
        'primary_clips' => 60,
        'overlay_placements' => [
          video_placement(start: 50.0, end_t: 53.0),
          video_placement(start: 100.0, end_t: 103.0),
          video_placement(start: 200.0, end_t: 203.0),
          video_placement(start: 300.0, end_t: 303.0),
          video_placement(start: 500.0, end_t: 503.0)
        ]
      )
      write_analysis(lib_dir, analysis)

      r = run_extract_patterns(test_lib)
      pacing = r[:result]['pacing_observations']
      expect(pacing['overlays_per_minute']).to eq(0.5)  # 5 overlays / 10 min
      expect(pacing['avg_primary_clip_duration']).to eq(10.0)  # 600s / 60 clips
    end

    it 'calculates longest unbroken primary run' do
      lib_dir = setup_extract_library(test_lib)
      analysis = base_analysis(
        'duration_seconds' => 300.0,
        'overlay_placements' => [
          video_placement(start: 50.0, end_t: 53.0),
          video_placement(start: 200.0, end_t: 203.0)
        ]
      )
      write_analysis(lib_dir, analysis)

      r = run_extract_patterns(test_lib)
      pacing = r[:result]['pacing_observations']
      # Gaps: 0→50 (50s), 53→200 (147s), 203→300 (97s)
      expect(pacing['longest_unbroken_primary_run']).to eq(147.0)
    end
  end

  describe 'output' do
    it 'writes edit_patterns.yaml to library directory' do
      lib_dir = setup_extract_library(test_lib)
      write_analysis(lib_dir, base_analysis)

      r = run_extract_patterns(test_lib)
      expect(r[:exit_code]).to eq(0)
      expect(r[:stdout]).to end_with('edit_patterns.yaml')
      expect(File.exist?(r[:stdout])).to be true
    end

    it 'includes all required top-level fields' do
      lib_dir = setup_extract_library(test_lib)
      write_analysis(lib_dir, base_analysis)

      r = run_extract_patterns(test_lib)
      expect(r[:result]).to have_key('patterns_from')
      expect(r[:result]).to have_key('generated_at')
      expect(r[:result]).to have_key('video_overlay_patterns')
      expect(r[:result]).to have_key('audio_overlay_patterns')
      expect(r[:result]).to have_key('pacing_observations')
    end
  end
end
