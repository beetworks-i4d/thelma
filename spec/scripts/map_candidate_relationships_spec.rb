require 'date'
require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

RELATIONSHIP_SCRIPT = File.expand_path('../../scripts/map_candidate_relationships.rb', __dir__)
CB_SCRIPT = File.expand_path('../../scripts/candidate_builder.rb', __dir__)

EMPHATIC_RANT = File.expand_path('../fixtures/session6_probe_emphatic_rant', __dir__)
EXPLAINER_RAPID = File.expand_path('../fixtures/session6_probe_explainer_rapid', __dir__)
LOW_ENERGY = File.expand_path('../fixtures/session6_probe_low_energy_reflective', __dir__)

REL_GENERATED = %w[candidate_substrate.yaml editorial_candidates.yaml candidate_relationships.yaml candidate_builder_warnings.log].freeze

def ensure_editorial(dir)
  ed_path = File.join(dir, 'editorial_candidates.yaml')
  return if File.exist?(ed_path)
  Open3.capture3('ruby', CB_SCRIPT, '--fixture', dir, '--phase', 'abc')
end

def run_relationships(dir)
  ensure_editorial(dir)
  stdout, stderr, status = Open3.capture3('ruby', RELATIONSHIP_SCRIPT, '--fixture', dir)
  rel_path = File.join(dir, 'candidate_relationships.yaml')
  result = File.exist?(rel_path) ? YAML.safe_load(File.read(rel_path)) : nil
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, result: result }
end

def run_relationships_on_mutated(base_dir)
  ensure_editorial(base_dir)
  editorial = YAML.safe_load(File.read(File.join(base_dir, 'editorial_candidates.yaml')), permitted_classes: [Date])
  yield editorial
  Dir.mktmpdir do |tmp|
    File.write(File.join(tmp, 'editorial_candidates.yaml'), YAML.dump(editorial))
    stdout, stderr, status = Open3.capture3('ruby', RELATIONSHIP_SCRIPT, '--fixture', tmp)
    rel_path = File.join(tmp, 'candidate_relationships.yaml')
    result = File.exist?(rel_path) ? YAML.safe_load(File.read(rel_path)) : nil
    { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, result: result }
  end
end

# ═══════════════════════════════════════════════════════════════════════════════

RSpec.describe 'map_candidate_relationships' do
  after(:all) do
    [EMPHATIC_RANT, EXPLAINER_RAPID, LOW_ENERGY].each do |dir|
      REL_GENERATED.each do |f|
        path = File.join(dir, f)
        File.delete(path) if File.exist?(path)
      end
    end
  end

  # ─── Basic execution ──────────────────────────────────────────────────────

  describe 'basic execution' do
    let(:run) { run_relationships(EMPHATIC_RANT) }

    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'writes candidate_relationships.yaml' do
      expect(run[:result]).not_to be_nil
    end

    it 'has version and fingerprint' do
      expect(run[:result]['version']).to eq('1')
      expect(run[:result]['input_fingerprint']).to be_a(String)
      expect(run[:result]['input_fingerprint'].size).to eq(64)
    end

    it 'reports candidate and relationship counts' do
      expect(run[:result]['candidate_count']).to eq(7)
      expect(run[:result]['relationship_count']).to eq(run[:result]['relationships'].size)
    end

    it 'all relationship IDs are rel_NNN' do
      run[:result]['relationships'].each do |r|
        expect(r['id']).to match(/\Arel_\d{3}\z/)
      end
    end

    it 'all relationship IDs are unique' do
      ids = run[:result]['relationships'].map { |r| r['id'] }
      expect(ids.uniq.size).to eq(ids.size)
    end

    it 'has no self-relationships' do
      run[:result]['relationships'].each do |r|
        expect(r['from_candidate_id']).not_to eq(r['to_candidate_id']),
          "#{r['id']} is a self-relationship"
      end
    end

    it 'all from/to candidate IDs resolve' do
      run
      editorial = YAML.safe_load(File.read(File.join(EMPHATIC_RANT, 'editorial_candidates.yaml')), permitted_classes: [Date])
      valid_ids = editorial['candidates'].map { |c| c['id'] }
      run[:result]['relationships'].each do |r|
        expect(valid_ids).to include(r['from_candidate_id']), "#{r['id']}: unknown from #{r['from_candidate_id']}"
        expect(valid_ids).to include(r['to_candidate_id']), "#{r['id']}: unknown to #{r['to_candidate_id']}"
      end
    end

    it 'all types are valid enum' do
      valid_types = %w[duplicate_of alternate_take_of supports example_of elaborates
                       contradicts setup_for payoff_of tangent_from bridge_to]
      run[:result]['relationships'].each do |r|
        expect(valid_types).to include(r['type']), "#{r['id']}: invalid type #{r['type']}"
      end
    end

    it 'all confidences are valid enum' do
      run[:result]['relationships'].each do |r|
        expect(%w[high medium low]).to include(r['confidence']), "#{r['id']}: invalid confidence #{r['confidence']}"
      end
    end

    it 'no duplicate triples (type+from+to)' do
      triples = run[:result]['relationships'].map { |r| "#{r['type']}:#{r['from_candidate_id']}:#{r['to_candidate_id']}" }
      expect(triples.uniq.size).to eq(triples.size)
    end

    it 'has no invented fields' do
      allowed = %w[id type from_candidate_id to_candidate_id confidence evidence]
      run[:result]['relationships'].each do |r|
        r.each_key do |k|
          expect(allowed).to include(k), "#{r['id']}: invented field '#{k}'"
        end
      end
    end
  end

  # ─── Duplicate / alternate detection ──────────────────────────────────────

  describe 'duplicate and alternate detection (explainer_rapid)' do
    let(:run) { run_relationships(EXPLAINER_RAPID) }
    let(:rels) { run[:result]['relationships'] }

    it 'detects duplicate_of between cand_008 and cand_010 (same cluster, high overlap)' do
      dups = rels.select { |r| r['type'] == 'duplicate_of' }
      pair_ids = dups.map { |r| Set.new([r['from_candidate_id'], r['to_candidate_id']]) }
      expect(pair_ids).to include(Set.new(%w[cand_008 cand_010]))
    end

    it 'detects duplicate_of between cand_009 and cand_011' do
      dups = rels.select { |r| r['type'] == 'duplicate_of' }
      pair_ids = dups.map { |r| Set.new([r['from_candidate_id'], r['to_candidate_id']]) }
      expect(pair_ids).to include(Set.new(%w[cand_009 cand_011]))
    end

    it 'duplicate_of has high confidence' do
      dups = rels.select { |r| r['type'] == 'duplicate_of' }
      dups.each { |r| expect(r['confidence']).to eq('high') }
    end
  end

  # ─── Supports detection ───────────────────────────────────────────────────

  describe 'supports detection (emphatic_rant)' do
    let(:run) { run_relationships(EMPHATIC_RANT) }
    let(:rels) { run[:result]['relationships'] }

    it 'detects at least one supports relationship' do
      supports = rels.select { |r| r['type'] == 'supports' }
      expect(supports.size).to be >= 1
    end

    it 'cand_002 supports cand_001 (evidence for claim)' do
      supports = rels.select { |r| r['type'] == 'supports' }
      match = supports.find { |r| r['from_candidate_id'] == 'cand_002' && r['to_candidate_id'] == 'cand_001' }
      expect(match).not_to be_nil, "Expected cand_002→cand_001 supports, got: #{supports.map{|r| "#{r['from_candidate_id']}→#{r['to_candidate_id']}"}.join(', ')}"
    end
  end

  # ─── Contradiction detection ──────────────────────────────────────────────

  describe 'contradiction detection (emphatic_rant)' do
    let(:run) { run_relationships(EMPHATIC_RANT) }
    let(:rels) { run[:result]['relationships'] }

    it 'detects at least one contradicts relationship' do
      contradictions = rels.select { |r| r['type'] == 'contradicts' }
      expect(contradictions.size).to be >= 1
    end

    it 'contradiction evidence mentions shared terms' do
      contradictions = rels.select { |r| r['type'] == 'contradicts' }
      contradictions.each do |r|
        expect(r['evidence']).to include('shared terms')
      end
    end
  end

  # ─── Bridge detection ─────────────────────────────────────────────────────

  describe 'bridge detection (emphatic_rant)' do
    let(:run) { run_relationships(EMPHATIC_RANT) }
    let(:rels) { run[:result]['relationships'] }

    it 'cand_006 (transition) bridges to cand_007' do
      bridges = rels.select { |r| r['type'] == 'bridge_to' }
      match = bridges.find { |r| r['from_candidate_id'] == 'cand_006' && r['to_candidate_id'] == 'cand_007' }
      expect(match).not_to be_nil
    end

    it 'bridge count is reasonable (not inflated)' do
      bridges = rels.select { |r| r['type'] == 'bridge_to' }
      expect(bridges.size).to be <= 3
    end
  end

  # ─── Tangent detection ────────────────────────────────────────────────────

  describe 'tangent detection' do
    it 'emphatic_rant detects tangents between adjacent low-overlap candidates' do
      run = run_relationships(EMPHATIC_RANT)
      tangents = run[:result]['relationships'].select { |r| r['type'] == 'tangent_from' }
      expect(tangents.size).to be >= 1
      tangents.each { |r| expect(r['confidence']).to eq('low') }
    end

    it 'low_energy detects tangents' do
      run = run_relationships(LOW_ENERGY)
      tangents = run[:result]['relationships'].select { |r| r['type'] == 'tangent_from' }
      expect(tangents.size).to be >= 1
    end
  end

  # ─── Setup/payoff detection ───────────────────────────────────────────────

  describe 'setup/payoff detection (low_energy_reflective)' do
    let(:run) { run_relationships(LOW_ENERGY) }
    let(:rels) { run[:result]['relationships'] }

    it 'setup_for and payoff_of come in pairs when detected' do
      setups = rels.select { |r| r['type'] == 'setup_for' }
      payoffs = rels.select { |r| r['type'] == 'payoff_of' }
      # Each setup should have a matching payoff and vice versa
      setups.each do |s|
        matching = payoffs.find { |p| p['from_candidate_id'] == s['to_candidate_id'] && p['to_candidate_id'] == s['from_candidate_id'] }
        expect(matching).not_to be_nil, "setup #{s['from_candidate_id']}→#{s['to_candidate_id']} has no matching payoff" if payoffs.any?
      end
    end
  end

  # ─── Deterministic repeatability ──────────────────────────────────────────

  describe 'deterministic repeatability' do
    it 'produces byte-identical output on consecutive runs' do
      run_relationships(EMPHATIC_RANT)
      first = File.read(File.join(EMPHATIC_RANT, 'candidate_relationships.yaml'))
      run_relationships(EMPHATIC_RANT)
      second = File.read(File.join(EMPHATIC_RANT, 'candidate_relationships.yaml'))
      expect(first).to eq(second)
    end
  end

  # ─── Multi-probe ──────────────────────────────────────────────────────────

  describe 'multi-probe execution' do
    it 'explainer_rapid exits 0 and produces relationships' do
      run = run_relationships(EXPLAINER_RAPID)
      expect(run[:exit_code]).to eq(0)
      expect(run[:result]['relationships'].size).to be >= 1
    end

    it 'low_energy_reflective exits 0 and produces relationships' do
      run = run_relationships(LOW_ENERGY)
      expect(run[:exit_code]).to eq(0)
      expect(run[:result]['relationships'].size).to be >= 1
    end

    it 'explainer_rapid has more relationships than low_energy (more candidates)' do
      exp = run_relationships(EXPLAINER_RAPID)
      low = run_relationships(LOW_ENERGY)
      expect(exp[:result]['relationships'].size).to be > low[:result]['relationships'].size
    end
  end

  # ─── Error handling ───────────────────────────────────────────────────────

  describe 'error handling' do
    it 'aborts when editorial_candidates.yaml is missing' do
      Dir.mktmpdir do |tmp|
        stdout, stderr, status = Open3.capture3('ruby', RELATIONSHIP_SCRIPT, '--fixture', tmp)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('editorial_candidates.yaml not found')
      end
    end

    it 'aborts with no arguments' do
      stdout, stderr, status = Open3.capture3('ruby', RELATIONSHIP_SCRIPT)
      expect(status.exitstatus).to eq(1)
    end
  end
end
