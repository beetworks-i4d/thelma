require 'date'
require 'open3'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'

AUGMENT_SCRIPT = File.expand_path('../../scripts/augment_candidate_relationships.rb', __dir__)
CB_SCRIPT_AUG = File.expand_path('../../scripts/candidate_builder.rb', __dir__)
REL_SCRIPT     = File.expand_path('../../scripts/map_candidate_relationships.rb', __dir__)

EMPHATIC_AUG = File.expand_path('../fixtures/session6_probe_emphatic_rant', __dir__)

AUG_GENERATED = %w[
  candidate_substrate.yaml editorial_candidates.yaml candidate_relationships.yaml
  augmented_candidate_relationships.yaml relationship_augmentation_pending.json
  candidate_builder_warnings.log
].freeze

def ensure_baseline(dir)
  ed_path = File.join(dir, 'editorial_candidates.yaml')
  unless File.exist?(ed_path)
    Open3.capture3('ruby', CB_SCRIPT_AUG, '--fixture', dir, '--phase', 'abc')
  end
  rel_path = File.join(dir, 'candidate_relationships.yaml')
  unless File.exist?(rel_path)
    Open3.capture3('ruby', REL_SCRIPT, '--fixture', dir)
  end
end

def run_augment(dir, mode: 'pending', env: {})
  ensure_baseline(dir)
  stdout, stderr, status = Open3.capture3(env, 'ruby', AUGMENT_SCRIPT, '--fixture', dir, '--mode', mode)
  output_path = File.join(dir, 'augmented_candidate_relationships.yaml')
  result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, result: result }
end

def write_test_response(dir, augmentations)
  File.write(
    File.join(dir, 'relationship_augmentation_response.json'),
    JSON.pretty_generate({ 'augmentations' => augmentations })
  )
end

# ═══════════════════════════════════════════════════════════════════════════════

RSpec.describe 'augment_candidate_relationships' do
  after(:all) do
    AUG_GENERATED.each do |f|
      path = File.join(EMPHATIC_AUG, f)
      File.delete(path) if File.exist?(path)
    end
  end

  # ─── Mock mode ─────────────────────────────────────────────────────────────

  describe 'mock mode' do
    let(:run) { run_augment(EMPHATIC_AUG, mode: 'mock') }

    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'writes augmented_candidate_relationships.yaml' do
      expect(run[:result]).not_to be_nil
    end

    it 'mode is mock' do
      expect(run[:result]['mode']).to eq('mock')
    end

    it 'passes through baseline unchanged' do
      baseline = YAML.safe_load(File.read(File.join(EMPHATIC_AUG, 'candidate_relationships.yaml')))
      expect(run[:result]['relationships'].size).to eq(baseline['relationships'].size)
      expect(run[:result]['augmentations_applied']).to eq(0)
    end
  end

  # ─── Pending mode (no response) ───────────────────────────────────────────

  describe 'pending mode without response' do
    it 'writes pending JSON and exits 0' do
      ensure_baseline(EMPHATIC_AUG)
      # Remove response to trigger pending generation
      resp = File.join(EMPHATIC_AUG, 'relationship_augmentation_response.json')
      had_resp = File.exist?(resp)
      backup = had_resp ? File.read(resp) : nil
      FileUtils.rm_f(resp)

      stdout, stderr, status = Open3.capture3(
        'ruby', AUGMENT_SCRIPT, '--fixture', EMPHATIC_AUG, '--mode', 'pending'
      )

      File.write(resp, backup) if had_resp

      expect(status.exitstatus).to eq(0)
      expect(stderr).to include('relationship_augmentation_pending.json written')

      pending_path = File.join(EMPHATIC_AUG, 'relationship_augmentation_pending.json')
      expect(File.exist?(pending_path)).to be true
      data = JSON.parse(File.read(pending_path))
      expect(data).to have_key('instructions')
      expect(data).to have_key('candidates')
      expect(data).to have_key('baseline_relationships')
      expect(data['prompt_version']).to eq('8B.1')
    end
  end

  # ─── Pending mode (with response) ─────────────────────────────────────────

  describe 'pending mode with response' do
    let(:run) { run_augment(EMPHATIC_AUG, mode: 'pending') }

    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'mode is augmented' do
      expect(run[:result]['mode']).to eq('augmented')
    end

    it 'has augmentation summary' do
      expect(run[:result]['augmentation_summary']).to be_a(Hash)
      summary = run[:result]['augmentation_summary']
      expect(summary).to have_key('adds')
      expect(summary).to have_key('upgrades')
      expect(summary).to have_key('downgrades')
      expect(summary).to have_key('removes')
      expect(summary).to have_key('reclassifies')
    end

    it 'removed false positive contradictions' do
      types_by_id = run[:result]['relationships'].each_with_object({}) { |r, h| h[r['id']] = r['type'] }
      # rel_003, rel_004, rel_007, rel_008 should be removed
      expect(types_by_id).not_to have_key('rel_003')
      expect(types_by_id).not_to have_key('rel_004')
      expect(types_by_id).not_to have_key('rel_007')
      expect(types_by_id).not_to have_key('rel_008')
    end

    it 'upgraded rel_001 confidence to high' do
      rel = run[:result]['relationships'].find { |r| r['id'] == 'rel_001' }
      expect(rel['confidence']).to eq('high')
    end

    it 'reclassified rel_005 from tangent_from to setup_for' do
      rel = run[:result]['relationships'].find { |r| r['id'] == 'rel_005' }
      expect(rel['type']).to eq('setup_for')
    end

    it 'added payoff_of relationship cand_003->cand_002' do
      payoffs = run[:result]['relationships'].select { |r| r['type'] == 'payoff_of' }
      match = payoffs.find { |r| r['from_candidate_id'] == 'cand_003' && r['to_candidate_id'] == 'cand_002' }
      expect(match).not_to be_nil
    end

    it 'added elaborates cand_004->cand_001' do
      elab = run[:result]['relationships'].select { |r| r['type'] == 'elaborates' }
      match = elab.find { |r| r['from_candidate_id'] == 'cand_004' && r['to_candidate_id'] == 'cand_001' }
      expect(match).not_to be_nil
    end

    it 'all relationship IDs valid and unique' do
      ids = run[:result]['relationships'].map { |r| r['id'] }
      ids.each { |id| expect(id).to match(/\Arel_\d{3}\z/) }
      expect(ids.uniq.size).to eq(ids.size)
    end

    it 'all from/to candidate IDs exist' do
      editorial = YAML.safe_load(
        File.read(File.join(EMPHATIC_AUG, 'editorial_candidates.yaml')),
        permitted_classes: [Date]
      )
      valid = editorial['candidates'].map { |c| c['id'] }
      run[:result]['relationships'].each do |r|
        expect(valid).to include(r['from_candidate_id'])
        expect(valid).to include(r['to_candidate_id'])
      end
    end

    it 'no self-relationships' do
      run[:result]['relationships'].each do |r|
        expect(r['from_candidate_id']).not_to eq(r['to_candidate_id'])
      end
    end

    it 'no duplicate triples' do
      triples = run[:result]['relationships'].map { |r| "#{r['type']}:#{r['from_candidate_id']}:#{r['to_candidate_id']}" }
      expect(triples.uniq.size).to eq(triples.size)
    end

    it 'LLM evidence is appended, not replaced' do
      rel = run[:result]['relationships'].find { |r| r['id'] == 'rel_001' }
      # Should contain both original and LLM evidence
      expect(rel['evidence']).to include('LLM upgrade')
      expect(rel['evidence']).to include('shared:')
    end
  end

  # ─── Validator rejection ───────────────────────────────────────────────────

  describe 'validator rejection' do
    it 'rejects invented candidate IDs' do
      Dir.mktmpdir do |tmp|
        setup_augment_tmp(tmp)
        write_test_response(tmp, [{
          'action' => 'add',
          'rationale' => 'test',
          'relationship' => {
            'type' => 'supports', 'from_candidate_id' => 'cand_999',
            'to_candidate_id' => 'cand_001', 'confidence' => 'high',
            'evidence' => 'fake'
          }
        }])
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp, '--mode', 'pending')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("unknown from 'cand_999'")
      end
    end

    it 'rejects self-relationships' do
      Dir.mktmpdir do |tmp|
        setup_augment_tmp(tmp)
        write_test_response(tmp, [{
          'action' => 'add',
          'rationale' => 'test',
          'relationship' => {
            'type' => 'supports', 'from_candidate_id' => 'cand_001',
            'to_candidate_id' => 'cand_001', 'confidence' => 'high',
            'evidence' => 'self'
          }
        }])
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp, '--mode', 'pending')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('self-relationship')
      end
    end

    it 'rejects invalid relationship type' do
      Dir.mktmpdir do |tmp|
        setup_augment_tmp(tmp)
        write_test_response(tmp, [{
          'action' => 'add',
          'rationale' => 'test',
          'relationship' => {
            'type' => 'causes', 'from_candidate_id' => 'cand_001',
            'to_candidate_id' => 'cand_002', 'confidence' => 'high',
            'evidence' => 'invented type'
          }
        }])
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp, '--mode', 'pending')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("invalid type 'causes'")
      end
    end

    it 'rejects invalid confidence' do
      Dir.mktmpdir do |tmp|
        setup_augment_tmp(tmp)
        write_test_response(tmp, [{
          'action' => 'add',
          'rationale' => 'test',
          'relationship' => {
            'type' => 'supports', 'from_candidate_id' => 'cand_001',
            'to_candidate_id' => 'cand_002', 'confidence' => 'very_high',
            'evidence' => 'bad confidence'
          }
        }])
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp, '--mode', 'pending')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("invalid confidence 'very_high'")
      end
    end

    it 'rejects invalid action' do
      Dir.mktmpdir do |tmp|
        setup_augment_tmp(tmp)
        write_test_response(tmp, [{
          'action' => 'destroy',
          'rationale' => 'test'
        }])
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp, '--mode', 'pending')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("invalid action 'destroy'")
      end
    end

    it 'rejects missing rationale' do
      Dir.mktmpdir do |tmp|
        setup_augment_tmp(tmp)
        write_test_response(tmp, [{
          'action' => 'remove',
          'relationship_id' => 'rel_001'
        }])
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp, '--mode', 'pending')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('missing rationale')
      end
    end

    it 'rejects unknown baseline relationship_id for upgrade' do
      Dir.mktmpdir do |tmp|
        setup_augment_tmp(tmp)
        write_test_response(tmp, [{
          'action' => 'upgrade',
          'relationship_id' => 'rel_999',
          'new_confidence' => 'high',
          'rationale' => 'test'
        }])
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp, '--mode', 'pending')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("unknown relationship_id 'rel_999'")
      end
    end

    it 'rejects invented fields' do
      Dir.mktmpdir do |tmp|
        setup_augment_tmp(tmp)
        write_test_response(tmp, [{
          'action' => 'remove',
          'relationship_id' => 'rel_001',
          'rationale' => 'test',
          'timestamp' => '12.34'
        }])
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp, '--mode', 'pending')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("invented field 'timestamp'")
      end
    end
  end

  # ─── Baseline preservation ─────────────────────────────────────────────────

  describe 'baseline preservation' do
    it 'does not modify candidate_relationships.yaml' do
      ensure_baseline(EMPHATIC_AUG)
      before = File.read(File.join(EMPHATIC_AUG, 'candidate_relationships.yaml'))
      run_augment(EMPHATIC_AUG, mode: 'pending')
      after = File.read(File.join(EMPHATIC_AUG, 'candidate_relationships.yaml'))
      expect(after).to eq(before)
    end

    it 'unmodified baseline relationships retain original evidence' do
      run = run_augment(EMPHATIC_AUG, mode: 'pending')
      # rel_002 was not touched by any augmentation
      rel = run[:result]['relationships'].find { |r| r['id'] == 'rel_002' }
      expect(rel['evidence']).not_to include('LLM')
    end
  end

  # ─── Error handling ────────────────────────────────────────────────────────

  describe 'error handling' do
    it 'aborts when editorial_candidates.yaml is missing' do
      Dir.mktmpdir do |tmp|
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp)
        expect(status.exitstatus).to eq(1)
      end
    end

    it 'aborts when candidate_relationships.yaml is missing' do
      Dir.mktmpdir do |tmp|
        # Write a minimal editorial_candidates.yaml
        File.write(File.join(tmp, 'editorial_candidates.yaml'), YAML.dump({
          'version' => '1.2', 'candidates' => []
        }))
        stdout, stderr, status = Open3.capture3('ruby', AUGMENT_SCRIPT, '--fixture', tmp)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('candidate_relationships.yaml not found')
      end
    end
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

def setup_augment_tmp(tmp)
  # Copy source fixtures, generate editorial + baseline relationships
  %w[segments_classified.yaml cleaned_transcript.json speech_analysis.json].each do |f|
    src = File.join(EMPHATIC_AUG, f)
    FileUtils.cp(src, tmp) if File.exist?(src)
  end
  Open3.capture3('ruby', CB_SCRIPT_AUG, '--fixture', tmp, '--phase', 'abc')
  Open3.capture3('ruby', REL_SCRIPT, '--fixture', tmp)
end
