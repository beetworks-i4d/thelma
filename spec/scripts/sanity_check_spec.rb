require 'open3'
require 'yaml'
require 'tmpdir'

SANITY_SCRIPT = File.expand_path('../../scripts/sanity_check.rb', __dir__)

def run_sanity(scored_yaml, segments_yaml, candidate_ids: [], skip: false, all: false,
               batch: false, strong_threshold: nil, acceptable_threshold: nil)
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
      args << '--batch' if batch
      args += ['--strong-threshold', strong_threshold.to_s] if strong_threshold
      args += ['--acceptable-threshold', acceptable_threshold.to_s] if acceptable_threshold
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
  describe 'distilled segments' do
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
      expect(c['distilled_segments']).to be_a(Array)
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
      %w[id profile duration_estimate combined_score shape cold_open close distilled_segments].each do |field|
        expect(c).to have_key(field), "missing candidate field: #{field}"
      end
    end

    it 'outputs path to stdout' do
      result = run_sanity(base_scored, base_segments)
      expect(result[:stdout]).to end_with('sanity_check.yaml')
    end

    it 'does not include tier field without --batch' do
      result = run_sanity(base_scored, base_segments)
      result[:result]['candidates'].each do |c|
        expect(c).not_to have_key('tier')
      end
    end
  end

  # --- Batch mode tests ---

  describe '--batch mode' do
    def batch_scored
      # Build a scored file with candidates across all tiers
      storylines = []

      # Strong tier (80+)
      3.times do |i|
        storylines << {
          'id' => "strong_#{i}", 'profile' => 'best_short',
          'state_score' => 85 + i, 'template_fit' => 80,
          'algorithmic_coherence' => 90, 'coherence_score' => 90,
          'combined_score' => 85 + i, 'passed_floor' => true, 'rank' => i + 1,
          'primary_state' => 'curiosity',
          'hook_segment' => 10.0, 'hook_signal' => 'test',
          'close_segment' => 70.0, 'close_signal' => 'test',
          'duration_estimate' => 60, 'segment_count' => 5,
          'scores' => { 'cold_viability' => 15 },
          'arc' => 'test', 'pitch' => 'test',
          'template_match' => { 'template' => 'three_item_framework', 'completeness' => 80 }
        }
      end

      # Acceptable tier (65-79)
      2.times do |i|
        storylines << {
          'id' => "acceptable_#{i}", 'profile' => 'best_short',
          'state_score' => 70 + i, 'template_fit' => 65,
          'algorithmic_coherence' => 75, 'coherence_score' => 75,
          'combined_score' => 70 + i, 'passed_floor' => true, 'rank' => 4 + i,
          'primary_state' => 'vindication',
          'hook_segment' => 10.0, 'hook_signal' => 'test',
          'close_segment' => 70.0, 'close_signal' => 'test',
          'duration_estimate' => 55, 'segment_count' => 5,
          'scores' => { 'cold_viability' => 10 },
          'arc' => 'test', 'pitch' => 'test',
          'template_match' => { 'template' => 'problem_solution', 'completeness' => 60 }
        }
      end

      # Borderline tier (60-64)
      2.times do |i|
        storylines << {
          'id' => "borderline_#{i}", 'profile' => 'best_short',
          'state_score' => 62 + i, 'template_fit' => 55,
          'algorithmic_coherence' => 60, 'coherence_score' => 60,
          'combined_score' => 62 + i, 'passed_floor' => true, 'rank' => 6 + i,
          'primary_state' => 'aspiration',
          'hook_segment' => 10.0, 'hook_signal' => 'test',
          'close_segment' => 70.0, 'close_signal' => 'test',
          'duration_estimate' => 45, 'segment_count' => 5,
          'scores' => { 'cold_viability' => 5 },
          'arc' => 'test', 'pitch' => 'test',
          'template_match' => { 'template' => 'none', 'completeness' => 30 }
        }
      end

      {
        'generated_at' => '2026-01-01T00:00:00+00:00',
        'source' => 'test-batch',
        'transcript_hash' => 'abc123',
        'scoring_mode' => 'algorithmic_only',
        'llm_pass_pending' => false,
        'storylines' => storylines
      }
    end

    describe 'tier classification' do
      it 'classifies score 80 as strong' do
        scored = base_scored
        scored['storylines'][0]['combined_score'] = 80
        result = run_sanity(scored, base_segments, batch: true)
        c = result[:result]['candidates'].find { |r| r['combined_score'] == 80 }
        expect(c['tier']).to eq('strong')
      end

      it 'classifies score 79 as acceptable' do
        scored = base_scored
        scored['storylines'][0]['combined_score'] = 79
        result = run_sanity(scored, base_segments, batch: true)
        c = result[:result]['candidates'].find { |r| r['combined_score'] == 79 }
        expect(c['tier']).to eq('acceptable')
      end

      it 'classifies score 65 as acceptable' do
        scored = base_scored
        scored['storylines'][0]['combined_score'] = 65
        result = run_sanity(scored, base_segments, batch: true)
        c = result[:result]['candidates'].find { |r| r['combined_score'] == 65 }
        expect(c['tier']).to eq('acceptable')
      end

      it 'classifies score 64 as borderline' do
        scored = base_scored
        scored['storylines'][0]['combined_score'] = 64
        result = run_sanity(scored, base_segments, batch: true)
        c = result[:result]['candidates'].find { |r| r['combined_score'] == 64 }
        expect(c['tier']).to eq('borderline')
      end

      it 'classifies score 60 as borderline' do
        scored = base_scored
        scored['storylines'][0]['combined_score'] = 60
        result = run_sanity(scored, base_segments, batch: true)
        c = result[:result]['candidates'].find { |r| r['combined_score'] == 60 }
        expect(c['tier']).to eq('borderline')
      end

      it 'classifies score 59 as borderline (below default floor)' do
        scored = base_scored
        scored['storylines'][0]['combined_score'] = 59
        result = run_sanity(scored, base_segments, batch: true)
        c = result[:result]['candidates'].find { |r| r['combined_score'] == 59 }
        expect(c['tier']).to eq('borderline')
      end
    end

    describe 'rollup format' do
      it 'includes batch_mode flag in output' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        expect(result[:result]['batch_mode']).to be true
      end

      it 'includes default thresholds in output' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        expect(result[:result]['thresholds']).to eq({ 'strong' => 80, 'acceptable' => 65 })
      end

      it 'includes tiers with counts and ids' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        tiers = result[:result]['tiers']

        expect(tiers['strong']['count']).to eq(3)
        expect(tiers['strong']['ids']).to all(start_with('strong_'))

        expect(tiers['acceptable']['count']).to eq(2)
        expect(tiers['acceptable']['ids']).to all(start_with('acceptable_'))

        expect(tiers['borderline']['count']).to eq(2)
        expect(tiers['borderline']['ids']).to all(start_with('borderline_'))
      end

      it 'adds tier field to each candidate' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        result[:result]['candidates'].each do |c|
          expect(c).to have_key('tier')
          expect(%w[strong acceptable borderline]).to include(c['tier'])
        end
      end

      it 'shows rollup header in stderr' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        expect(result[:stderr]).to include('BATCH: 7 candidates')
        expect(result[:stderr]).to include('Strong (80+): 3')
        expect(result[:stderr]).to include('Acceptable (65-79): 2')
        expect(result[:stderr]).to include('Borderline (60-64): 2')
      end

      it 'shows borderline review section in stderr' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        expect(result[:stderr]).to include('BORDERLINE REVIEW:')
        expect(result[:stderr]).to include('borderline_0')
        expect(result[:stderr]).to include('borderline_1')
      end

      it 'shows acceptable summaries in stderr' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        expect(result[:stderr]).to include('ACCEPTABLE (summaries only):')
        expect(result[:stderr]).to include('acceptable_0')
        expect(result[:stderr]).to include('acceptable_1')
      end

      it 'shows action prompt in stderr' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        expect(result[:stderr]).to include('Build all 5 strong+acceptable, review 2 borderline?')
        expect(result[:stderr]).to include('[y/review all/cancel/build all]')
      end
    end

    describe 'threshold overrides' do
      it 'uses custom strong threshold' do
        result = run_sanity(batch_scored, base_segments, batch: true, strong_threshold: 85)
        tiers = result[:result]['tiers']
        # strong_0=85, strong_1=86, strong_2=87 → all strong at 85+
        # But strong_0 is exactly 85 → strong
        expect(tiers['strong']['count']).to eq(3)
        expect(result[:result]['thresholds']['strong']).to eq(85)
      end

      it 'reclassifies with higher strong threshold' do
        result = run_sanity(batch_scored, base_segments, batch: true, strong_threshold: 87)
        tiers = result[:result]['tiers']
        # Only strong_2 (87) is strong; strong_0 (85) and strong_1 (86) become acceptable
        expect(tiers['strong']['count']).to eq(1)
        expect(tiers['acceptable']['count']).to eq(4) # 2 original acceptable + 2 reclassified
      end

      it 'uses custom acceptable threshold' do
        result = run_sanity(batch_scored, base_segments, batch: true, acceptable_threshold: 70)
        tiers = result[:result]['tiers']
        # acceptable_0=70 is now at boundary → acceptable; acceptable_1=71 → acceptable
        # borderline_0=62, borderline_1=63 still borderline
        expect(tiers['acceptable']['count']).to eq(2)
        expect(result[:result]['thresholds']['acceptable']).to eq(70)
      end

      it 'reclassifies with higher acceptable threshold' do
        result = run_sanity(batch_scored, base_segments, batch: true, acceptable_threshold: 72)
        tiers = result[:result]['tiers']
        # acceptable_0=70, acceptable_1=71 now borderline (< 72)
        expect(tiers['borderline']['count']).to eq(4) # 2 original + 2 reclassified
        expect(tiers['acceptable']['count']).to eq(0)
      end

      it 'reflects custom thresholds in stderr rollup' do
        result = run_sanity(batch_scored, base_segments, batch: true, strong_threshold: 90, acceptable_threshold: 75)
        expect(result[:stderr]).to include('Strong (90+)')
        expect(result[:stderr]).to include('Acceptable (75-89)')
        expect(result[:stderr]).to include('Borderline (70-74)')
      end
    end

    describe '--batch flag parsing' do
      it 'activates batch mode with --batch flag' do
        result = run_sanity(base_scored, base_segments, batch: true)
        expect(result[:exit_code]).to eq(0)
        expect(result[:result]['batch_mode']).to be true
      end

      it 'does not produce batch output without --batch' do
        result = run_sanity(base_scored, base_segments)
        expect(result[:result]).not_to have_key('batch_mode')
        expect(result[:result]).not_to have_key('tiers')
      end

      it 'combines --batch with --all' do
        scored = base_scored
        scored['storylines'] << {
          'id' => 'unranked_extra', 'profile' => 'best_medium',
          'state_score' => 30, 'template_fit' => 30,
          'algorithmic_coherence' => 40, 'coherence_score' => 40,
          'combined_score' => 33, 'passed_floor' => false,
          'primary_state' => 'vindication',
          'hook_segment' => 10.0, 'close_segment' => 70.0,
          'duration_estimate' => 200, 'segment_count' => 5,
          'arc' => 'test', 'pitch' => 'test',
          'template_match' => { 'template' => 'none', 'completeness' => 0 }
        }
        result = run_sanity(scored, base_segments, batch: true, all: true)
        expect(result[:result]['batch_mode']).to be true
        ids = result[:result]['candidates'].map { |c| c['id'] }
        expect(ids).to include('unranked_extra')
        expect(result[:result]['candidates'].find { |c| c['id'] == 'unranked_extra' }['tier']).to eq('borderline')
      end
    end

    describe 'all user action paths' do
      # These tests verify the output format supports each action path.
      # The script produces data; the agent interprets the action.

      it 'y path: strong+acceptable have tier, borderline identified for review' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        tiers = result[:result]['tiers']
        buildable_ids = tiers['strong']['ids'] + tiers['acceptable']['ids']
        borderline_ids = tiers['borderline']['ids']

        expect(buildable_ids.size).to eq(5)
        expect(borderline_ids.size).to eq(2)

        # Each borderline candidate has full review data
        borderline_ids.each do |id|
          c = result[:result]['candidates'].find { |r| r['id'] == id }
          expect(c['cold_open']).to have_key('works')
          expect(c['close']).to have_key('works')
          expect(c['distilled_segments']).to be_an(Array)
        end
      end

      it 'review all path: all candidates have full review data' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        result[:result]['candidates'].each do |c|
          expect(c['cold_open']).to have_key('works')
          expect(c['close']).to have_key('works')
          expect(c['distilled_segments']).to be_an(Array)
        end
      end

      it 'build all path: all candidates above floor available' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        # All 7 candidates are ranked, all available for build-all
        expect(result[:result]['candidates_reviewed']).to eq(7)
        all_ids = result[:result]['candidates'].map { |c| c['id'] }
        expect(all_ids.size).to eq(7)
      end

      it 'cancel path: output file still written for reference' do
        result = run_sanity(batch_scored, base_segments, batch: true)
        expect(result[:exit_code]).to eq(0)
        expect(result[:result]).not_to be_nil
      end
    end

    describe 'no borderline candidates' do
      it 'omits borderline section when none exist' do
        scored = base_scored
        # Both candidates are above acceptable (80, 68)
        result = run_sanity(scored, base_segments, batch: true)
        expect(result[:stderr]).not_to include('BORDERLINE REVIEW:')
      end

      it 'shows zero borderline in rollup' do
        scored = base_scored
        result = run_sanity(scored, base_segments, batch: true)
        expect(result[:result]['tiers']['borderline']['count']).to eq(0)
      end
    end

    describe 'all strong batch' do
      it 'handles batch where all candidates are strong' do
        scored = base_scored
        scored['storylines'].each { |s| s['combined_score'] = 90 }
        result = run_sanity(scored, base_segments, batch: true)

        expect(result[:result]['tiers']['strong']['count']).to eq(2)
        expect(result[:result]['tiers']['acceptable']['count']).to eq(0)
        expect(result[:result]['tiers']['borderline']['count']).to eq(0)

        expect(result[:stderr]).to include('Build all 2 strong+acceptable, review 0 borderline?')
      end
    end
  end
end
