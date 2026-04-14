require 'open3'
require 'yaml'
require 'tmpdir'

DEDUP_SCRIPT = File.expand_path('../../scripts/semantic_dedup.rb', __dir__)

def make_segment(t:, e:, states:, distillation:, dur: 'mood', roles: ['secondary'], confidence: 'high')
  { 't' => t, 'e' => e, 'states' => states, 'distillation' => distillation,
    'dur' => dur, 'roles' => roles, 'confidence' => confidence,
    'signal' => 'test', 'notes' => 'test', 'rationale' => 'test' }
end

def run_dedup(classified_yaml)
  Dir.mktmpdir do |dir|
    input_path = File.join(dir, 'segments_classified.yaml')
    File.write(input_path, classified_yaml.to_yaml)

    stdout, stderr, status = Open3.capture3('ruby', DEDUP_SCRIPT, input_path)

    output_path = File.join(dir, 'segments_deduped.yaml')
    log_path = File.join(dir, 'semantic_dedup_log.yaml')

    deduped = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
    log = File.exist?(log_path) ? YAML.safe_load(File.read(log_path)) : nil

    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus,
      deduped: deduped, log: log }
  end
end

def base_classified
  {
    'transcript_hash' => 'abc123',
    'segments' => [
      make_segment(t: 10.0, e: 20.0, states: %w[curiosity aspiration], distillation: 'guy earned money fast'),
      make_segment(t: 25.0, e: 35.0, states: %w[awe competence], distillation: 'built something completely different')
    ]
  }
end

RSpec.describe 'semantic_dedup.rb' do
  describe 'retake detection' do
    it 'drops first segment on exact-match retake (short pause, same states)' do
      data = {
        'transcript_hash' => 'test1',
        'segments' => [
          make_segment(t: 10.0, e: 15.0, states: %w[curiosity aspiration], distillation: 'guy earned money fast'),
          make_segment(t: 15.2, e: 20.0, states: %w[curiosity aspiration], distillation: 'guy earned money fast')
        ]
      }
      result = run_dedup(data)
      expect(result[:exit_code]).to eq(0)
      expect(result[:deduped]['segments'].size).to eq(1)
      expect(result[:deduped]['segments'][0]['t']).to eq(15.2)
      expect(result[:log]['summary']['dropped_count']).to eq(1)
      expect(result[:log]['entries'].first['action']).to eq('dropped_retake')
    end
  end

  describe 'rhetorical emphasis' do
    it 'keeps both segments on high overlap with long pause' do
      data = {
        'transcript_hash' => 'test2',
        'segments' => [
          make_segment(t: 10.0, e: 15.0, states: %w[curiosity], distillation: 'guy earned money fast'),
          make_segment(t: 16.0, e: 21.0, states: %w[curiosity], distillation: 'guy earned money fast')
        ]
      }
      result = run_dedup(data)
      expect(result[:exit_code]).to eq(0)
      expect(result[:deduped]['segments'].size).to eq(2)
      expect(result[:log]['entries'].first['action']).to eq('kept_rhetorical_emphasis')
    end
  end

  describe 'different content' do
    it 'keeps both segments with different distillations and logs nothing' do
      result = run_dedup(base_classified)
      expect(result[:exit_code]).to eq(0)
      expect(result[:deduped]['segments'].size).to eq(2)
      expect(result[:deduped]['dedup_meta']['dropped_count']).to eq(0)
      expect(result[:log]['entries']).to be_empty
    end
  end

  describe 'ambiguous overlap' do
    it 'keeps both and flags review_recommended for 60-80% overlap' do
      data = {
        'transcript_hash' => 'test4',
        'segments' => [
          make_segment(t: 10.0, e: 15.0, states: %w[curiosity], distillation: 'earned money building apps'),
          make_segment(t: 15.2, e: 20.0, states: %w[curiosity], distillation: 'earned money selling apps')
        ]
      }
      result = run_dedup(data)
      expect(result[:exit_code]).to eq(0)
      expect(result[:deduped]['segments'].size).to eq(2)
      entry = result[:log]['entries'].first
      expect(entry['action']).to eq('review_recommended')
      expect(entry['review_recommended']).to eq(true)
    end
  end

  describe 'different states' do
    it 'keeps both on high overlap + short pause + different states' do
      data = {
        'transcript_hash' => 'test5',
        'segments' => [
          make_segment(t: 10.0, e: 15.0, states: %w[curiosity aspiration], distillation: 'guy earned money fast'),
          make_segment(t: 15.2, e: 20.0, states: %w[awe competence], distillation: 'guy earned money fast')
        ]
      }
      result = run_dedup(data)
      expect(result[:exit_code]).to eq(0)
      expect(result[:deduped]['segments'].size).to eq(2)
      expect(result[:log]['entries'].first['action']).to eq('kept_different_states')
    end
  end

  describe 'log structure' do
    it 'has correct YAML structure with all required keys' do
      data = {
        'transcript_hash' => 'test6',
        'segments' => [
          make_segment(t: 10.0, e: 15.0, states: %w[curiosity], distillation: 'guy earned money fast'),
          make_segment(t: 15.2, e: 20.0, states: %w[curiosity], distillation: 'guy earned money fast')
        ]
      }
      result = run_dedup(data)
      expect(result[:exit_code]).to eq(0)
      log = result[:log]
      expect(log).to have_key('transcript_hash')
      expect(log).to have_key('summary')
      expect(log).to have_key('entries')
      expect(log['summary']).to have_key('original_count')
      expect(log['summary']).to have_key('kept_count')
      expect(log['summary']).to have_key('dropped_count')
      expect(log['summary']).to have_key('review_recommended_count')
    end
  end

  describe 'Branch A input' do
    it 'exits 1 with Branch A message' do
      data = { 'segments_used' => [{ 't' => 10.0, 'e' => 15.0, 'beat' => 'hook' }] }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'segments_classified.yaml')
        File.write(path, data.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', DEDUP_SCRIPT, path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('Branch A')
      end
    end
  end

  describe 'missing distillations' do
    it 'exits 1 with no distillation message' do
      data = {
        'transcript_hash' => 'test8',
        'segments' => [
          { 't' => 10.0, 'e' => 15.0, 'states' => %w[curiosity], 'dur' => 'mood' },
          { 't' => 20.0, 'e' => 25.0, 'states' => %w[awe], 'dur' => 'mood' }
        ]
      }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'segments_classified.yaml')
        File.write(path, data.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', DEDUP_SCRIPT, path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('distillation')
      end
    end
  end

  describe 'clean diverse input' do
    it 'passes through unchanged with 0 drops' do
      data = {
        'transcript_hash' => 'test9',
        'segments' => [
          make_segment(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'starting new business venture'),
          make_segment(t: 25.0, e: 35.0, states: %w[aspiration], distillation: 'results exceeded expectations dramatically'),
          make_segment(t: 40.0, e: 50.0, states: %w[awe], distillation: 'community grew organically fast'),
          make_segment(t: 55.0, e: 65.0, states: %w[competence], distillation: 'technical skills developed quickly')
        ]
      }
      result = run_dedup(data)
      expect(result[:exit_code]).to eq(0)
      expect(result[:deduped]['segments'].size).to eq(4)
      expect(result[:deduped]['dedup_meta']['dropped_count']).to eq(0)
    end
  end

  describe 'field preservation' do
    it 'preserves all segment fields on kept segments' do
      data = {
        'transcript_hash' => 'test10',
        'segments' => [
          make_segment(t: 10.0, e: 20.0, states: %w[curiosity aspiration], distillation: 'guy earned money fast')
            .merge('id' => 1, 'text' => 'Some transcript text', 'narrative_role' => 'claim'),
          make_segment(t: 30.0, e: 40.0, states: %w[awe], distillation: 'something completely different')
            .merge('id' => 2, 'text' => 'Other text', 'narrative_role' => 'evidence')
        ]
      }
      result = run_dedup(data)
      expect(result[:exit_code]).to eq(0)
      segs = result[:deduped]['segments']
      expect(segs.size).to eq(2)
      expect(segs[0]['id']).to eq(1)
      expect(segs[0]['text']).to eq('Some transcript text')
      expect(segs[0]['narrative_role']).to eq('claim')
      expect(segs[1]['id']).to eq(2)
      expect(segs[1]['narrative_role']).to eq('evidence')
    end
  end
end
