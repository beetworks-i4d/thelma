require 'date'
require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

BUILDER_SCRIPT = File.expand_path('../../scripts/candidate_builder.rb', __dir__)
FIXTURE_DIR    = File.expand_path('../fixtures/session6', __dir__)

def run_phase_a(fixture_dir = FIXTURE_DIR)
  stdout, stderr, status = Open3.capture3('ruby', BUILDER_SCRIPT, '--fixture', fixture_dir, '--phase', 'a')
  output_path = File.join(fixture_dir, 'candidate_substrate.yaml')
  result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path), permitted_classes: [Date]) : nil
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, result: result, output_path: output_path }
end

RSpec.describe 'candidate_builder Phase A' do
  let(:run) { run_phase_a }
  let(:candidates) { run[:result]['candidates'] }

  after(:all) do
    # Clean up generated file so fixture dir stays pristine.
    out = File.join(FIXTURE_DIR, 'candidate_substrate.yaml')
    File.delete(out) if File.exist?(out)
  end

  describe 'basic execution' do
    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'produces valid YAML with version 1.2' do
      expect(run[:result]['version']).to eq('1.2')
    end

    it 'reports correct candidate count' do
      expect(run[:result]['candidate_count']).to eq(candidates.size)
    end
  end

  describe 'candidate spanning' do
    it 'creates 4 candidates from 5 segments' do
      expect(candidates.size).to eq(4)
    end

    it 'creates a multi-atom candidate for contiguous same-source segments' do
      multi = candidates.find { |c| c['segment_ids'].size > 1 }
      expect(multi).not_to be_nil
      expect(multi['segment_ids']).to eq(%w[seg_004 seg_005])
    end

    it 'keeps non-contiguous segments as separate candidates' do
      single_ids = candidates.select { |c| c['segment_ids'].size == 1 }.map { |c| c['segment_ids'].first }
      expect(single_ids).to include('seg_001', 'seg_002', 'seg_003')
    end

    it 'computes correct t and e for multi-atom candidates' do
      multi = candidates.find { |c| c['id'] == 'cand_004' }
      expect(multi['t']).to eq(42.0)
      expect(multi['e']).to eq(53.8)
    end

    it 'concatenates text for multi-atom candidates' do
      multi = candidates.find { |c| c['id'] == 'cand_004' }
      expect(multi['text']).to include('measuring every branch')
      expect(multi['text']).to include('support beam')
    end
  end

  describe 'ID formats' do
    it 'assigns cand_NNN ids' do
      candidates.each do |c|
        expect(c['id']).to match(/\Acand_\d{3}\z/)
      end
    end

    it 'assigns trim_NNN ids' do
      candidates.each do |c|
        c['trim_choices'].each do |tc|
          expect(tc['id']).to match(/\Atrim_\d{3}\z/)
        end
      end
    end

    it 'assigns ex_NNN ids for exclusions' do
      all_ex = candidates.flat_map { |c| c['exclusion_choices'] }
      all_ex.each do |ec|
        expect(ec['id']).to match(/\Aex_\d{3}\z/)
      end
    end

    it 'has globally unique candidate ids' do
      ids = candidates.map { |c| c['id'] }
      expect(ids.uniq.size).to eq(ids.size)
    end
  end

  describe 'trim_choices' do
    it 'every candidate has at least a full_clean trim' do
      candidates.each do |c|
        labels = c['trim_choices'].map { |tc| tc['label'] }
        expect(labels).to include('full_clean'), "#{c['id']} missing full_clean"
      end
    end

    it 'trim boundaries stay within candidate bounds' do
      candidates.each do |c|
        c['trim_choices'].each do |tc|
          expect(tc['in']).to be >= c['t'] - 0.001
          expect(tc['out']).to be <= c['e'] + 0.001
          expect(tc['in']).to be < tc['out']
        end
      end
    end

    it 'full_clean in/out match candidate t/e' do
      candidates.each do |c|
        full = c['trim_choices'].find { |tc| tc['label'] == 'full_clean' }
        expect(full['in']).to eq(c['t'])
        expect(full['out']).to eq(c['e'])
      end
    end

    it 'sets mechanical_boundary_safe on every trim' do
      candidates.each do |c|
        c['trim_choices'].each do |tc|
          expect(tc).to have_key('mechanical_boundary_safe')
          expect(tc['mechanical_boundary_safe']).to be(true).or be(false)
        end
      end
    end

    it 'content_preserved is nil (Phase B not run)' do
      candidates.each do |c|
        c['trim_choices'].each do |tc|
          expect(tc['content_preserved']).to be_nil
        end
      end
    end

    it 'generates tighter_end for multi-atom candidate with trailing silence' do
      multi = candidates.find { |c| c['id'] == 'cand_004' }
      labels = multi['trim_choices'].map { |tc| tc['label'] }
      expect(labels).to include('tighter_end')
    end
  end

  describe 'exclusion_choices' do
    it 'detects long-pause exclusion in seg_002' do
      cand = candidates.find { |c| c['segment_ids'] == ['seg_002'] }
      expect(cand['exclusion_choices'].size).to eq(1)
      ex = cand['exclusion_choices'].first
      expect(ex['type']).to eq('pacing')
      expect(ex['reason']).to eq('long_pause')
      expect(ex['recommended']).to be true
    end

    it 'exclusion ranges fall within candidate bounds' do
      candidates.each do |c|
        c['exclusion_choices'].each do |ec|
          expect(ec['start']).to be >= c['t']
          expect(ec['end']).to be <= c['e']
          expect(ec['start']).to be < ec['end']
        end
      end
    end

    it 'candidates without detected pauses have empty exclusion_choices' do
      no_ex = candidates.select { |c| c['exclusion_choices'].empty? }
      expect(no_ex.size).to eq(3)
    end
  end

  describe 'lexical clustering' do
    it 'clusters cand_001 and cand_003 together' do
      c1 = candidates.find { |c| c['id'] == 'cand_001' }
      c3 = candidates.find { |c| c['id'] == 'cand_003' }
      expect(c1['cluster']).not_to be_nil
      expect(c1['cluster']).to eq(c3['cluster'])
    end

    it 'does not cluster unrelated candidates' do
      c2 = candidates.find { |c| c['id'] == 'cand_002' }
      c4 = candidates.find { |c| c['id'] == 'cand_004' }
      expect(c2['cluster']).to be_nil
      expect(c4['cluster']).to be_nil
    end

    it 'cluster label is snake_case' do
      candidates.each do |c|
        next if c['cluster'].nil?
        expect(c['cluster']).to match(/\A[a-z0-9]+(_[a-z0-9]+)*\z/)
      end
    end
  end

  describe 'prosody aggregation' do
    it 'every candidate has prosody with all required fields' do
      candidates.each do |c|
        expect(c['prosody']).to have_key('audio_profile')
        expect(c['prosody']).to have_key('energy')
        expect(c['prosody']).to have_key('stumble_count')
        expect(c['prosody']).to have_key('max_pause_ms')
        expect(c['prosody']).to have_key('pitch_trend')
      end
    end

    it 'converts energy float to enum' do
      candidates.each do |c|
        expect(%w[low medium high]).to include(c['prosody']['energy'])
      end
    end

    it 'aggregates prosody across atoms for multi-atom candidate' do
      multi = candidates.find { |c| c['id'] == 'cand_004' }
      # seg_004 stumble_count=0, seg_005 stumble_count=0 → sum=0
      expect(multi['prosody']['stumble_count']).to eq(0)
      # max_pause_ms = max(200, 250) = 250
      expect(multi['prosody']['max_pause_ms']).to eq(250)
    end
  end

  describe 'Phase B fields omitted' do
    it 'does not include Phase B semantic fields' do
      phase_b_fields = %w[summary distillation usability candidate_priority
                          suggested_narrative_roles states durability confidence edit_notes]
      candidates.each do |c|
        phase_b_fields.each do |field|
          expect(c).not_to have_key(field), "#{c['id']} should not have Phase B field '#{field}'"
        end
      end
    end
  end

  describe 'deterministic repeatability' do
    it 'produces byte-identical output on consecutive runs' do
      run_phase_a
      first_content = File.read(File.join(FIXTURE_DIR, 'candidate_substrate.yaml'))

      run_phase_a
      second_content = File.read(File.join(FIXTURE_DIR, 'candidate_substrate.yaml'))

      expect(first_content).to eq(second_content)
    end
  end

  describe 'expected output match' do
    it 'matches the golden expected_candidate_substrate.yaml' do
      run_phase_a
      actual = File.read(File.join(FIXTURE_DIR, 'candidate_substrate.yaml'))
      expected = File.read(File.join(FIXTURE_DIR, 'expected_candidate_substrate.yaml'))
      expect(actual).to eq(expected)
    end
  end
end
