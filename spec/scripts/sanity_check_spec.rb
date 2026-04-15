require 'open3'
require 'yaml'
require 'tmpdir'

SANITY_SCRIPT = File.expand_path('../../scripts/sanity_check.rb', __dir__)

def run_sanity(scored_yaml, segments_yaml, candidate_ids: [], skip: false, all: false)
  Dir.mktmpdir do |dir|
    scored_path = File.join(dir, 'storylines_scored.yaml')
    segments_path = File.join(dir, 'segments_classified.yaml')
    File.write(scored_path, scored_yaml.to_yaml)
    File.write(segments_path, segments_yaml.to_yaml)

    args = ['ruby', SANITY_SCRIPT]
    if skip
      args << '--skip-sanity-check'
    else
      args << '--all' if all
      args += [scored_path, segments_path]
      args += candidate_ids unless candidate_ids.empty?
    end

    stdout, stderr, status = Open3.capture3(*args)
    output_path = File.join(dir, 'sanity_check.yaml')
    result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result }
  end
end

def make_seg(t:, e:, states:, distillation:, dur: 'mood', roles: ['secondary'], confidence: 'high')
  { 't' => t, 'e' => e, 'states' => states, 'distillation' => distillation,
    'dur' => dur, 'roles' => roles, 'confidence' => confidence,
    'signal' => 'test signal', 'notes' => 'test', 'rationale' => 'test' }
end

def base_segments
  {
    'transcript_hash' => 'abc123',
    'segments' => [
      make_seg(t: 10.0, e: 20.0, states: %w[curiosity aspiration], distillation: 'hook opening numbers $500', dur: 'identity', roles: %w[primary]),
      make_seg(t: 25.0, e: 35.0, states: %w[competence], distillation: 'body framework step one'),
      make_seg(t: 40.0, e: 50.0, states: %w[vindication competence], distillation: 'body proof results'),
      make_seg(t: 55.0, e: 65.0, states: %w[aspiration], distillation: 'body three motivation'),
      make_seg(t: 70.0, e: 80.0, states: %w[competence aspiration], distillation: 'close takeaway identity', dur: 'identity', roles: %w[tertiary]),
      # Unused high-signal segment — contiguous run
      make_seg(t: 100.0, e: 115.0, states: %w[vindication], distillation: 'freelancer hates platform fees', dur: 'identity'),
      make_seg(t: 116.0, e: 132.0, states: %w[aspiration], distillation: 'switched to drop servicing', dur: 'mood'),
      make_seg(t: 133.0, e: 148.0, states: %w[competence], distillation: 'first sale within two weeks', dur: 'identity')
    ]
  }
end

def base_scored
  {
    'generated_at' => '2026-01-01T00:00:00+00:00',
    'source' => 'test-lib',
    'transcript_hash' => 'abc123',
    'scoring_mode' => 'algorithmic_only',
    'llm_pass_pending' => false,
    'storylines' => [
      {
        'id' => 'short_results_reveal_led',
        'profile' => 'best_short',
        'state_score' => 80,
        'template_fit' => 75,
        'algorithmic_coherence' => 90,
        'coherence_score' => 90,
        'combined_score' => 80,
        'passed_floor' => true,
        'rank' => 1,
        'primary_state' => 'curiosity',
        'hook_segment' => 10.0,
        'hook_signal' => 'specific numbers',
        'close_segment' => 70.0,
        'close_signal' => 'identity close',
        'duration_estimate' => 60,
        'segment_count' => 5,
        'scores' => { 'cold_viability' => 15 },
        'arc' => 'Curiosity proof → competence → aspiration close',
        'pitch' => 'test pitch',
        'template_match' => {
          'template' => 'three_item_framework',
          'fit_score' => 75,
          'completeness' => 67,
          'order_score' => 80,
          'matched_beats' => {},
          'missing_beats' => ['final_beat']
        }
      },
      {
        'id' => 'short_alternative_led',
        'profile' => 'best_short',
        'state_score' => 70,
        'template_fit' => 60,
        'algorithmic_coherence' => 75,
        'coherence_score' => 75,
        'combined_score' => 68,
        'passed_floor' => true,
        'rank' => 2,
        'primary_state' => 'vindication',
        'hook_segment' => 10.0,
        'hook_signal' => 'alternative hook',
        'close_segment' => 70.0,
        'close_signal' => 'alt close',
        'duration_estimate' => 55,
        'segment_count' => 5,
        'scores' => { 'cold_viability' => 10 },
        'arc' => 'Vindication proof → competence → close',
        'pitch' => 'alt pitch',
        'template_match' => {
          'template' => 'problem_solution',
          'fit_score' => 60,
          'completeness' => 50,
          'order_score' => 70,
          'matched_beats' => {},
          'missing_beats' => ['solution_beat']
        }
      }
    ]
  }
end

RSpec.describe 'sanity_check.rb' do
  describe 'logline generation schema' do
    it 'includes logline_prompt and nil logline for each candidate' do
      result = run_sanity(base_scored, base_segments)
      expect(result[:exit_code]).to eq(0)

      c = result[:result]['candidates'].first
      expect(c).to have_key('logline_prompt')
      expect(c['logline_prompt']).to include('logline')
      expect(c['logline_prompt']).to include('Distilled segments')
      expect(c['logline']).to be_nil
    end

    it 'includes distilled_segments extracted from arc' do
      result = run_sanity(base_scored, base_segments)
      c = result[:result]['candidates'].first
      expect(c['distilled_segments']).to be_an(Array)
      expect(c['distilled_segments'].size).to be >= 3
      expect(c['distilled_segments']).to include('hook opening numbers $500')
    end

    it 'includes shape descriptor' do
      result = run_sanity(base_scored, base_segments)
      c = result[:result]['candidates'].first
      expect(c['shape']).to be_a(String)
      expect(c['shape']).not_to be_empty
      expect(c['shape']).to include('three item framework')
    end
  end

  describe 'cold-open assessment' do
    it 'returns works: true for identity-durable hook' do
      result = run_sanity(base_scored, base_segments)
      c = result[:result]['candidates'].first
      expect(c['cold_open']['works']).to be true
      expect(c['cold_open']['reason']).to include('identity')
    end

    it 'returns works: false for spike-only low-confidence hook' do
      scored = base_scored
      segments = base_segments
      segments['segments'][0] = make_seg(
        t: 10.0, e: 20.0, states: %w[amusement],
        distillation: 'vague intro', dur: 'spike', roles: %w[primary], confidence: 'low'
      )
      result = run_sanity(scored, segments)
      c = result[:result]['candidates'].first
      expect(c['cold_open']['works']).to be false
      expect(c['cold_open']['reason']).to include('low confidence')
    end

    it 'marks works: true when distillation has specific numbers' do
      scored = base_scored
      segments = base_segments
      # Hook already has $500 in distillation
      result = run_sanity(scored, segments)
      c = result[:result]['candidates'].first
      expect(c['cold_open']['works']).to be true
      expect(c['cold_open']['reason']).to include('numbers')
    end
  end

  describe 'close assessment' do
    it 'returns works: true for identity-durable close' do
      result = run_sanity(base_scored, base_segments)
      c = result[:result]['candidates'].first
      expect(c['close']['works']).to be true
      expect(c['close']['reason']).to include('identity')
    end

    it 'returns works: false for spike-only close' do
      segments = base_segments
      segments['segments'][4] = make_seg(
        t: 70.0, e: 80.0, states: %w[amusement],
        distillation: 'joke ending', dur: 'spike', roles: %w[tertiary]
      )
      result = run_sanity(base_scored, segments)
      c = result[:result]['candidates'].first
      expect(c['close']['works']).to be false
      expect(c['close']['reason']).to include('spike')
    end

    it 'notes when close echoes hook states' do
      result = run_sanity(base_scored, base_segments)
      c = result[:result]['candidates'].first
      # Hook has [curiosity, aspiration], close has [competence, aspiration] — shared: aspiration
      expect(c['close']['reason']).to include('echoes hook state')
    end

    it 'returns works: false when no close segment' do
      scored = base_scored
      scored['storylines'][0]['close_segment'] = nil
      result = run_sanity(scored, base_segments)
      c = result[:result]['candidates'].first
      expect(c['close']['works']).to be false
      expect(c['close']['reason']).to include('no close segment')
    end
  end

  describe 'unused high-signal calculation' do
    it 'detects contiguous unused high-signal runs >= 15s' do
      result = run_sanity(base_scored, base_segments)
      unused = result[:result]['unused_high_signal']
      expect(unused).not_to be_empty
      expect(unused.first['duration']).to be >= 15
      expect(unused.first['distillations']).to include('freelancer hates platform fees')
    end

    it 'ignores low-confidence unused segments' do
      segments = base_segments
      # Replace high-signal unused with low confidence
      segments['segments'][5] = make_seg(
        t: 100.0, e: 115.0, states: %w[vindication],
        distillation: 'something vague', dur: 'identity', confidence: 'low'
      )
      segments['segments'][6] = make_seg(
        t: 116.0, e: 132.0, states: %w[aspiration],
        distillation: 'also vague', dur: 'mood', confidence: 'low'
      )
      segments['segments'][7] = make_seg(
        t: 133.0, e: 148.0, states: %w[competence],
        distillation: 'still vague', dur: 'identity', confidence: 'low'
      )
      result = run_sanity(base_scored, segments)
      expect(result[:result]['unused_high_signal']).to be_empty
    end

    it 'ignores spike-only durability segments' do
      segments = base_segments
      segments['segments'][5] = make_seg(
        t: 100.0, e: 115.0, states: %w[amusement],
        distillation: 'funny moment spike', dur: 'spike'
      )
      segments['segments'][6] = make_seg(
        t: 116.0, e: 132.0, states: %w[amusement],
        distillation: 'another laugh spike', dur: 'spike'
      )
      segments['segments'][7] = make_seg(
        t: 133.0, e: 148.0, states: %w[amusement],
        distillation: 'third joke spike', dur: 'spike'
      )
      result = run_sanity(base_scored, segments)
      expect(result[:result]['unused_high_signal']).to be_empty
    end

    it 'ignores short distillations (filler)' do
      segments = base_segments
      segments['segments'][5] = make_seg(
        t: 100.0, e: 115.0, states: %w[vindication],
        distillation: 'uh', dur: 'identity'
      )
      segments['segments'][6] = make_seg(
        t: 116.0, e: 132.0, states: %w[aspiration],
        distillation: 'um ok', dur: 'mood'
      )
      segments['segments'][7] = make_seg(
        t: 133.0, e: 148.0, states: %w[competence],
        distillation: 'yeah', dur: 'identity'
      )
      result = run_sanity(base_scored, segments)
      expect(result[:result]['unused_high_signal']).to be_empty
    end

    it 'returns empty when all high-signal content is used' do
      segments = base_segments
      # Remove unused segments
      segments['segments'] = segments['segments'][0..4]
      result = run_sanity(base_scored, segments)
      expect(result[:result]['unused_high_signal']).to be_empty
    end

    it 'skips runs shorter than 15s' do
      segments = base_segments
      # Make unused segments very short
      segments['segments'][5] = make_seg(
        t: 100.0, e: 105.0, states: %w[vindication],
        distillation: 'short high signal', dur: 'identity'
      )
      segments['segments'].delete_at(7)
      segments['segments'].delete_at(6)
      result = run_sanity(base_scored, segments)
      expect(result[:result]['unused_high_signal']).to be_empty
    end
  end

  describe 'swap to next-ranked candidate' do
    it 'includes next_candidate_id for swap' do
      result = run_sanity(base_scored, base_segments)
      c = result[:result]['candidates'].first
      expect(c['next_candidate_id']).to eq('short_alternative_led')
      expect(c['next_candidate_score']).to eq(68)
    end

    it 'returns nil next_candidate when no alternatives exist' do
      scored = base_scored
      scored['storylines'] = [scored['storylines'][0]]
      result = run_sanity(scored, base_segments)
      c = result[:result]['candidates'].first
      expect(c['next_candidate_id']).to be_nil
    end

    it 'regenerates review data when reviewing swapped candidate' do
      result = run_sanity(base_scored, base_segments, candidate_ids: ['short_alternative_led'])
      expect(result[:exit_code]).to eq(0)
      c = result[:result]['candidates'].first
      expect(c['id']).to eq('short_alternative_led')
      expect(c['shape']).to be_a(String)
      expect(c['cold_open']).to have_key('works')
      expect(c['logline_prompt']).to include('Distilled segments')
    end
  end

  describe '--skip-sanity-check flag' do
    it 'exits 0 immediately without output file' do
      result = run_sanity({}, {}, skip: true)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]).to be_nil
      expect(result[:stderr]).to include('skipped')
    end
  end

  describe 'candidate selection' do
    it 'reviews only ranked candidates by default' do
      scored = base_scored
      scored['storylines'] << {
        'id' => 'unranked_fail',
        'profile' => 'best_medium',
        'state_score' => 20,
        'template_fit' => 20,
        'algorithmic_coherence' => 30,
        'coherence_score' => 30,
        'combined_score' => 23,
        'passed_floor' => false,
        'primary_state' => 'curiosity',
        'hook_segment' => 10.0,
        'close_segment' => 70.0,
        'duration_estimate' => 300,
        'segment_count' => 5,
        'arc' => 'test',
        'pitch' => 'test',
        'template_match' => { 'template' => 'none', 'completeness' => 0 }
      }
      result = run_sanity(scored, base_segments)
      ids = result[:result]['candidates'].map { |c| c['id'] }
      expect(ids).not_to include('unranked_fail')
    end

    it 'reviews specific candidates by ID' do
      result = run_sanity(base_scored, base_segments, candidate_ids: ['short_alternative_led'])
      expect(result[:result]['candidates'].size).to eq(1)
      expect(result[:result]['candidates'].first['id']).to eq('short_alternative_led')
    end

    it 'reviews all candidates with --all flag' do
      scored = base_scored
      scored['storylines'] << {
        'id' => 'unranked_extra',
        'profile' => 'best_medium',
        'state_score' => 30,
        'template_fit' => 30,
        'algorithmic_coherence' => 40,
        'coherence_score' => 40,
        'combined_score' => 33,
        'passed_floor' => false,
        'primary_state' => 'vindication',
        'hook_segment' => 10.0,
        'close_segment' => 70.0,
        'duration_estimate' => 200,
        'segment_count' => 5,
        'arc' => 'test',
        'pitch' => 'test',
        'template_match' => { 'template' => 'none', 'completeness' => 0 }
      }
      result = run_sanity(scored, base_segments, all: true)
      ids = result[:result]['candidates'].map { |c| c['id'] }
      expect(ids).to include('unranked_extra')
    end
  end

  describe 'edge cases' do
    it 'aborts on missing files' do
      _, stderr, status = Open3.capture3('ruby', SANITY_SCRIPT, '/nonexistent.yaml', '/also.yaml')
      expect(status.exitstatus).to eq(1)
    end

    it 'aborts on empty storylines' do
      scored = base_scored
      scored['storylines'] = []
      Dir.mktmpdir do |dir|
        sp = File.join(dir, 'storylines_scored.yaml')
        cp = File.join(dir, 'segments_classified.yaml')
        File.write(sp, scored.to_yaml)
        File.write(cp, base_segments.to_yaml)
        _, stderr, status = Open3.capture3('ruby', SANITY_SCRIPT, sp, cp)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('No storylines')
      end
    end

    it 'aborts on empty segments' do
      segments = { 'transcript_hash' => 'abc', 'segments' => [] }
      Dir.mktmpdir do |dir|
        sp = File.join(dir, 'storylines_scored.yaml')
        cp = File.join(dir, 'segments_classified.yaml')
        File.write(sp, base_scored.to_yaml)
        File.write(cp, segments.to_yaml)
        _, stderr, status = Open3.capture3('ruby', SANITY_SCRIPT, sp, cp)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('No segments')
      end
    end

    it 'exits cleanly when no ranked candidates exist' do
      scored = base_scored
      scored['storylines'].each { |s| s.delete('rank') }
      result = run_sanity(scored, base_segments)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]).to be_nil
    end

    it 'handles candidate with missing hook segment gracefully' do
      scored = base_scored
      scored['storylines'][0]['hook_segment'] = 999.0
      result = run_sanity(scored, base_segments)
      expect(result[:exit_code]).to eq(0)
      c = result[:result]['candidates'].first
      expect(c['cold_open']['works']).to be false
    end

    it 'handles candidate with missing close segment gracefully' do
      scored = base_scored
      scored['storylines'][0]['close_segment'] = 999.0
      result = run_sanity(scored, base_segments)
      expect(result[:exit_code]).to eq(0)
      c = result[:result]['candidates'].first
      expect(c['close']['works']).to be false
    end

    it 'aborts when specified candidate IDs not found' do
      Dir.mktmpdir do |dir|
        sp = File.join(dir, 'storylines_scored.yaml')
        cp = File.join(dir, 'segments_classified.yaml')
        File.write(sp, base_scored.to_yaml)
        File.write(cp, base_segments.to_yaml)
        _, stderr, status = Open3.capture3('ruby', SANITY_SCRIPT, sp, cp, 'nonexistent_id')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('No matching candidates')
      end
    end
  end

  describe 'output schema' do
    it 'includes all required top-level fields' do
      result = run_sanity(base_scored, base_segments)
      %w[generated_at source candidates_reviewed candidates unused_high_signal].each do |field|
        expect(result[:result]).to have_key(field), "missing top-level field: #{field}"
      end
    end

    it 'includes all required per-candidate fields' do
      result = run_sanity(base_scored, base_segments)
      c = result[:result]['candidates'].first
      %w[id profile duration_estimate combined_score shape cold_open close distilled_segments logline_prompt logline].each do |field|
        expect(c).to have_key(field), "missing candidate field: #{field}"
      end
    end

    it 'outputs path to stdout' do
      result = run_sanity(base_scored, base_segments)
      expect(result[:stdout]).to end_with('sanity_check.yaml')
    end
  end
end
