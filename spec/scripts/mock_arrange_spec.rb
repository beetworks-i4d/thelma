require 'open3'
require 'yaml'
require 'set'

MOCK_ARRANGE_SCRIPT = File.expand_path('../../scripts/mock_arrange.rb', __dir__)
BUILDER_SCRIPT = File.expand_path('../../scripts/candidate_builder.rb', __dir__) unless defined?(BUILDER_SCRIPT)

EMPHATIC_DIR = File.expand_path('../fixtures/session6_probe_emphatic_rant', __dir__)
RAPID_DIR    = File.expand_path('../fixtures/session6_probe_explainer_rapid', __dir__)
DEAD_AIR_DIR_A = File.expand_path('../fixtures/session6_probe_dead_air_setup', __dir__)

ARRANGEMENT_FILES = %w[arrangement.yaml candidate_substrate.yaml editorial_candidates.yaml candidate_builder_warnings.log].freeze

def ensure_editorial_candidates(dir)
  ec_path = File.join(dir, 'editorial_candidates.yaml')
  return if File.exist?(ec_path)
  Open3.capture3('ruby', BUILDER_SCRIPT, '--fixture', dir, '--phase', 'abc')
end

def run_arrange(dir)
  ensure_editorial_candidates(dir)
  stdout, stderr, status = Open3.capture3('ruby', MOCK_ARRANGE_SCRIPT, '--fixture', dir)
  output_path = File.join(dir, 'arrangement.yaml')
  result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, result: result }
end

def run_validate(dir)
  stdout, stderr, status = Open3.capture3('ruby', MOCK_ARRANGE_SCRIPT, '--fixture', dir, '--validate-only')
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus }
end

def load_candidates(dir)
  path = File.join(dir, 'editorial_candidates.yaml')
  YAML.safe_load(File.read(path))
end

# ═══════════════════════════════════════════════════════════════════════════════
# Mock Arrange — emphatic_rant probe
# ═══════════════════════════════════════════════════════════════════════════════

RSpec.describe 'mock_arrange.rb' do
  after(:all) do
    [EMPHATIC_DIR, RAPID_DIR, DEAD_AIR_DIR_A].each do |dir|
      ARRANGEMENT_FILES.each do |f|
        path = File.join(dir, f)
        File.delete(path) if File.exist?(path)
      end
    end
  end

  describe 'arrangement generation (emphatic_rant)' do
    let(:run) { run_arrange(EMPHATIC_DIR) }
    let(:arr) { run[:result] }
    let(:candidates) { load_candidates(EMPHATIC_DIR) }

    it 'exits with code 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'produces valid YAML with version 4' do
      expect(arr['version']).to eq('4')
    end

    it 'uses Branch A with null thesis' do
      expect(arr['branch']).to eq('A')
      expect(arr['selected_thesis']).to be_nil
    end

    it 'includes required top-level fields' do
      %w[version branch selected_thesis input_fingerprint generated_at model chapters].each do |field|
        expect(arr).to have_key(field), "missing field: #{field}"
      end
    end

    it 'produces 2-3 chapters' do
      expect(arr['chapters'].size).to be_between(2, 3)
    end

    it 'has sequential chapter IDs' do
      arr['chapters'].each_with_index do |ch, i|
        expect(ch['id']).to eq(format('chapter_%03d', i + 1))
      end
    end

    it 'every chapter has non-empty segments' do
      arr['chapters'].each do |ch|
        expect(ch['segments']).not_to be_empty, "#{ch['id']} has empty segments"
      end
    end

    it 'every chapter has a title' do
      arr['chapters'].each do |ch|
        expect(ch['title']).to be_a(String)
        expect(ch['title']).not_to be_empty
      end
    end
  end

  describe 'hook selection' do
    let(:arr) { run_arrange(EMPHATIC_DIR)[:result] }

    it 'first segment is a hook' do
      first_seg = arr['chapters'].first['segments'].first
      expect(first_seg['narrative_role']).to eq('hook')
    end

    it 'hook is cand_003 (emphatic/high, shortest primary)' do
      first_seg = arr['chapters'].first['segments'].first
      expect(first_seg['candidate_id']).to eq('cand_003')
    end
  end

  describe 'payoff selection' do
    let(:arr) { run_arrange(EMPHATIC_DIR)[:result] }

    it 'last segment is a payoff' do
      last_seg = arr['chapters'].last['segments'].last
      expect(last_seg['narrative_role']).to eq('payoff')
    end

    it 'payoff is cand_007 (last in chronological order)' do
      last_seg = arr['chapters'].last['segments'].last
      expect(last_seg['candidate_id']).to eq('cand_007')
    end
  end

  describe 'candidate ID validation' do
    let(:arr) { run_arrange(EMPHATIC_DIR)[:result] }
    let(:candidates) { load_candidates(EMPHATIC_DIR) }

    it 'all candidate_ids reference existing candidates' do
      valid_ids = Set.new(candidates['candidates'].map { |c| c['id'] })
      arr['chapters'].each do |ch|
        ch['segments'].each do |seg|
          expect(valid_ids).to include(seg['candidate_id']),
            "#{seg['candidate_id']} not found in editorial_candidates"
        end
      end
    end

    it 'no duplicate candidate_ids across all chapters' do
      all_ids = arr['chapters'].flat_map { |ch| ch['segments'].map { |s| s['candidate_id'] } }
      expect(all_ids.uniq.size).to eq(all_ids.size),
        "Duplicate candidate_ids: #{all_ids.select { |id| all_ids.count(id) > 1 }.uniq}"
    end
  end

  describe 'trim validation' do
    let(:arr) { run_arrange(EMPHATIC_DIR)[:result] }
    let(:candidates) { load_candidates(EMPHATIC_DIR) }

    it 'all trim_choice_ids reference existing trims in their candidate' do
      cands_by_id = candidates['candidates'].each_with_object({}) { |c, h| h[c['id']] = c }
      arr['chapters'].each do |ch|
        ch['segments'].each do |seg|
          cand = cands_by_id[seg['candidate_id']]
          trim_ids = cand['trim_choices'].map { |t| t['id'] }
          expect(trim_ids).to include(seg['trim_choice_id']),
            "#{seg['candidate_id']}: trim #{seg['trim_choice_id']} not found"
        end
      end
    end

    it 'all selected trims are arrangement-safe (boundary_safe AND content_preserved)' do
      cands_by_id = candidates['candidates'].each_with_object({}) { |c, h| h[c['id']] = c }
      arr['chapters'].each do |ch|
        ch['segments'].each do |seg|
          cand = cands_by_id[seg['candidate_id']]
          trim = cand['trim_choices'].find { |t| t['id'] == seg['trim_choice_id'] }
          expect(trim['mechanical_boundary_safe']).to be(true),
            "#{seg['candidate_id']}: trim not mechanical_boundary_safe"
          expect(trim['content_preserved']).to be(true),
            "#{seg['candidate_id']}: trim not content_preserved"
        end
      end
    end
  end

  describe 'exclusion validation' do
    let(:arr) { run_arrange(EMPHATIC_DIR)[:result] }
    let(:candidates) { load_candidates(EMPHATIC_DIR) }

    it 'all exclusion_choice_ids reference existing exclusions' do
      cands_by_id = candidates['candidates'].each_with_object({}) { |c, h| h[c['id']] = c }
      arr['chapters'].each do |ch|
        ch['segments'].each do |seg|
          cand = cands_by_id[seg['candidate_id']]
          ex_ids = (cand['exclusion_choices'] || []).map { |e| e['id'] }
          (seg['exclusion_choice_ids'] || []).each do |eid|
            expect(ex_ids).to include(eid),
              "#{seg['candidate_id']}: exclusion #{eid} not found"
          end
        end
      end
    end

    it 'exclusions are only applied when they leave >= 40% remaining' do
      cands_by_id = candidates['candidates'].each_with_object({}) { |c, h| h[c['id']] = c }
      arr['chapters'].each do |ch|
        ch['segments'].each do |seg|
          next if (seg['exclusion_choice_ids'] || []).empty?
          cand = cands_by_id[seg['candidate_id']]
          raw_dur = cand['e'] - cand['t']
          (seg['exclusion_choice_ids'] || []).each do |eid|
            ex = cand['exclusion_choices'].find { |e| e['id'] == eid }
            ex_dur = ex['end'] - ex['start']
            remaining_ratio = (raw_dur - ex_dur) / raw_dur
            expect(remaining_ratio).to be >= 0.40,
              "#{seg['candidate_id']}: exclusion #{eid} leaves only #{(remaining_ratio * 100).round}%"
          end
        end
      end
    end
  end

  describe 'narrative role validation' do
    let(:arr) { run_arrange(EMPHATIC_DIR)[:result] }

    it 'all narrative_roles are from the allowed enum' do
      valid = %w[hook setup continuation payoff transition claim evidence definition aside]
      arr['chapters'].each do |ch|
        ch['segments'].each do |seg|
          expect(valid).to include(seg['narrative_role']),
            "#{seg['candidate_id']}: invalid role '#{seg['narrative_role']}'"
        end
      end
    end

    it 'contains at least one hook' do
      roles = arr['chapters'].flat_map { |ch| ch['segments'].map { |s| s['narrative_role'] } }
      expect(roles).to include('hook')
    end

    it 'contains at least one payoff' do
      roles = arr['chapters'].flat_map { |ch| ch['segments'].map { |s| s['narrative_role'] } }
      expect(roles).to include('payoff')
    end
  end

  describe 'too-short candidate skipping' do
    let(:arr) { run_arrange(EMPHATIC_DIR)[:result] }

    it 'does not include cand_006 (1.34s < 1.5s threshold)' do
      all_ids = arr['chapters'].flat_map { |ch| ch['segments'].map { |s| s['candidate_id'] } }
      expect(all_ids).not_to include('cand_006')
    end

    it 'lists cand_006 in unused_candidate_audit.cut_for_pacing' do
      expect(arr['unused_candidate_audit']['cut_for_pacing']).to include('cand_006')
    end
  end

  describe 'cluster dedup (explainer_rapid)' do
    let(:run) { run_arrange(RAPID_DIR) }
    let(:arr) { run[:result] }
    # load_candidates must be called after run_arrange to ensure editorial_candidates.yaml exists
    let(:candidates) { run; load_candidates(RAPID_DIR) }

    it 'no two selected candidates share a cluster' do
      cands_by_id = candidates['candidates'].each_with_object({}) { |c, h| h[c['id']] = c }
      used_clusters = Set.new
      arr['chapters'].each do |ch|
        ch['segments'].each do |seg|
          cand = cands_by_id[seg['candidate_id']]
          cluster = cand['cluster']
          next if cluster.nil? || cluster.to_s.strip.empty?
          expect(used_clusters).not_to include(cluster),
            "#{seg['candidate_id']}: cluster '#{cluster}' already used"
          used_clusters << cluster
        end
      end
    end

    it 'passes self-validation' do
      run_arrange(RAPID_DIR)
      result = run_validate(RAPID_DIR)
      expect(result[:exit_code]).to eq(0)
    end
  end

  describe 'deterministic repeatability' do
    it 'produces identical output on consecutive runs (emphatic_rant)' do
      run_arrange(EMPHATIC_DIR)
      first = File.read(File.join(EMPHATIC_DIR, 'arrangement.yaml'))
      run_arrange(EMPHATIC_DIR)
      second = File.read(File.join(EMPHATIC_DIR, 'arrangement.yaml'))
      expect(first).to eq(second)
    end
  end

  describe 'validate-only mode' do
    it 'returns 0 for valid arrangement' do
      run_arrange(EMPHATIC_DIR)
      result = run_validate(EMPHATIC_DIR)
      expect(result[:exit_code]).to eq(0)
      expect(result[:stdout]).to include('0 errors')
    end
  end
end
