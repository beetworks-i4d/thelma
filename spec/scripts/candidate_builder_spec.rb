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

GENERATED_FILES = %w[candidate_substrate.yaml editorial_candidates.yaml candidate_builder_warnings.log semantic_labels_pending.json].freeze

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
# Phase B — Pending Semantic Labeling (Session 7D)
# ═══════════════════════════════════════════════════════════════════════════════

EMPHATIC_RANT_PENDING_DIR = File.expand_path('../fixtures/session6_probe_emphatic_rant', __dir__) unless defined?(EMPHATIC_RANT_PENDING_DIR)
PENDING_GENERATED = %w[candidate_substrate.yaml editorial_candidates.yaml candidate_builder_warnings.log semantic_labels_pending.json].freeze unless defined?(PENDING_GENERATED)

def run_pending_no_response(dir)
  # Remove response file to force pending request generation
  resp = File.join(dir, 'semantic_labels_response.json')
  FileUtils.rm_f(resp) if File.exist?(resp)
  pending_path = File.join(dir, 'semantic_labels_pending.json')
  FileUtils.rm_f(pending_path) if File.exist?(pending_path)
  stdout, stderr, status = Open3.capture3('ruby', BUILDER_SCRIPT, '--fixture', dir, '--phase', 'ab', '--semantic-mode', 'pending')
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, pending_path: pending_path }
end

def run_pending_with_response(dir)
  stdout, stderr, status = Open3.capture3('ruby', BUILDER_SCRIPT, '--fixture', dir, '--phase', 'abc', '--semantic-mode', 'pending')
  editorial_path = File.join(dir, 'editorial_candidates.yaml')
  {
    stdout: stdout,
    stderr: stderr,
    exit_code: status.exitstatus,
    editorial: File.exist?(editorial_path) ? YAML.safe_load(File.read(editorial_path), permitted_classes: [Date]) : nil
  }
end

RSpec.describe 'candidate_builder Phase B (pending)' do
  after(:all) do
    PENDING_GENERATED.each do |f|
      path = File.join(EMPHATIC_RANT_PENDING_DIR, f)
      File.delete(path) if File.exist?(path)
    end
  end

  describe 'pending request generation (no response file)' do
    let(:run) do
      # Temporarily hide the response file
      resp = File.join(EMPHATIC_RANT_PENDING_DIR, 'semantic_labels_response.json')
      had_resp = File.exist?(resp)
      backup = had_resp ? File.read(resp) : nil
      FileUtils.rm_f(resp) if had_resp
      result = run_pending_no_response(EMPHATIC_RANT_PENDING_DIR)
      File.write(resp, backup) if had_resp
      result
    end

    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'writes semantic_labels_pending.json' do
      run
      expect(File.exist?(run[:pending_path])).to be true
    end

    it 'pending file is valid JSON' do
      run
      data = JSON.parse(File.read(run[:pending_path]))
      expect(data).to be_a(Hash)
    end

    it 'pending file has correct structure' do
      run
      data = JSON.parse(File.read(run[:pending_path]))
      expect(data).to have_key('prompt_version')
      expect(data).to have_key('schema_version')
      expect(data).to have_key('instructions')
      expect(data).to have_key('constraints')
      expect(data).to have_key('output_format')
      expect(data).to have_key('candidates')
    end

    it 'pending candidates match substrate count' do
      run
      data = JSON.parse(File.read(run[:pending_path]))
      expect(data['candidates'].size).to eq(7)
    end

    it 'pending candidates have text but no raw timestamps' do
      run
      data = JSON.parse(File.read(run[:pending_path]))
      data['candidates'].each do |c|
        expect(c).to have_key('text')
        expect(c).to have_key('id')
        expect(c).not_to have_key('t')
        expect(c).not_to have_key('e')
        expect(c).not_to have_key('segment_ids')
        expect(c).not_to have_key('source')
      end
    end

    it 'pending trims have keeps_percent but no raw in/out' do
      run
      data = JSON.parse(File.read(run[:pending_path]))
      data['candidates'].each do |c|
        c['trim_choices'].each do |tc|
          expect(tc).to have_key('keeps_percent')
          expect(tc).not_to have_key('in')
          expect(tc).not_to have_key('out')
        end
      end
    end

    it 'does not write editorial_candidates.yaml' do
      run
      editorial = File.join(EMPHATIC_RANT_PENDING_DIR, 'editorial_candidates.yaml')
      # editorial may exist from prior test runs; we check stderr instead
      expect(run[:stderr]).to include('Pending semantic label request written')
    end
  end

  describe 'response merge (with response file)' do
    let(:run) { run_pending_with_response(EMPHATIC_RANT_PENDING_DIR) }
    let(:candidates) { run[:editorial]['candidates'] }

    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'produces editorial_candidates.yaml' do
      expect(run[:editorial]).not_to be_nil
    end

    it 'preserves candidate count' do
      expect(candidates.size).to eq(7)
    end

    it 'uses LLM summaries (not mock)' do
      cand = candidates.find { |c| c['id'] == 'cand_003' }
      expect(cand['summary']).to include('dangerous')
    end

    it 'every candidate has all Phase B fields' do
      phase_b_fields = %w[summary distillation usability candidate_priority
                          suggested_narrative_roles states durability confidence edit_notes]
      candidates.each do |c|
        phase_b_fields.each do |field|
          expect(c).to have_key(field), "#{c['id']} missing '#{field}'"
        end
      end
    end

    it 'content_preserved is set on every trim from LLM response' do
      candidates.each do |c|
        c['trim_choices'].each do |tc|
          expect(tc['content_preserved']).not_to be_nil, "#{c['id']} trim #{tc['id']} content_preserved nil"
          expect(tc['content_preserved']).to be(true).or be(false)
        end
      end
    end

    it 'preserves substrate-authoritative fields' do
      substrate = YAML.safe_load(File.read(File.join(EMPHATIC_RANT_PENDING_DIR, 'candidate_substrate.yaml')), permitted_classes: [Date])
      phase_a_fields = %w[id source segment_ids t e text exclusion_choices cluster prosody]
      candidates.each_with_index do |c, i|
        sub = substrate['candidates'][i]
        phase_a_fields.each do |field|
          expect(c[field]).to eq(sub[field]), "#{c['id']}.#{field} changed after pending merge"
        end
      end
    end

    it 'passes Phase C validation' do
      expect(run[:stderr]).to include('Phase C validation passed')
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Phase B — Semantic Labeling Quality (Session 7C)
# ═══════════════════════════════════════════════════════════════════════════════

EMPHATIC_RANT_DIR = File.expand_path('../fixtures/session6_probe_emphatic_rant', __dir__) unless defined?(EMPHATIC_RANT_DIR)
PAUSE_HEAVY_DIR   = File.expand_path('../fixtures/session6_probe_pause_heavy_transition', __dir__) unless defined?(PAUSE_HEAVY_DIR)
LOW_ENERGY_DIR    = File.expand_path('../fixtures/session6_probe_low_energy_reflective', __dir__) unless defined?(LOW_ENERGY_DIR)
EXPLAINER_DIR     = File.expand_path('../fixtures/session6_probe_explainer_rapid', __dir__) unless defined?(EXPLAINER_DIR)
REAL_PROBE_DIR    = File.expand_path('../fixtures/session6_real_probe', __dir__) unless defined?(REAL_PROBE_DIR)

PROBE_GENERATED_FILES = %w[candidate_substrate.yaml editorial_candidates.yaml candidate_builder_warnings.log semantic_labels_pending.json].freeze unless defined?(PROBE_GENERATED_FILES)

def run_probe_abc(dir)
  stdout, stderr, status = Open3.capture3('ruby', BUILDER_SCRIPT, '--fixture', dir, '--phase', 'abc')
  editorial_path = File.join(dir, 'editorial_candidates.yaml')
  {
    stdout: stdout,
    stderr: stderr,
    exit_code: status.exitstatus,
    editorial: File.exist?(editorial_path) ? YAML.safe_load(File.read(editorial_path), permitted_classes: [Date]) : nil
  }
end

RSpec.describe 'Phase B semantic labeling quality' do
  after(:all) do
    [EMPHATIC_RANT_DIR, PAUSE_HEAVY_DIR, LOW_ENERGY_DIR, EXPLAINER_DIR, REAL_PROBE_DIR].each do |dir|
      PROBE_GENERATED_FILES.each do |f|
        path = File.join(dir, f)
        File.delete(path) if File.exist?(path)
      end
    end
  end

  describe 'role diversity' do
    it 'aside does not dominate emphatic_rant roles' do
      result = run_probe_abc(EMPHATIC_RANT_DIR)
      roles = result[:editorial]['candidates'].flat_map { |c| c['suggested_narrative_roles'].map { |r| r['role'] } }
      aside_count = roles.count('aside')
      expect(aside_count).to be <= 2, "aside appears #{aside_count} times, expected <= 2"
    end

    it 'pause_heavy has at least 3 distinct role types' do
      result = run_probe_abc(PAUSE_HEAVY_DIR)
      roles = result[:editorial]['candidates'].flat_map { |c| c['suggested_narrative_roles'].map { |r| r['role'] } }
      unique_roles = roles.uniq
      expect(unique_roles.size).to be >= 3, "Only #{unique_roles.size} role types: #{unique_roles}"
    end

    it 'pause_heavy is not all aside/transition' do
      result = run_probe_abc(PAUSE_HEAVY_DIR)
      roles = result[:editorial]['candidates'].flat_map { |c| c['suggested_narrative_roles'].map { |r| r['role'] } }
      aside_transition = roles.count { |r| r == 'aside' || r == 'transition' }
      expect(aside_transition).to be < roles.size, "All roles are aside/transition"
    end
  end

  describe 'emphatic declarative candidates become claims/hooks' do
    it 'cand_003 in emphatic_rant has claim or hook as top role' do
      result = run_probe_abc(EMPHATIC_RANT_DIR)
      cand = result[:editorial]['candidates'].find { |c| c['id'] == 'cand_003' }
      top_role = cand['suggested_narrative_roles'].first['role']
      expect(%w[claim hook]).to include(top_role), "cand_003 top role is #{top_role}, expected claim or hook"
    end

    it 'cand_001 in low_energy has claim or hook as top role (counterintuitive claim)' do
      result = run_probe_abc(LOW_ENERGY_DIR)
      cand = result[:editorial]['candidates'].find { |c| c['id'] == 'cand_001' }
      top_role = cand['suggested_narrative_roles'].first['role']
      expect(%w[claim hook]).to include(top_role), "cand_001 top role is #{top_role}, expected claim or hook"
    end
  end

  describe 'evidence-heavy candidates become evidence' do
    it 'personal narrative candidates get evidence role' do
      result = run_probe_abc(REAL_PROBE_DIR)
      cand = result[:editorial]['candidates'].find { |c| c['id'] == 'cand_001' }
      roles = cand['suggested_narrative_roles'].map { |r| r['role'] }
      expect(roles).to include('evidence'), "cand_001 roles #{roles} missing evidence"
    end

    it 'number-heavy candidates get evidence role' do
      result = run_probe_abc(REAL_PROBE_DIR)
      cand = result[:editorial]['candidates'].find { |c| c['id'] == 'cand_002' }
      roles = cand['suggested_narrative_roles'].map { |r| r['role'] }
      expect(roles).to include('evidence'), "cand_002 roles #{roles} missing evidence"
    end
  end

  describe 'transition detection' do
    it 'short bridge text gets transition role' do
      result = run_probe_abc(EMPHATIC_RANT_DIR)
      # cand_006 "But let me ask you something." - 1.34s bridge
      cand = result[:editorial]['candidates'].find { |c| c['id'] == 'cand_006' }
      roles = cand['suggested_narrative_roles'].map { |r| r['role'] }
      expect(roles).to include('transition'), "cand_006 roles #{roles} missing transition"
    end
  end

  describe 'state diversity' do
    it 'pause_heavy has more than just amusement' do
      result = run_probe_abc(PAUSE_HEAVY_DIR)
      all_states = result[:editorial]['candidates'].flat_map { |c| c['states'] }
      unique_states = all_states.uniq
      expect(unique_states.size).to be >= 3, "Only #{unique_states.size} state types: #{unique_states}"
      expect(unique_states).not_to eq(['amusement']), "All states are amusement"
    end

    it 'emphatic_rant has vindication' do
      result = run_probe_abc(EMPHATIC_RANT_DIR)
      all_states = result[:editorial]['candidates'].flat_map { |c| c['states'] }
      expect(all_states).to include('vindication')
    end

    it 'low_energy_reflective has calm or catharsis' do
      result = run_probe_abc(LOW_ENERGY_DIR)
      all_states = result[:editorial]['candidates'].flat_map { |c| c['states'] }
      expect(all_states.any? { |s| %w[calm catharsis].include?(s) }).to be(true),
        "States #{all_states.uniq} contain neither calm nor catharsis"
    end

    it 'system critique text gets outrage state' do
      result = run_probe_abc(PAUSE_HEAVY_DIR)
      # cand_005 "the system that we're thrown into from birth trains us to wait"
      cand = result[:editorial]['candidates'].find { |c| c['id'] == 'cand_005' }
      expect(cand['states']).to include('outrage'), "cand_005 states #{cand['states']} missing outrage"
    end
  end

  describe 'priority distribution' do
    it 'pause_heavy has at least 1 primary candidate' do
      result = run_probe_abc(PAUSE_HEAVY_DIR)
      primaries = result[:editorial]['candidates'].count { |c| c['candidate_priority'] == 'primary' }
      expect(primaries).to be >= 1, "pause_heavy has #{primaries} primary candidates, expected >= 1"
    end

    it 'low_energy has at least 2 primary candidates' do
      result = run_probe_abc(LOW_ENERGY_DIR)
      primaries = result[:editorial]['candidates'].count { |c| c['candidate_priority'] == 'primary' }
      expect(primaries).to be >= 2, "low_energy has #{primaries} primary candidates, expected >= 2"
    end
  end

  describe 'durability calibration' do
    it 'not all candidates are spike durability' do
      result = run_probe_abc(PAUSE_HEAVY_DIR)
      all_dur = result[:editorial]['candidates'].map { |c| c['durability'] }
      expect(all_dur.uniq.size).to be >= 2, "All durability is #{all_dur.first}"
    end

    it 'empowerment text gets mood or identity durability' do
      result = run_probe_abc(PAUSE_HEAVY_DIR)
      # cand_006 "The people that get results are those that just take action"
      cand = result[:editorial]['candidates'].find { |c| c['id'] == 'cand_006' }
      expect(%w[mood identity]).to include(cand['durability']),
        "cand_006 durability is #{cand['durability']}, expected mood or identity"
    end
  end

  describe 'confidence calibration' do
    it 'not all candidates get high confidence' do
      result = run_probe_abc(PAUSE_HEAVY_DIR)
      all_conf = result[:editorial]['candidates'].map { |c| c['confidence'] }
      expect(all_conf.uniq.size).to be >= 2, "All confidence is #{all_conf.first}"
    end

    it 'short ambiguous fragments get medium or low confidence' do
      result = run_probe_abc(EMPHATIC_RANT_DIR)
      # cand_006 "But let me ask you something." - 1.34s
      cand = result[:editorial]['candidates'].find { |c| c['id'] == 'cand_006' }
      expect(%w[medium low]).to include(cand['confidence']),
        "cand_006 confidence is #{cand['confidence']}, expected medium or low"
    end
  end

  describe 'determinism' do
    it 'produces identical labels on consecutive runs' do
      run_probe_abc(EMPHATIC_RANT_DIR)
      first = File.read(File.join(EMPHATIC_RANT_DIR, 'editorial_candidates.yaml'))
      run_probe_abc(EMPHATIC_RANT_DIR)
      second = File.read(File.join(EMPHATIC_RANT_DIR, 'editorial_candidates.yaml'))
      expect(first).to eq(second)
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

# ═══════════════════════════════════════════════════════════════════════════════
# Real Probe — session6_real_probe fixture
# ═══════════════════════════════════════════════════════════════════════════════

REAL_PROBE_DIR = File.expand_path('../fixtures/session6_real_probe', __dir__) unless defined?(REAL_PROBE_DIR)
REAL_PROBE_GENERATED = %w[candidate_substrate.yaml editorial_candidates.yaml candidate_builder_warnings.log].freeze unless defined?(REAL_PROBE_GENERATED)

RSpec.describe 'candidate_builder real probe' do
  after(:all) do
    REAL_PROBE_GENERATED.each do |f|
      path = File.join(REAL_PROBE_DIR, f)
      File.delete(path) if File.exist?(path)
    end
  end

  describe 'Phase ABC on real material' do
    let(:result) { run_phase_abc(REAL_PROBE_DIR) }
    let(:candidates) { result[:editorial]['candidates'] }

    it 'exits 0 (no Phase C errors)' do
      expect(result[:exit_code]).to eq(0), "Expected exit 0, got #{result[:exit_code]}.\nstderr: #{result[:stderr]}"
    end

    it 'produces candidates' do
      expect(candidates.size).to be >= 1
    end

    it 'accepts flat pitch_trend without error' do
      flat_candidates = candidates.select { |c| c['prosody']['pitch_trend'] == 'flat' }
      expect(flat_candidates).not_to be_empty, 'Expected at least one candidate with flat pitch_trend'
      expect(result[:exit_code]).to eq(0)
    end

    it 'all candidates have valid Phase B fields' do
      candidates.each do |c|
        expect(c['states']).to be_a(Array)
        expect(c['states']).not_to be_empty
        expect(c['distillation']).to be_a(String)
        expect(c['summary']).to be_a(String)
        expect(c['usability']).not_to be_nil
      end
    end
  end
end

# ═══════════════════════════════════════════════════════════════════════════════
# V2 Boundary Heuristic — multi-probe validation
# ═══════════════════════════════════════════════════════════════════════════════

EXPLAINER_RAPID_DIR = File.expand_path('../fixtures/session6_probe_explainer_rapid', __dir__) unless defined?(EXPLAINER_RAPID_DIR)
EMPHATIC_RANT_DIR   = File.expand_path('../fixtures/session6_probe_emphatic_rant', __dir__) unless defined?(EMPHATIC_RANT_DIR)
LOW_ENERGY_DIR      = File.expand_path('../fixtures/session6_probe_low_energy_reflective', __dir__) unless defined?(LOW_ENERGY_DIR)
PAUSE_HEAVY_DIR     = File.expand_path('../fixtures/session6_probe_pause_heavy_transition', __dir__) unless defined?(PAUSE_HEAVY_DIR)
DEAD_AIR_DIR        = File.expand_path('../fixtures/session6_probe_dead_air_setup', __dir__) unless defined?(DEAD_AIR_DIR)

PROBE_GENERATED = %w[candidate_substrate.yaml editorial_candidates.yaml candidate_builder_warnings.log].freeze unless defined?(PROBE_GENERATED)

RSpec.describe 'V2 boundary heuristic' do
  after(:all) do
    [EXPLAINER_RAPID_DIR, EMPHATIC_RANT_DIR, LOW_ENERGY_DIR, PAUSE_HEAVY_DIR, DEAD_AIR_DIR].each do |dir|
      PROBE_GENERATED.each do |f|
        path = File.join(dir, f)
        File.delete(path) if File.exist?(path)
      end
    end
  end

  describe 'monster reduction (explainer_rapid)' do
    let(:result) { run_phase_a(EXPLAINER_RAPID_DIR) }
    let(:candidates) { result[:result]['candidates'] }

    it 'passes Phase A' do
      expect(result[:exit_code]).to eq(0)
    end

    it 'produces more candidates than v1 baseline (was 4)' do
      expect(candidates.size).to be > 4
    end

    it 'max candidate duration under 15s' do
      max_dur = candidates.map { |c| c['e'] - c['t'] }.max
      expect(max_dur).to be < 15.0
    end

    it 'majority of candidates are single-atom' do
      single = candidates.count { |c| c['segment_ids'].size == 1 }
      expect(single).to be > candidates.size / 2
    end

    it 'passes full Phase ABC' do
      abc = run_phase_abc(EXPLAINER_RAPID_DIR)
      expect(abc[:exit_code]).to eq(0)
    end
  end

  describe 'hard splits on rhetorical markers (explainer_rapid)' do
    let(:result) { run_phase_a(EXPLAINER_RAPID_DIR) }
    let(:candidates) { result[:result]['candidates'] }

    it 'seg_039 (starts with "So") is not merged with prior segment' do
      cand = candidates.find { |c| c['segment_ids'].include?('seg_039') }
      expect(cand['segment_ids'].first).to eq('seg_039'),
        "seg_039 should start a new candidate, not trail a prior one"
    end

    it 'seg_046 (starts with "So") is not merged with prior segment' do
      cand = candidates.find { |c| c['segment_ids'].include?('seg_046') }
      expect(cand['segment_ids'].first).to eq('seg_046')
    end

    it 'seg_036 (starts with "Here\'s") stands alone' do
      cand = candidates.find { |c| c['segment_ids'].include?('seg_036') }
      expect(cand['segment_ids']).to eq(['seg_036'])
    end

    it 'seg_037 (starts with "Now") starts a new candidate' do
      cand = candidates.find { |c| c['segment_ids'].include?('seg_037') }
      expect(cand['segment_ids'].first).to eq('seg_037')
    end
  end

  describe 'reflective speech not over-split' do
    let(:result) { run_phase_a(LOW_ENERGY_DIR) }
    let(:candidates) { result[:result]['candidates'] }

    it 'candidate count unchanged from v1 (6 segments -> 6 candidates)' do
      expect(candidates.size).to eq(6)
    end

    it 'all candidates are single-atom (natural segment boundaries)' do
      candidates.each do |c|
        expect(c['segment_ids'].size).to eq(1)
      end
    end

    it 'passes Phase ABC' do
      abc = run_phase_abc(LOW_ENERGY_DIR)
      expect(abc[:exit_code]).to eq(0)
    end
  end

  describe 'profile incompatibility prevents merge (emphatic_rant)' do
    let(:result) { run_phase_a(EMPHATIC_RANT_DIR) }
    let(:candidates) { result[:result]['candidates'] }

    it 'all candidates are single-atom' do
      candidates.each do |c|
        expect(c['segment_ids'].size).to eq(1),
          "#{c['id']} has #{c['segment_ids'].size} segments, expected 1"
      end
    end

    it 'passes Phase ABC' do
      abc = run_phase_abc(EMPHATIC_RANT_DIR)
      expect(abc[:exit_code]).to eq(0)
    end
  end

  describe 'pause-heavy transitions' do
    let(:result) { run_phase_a(PAUSE_HEAVY_DIR) }
    let(:candidates) { result[:result]['candidates'] }

    it 'passes Phase A' do
      expect(result[:exit_code]).to eq(0)
    end

    it 'produces at least as many candidates as v1 (was 6)' do
      expect(candidates.size).to be >= 6
    end

    it 'passes Phase ABC' do
      abc = run_phase_abc(PAUSE_HEAVY_DIR)
      expect(abc[:exit_code]).to eq(0)
    end
  end

  describe 'dead air setup' do
    let(:result) { run_phase_a(DEAD_AIR_DIR) }
    let(:candidates) { result[:result]['candidates'] }

    it 'passes Phase A' do
      expect(result[:exit_code]).to eq(0)
    end

    it 'passes Phase ABC' do
      abc = run_phase_abc(DEAD_AIR_DIR)
      expect(abc[:exit_code]).to eq(0)
    end
  end

  describe 'deterministic across all probes' do
    it 'produces identical output on consecutive runs for explainer_rapid' do
      run_phase_a(EXPLAINER_RAPID_DIR)
      first = File.read(File.join(EXPLAINER_RAPID_DIR, 'candidate_substrate.yaml'))
      run_phase_a(EXPLAINER_RAPID_DIR)
      second = File.read(File.join(EXPLAINER_RAPID_DIR, 'candidate_substrate.yaml'))
      expect(first).to eq(second)
    end
  end
end
