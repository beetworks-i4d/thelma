require 'open3'
require 'json'
require 'yaml'
require 'tmpdir'

COHERENCE_SCRIPT = File.expand_path('../../scripts/score_coherence.rb', __dir__)

def run_scorer(matched_yaml, classified_yaml, no_llm: false)
  Dir.mktmpdir do |dir|
    matched_path = File.join(dir, 'storylines_matched.yaml')
    classified_path = File.join(dir, 'segments_classified.yaml')
    File.write(matched_path, matched_yaml.to_yaml)
    File.write(classified_path, classified_yaml.to_yaml)
    args = ['ruby', COHERENCE_SCRIPT]
    args << '--no-llm' if no_llm
    args += [matched_path, classified_path]
    stdout, stderr, status = Open3.capture3(*args)
    output_path = File.join(dir, 'storylines_scored.yaml')
    scored = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, scored: scored }
  end
end

def make_segment(t:, e:, states:, distillation:, dur: 'mood', roles: ['secondary'], confidence: 'high')
  { 't' => t, 'e' => e, 'states' => states, 'distillation' => distillation,
    'dur' => dur, 'roles' => roles, 'confidence' => confidence,
    'signal' => 'test', 'notes' => 'test', 'rationale' => 'test' }
end

def base_classified
  {
    'transcript_hash' => 'test123',
    'segments' => [
      make_segment(t: 10.0, e: 20.0, states: %w[curiosity aspiration], distillation: 'hook opening', dur: 'spike', roles: %w[primary]),
      make_segment(t: 25.0, e: 35.0, states: %w[competence], distillation: 'body one'),
      make_segment(t: 40.0, e: 50.0, states: %w[vindication competence], distillation: 'body two'),
      make_segment(t: 55.0, e: 65.0, states: %w[aspiration], distillation: 'body three'),
      make_segment(t: 70.0, e: 80.0, states: %w[competence aspiration], distillation: 'close takeaway', dur: 'identity', roles: %w[tertiary])
    ]
  }
end

def base_matched
  {
    'generated_at' => '2026-01-01T00:00:00+00:00',
    'source' => 'test-lib',
    'transcript_hash' => 'test123',
    'storylines' => [
      {
        'id' => 'test_storyline_1',
        'profile' => 'best_short',
        'score' => 80,
        'primary_state' => 'curiosity',
        'hook_segment' => 10.0,
        'hook_signal' => 'test hook',
        'close_segment' => 70.0,
        'close_signal' => 'test close',
        'duration_estimate' => 60,
        'segment_count' => 5,
        'arc' => 'test arc',
        'pitch' => 'test pitch',
        'template_match' => {
          'template' => 'problem_solution',
          'fit_score' => 75,
          'completeness' => 100,
          'order_score' => 60,
          'missing_beats' => []
        }
      }
    ]
  }
end

RSpec.describe 'score_coherence.rb' do
  describe 'scoring math' do
    it 'computes combined_score as state*0.3 + template*0.4 + coherence*0.3' do
      result = run_scorer(base_matched, base_classified)
      expect(result[:exit_code]).to eq(0)

      s = result[:scored]['storylines'].first
      expected = (s['state_score'] * 0.3 + s['template_fit'] * 0.4 + s['coherence_score'] * 0.3).round
      expect(s['combined_score']).to eq(expected)
    end

    it 'preserves state_score from storyline score field' do
      result = run_scorer(base_matched, base_classified)
      expect(result[:scored]['storylines'].first['state_score']).to eq(80)
    end

    it 'preserves template_fit from template_match.fit_score' do
      result = run_scorer(base_matched, base_classified)
      expect(result[:scored]['storylines'].first['template_fit']).to eq(75)
    end
  end

  describe 'quality floor' do
    it 'passes candidates with combined >= 60' do
      result = run_scorer(base_matched, base_classified)
      s = result[:scored]['storylines'].first
      expect(s['combined_score']).to be >= 60
      expect(s['passed_floor']).to be true
    end

    it 'fails candidates below floor' do
      matched = base_matched
      matched['storylines'][0]['score'] = 10
      matched['storylines'][0]['template_match']['fit_score'] = 10
      # coherence will be decent but state+template drag combined below 60
      result = run_scorer(matched, base_classified)
      s = result[:scored]['storylines'].first
      expect(s['combined_score']).to be < 60
      expect(s['passed_floor']).to be false
    end
  end

  describe 'schema completeness' do
    it 'includes all required output fields' do
      result = run_scorer(base_matched, base_classified)
      s = result[:scored]['storylines'].first
      %w[id state_score template_fit algorithmic_coherence coherence_score combined_score passed_floor].each do |field|
        expect(s).to have_key(field), "missing field: #{field}"
      end
    end

    it 'includes top-level generated_at and source' do
      result = run_scorer(base_matched, base_classified)
      expect(result[:scored]).to have_key('generated_at')
      expect(result[:scored]).to have_key('source')
    end

    it 'preserves editorial fields for Phase 2' do
      result = run_scorer(base_matched, base_classified)
      s = result[:scored]['storylines'].first
      %w[primary_state hook_segment close_segment arc pitch template_match].each do |field|
        expect(s).to have_key(field), "missing editorial field: #{field}"
      end
    end
  end

  describe 'coherence scoring heuristics' do
    it 'penalizes missing close segment' do
      matched = base_matched
      matched['storylines'][0]['close_segment'] = nil
      result = run_scorer(matched, base_classified)
      s = result[:scored]['storylines'].first
      expect(s['coherence_score']).to be < 100
      expect(s['coherence_issues']).to include(a_string_matching(/No close segment/))
    end

    it 'penalizes incompatible adjacent transitions' do
      classified = base_classified
      # Insert sensual then calm adjacent (incompatible pair)
      classified['segments'][1] = make_segment(t: 25.0, e: 35.0, states: %w[sensual], distillation: 'body one')
      classified['segments'][2] = make_segment(t: 40.0, e: 50.0, states: %w[calm], distillation: 'body two')
      result = run_scorer(base_matched, classified)
      s = result[:scored]['storylines'].first
      expect(s['coherence_issues']).to include(a_string_matching(/incompatible/))
    end

    it 'penalizes redundant state clusters' do
      classified = base_classified
      # Make all body segments same primary state
      classified['segments'] = [
        make_segment(t: 10.0, e: 20.0, states: %w[competence], distillation: 'hook', roles: %w[primary]),
        make_segment(t: 25.0, e: 30.0, states: %w[competence], distillation: 'body a'),
        make_segment(t: 30.0, e: 35.0, states: %w[competence], distillation: 'body b'),
        make_segment(t: 35.0, e: 40.0, states: %w[competence], distillation: 'body c'),
        make_segment(t: 40.0, e: 45.0, states: %w[competence], distillation: 'body d'),
        make_segment(t: 45.0, e: 50.0, states: %w[competence], distillation: 'body e'),
        make_segment(t: 70.0, e: 80.0, states: %w[competence], distillation: 'close', roles: %w[tertiary])
      ]
      result = run_scorer(base_matched, classified)
      s = result[:scored]['storylines'].first
      expect(s['coherence_issues']).to include(a_string_matching(/cluster.*redundancy/))
    end

    it 'gives high coherence to clean diverse arc' do
      result = run_scorer(base_matched, base_classified)
      s = result[:scored]['storylines'].first
      # Clean arc: shared hook/close states, no incompatible pairs, diverse distillations
      expect(s['coherence_score']).to be >= 80
    end
  end

  describe 'ranking' do
    it 'ranks passing candidates within profile' do
      matched = base_matched
      matched['storylines'] << {
        'id' => 'test_storyline_2', 'profile' => 'best_short',
        'score' => 90, 'primary_state' => 'aspiration',
        'hook_segment' => 10.0, 'close_segment' => 70.0,
        'duration_estimate' => 60, 'segment_count' => 5,
        'arc' => 'test', 'pitch' => 'test',
        'template_match' => { 'fit_score' => 85, 'completeness' => 100, 'missing_beats' => [] }
      }
      result = run_scorer(matched, base_classified)
      ranked = result[:scored]['storylines'].select { |s| s['rank'] }
      expect(ranked.size).to eq(2)
      expect(ranked.sort_by { |s| s['rank'] }.first['combined_score']).to be >= ranked.last['combined_score']
    end
  end

  describe 'two-layer scoring schema' do
    it 'includes algorithmic_coherence and llm_coherence fields' do
      result = run_scorer(base_matched, base_classified)
      s = result[:scored]['storylines'].first
      expect(s).to have_key('algorithmic_coherence')
      expect(s).to have_key('llm_coherence')
      expect(s['algorithmic_coherence']).to be_a(Integer)
      expect(s['llm_coherence']).to be_nil
    end

    it 'sets coherence_score equal to algorithmic_coherence (placeholder)' do
      result = run_scorer(base_matched, base_classified)
      s = result[:scored]['storylines'].first
      expect(s['coherence_score']).to eq(s['algorithmic_coherence'])
    end

    it 'includes scoring_mode and llm_pass_pending in top-level output' do
      result = run_scorer(base_matched, base_classified)
      expect(result[:scored]['scoring_mode']).to eq('algorithmic_plus_llm')
      expect(result[:scored]['llm_pass_pending']).to be true
    end

    it 'generates llm_eval_prompt for eligible candidates (algorithmic >= 50)' do
      result = run_scorer(base_matched, base_classified)
      s = result[:scored]['storylines'].first
      expect(s['algorithmic_coherence']).to be >= 50
      expect(s).to have_key('llm_eval_prompt')
      expect(s['llm_eval_prompt']).to include('Score 0-100')
      expect(s['llm_eval_prompt']).to include('Distilled clip order')
    end

    it 'skips llm_eval_prompt for sub-threshold candidates' do
      matched = base_matched
      # Force a storyline with no matching segments → algorithmic = 0
      matched['storylines'][0]['hook_segment'] = 999.0
      matched['storylines'][0]['close_segment'] = 999.9
      result = run_scorer(matched, base_classified)
      s = result[:scored]['storylines'].first
      expect(s['algorithmic_coherence']).to be < 50
      expect(s).not_to have_key('llm_eval_prompt')
    end
  end

  describe '--no-llm mode' do
    it 'sets scoring_mode to algorithmic_only' do
      result = run_scorer(base_matched, base_classified, no_llm: true)
      expect(result[:scored]['scoring_mode']).to eq('algorithmic_only')
    end

    it 'sets llm_pass_pending to false' do
      result = run_scorer(base_matched, base_classified, no_llm: true)
      expect(result[:scored]['llm_pass_pending']).to be false
    end

    it 'omits llm_eval_prompt from all storylines' do
      result = run_scorer(base_matched, base_classified, no_llm: true)
      result[:scored]['storylines'].each do |s|
        expect(s).not_to have_key('llm_eval_prompt')
      end
    end

    it 'still computes algorithmic_coherence and combined_score correctly' do
      result = run_scorer(base_matched, base_classified, no_llm: true)
      s = result[:scored]['storylines'].first
      expect(s['algorithmic_coherence']).to be_a(Integer)
      expect(s['coherence_score']).to eq(s['algorithmic_coherence'])
      expected = (s['state_score'] * 0.3 + s['template_fit'] * 0.4 + s['coherence_score'] * 0.3).round
      expect(s['combined_score']).to eq(expected)
    end
  end

  describe 'empty/malformed inputs' do
    it 'aborts on missing files' do
      stdout, stderr, status = Open3.capture3('ruby', COHERENCE_SCRIPT, '/nonexistent.yaml', '/also.yaml')
      expect(status.exitstatus).to eq(1)
    end

    it 'aborts when no storylines present' do
      matched = base_matched
      matched['storylines'] = []
      Dir.mktmpdir do |dir|
        mp = File.join(dir, 'storylines_matched.yaml')
        cp = File.join(dir, 'segments_classified.yaml')
        File.write(mp, matched.to_yaml)
        File.write(cp, base_classified.to_yaml)
        _, stderr, status = Open3.capture3('ruby', COHERENCE_SCRIPT, mp, cp)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to match(/No storylines/)
      end
    end

    it 'handles storyline with no matching segments gracefully' do
      matched = base_matched
      matched['storylines'][0]['hook_segment'] = 999.0
      matched['storylines'][0]['close_segment'] = 999.9
      result = run_scorer(matched, base_classified)
      expect(result[:exit_code]).to eq(0)
      s = result[:scored]['storylines'].first
      expect(s['coherence_score']).to eq(0)
    end
  end
end
