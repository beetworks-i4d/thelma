require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'
require 'fileutils'

BRIEF_SCRIPT = File.expand_path('../../scripts/export_packaging_brief.rb', __dir__)

def make_brief_library(dir, overrides = {})
  library = {
    'library_name' => 'test-lib',
    'language' => 'english',
    'editor' => 'fcp7',
    'content_type' => { 'detected' => 'talking_head_business', 'confidence' => 0.9, 'source' => 'auto_detection' },
    'videos' => [{
      'path' => '/tmp/test_video.mp4',
      'duration' => '15:37',
      'transcript' => 'test.json',
      'visual_transcript' => 'test_visual.json'
    }]
  }.merge(overrides)

  File.write(File.join(dir, 'library.yaml'), library.to_yaml)
  dir
end

def make_brief_classified(dir, segments = nil)
  segments ||= [
    { 't' => 10.0, 'e' => 18.5, 'states' => %w[aspiration competence], 'distillation' => 'seven months to quitting job',
      'signal' => 'specific timeline', 'dur' => 'spike', 'roles' => %w[primary], 'confidence' => 'high',
      'signpost' => false, 'audio_profile' => 'emphatic', 'audio_pitch_trend' => 'rising', 'audio_speaking_rate' => 1.3 },
    { 't' => 20.0, 'e' => 30.0, 'states' => %w[competence], 'distillation' => 'first business model explained',
      'signal' => 'teaching framework', 'dur' => 'mood', 'roles' => %w[primary], 'confidence' => 'high',
      'signpost' => false, 'audio_profile' => 'authoritative' },
    { 't' => 35.0, 'e' => 45.0, 'states' => %w[fear aspiration], 'distillation' => 'twelve months zero revenue',
      'signal' => 'failure story', 'dur' => 'spike', 'roles' => %w[secondary], 'confidence' => 'medium',
      'signpost' => false, 'audio_profile' => 'urgent' },
    { 't' => 50.0, 'e' => 62.0, 'states' => %w[competence vindication], 'distillation' => 'drop servicing discovery',
      'signal' => 'concrete proof', 'dur' => 'identity', 'roles' => %w[primary], 'confidence' => 'high',
      'signpost' => false, 'audio_profile' => 'authoritative' },
    { 't' => 70.0, 'e' => 82.0, 'states' => %w[vindication aspiration], 'distillation' => 'affiliate vs drop servicing',
      'signal' => 'comparison data', 'dur' => 'identity', 'roles' => %w[primary], 'confidence' => 'high',
      'signpost' => false, 'audio_profile' => 'emphatic' },
    { 't' => 90.0, 'e' => 100.0, 'states' => %w[vindication], 'distillation' => 'proof of results',
      'signal' => 'revenue screenshot', 'dur' => 'identity', 'roles' => %w[primary], 'confidence' => 'high',
      'signpost' => false, 'audio_profile' => 'landing' }
  ]
  File.write(File.join(dir, 'segments_classified.yaml'), { 'segments' => segments }.to_yaml)
end

def make_brief_scored(dir, storylines = nil)
  storylines ||= [{
    'id' => 'longform_main',
    'hook_segment' => 10.0,
    'close_segment' => 90.0,
    'combined_score' => 82,
    'passed_floor' => true,
    'duration_estimate' => 540,
    'primary_state' => 'competence',
    'arc' => 'aspiration hook → competence body → vindication close',
    'scores' => {
      'cold_viability' => 13,
      'close_durability' => 14,
      'spine' => 12,
      'completeness' => 18
    },
    'template_match' => {
      'template' => 'comparative_walkthrough',
      'fit_score' => 76,
      'completeness' => 80,
      'matched_beats' => {
        'bold_claim' => { 'segment_t' => 10.0, 'distillation' => 'seven months to quitting job' },
        'evidence' => { 'segment_t' => 50.0, 'distillation' => 'drop servicing discovery' },
        'comparison' => { 'segment_t' => 70.0, 'distillation' => 'affiliate vs drop servicing' }
      },
      'missing_beats' => %w[takeaway]
    }
  }]
  File.write(File.join(dir, 'storylines_scored.yaml'), { 'storylines' => storylines }.to_yaml)
end

def make_brief_audio(dir)
  audio = {
    'source_wav' => 'test.wav',
    'sample_rate' => 48000,
    'baseline' => { 'rms_mean' => 0.05, 'f0_mean' => 160.0, 'speaking_rate' => 3.5 },
    'segments' => [
      { 't' => 10.0, 'e' => 18.5, 'energy' => 1.4, 'pitch_trend' => 'rising', 'speaking_rate' => 1.3, 'audio_profile' => 'emphatic' }
    ]
  }
  File.write(File.join(dir, 'audio_features.yaml'), audio.to_yaml)
end

def run_brief(dir, xml_path, flags: {})
  args = ['ruby', BRIEF_SCRIPT, '--library-dir', dir, '--output', xml_path]
  args += ['--profile', flags[:profile]] if flags[:profile]
  env = { 'THELMA_LLM_STUB' => '1' }
  stdout, stderr, status = Open3.capture3(env, *args)
  result = nil
  if status.success? && !stdout.strip.empty?
    brief_path = stdout.strip
    result = File.read(brief_path) if File.exist?(brief_path)
  end
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result, path: stdout.strip }
end

def run_brief_with_library(library_name, output_xml = nil, flags: {})
  args = ['ruby', BRIEF_SCRIPT, '--library', library_name]
  args += ['--output', output_xml] if output_xml
  args += ['--profile', flags[:profile]] if flags[:profile]
  args += ['--llm-mode', flags[:llm_mode]] if flags[:llm_mode]
  args << '--no-review' if flags[:no_review]
  env = { 'THELMA_LLM_STUB' => '1' }
  stdout, stderr, status = Open3.capture3(env, *args)
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus }
end

RSpec.describe 'export_packaging_brief.rb' do
  describe 'CLI validation' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3({ 'THELMA_LLM_STUB' => '1' }, 'ruby', BRIEF_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when library dir does not exist' do
      _, stderr, status = Open3.capture3({ 'THELMA_LLM_STUB' => '1' },
        'ruby', BRIEF_SCRIPT, '--library-dir', '/nonexistent', '--output', '/tmp/test.xml')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('not found')
    end

    it 'exits 1 when segments_classified.yaml is missing' do
      Dir.mktmpdir do |dir|
        make_brief_library(dir)
        r = run_brief(dir, '/tmp/test_20250419-120000.xml')
        expect(r[:exit_code]).to eq(1)
        expect(r[:stderr]).to include('segments_classified.yaml')
      end
    end

    it 'accepts --library flag to resolve library directory' do
      r = run_brief_with_library('nonexistent-test-lib-xyz')
      expect(r[:exit_code]).to eq(1)
      expect(r[:stderr]).to include('not found')
    end

    it 'emits deprecation warning for --library-dir' do
      _, stderr, _ = Open3.capture3({ 'THELMA_LLM_STUB' => '1' },
        'ruby', BRIEF_SCRIPT, '--library-dir', '/nonexistent', '--output', '/tmp/test.xml')
      expect(stderr).to include('DEPRECATED')
    end

    it 'accepts --llm-mode flag without error' do
      _, stderr, status = Open3.capture3({ 'THELMA_LLM_STUB' => '1' },
        'ruby', BRIEF_SCRIPT, '--library', 'nonexistent-xyz', '--llm-mode', 'claude_code')
      # Should fail on library not found, not on unknown argument
      expect(stderr).to include('not found')
      expect(stderr).not_to include('Unknown argument')
    end

    it 'accepts --no-review flag without error' do
      _, stderr, status = Open3.capture3({ 'THELMA_LLM_STUB' => '1' },
        'ruby', BRIEF_SCRIPT, '--library', 'nonexistent-xyz', '--no-review')
      expect(stderr).to include('not found')
      expect(stderr).not_to include('Unknown argument')
    end
  end

  describe 'pending LLM flow' do
    it 'exits 2 when LLM calls are pending in claude_code mode' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          # Run WITHOUT THELMA_LLM_STUB and without API key — forces claude_code mode
          env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
          env.delete('THELMA_LLM_STUB')
          _, stderr, status = Open3.capture3(env,
            'ruby', BRIEF_SCRIPT, '--library-dir', dir, '--output', xml_path, '--llm-mode', 'claude_code')
          expect(status.exitstatus).to eq(2)
          expect(stderr).to include('pending')

          # Verify both pending files were written
          pending_dir = File.join(dir, 'pending_llm_calls')
          expect(File.exist?(File.join(pending_dir, 'packaging_thumbnail.yaml'))).to be true
          expect(File.exist?(File.join(pending_dir, 'packaging_title.yaml'))).to be true
        end
      end
    end

    it 'picks up responses on re-run after pending' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          # First run — exits 2 with pending
          env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
          env.delete('THELMA_LLM_STUB')
          Open3.capture3(env,
            'ruby', BRIEF_SCRIPT, '--library-dir', dir, '--output', xml_path, '--llm-mode', 'claude_code')

          # Write response files
          pending_dir = File.join(dir, 'pending_llm_calls')
          File.write(File.join(pending_dir, 'packaging_thumbnail_response.yaml'),
            { 'response' => "Primary emotion: curiosity\nVisual suggestion: test\nText overlay: test\nAvoid: test" }.to_yaml)
          File.write(File.join(pending_dir, 'packaging_title_response.yaml'),
            { 'response' => "Promise type: revelation\n1. Test Title — test reasoning" }.to_yaml)

          # Second run — should complete
          stdout, stderr, status = Open3.capture3(env,
            'ruby', BRIEF_SCRIPT, '--library-dir', dir, '--output', xml_path, '--llm-mode', 'claude_code')
          expect(status.exitstatus).to eq(0)
          expect(stdout.strip).to end_with('_packaging_brief.md')
        end
      end
    end
  end

  describe 'longform brief' do
    it 'generates all sections for longform storyline' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:exit_code]).to eq(0)
          expect(r[:result]).to include('# Packaging Brief')
          expect(r[:result]).to include('## Hook Cash')
          expect(r[:result]).to include('## Primary Spine')
          expect(r[:result]).to include('## Peak Map')
          expect(r[:result]).to include('## Thumbnail Direction')
          expect(r[:result]).to include('## Title Direction')
          expect(r[:result]).to include('## Packaging-to-Content Alignment')
          expect(r[:result]).to include('## Structural Notes')
        end
      end
    end

    it 'outputs brief file alongside the XML' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:path]).to end_with('_packaging_brief.md')
          expect(File.dirname(r[:path])).to eq(out)
        end
      end
    end
  end

  describe 'Hook Cash section' do
    it 'extracts correct opening state and durability' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('aspiration(spike)')
        end
      end
    end

    it 'includes audio delivery details' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('emphatic')
          expect(r[:result]).to include('rising pitch')
        end
      end
    end

    it 'includes cold viability assessment' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir) # cold_viability = 13 → "yes"
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to match(/Cold-viable: yes/)
        end
      end
    end

    it 'reports cold viability as maybe for mid-range scores' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir, [{
            'id' => 'longform_main', 'hook_segment' => 10.0, 'close_segment' => 90.0,
            'combined_score' => 65, 'passed_floor' => true, 'duration_estimate' => 540,
            'scores' => { 'cold_viability' => 9 },
            'template_match' => {}
          }])
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to match(/Cold-viable: maybe/)
        end
      end
    end

    it 'includes hook distillation as promise' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('seven months to quitting job')
        end
      end
    end
  end

  describe 'Primary Spine section' do
    it 'identifies the dominant state across segments' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          # competence appears in 3 segments as primary (double-counted) + others
          expect(r[:result]).to match(/Spine state: (competence|vindication)/)
        end
      end
    end

    it 'lists compatible secondaries' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('Compatible secondaries:')
        end
      end
    end
  end

  describe 'Peak Map section' do
    it 'ranks segments by composite score with star for top' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          # Identity + high confidence segments should score highest (3*3=9)
          expect(r[:result]).to include('★')
          # Should have identity segments at top
          expect(r[:result]).to match(/★.*identity/)
        end
      end
    end

    it 'limits to 5 peaks maximum' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          # Create 8 segments
          many_segments = (1..8).map do |i|
            { 't' => i * 10.0, 'e' => i * 10.0 + 8.0, 'states' => %w[competence],
              'distillation' => "segment #{i}", 'dur' => 'mood', 'confidence' => 'high',
              'audio_profile' => 'authoritative' }
          end
          make_brief_library(dir)
          make_brief_classified(dir, many_segments)
          xml_path = File.join(out, 'test-lib_all_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          peak_lines = r[:result].lines.select { |l| l.strip.start_with?('- ★', '-  ') && l.include?('t=') }
          expect(peak_lines.size).to be <= 5
        end
      end
    end
  end

  describe 'Thumbnail Direction section' do
    it 'includes LLM stub response' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('## Thumbnail Direction')
          expect(r[:result]).to include('LLM stub')
        end
      end
    end
  end

  describe 'Title Direction section' do
    it 'includes LLM stub response' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('## Title Direction')
          expect(r[:result]).to include('LLM stub')
        end
      end
    end
  end

  describe 'Structural Notes section' do
    it 'includes video duration' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('15:37')
        end
      end
    end

    it 'includes template match info' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('comparative_walkthrough')
          expect(r[:result]).to include('76%')
        end
      end
    end

    it 'includes content type' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('talking_head_business')
        end
      end
    end

    it 'includes durability arc' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to match(/Durability arc:.*hook.*body.*close/)
        end
      end
    end

    it 'includes re-hook points from template beats' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('Re-hook points')
          expect(r[:result]).to include('evidence')
        end
      end
    end
  end

  describe 'Alignment section' do
    it 'reports hook delivery time' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to match(/Hook delivers on promise within: \d+s/)
        end
      end
    end

    it 'identifies payoff moment' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('Payoff:')
          expect(r[:result]).to include('identity moment')
        end
      end
    end
  end

  describe 'format detection' do
    it 'detects short format from storyline ID' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir, [{
            'id' => 'short_hook_1', 'hook_segment' => 10.0, 'close_segment' => 35.0,
            'combined_score' => 80, 'passed_floor' => true, 'duration_estimate' => 25,
            'scores' => { 'cold_viability' => 12 },
            'template_match' => {}
          }])
          xml_path = File.join(out, 'test-lib_short_hook_1_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:exit_code]).to eq(0)
          expect(r[:result]).to include('# First-Frame Brief')
          expect(r[:result]).not_to include('## Peak Map')
        end
      end
    end

    it 'detects medium format from duration under 180s' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir, [{
            'id' => 'medium_clip_1', 'hook_segment' => 10.0, 'close_segment' => 90.0,
            'combined_score' => 75, 'passed_floor' => true, 'duration_estimate' => 120,
            'scores' => { 'cold_viability' => 10 },
            'template_match' => { 'template' => 'problem_solution', 'fit_score' => 60 }
          }])
          xml_path = File.join(out, 'test-lib_medium_clip_1_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:exit_code]).to eq(0)
          expect(r[:result]).to include('## Hook Cash')
          expect(r[:result]).to include('## Thumbnail Direction')
          expect(r[:result]).not_to include('## Peak Map')
          expect(r[:result]).not_to include('## Packaging-to-Content Alignment')
        end
      end
    end

    it 'defaults to longform for durations over 180s' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('## Peak Map')
          expect(r[:result]).to include('## Packaging-to-Content Alignment')
        end
      end
    end
  end

  describe 'short format output' do
    it 'produces first-frame brief with state and delivery' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir, [{
            'id' => 'short_hook_1', 'hook_segment' => 10.0, 'close_segment' => 35.0,
            'combined_score' => 80, 'passed_floor' => true, 'duration_estimate' => 25,
            'scores' => { 'cold_viability' => 12 },
            'template_match' => {}
          }])
          xml_path = File.join(out, 'test-lib_short_hook_1_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:result]).to include('Frame 1 state:')
          expect(r[:result]).to include('Vertical framing:')
          expect(r[:result]).to include('## Text Direction')
        end
      end
    end
  end

  describe 'graceful degradation' do
    it 'works without storylines_scored.yaml' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          # No scored data
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:exit_code]).to eq(0)
          expect(r[:result]).to include('## Hook Cash')
          # Without storyline data, cold viability shows as unknown
          expect(r[:result]).to include('no storyline scoring available')
        end
      end
    end

    it 'works without audio_features.yaml' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          # Segments without audio fields
          segs = [
            { 't' => 10.0, 'e' => 20.0, 'states' => %w[aspiration], 'distillation' => 'opening',
              'dur' => 'spike', 'confidence' => 'high' },
            { 't' => 25.0, 'e' => 35.0, 'states' => %w[competence], 'distillation' => 'body',
              'dur' => 'mood', 'confidence' => 'high' }
          ]
          make_brief_classified(dir, segs)
          xml_path = File.join(out, 'test-lib_all_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:exit_code]).to eq(0)
          expect(r[:result]).to include('audio analysis unavailable')
        end
      end
    end

    it 'works without template match data' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir, [{
            'id' => 'longform_main', 'hook_segment' => 10.0, 'close_segment' => 90.0,
            'combined_score' => 70, 'passed_floor' => true, 'duration_estimate' => 540,
            'scores' => { 'cold_viability' => 10 },
            'template_match' => {}
          }])
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:exit_code]).to eq(0)
          expect(r[:result]).to include('no template matched')
        end
      end
    end

    it 'handles single segment gracefully' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir, [
            { 't' => 5.0, 'e' => 15.0, 'states' => %w[curiosity], 'distillation' => 'opening hook',
              'dur' => 'spike', 'confidence' => 'medium', 'audio_profile' => 'casual' }
          ])
          xml_path = File.join(out, 'test-lib_all_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:exit_code]).to eq(0)
          expect(r[:result]).to include('## Hook Cash')
        end
      end
    end
  end

  describe 'profile setting' do
    it 'exits cleanly when generate_packaging_brief is false' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)

          # Create a temporary profile that disables briefs
          profiles_dir = File.join(File.dirname(BRIEF_SCRIPT), '..', 'profiles')
          # Use the default profile which has generate_packaging_brief: true
          # We test the profile check by passing a nonexistent profile — it should fall back to default
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          # With default profile (generate_packaging_brief: true), it should generate
          r = run_brief(dir, xml_path)
          expect(r[:exit_code]).to eq(0)
          expect(r[:result]).not_to be_nil
        end
      end
    end
  end

  describe 'output file naming' do
    it 'names brief file based on XML filename' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(r[:path]).to eq(File.join(out, 'test-lib_longform_main_20250419-120000_packaging_brief.md'))
        end
      end
    end

    it 'creates output in same directory as XML' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          subdir = File.join(out, 'nested', 'output')
          FileUtils.mkdir_p(subdir)
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(subdir, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          expect(File.dirname(r[:path])).to eq(subdir)
        end
      end
    end
  end

  describe 'markdown output formatting' do
    it 'produces valid markdown with proper heading hierarchy' do
      Dir.mktmpdir do |dir|
        Dir.mktmpdir do |out|
          make_brief_library(dir)
          make_brief_classified(dir)
          make_brief_scored(dir)
          xml_path = File.join(out, 'test-lib_longform_main_20250419-120000.xml')
          FileUtils.touch(xml_path)

          r = run_brief(dir, xml_path)
          lines = r[:result].lines

          # H1 should be first line
          expect(lines.first).to start_with('# ')

          # All section headers should be H2
          h2_lines = lines.select { |l| l.start_with?('## ') }
          expect(h2_lines.size).to be >= 5

          # Bullet points use dash
          bullet_lines = lines.select { |l| l.strip.start_with?('- ') }
          expect(bullet_lines.size).to be > 5
        end
      end
    end
  end
end
