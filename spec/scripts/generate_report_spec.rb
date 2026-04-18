require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'
require 'fileutils'

REPORT_SCRIPT = File.expand_path('../../scripts/generate_report.rb', __dir__)

def make_library(dir, overrides = {})
  transcripts_dir = File.join(dir, 'transcripts')
  FileUtils.mkdir_p(transcripts_dir)

  library = {
    'library_name' => 'test-lib',
    'language' => 'english',
    'editor' => 'premiere',
    'videos' => [{
      'path' => '/tmp/test_video.mp4',
      'duration' => '05:30',
      'transcript' => 'test.json',
      'visual_transcript' => nil,
      'speech_analysis' => nil
    }]
  }.merge(overrides)

  File.write(File.join(dir, 'library.yaml'), library.to_yaml)
  dir
end

def make_classified(dir, segments = nil)
  segments ||= [
    { 't' => 10.0, 'e' => 18.5, 'states' => %w[competence aspiration], 'distillation' => 'business model comparison',
      'signal' => 'named frameworks', 'dur' => 'identity', 'roles' => %w[primary], 'confidence' => 'high',
      'signpost' => false, 'audio_profile' => 'authoritative' },
    { 't' => 20.0, 'e' => 28.0, 'states' => %w[vindication], 'distillation' => 'why others fail',
      'signal' => 'specific critique', 'dur' => 'mood', 'roles' => %w[secondary], 'confidence' => 'high',
      'signpost' => false, 'audio_profile' => 'emphatic' },
    { 't' => 30.0, 'e' => 42.0, 'states' => %w[aspiration competence], 'distillation' => 'winning strategy revealed',
      'signal' => 'concrete proof', 'dur' => 'identity', 'roles' => %w[primary], 'confidence' => 'high',
      'signpost' => false, 'audio_profile' => 'authoritative' }
  ]
  File.write(File.join(dir, 'segments_classified.yaml'), { 'segments' => segments }.to_yaml)
end

def make_scored(dir, storylines = nil)
  storylines ||= [{
    'id' => 'test_storyline',
    'hook_segment' => 10.0,
    'close_segment' => 30.0,
    'combined_score' => 82,
    'passed_floor' => true,
    'duration_estimate' => 32,
    'template_match' => {
      'template' => 'problem_solution',
      'fit_score' => 76,
      'completeness' => 80,
      'matched_beats' => {
        'problem_statement' => { 'segment_t' => 10.0, 'distillation' => 'business model comparison' },
        'evidence' => { 'segment_t' => 20.0, 'distillation' => 'why others fail' },
        'solution_reveal' => { 'segment_t' => 30.0, 'distillation' => 'winning strategy revealed' }
      },
      'missing_beats' => %w[proof takeaway]
    }
  }]
  File.write(File.join(dir, 'storylines_scored.yaml'), { 'storylines' => storylines }.to_yaml)
end

def run_report(dir, flags: {})
  args = ['ruby', REPORT_SCRIPT, dir]
  args += ['--profile', flags[:profile]] if flags[:profile]
  stdout, stderr, status = Open3.capture3(*args)
  result = nil
  if status.success? && !stdout.strip.empty?
    report_path = stdout.strip
    result = YAML.safe_load(File.read(report_path), permitted_classes: [Date]) if File.exist?(report_path)
  end
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result }
end

RSpec.describe 'generate_report.rb' do
  describe 'CLI' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', REPORT_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when library path not found' do
      _, stderr, status = Open3.capture3('ruby', REPORT_SCRIPT, '/nonexistent/path')
      expect(status.exitstatus).to eq(1)
    end
  end

  describe 'report schema' do
    it 'produces all required top-level fields' do
      Dir.mktmpdir do |dir|
        make_library(dir)
        make_classified(dir)
        make_scored(dir)
        result = run_report(dir)

        expect(result[:exit_code]).to eq(0)
        report = result[:result]
        expect(report).to have_key('video')
        expect(report).to have_key('creator')
        expect(report).to have_key('duration')
        expect(report).to have_key('analyzed')
        expect(report).to have_key('structure')
        expect(report).to have_key('emotional_architecture')
        expect(report).to have_key('pacing')
        expect(report).to have_key('audio_delivery')
        expect(report).to have_key('visual_language')
        expect(report).to have_key('hook')
        expect(report).to have_key('close')
      end
    end

    it 'populates structure from scored storylines' do
      Dir.mktmpdir do |dir|
        make_library(dir)
        make_classified(dir)
        make_scored(dir)
        result = run_report(dir)
        report = result[:result]

        expect(report['structure']['template_match']).to eq('problem_solution')
        expect(report['structure']['template_fit']).to eq(76)
        expect(report['structure']['beat_count']).to eq(3)
        expect(report['structure']['beats']).to include('problem_statement')
      end
    end

    it 'populates emotional architecture from segments' do
      Dir.mktmpdir do |dir|
        make_library(dir)
        make_classified(dir)
        make_scored(dir)
        result = run_report(dir)
        report = result[:result]

        ea = report['emotional_architecture']
        expect(ea['primary_states']).to be_an(Array)
        expect(ea['primary_states'].size).to be <= 3
        expect(ea['spine']).to be_a(String)
        expect(ea['state_transitions']).to be_a(Integer)
        expect(ea['transitions_per_minute']).to be_a(Float)
      end
    end

    it 'populates pacing from segments' do
      Dir.mktmpdir do |dir|
        make_library(dir)
        make_classified(dir)
        result = run_report(dir)
        report = result[:result]

        pacing = report['pacing']
        expect(pacing['total_segments']).to eq(3)
        expect(pacing['avg_segment_duration']).to be > 0
        expect(pacing['median_segment_duration']).to be > 0
        expect(pacing['segments_over_12s']).to be_a(Integer)
      end
    end

    it 'populates hook and close from top storyline' do
      Dir.mktmpdir do |dir|
        make_library(dir)
        make_classified(dir)
        make_scored(dir)
        result = run_report(dir)
        report = result[:result]

        expect(report['hook']['duration']).to eq(8.5)
        expect(report['hook']['state']).to include('competence')
        expect(report['close']['duration']).to eq(12.0)
      end
    end
  end

  describe 'edge cases' do
    it 'handles library with no classification' do
      Dir.mktmpdir do |dir|
        make_library(dir)
        result = run_report(dir)
        expect(result[:exit_code]).to eq(0)
        expect(result[:result]['pacing']).to eq({})
        expect(result[:result]['emotional_architecture']).to eq({})
      end
    end

    it 'handles library with classification but no scoring' do
      Dir.mktmpdir do |dir|
        make_library(dir)
        make_classified(dir)
        result = run_report(dir)
        expect(result[:exit_code]).to eq(0)
        expect(result[:result]['structure']).to eq({})
        expect(result[:result]['pacing']['total_segments']).to eq(3)
      end
    end

    it 'calculates duration from HH:MM:SS format' do
      Dir.mktmpdir do |dir|
        make_library(dir, { 'videos' => [{ 'path' => '/tmp/test.mp4', 'duration' => '01:05:30' }] })
        result = run_report(dir)
        expect(result[:result]['duration']).to eq(3930.0)
      end
    end
  end

  describe '--profile flag' do
    it 'sets creator from profile name' do
      Dir.mktmpdir do |dir|
        make_library(dir)
        make_classified(dir)
        result = run_report(dir, flags: { profile: 'dylan' })
        expect(result[:result]['creator']).to eq('dylan')
      end
    end
  end
end
