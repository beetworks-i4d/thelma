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

def run_phase_b(fixture_dir = FIXTURE_DIR)
  stdout, stderr, status = Open3.capture3('ruby', BUILDER_SCRIPT, '--fixture', fixture_dir, '--phase', 'b')
  output_path = File.join(fixture_dir, 'editorial_candidates.yaml')
  result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path), permitted_classes: [Date]) : nil
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, result: result, output_path: output_path }
end

def run_phase_c(fixture_dir = FIXTURE_DIR)
  stdout, stderr, status = Open3.capture3('ruby', BUILDER_SCRIPT, '--fixture', fixture_dir, '--phase', 'c')
  warnings_path = File.join(fixture_dir, 'candidate_builder_warnings.log')
  warnings = File.exist?(warnings_path) ? File.read(warnings_path) : nil
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, warnings: warnings }
end

def run_phase_abc(fixture_dir = FIXTURE_DIR)
  stdout, stderr, status = Open3.capture3('ruby', BUILDER_SCRIPT, '--fixture', fixture_dir, '--phase', 'abc')
  editorial_path = File.join(fixture_dir, 'editorial_candidates.yaml')
  warnings_path = File.join(fixture_dir, 'candidate_builder_warnings.log')
  {
    stdout: stdout,
    stderr: stderr,
    exit_code: status.exitstatus,
    editorial: File.exist?(editorial_path) ? YAML.safe_load(File.read(editorial_path), permitted_classes: [Date]) : nil,
    warnings: File.exist?(warnings_path) ? File.read(warnings_path) : nil,
    editorial_path: editorial_path
  }
end

# Run Phase C on a mutated editorial_candidates.yaml.
# Yields the parsed editorial hash for mutation, writes to temp dir, runs Phase C.
def run_phase_c_mutated
  # Ensure valid editorial exists first
  run_phase_a
  run_phase_b
  editorial = YAML.safe_load(File.read(File.join(FIXTURE_DIR, 'editorial_candidates.yaml')), permitted_classes: [Date])
  yield editorial
  Dir.mktmpdir do |tmp_dir|
    FileUtils.cp(File.join(FIXTURE_DIR, 'segments_classified.yaml'), tmp_dir)
    File.write(File.join(tmp_dir, 'editorial_candidates.yaml'), YAML.dump(editorial))
    run_phase_c(tmp_dir)
  end
end

GENERATED_FILES = %w[candidate_substrate.yaml editorial_candidates.yaml candidate_builder_warnings.log].freeze

RSpec.describe 'candidate_builder Phase A' do
  let(:run) { run_phase_a }
  let(:candidates) { run[:result]['candidates'] }

  after(:all) do
    GENERATED_FILES.each do |f|
      path = File.join(FIXTURE_DIR, f)
      File.delete(path) if File.exist?(path)
    end
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
      expect(multi['prosody']['stumble_count']).to eq(0)
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

# ═══════════════════════════════════════════════════════════════════════════════
# Phase B — Mock Semantic Labeling
# ═══════════════════════════════════════════════════════════════════════════════

RSpec.describe 'candidate_builder Phase B (mock)' do
  before(:all) do
    run_phase_a
    @b_run = run_phase_b
  end

  after(:all) do
    GENERATED_FILES.each do |f|
      path = File.join(FIXTURE_DIR, f)
      File.delete(path) if File.exist?(path)
    end
  end

  let(:run) { @b_run }
  let(:candidates) { run[:result]['candidates'] }

  describe 'basic execution' do
    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'produces editorial_candidates.yaml' do
      expect(run[:result]).not_to be_nil
      expect(run[:result]['version']).to eq('1.2')
    end

    it 'preserves candidate count' do
      expect(run[:result]['candidate_count']).to eq(4)
      expect(candidates.size).to eq(4)
    end
  end

  describe 'semantic fields populated' do
    it 'every candidate has all Phase B fields' do
      phase_b_fields = %w[summary distillation usability candidate_priority
                          suggested_narrative_roles states durability confidence edit_notes]
      candidates.each do |c|
        phase_b_fields.each do |field|
          expect(c).to have_key(field), "#{c['id']} missing Phase B field '#{field}'"
        end
      end
    end

    it 'summary is a non-empty string under 25 words' do
      candidates.each do |c|
        expect(c['summary']).to be_a(String)
        expect(c['summary']).not_to be_empty
        expect(c['summary'].split.size).to be <= 25
      end
    end

    it 'distillation is a non-empty string of max 5 words' do
      candidates.each do |c|
        expect(c['distillation']).to be_a(String)
        expect(c['distillation']).not_to be_empty
        expect(c['distillation'].split.size).to be <= 5
      end
    end

    it 'usability is a valid enum' do
      candidates.each do |c|
        expect(%w[fine marginal unusable]).to include(c['usability'])
      end
    end

    it 'candidate_priority is a valid enum' do
      candidates.each do |c|
        expect(%w[primary secondary tertiary]).to include(c['candidate_priority'])
      end
    end

    it 'states is a non-empty array of valid taxonomy values' do
      valid = %w[vindication outrage awe competence fear schadenfreude
                 amusement catharsis nostalgia belonging escape calm
                 aspiration sensual curiosity]
      candidates.each do |c|
        expect(c['states']).to be_a(Array)
        expect(c['states'].size).to be_between(1, 3)
        c['states'].each { |s| expect(valid).to include(s) }
      end
    end

    it 'durability is a valid enum' do
      candidates.each do |c|
        expect(%w[spike mood identity]).to include(c['durability'])
      end
    end

    it 'confidence is a valid enum' do
      candidates.each do |c|
        expect(%w[high medium low]).to include(c['confidence'])
      end
    end

    it 'suggested_narrative_roles has valid roles with confidence' do
      valid_roles = %w[hook setup continuation payoff transition claim evidence definition aside]
      candidates.each do |c|
        expect(c['suggested_narrative_roles']).to be_a(Array)
        c['suggested_narrative_roles'].each do |r|
          expect(valid_roles).to include(r['role'])
          expect(%w[high medium low]).to include(r['confidence'])
        end
      end
    end
  end

  describe 'merge correctness' do
    it 'preserves Phase A substrate fields unchanged' do
      substrate = YAML.safe_load(File.read(File.join(FIXTURE_DIR, 'candidate_substrate.yaml')), permitted_classes: [Date])
      phase_a_fields = %w[id source segment_ids t e text exclusion_choices cluster prosody]

      candidates.each_with_index do |c, i|
        sub = substrate['candidates'][i]
        phase_a_fields.each do |field|
          expect(c[field]).to eq(sub[field]), "#{c['id']}.#{field} changed after Phase B"
        end
      end
    end

    it 'content_preserved is set on every trim_choice' do
      candidates.each do |c|
        c['trim_choices'].each do |tc|
          expect(tc['content_preserved']).not_to be_nil, "#{c['id']} trim #{tc['id']} content_preserved is nil"
          expect(tc['content_preserved']).to be(true).or be(false)
        end
      end
    end

    it 'full_clean trims have content_preserved=true' do
      candidates.each do |c|
        full = c['trim_choices'].find { |tc| tc['label'] == 'full_clean' }
        expect(full['content_preserved']).to be true
      end
    end

    it 'does not invent new IDs' do
      substrate = YAML.safe_load(File.read(File.join(FIXTURE_DIR, 'candidate_substrate.yaml')), permitted_classes: [Date])
      candidates.each_with_index do |c, i|
        expect(c['id']).to eq(substrate['candidates'][i]['id'])
        expect(c['trim_choices'].map { |t| t['id'] }).to eq(substrate['candidates'][i]['trim_choices'].map { |t| t['id'] })
      end
    end

    it 'does not invent timestamps' do
      substrate = YAML.safe_load(File.read(File.join(FIXTURE_DIR, 'candidate_substrate.yaml')), permitted_classes: [Date])
      candidates.each_with_index do |c, i|
        sub = substrate['candidates'][i]
        expect(c['t']).to eq(sub['t'])
        expect(c['e']).to eq(sub['e'])
        c['trim_choices'].each_with_index do |tc, j|
          expect(tc['in']).to eq(sub['trim_choices'][j]['in'])
          expect(tc['out']).to eq(sub['trim_choices'][j]['out'])
        end
      end
    end
  end

  describe 'deterministic repeatability' do
    it 'produces byte-identical output on consecutive runs' do
      run_phase_b
      first = File.read(File.join(FIXTURE_DIR, 'editorial_candidates.yaml'))
      run_phase_b
      second = File.read(File.join(FIXTURE_DIR, 'editorial_candidates.yaml'))
      expect(first).to eq(second)
    end
  end

  describe 'expected output match' do
    it 'matches the golden expected_editorial_candidates.yaml' do
      run_phase_a
      run_phase_b
      actual = File.read(File.join(FIXTURE_DIR, 'editorial_candidates.yaml'))
      expected = File.read(File.join(FIXTURE_DIR, 'expected_editorial_candidates.yaml'))
      expect(actual).to eq(expected)
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Phase C — Deterministic Validation
# ═══════════════════════════════════════════════════════════════════════════════

RSpec.describe 'candidate_builder Phase C' do
  after(:all) do
    GENERATED_FILES.each do |f|
      path = File.join(FIXTURE_DIR, f)
      File.delete(path) if File.exist?(path)
    end
  end

  describe 'pass case' do
    it 'exits 0 on valid editorial_candidates.yaml' do
      result = run_phase_abc
      expect(result[:exit_code]).to eq(0)
    end

    it 'produces cluster state mismatch warning' do
      result = run_phase_abc
      expect(result[:warnings]).to include('share no common state')
    end
  end

  describe 'full pipeline ABC' do
    it 'produces byte-identical output on consecutive runs' do
      run_phase_abc
      first = File.read(File.join(FIXTURE_DIR, 'editorial_candidates.yaml'))
      run_phase_abc
      second = File.read(File.join(FIXTURE_DIR, 'editorial_candidates.yaml'))
      expect(first).to eq(second)
    end
  end

  describe 'invalid enum rejection' do
    it 'rejects invalid state with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['states'] = ['invalid_state']
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include("invalid state 'invalid_state'")
    end

    it 'rejects invalid durability with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['durability'] = 'permanent'
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include("invalid durability")
    end

    it 'rejects invalid usability with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['usability'] = 'great'
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include("invalid usability")
    end

    it 'rejects invalid narrative role with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['suggested_narrative_roles'] = [{ 'role' => 'climax', 'confidence' => 'high' }]
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include("invalid narrative role")
    end

    it 'rejects invalid trim label with exit 2' do
      result = run_phase_c_mutated do |ed|
        # Mutate cand_004's tighter_end (index 3, trim index 1) to keep full_clean intact
        ed['candidates'][3]['trim_choices'][1]['label'] = 'extra_tight'
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include("invalid trim label")
    end
  end

  describe 'duplicate ID rejection' do
    it 'rejects duplicate candidate ids with exit 1' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][1]['id'] = ed['candidates'][0]['id']
      end
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include('Duplicate candidate ids')
    end

    it 'rejects duplicate trim ids with exit 1' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][1]['trim_choices'][0]['id'] = ed['candidates'][0]['trim_choices'][0]['id']
      end
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include('Duplicate trim ids')
    end
  end

  describe 'missing content_preserved rejection' do
    it 'rejects nil content_preserved with exit 3' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['trim_choices'][0]['content_preserved'] = nil
      end
      expect(result[:exit_code]).to eq(3)
      expect(result[:stderr]).to include('content_preserved not set')
    end
  end

  describe 'incompatible state pair rejection' do
    it 'rejects sensual+calm pair with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['states'] = %w[sensual calm]
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include('incompatible state pair sensual+calm')
    end

    it 'rejects outrage+amusement pair with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['states'] = %w[outrage amusement]
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include('incompatible state pair outrage+amusement')
    end
  end

  describe 'invalid trim boundary rejection' do
    it 'rejects trim in >= out with exit 1' do
      result = run_phase_c_mutated do |ed|
        tc = ed['candidates'][0]['trim_choices'][0]
        tc['in'] = tc['out'] + 1.0
      end
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include('in >= out')
    end
  end

  describe 'invented ID rejection' do
    it 'rejects unknown segment_ids reference with exit 1' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['segment_ids'] = ['seg_999']
      end
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include('references unknown seg_999')
    end
  end

  describe 'structural checks' do
    it 'rejects wrong version with exit 1' do
      result = run_phase_c_mutated do |ed|
        ed['version'] = '2.0'
      end
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include("version must be '1.2'")
    end

    it 'rejects empty states with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['states'] = []
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include('states missing or empty')
    end

    it 'rejects more than 3 states with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['states'] = %w[vindication competence awe curiosity]
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include('states exceeds max 3')
    end

    it 'rejects distillation exceeding 5 words with exit 2' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['distillation'] = 'one two three four five six'
      end
      expect(result[:exit_code]).to eq(2)
      expect(result[:stderr]).to include('distillation exceeds 5 words')
    end
  end

  describe 'arrangement-safe trim check' do
    it 'rejects candidate with no arrangement-safe trim with exit 3' do
      result = run_phase_c_mutated do |ed|
        # Set all trims to content_preserved=false (not usable for arrangement)
        ed['candidates'][0]['trim_choices'].each { |tc| tc['content_preserved'] = false }
      end
      expect(result[:exit_code]).to eq(3)
      expect(result[:stderr]).to include('no arrangement-safe trim')
    end

    it 'allows unusable candidate with no arrangement-safe trim' do
      result = run_phase_c_mutated do |ed|
        ed['candidates'][0]['usability'] = 'unusable'
        ed['candidates'][0]['confidence'] = 'low'
        ed['candidates'][0]['trim_choices'].each { |tc| tc['content_preserved'] = false }
      end
      # Should not have exit 3 for this candidate specifically
      # (other candidates still valid, so overall should pass)
      expect(result[:exit_code]).to eq(0)
    end
  end
end
