require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'
require 'fileutils'

CREATOR_PROFILE_SCRIPT = File.expand_path('../../scripts/extract_creator_profile.rb', __dir__)

def make_report(dir, name, overrides = {})
  report = {
    'video' => "#{name}.mp4",
    'creator' => 'testcreator',
    'duration' => 600.0,
    'analyzed' => '2026-04-19T00:00:00+00:00',
    'structure' => {
      'template_match' => 'problem_solution',
      'template_fit' => 75,
      'beats' => %w[problem evidence solution],
      'beat_count' => 3
    },
    'emotional_architecture' => {
      'primary_states' => %w[competence aspiration vindication],
      'spine' => 'competence',
      'durability_arc' => 'identity(3) → mood(1)',
      'state_transitions' => 4,
      'transitions_per_minute' => 0.8
    },
    'pacing' => {
      'avg_segment_duration' => 10.0,
      'median_segment_duration' => 9.5,
      'segments_over_12s' => 2,
      'total_segments' => 30
    },
    'audio_delivery' => {
      'dominant_profile' => 'authoritative',
      'energy_baseline' => 'medium',
      'speaking_rate' => 1.05
    },
    'visual_language' => {
      'talking_head_ratio' => 0.85,
      'scene_changes' => 10,
      'cuts_per_minute' => 1.5,
      'avg_shot_duration' => 40.0
    },
    'hook' => {
      'duration' => 8.5,
      'state' => 'competence (identity)',
      'audio_profile' => 'authoritative'
    },
    'close' => {
      'duration' => 15.0,
      'state' => 'aspiration (identity)',
      'audio_profile' => 'landing'
    }
  }.merge(overrides)

  path = File.join(dir, "#{name}_report.yaml")
  File.write(path, report.to_yaml)
  path
end

def run_creator_extract(args)
  stdout, stderr, status = Open3.capture3('ruby', CREATOR_PROFILE_SCRIPT, *args)
  profile = nil
  if status.success? && !stdout.strip.empty? && File.exist?(stdout.strip)
    profile = YAML.safe_load(File.read(stdout.strip), permitted_classes: [Date])
  end
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, profile: profile }
end

RSpec.describe 'extract_creator_profile.rb' do
  describe 'CLI' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', CREATOR_PROFILE_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when fewer than 2 reports' do
      Dir.mktmpdir do |dir|
        path = make_report(dir, 'vid1')
        _, stderr, status = Open3.capture3('ruby', CREATOR_PROFILE_SCRIPT, path, '--name', 'test', '--output-dir', dir)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('at least 2')
      end
    end
  end

  describe 'profile extraction' do
    it 'produces valid creator profile from 2 reports' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1')
        r2 = make_report(dir, 'vid2', {
          'duration' => 800.0,
          'pacing' => {
            'avg_segment_duration' => 12.0,
            'median_segment_duration' => 11.5,
            'segments_over_12s' => 5,
            'total_segments' => 40
          }
        })

        result = run_creator_extract([r1, r2, '--name', 'testcreator', '--output-dir', dir])
        expect(result[:exit_code]).to eq(0)

        profile = result[:profile]
        expect(profile['name']).to eq('testcreator')
        expect(profile['videos_analyzed']).to eq(2)
        expect(profile['editing_signature']).to be_a(Hash)
        expect(profile['emotional_signature']).to be_a(Hash)
        expect(profile['pacing_signature']).to be_a(Hash)
        expect(profile['audio_signature']).to be_a(Hash)
        expect(profile['template_affinities']).to be_an(Array)
        expect(profile['hook_patterns']).to be_a(Hash)
        expect(profile['close_patterns']).to be_a(Hash)
      end
    end

    it 'computes correct mean for pacing' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1')
        r2 = make_report(dir, 'vid2', {
          'pacing' => {
            'avg_segment_duration' => 14.0,
            'median_segment_duration' => 13.0,
            'segments_over_12s' => 6,
            'total_segments' => 40
          }
        })

        result = run_creator_extract([r1, r2, '--name', 'test', '--output-dir', dir])
        expect(result[:profile]['pacing_signature']['avg_segment_duration']).to eq(12.0)
      end
    end

    it 'identifies dominant emotional spine' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1')
        r2 = make_report(dir, 'vid2', {
          'emotional_architecture' => {
            'primary_states' => %w[competence curiosity],
            'spine' => 'competence',
            'durability_arc' => 'identity(2) → spike(1)',
            'state_transitions' => 3,
            'transitions_per_minute' => 0.6
          }
        })

        result = run_creator_extract([r1, r2, '--name', 'test', '--output-dir', dir])
        expect(result[:profile]['emotional_signature']['spine']).to eq('competence')
        expect(result[:profile]['emotional_signature']['dominant_states']).to include('competence')
      end
    end

    it 'computes template affinities as proportions' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1')
        r2 = make_report(dir, 'vid2')
        r3 = make_report(dir, 'vid3', {
          'structure' => {
            'template_match' => 'contrarian_argument',
            'template_fit' => 80,
            'beats' => %w[claim evidence],
            'beat_count' => 2
          }
        })

        result = run_creator_extract([r1, r2, r3, '--name', 'test', '--output-dir', dir])
        affinities = result[:profile]['template_affinities']
        expect(affinities).to be_an(Array)
        ps = affinities.find { |a| a.key?('problem_solution') }
        expect(ps['problem_solution']).to be >= 0.6
      end
    end

    it 'computes hook and close patterns' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1')
        r2 = make_report(dir, 'vid2', {
          'hook' => { 'duration' => 10.5, 'state' => 'curiosity (spike)', 'audio_profile' => 'urgent' },
          'close' => { 'duration' => 18.0, 'state' => 'vindication (identity)', 'audio_profile' => 'landing' }
        })

        result = run_creator_extract([r1, r2, '--name', 'test', '--output-dir', dir])
        expect(result[:profile]['hook_patterns']['avg_duration']).to eq(9.5)
        expect(result[:profile]['close_patterns']['avg_duration']).to eq(16.5)
        expect(result[:profile]['close_patterns']['typical_audio']).to eq('landing')
      end
    end

    it 'includes visual scene data when present' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1')
        r2 = make_report(dir, 'vid2', {
          'visual_language' => {
            'scene_changes' => 20,
            'cuts_per_minute' => 2.5,
            'avg_shot_duration' => 24.0,
            'talking_head_ratio' => 0.75
          }
        })

        result = run_creator_extract([r1, r2, '--name', 'test', '--output-dir', dir])
        expect(result[:profile]['editing_signature']['avg_scene_changes']).to eq(15)
        expect(result[:profile]['editing_signature']['talking_head_ratio']).to eq(0.8)
      end
    end

    it 'marks pacing as fast when avg < 9s' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1', {
          'pacing' => { 'avg_segment_duration' => 7.0, 'median_segment_duration' => 6.5, 'segments_over_12s' => 0, 'total_segments' => 50 }
        })
        r2 = make_report(dir, 'vid2', {
          'pacing' => { 'avg_segment_duration' => 8.0, 'median_segment_duration' => 7.5, 'segments_over_12s' => 1, 'total_segments' => 45 }
        })

        result = run_creator_extract([r1, r2, '--name', 'test', '--output-dir', dir])
        expect(result[:profile]['pacing_signature']['fast']).to be true
      end
    end
  end

  describe 'edge cases' do
    it 'handles reports with missing sections gracefully' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1')
        r2_path = File.join(dir, 'vid2_report.yaml')
        File.write(r2_path, {
          'video' => 'vid2.mp4',
          'creator' => 'test',
          'duration' => 500.0,
          'structure' => {},
          'emotional_architecture' => {},
          'pacing' => {},
          'audio_delivery' => {},
          'visual_language' => {},
          'hook' => {},
          'close' => {}
        }.to_yaml)

        result = run_creator_extract([r1, r2_path, '--name', 'test', '--output-dir', dir])
        expect(result[:exit_code]).to eq(0)
      end
    end

    it 'skips malformed report files with warning' do
      Dir.mktmpdir do |dir|
        r1 = make_report(dir, 'vid1')
        r2 = make_report(dir, 'vid2')
        bad = File.join(dir, 'bad_report.yaml')
        File.write(bad, "{{{{not yaml")

        result = run_creator_extract([r1, r2, bad, '--name', 'test', '--output-dir', dir])
        expect(result[:exit_code]).to eq(0)
        expect(result[:stderr]).to include('skipping')
      end
    end
  end
end
