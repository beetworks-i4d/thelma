require 'date'
require 'open3'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'

THESIS_SCRIPT = File.expand_path('../../scripts/select_thesis.rb', __dir__)
CB_SCRIPT_TH  = File.expand_path('../../scripts/candidate_builder.rb', __dir__)
REL_SCRIPT_TH = File.expand_path('../../scripts/map_candidate_relationships.rb', __dir__)
AUG_SCRIPT_TH = File.expand_path('../../scripts/augment_candidate_relationships.rb', __dir__)

EMPHATIC_TH = File.expand_path('../fixtures/session6_probe_emphatic_rant', __dir__)

TH_GENERATED = %w[
  candidate_substrate.yaml editorial_candidates.yaml candidate_relationships.yaml
  augmented_candidate_relationships.yaml relationship_augmentation_pending.json
  selected_thesis.yaml thesis_selection_pending.json
  candidate_builder_warnings.log
].freeze

def ensure_thesis_baseline(dir)
  ed_path = File.join(dir, 'editorial_candidates.yaml')
  unless File.exist?(ed_path)
    Open3.capture3('ruby', CB_SCRIPT_TH, '--fixture', dir, '--phase', 'abc')
  end
  rel_path = File.join(dir, 'candidate_relationships.yaml')
  unless File.exist?(rel_path)
    Open3.capture3('ruby', REL_SCRIPT_TH, '--fixture', dir)
  end
  aug_path = File.join(dir, 'augmented_candidate_relationships.yaml')
  unless File.exist?(aug_path)
    Open3.capture3('ruby', AUG_SCRIPT_TH, '--fixture', dir, '--mode', 'pending')
  end
end

def run_thesis(dir, mode: 'mock')
  ensure_thesis_baseline(dir)
  stdout, stderr, status = Open3.capture3('ruby', THESIS_SCRIPT, '--fixture', dir, '--mode', mode)
  output_path = File.join(dir, 'selected_thesis.yaml')
  result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, result: result }
end

def write_thesis_response(dir, theses)
  File.write(
    File.join(dir, 'thesis_selection_response.json'),
    JSON.pretty_generate({ 'theses' => theses })
  )
end

def setup_thesis_tmp(tmp)
  %w[segments_classified.yaml cleaned_transcript.json speech_analysis.json
     relationship_augmentation_response.json].each do |f|
    src = File.join(EMPHATIC_TH, f)
    FileUtils.cp(src, tmp) if File.exist?(src)
  end
  Open3.capture3('ruby', CB_SCRIPT_TH, '--fixture', tmp, '--phase', 'abc')
  Open3.capture3('ruby', REL_SCRIPT_TH, '--fixture', tmp)
  Open3.capture3('ruby', AUG_SCRIPT_TH, '--fixture', tmp, '--mode', 'pending')
end

# ═══════════════════════════════════════════════════════════════════════════════

RSpec.describe 'select_thesis' do
  after(:all) do
    TH_GENERATED.each do |f|
      path = File.join(EMPHATIC_TH, f)
      File.delete(path) if File.exist?(path)
    end
  end

  # ─── Mock mode ──────────────────────────────────────────────────────────────

  describe 'mock mode' do
    let(:run) { run_thesis(EMPHATIC_TH, mode: 'mock') }

    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'writes selected_thesis.yaml' do
      expect(run[:result]).not_to be_nil
    end

    it 'mode is mock' do
      expect(run[:result]['mode']).to eq('mock')
    end

    it 'has at least one thesis' do
      expect(run[:result]['possible_theses'].size).to be >= 1
    end

    it 'selects first thesis as selected_thesis' do
      expect(run[:result]['selected_thesis']).to eq(run[:result]['possible_theses'].first['id'])
    end

    it 'thesis IDs match thesis_NNN format' do
      run[:result]['possible_theses'].each do |t|
        expect(t['id']).to match(/\Athesis_\d{3}\z/)
      end
    end

    it 'all primary_candidates reference valid candidate IDs' do
      editorial = YAML.safe_load(
        File.read(File.join(EMPHATIC_TH, 'editorial_candidates.yaml')),
        permitted_classes: [Date]
      )
      valid_ids = editorial['candidates'].map { |c| c['id'] }
      run[:result]['possible_theses'].each do |t|
        t['primary_candidates'].each do |cid|
          expect(valid_ids).to include(cid)
        end
      end
    end

    it 'has valid confidence on all theses' do
      run[:result]['possible_theses'].each do |t|
        expect(%w[high medium low]).to include(t['confidence'])
      end
    end

    it 'has target_duration_s as positive integer' do
      run[:result]['possible_theses'].each do |t|
        expect(t['target_duration_s']).to be_a(Integer)
        expect(t['target_duration_s']).to be > 0
      end
    end

    it 'has 1-3 throughlines per thesis' do
      run[:result]['possible_theses'].each do |t|
        expect(t['throughlines'].size).to be_between(1, 3)
      end
    end
  end

  # ─── Thesis quality (emphatic_rant) ─────────────────────────────────────────

  describe 'thesis quality for emphatic_rant' do
    let(:run) { run_thesis(EMPHATIC_TH, mode: 'mock') }

    it 'cand_001 is the anchor of the top thesis' do
      top = run[:result]['possible_theses'].first
      expect(top['anchor_candidate']).to eq('cand_001')
    end

    it 'top thesis has high confidence' do
      top = run[:result]['possible_theses'].first
      expect(top['confidence']).to eq('high')
    end

    it 'top thesis includes multiple primary candidates' do
      top = run[:result]['possible_theses'].first
      expect(top['primary_candidates'].size).to be >= 3
    end

    it 'cand_006 (transition) is excluded from top thesis primary' do
      top = run[:result]['possible_theses'].first
      expect(top['primary_candidates']).not_to include('cand_006')
    end

    it 'likely_hook references a valid candidate' do
      top = run[:result]['possible_theses'].first
      editorial = YAML.safe_load(
        File.read(File.join(EMPHATIC_TH, 'editorial_candidates.yaml')),
        permitted_classes: [Date]
      )
      valid_ids = editorial['candidates'].map { |c| c['id'] }
      expect(valid_ids).to include(top['likely_hook'])
    end

    it 'no candidate appears in both primary and excluded' do
      run[:result]['possible_theses'].each do |t|
        primary = Set.new(t['primary_candidates'])
        excluded = Set.new(t['excluded_candidates'] || [])
        expect(primary & excluded).to be_empty
      end
    end

    it 'no candidate appears in both primary and supporting' do
      run[:result]['possible_theses'].each do |t|
        primary = Set.new(t['primary_candidates'])
        supporting = Set.new(t['supporting_candidates'] || [])
        expect(primary & supporting).to be_empty
      end
    end

    it 'rejects single-candidate theses' do
      run[:result]['possible_theses'].each do |t|
        expect(t['primary_candidates'].size).to be >= 2
      end
    end
  end

  # ─── Deterministic repeatability ────────────────────────────────────────────

  describe 'deterministic repeatability' do
    it 'produces identical output on consecutive runs' do
      run1 = run_thesis(EMPHATIC_TH, mode: 'mock')
      run2 = run_thesis(EMPHATIC_TH, mode: 'mock')
      expect(run1[:result]).to eq(run2[:result])
    end
  end

  # ─── Pending mode (no response) ─────────────────────────────────────────────

  describe 'pending mode without response' do
    it 'writes pending JSON and exits 0' do
      Dir.mktmpdir do |tmp|
        setup_thesis_tmp(tmp)
        # Remove response to trigger pending generation
        FileUtils.rm_f(File.join(tmp, 'thesis_selection_response.json'))

        stdout, stderr, status = Open3.capture3(
          'ruby', THESIS_SCRIPT, '--fixture', tmp, '--mode', 'pending'
        )

        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('thesis_selection_pending.json written')

        pending_path = File.join(tmp, 'thesis_selection_pending.json')
        expect(File.exist?(pending_path)).to be true
        data = JSON.parse(File.read(pending_path))
        expect(data).to have_key('instructions')
        expect(data).to have_key('candidates')
        expect(data).to have_key('relationships')
        expect(data).to have_key('baseline_theses')
        expect(data['prompt_version']).to eq('9A.1')
      end
    end
  end

  # ─── Pending mode (with response) ──────────────────────────────────────────

  describe 'pending mode with response' do
    let(:run) { run_thesis(EMPHATIC_TH, mode: 'pending') }

    it 'exits 0' do
      expect(run[:exit_code]).to eq(0)
    end

    it 'mode is augmented' do
      expect(run[:result]['mode']).to eq('augmented')
    end

    it 'uses refined thesis statement from response' do
      top = run[:result]['possible_theses'].first
      expect(top['thesis_statement']).to include('unemployable')
    end

    it 'updated payoff from response' do
      top = run[:result]['possible_theses'].first
      expect(top['likely_payoff']).to eq('cand_007')
    end

    it 'has LLM reasoning' do
      top = run[:result]['possible_theses'].first
      expect(top['reasoning']).to include('coherent argument')
    end
  end

  # ─── Validator rejection ────────────────────────────────────────────────────

  describe 'validator rejection' do
    it 'rejects invented candidate IDs in response' do
      Dir.mktmpdir do |tmp|
        setup_thesis_tmp(tmp)
        write_thesis_response(tmp, [{
          'id' => 'thesis_001',
          'thesis_statement' => 'test',
          'confidence' => 'high',
          'primary_candidates' => ['cand_999'],
          'supporting_candidates' => [],
          'excluded_candidates' => [],
          'throughlines' => [{ 'id' => 'tl_001', 'description' => 'test' }],
          'target_duration_s' => 60,
          'reasoning' => 'test'
        }])
        stdout, stderr, status = Open3.capture3(
          'ruby', THESIS_SCRIPT, '--fixture', tmp, '--mode', 'pending'
        )
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("unknown primary_candidate 'cand_999'")
      end
    end

    it 'rejects invalid confidence in response' do
      Dir.mktmpdir do |tmp|
        setup_thesis_tmp(tmp)
        write_thesis_response(tmp, [{
          'id' => 'thesis_001',
          'thesis_statement' => 'test',
          'confidence' => 'very_high',
          'primary_candidates' => ['cand_001'],
          'supporting_candidates' => [],
          'excluded_candidates' => [],
          'throughlines' => [{ 'id' => 'tl_001', 'description' => 'test' }],
          'target_duration_s' => 60,
          'reasoning' => 'test'
        }])
        stdout, stderr, status = Open3.capture3(
          'ruby', THESIS_SCRIPT, '--fixture', tmp, '--mode', 'pending'
        )
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("invalid confidence 'very_high'")
      end
    end

    it 'rejects candidate in both primary and excluded' do
      Dir.mktmpdir do |tmp|
        setup_thesis_tmp(tmp)
        write_thesis_response(tmp, [{
          'id' => 'thesis_001',
          'thesis_statement' => 'test',
          'confidence' => 'high',
          'primary_candidates' => ['cand_001', 'cand_002'],
          'supporting_candidates' => [],
          'excluded_candidates' => ['cand_001'],
          'throughlines' => [{ 'id' => 'tl_001', 'description' => 'test' }],
          'target_duration_s' => 60,
          'reasoning' => 'test'
        }])
        stdout, stderr, status = Open3.capture3(
          'ruby', THESIS_SCRIPT, '--fixture', tmp, '--mode', 'pending'
        )
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('primary and excluded')
      end
    end

    it 'rejects invented fields' do
      Dir.mktmpdir do |tmp|
        setup_thesis_tmp(tmp)
        write_thesis_response(tmp, [{
          'id' => 'thesis_001',
          'thesis_statement' => 'test',
          'confidence' => 'high',
          'primary_candidates' => ['cand_001', 'cand_002'],
          'supporting_candidates' => [],
          'excluded_candidates' => [],
          'throughlines' => [{ 'id' => 'tl_001', 'description' => 'test' }],
          'target_duration_s' => 60,
          'reasoning' => 'test',
          'mood_board' => 'dark and moody'
        }])
        stdout, stderr, status = Open3.capture3(
          'ruby', THESIS_SCRIPT, '--fixture', tmp, '--mode', 'pending'
        )
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("invented field 'mood_board'")
      end
    end

    it 'rejects unknown likely_hook' do
      Dir.mktmpdir do |tmp|
        setup_thesis_tmp(tmp)
        write_thesis_response(tmp, [{
          'id' => 'thesis_001',
          'thesis_statement' => 'test',
          'confidence' => 'high',
          'primary_candidates' => ['cand_001', 'cand_002'],
          'supporting_candidates' => [],
          'excluded_candidates' => [],
          'likely_hook' => 'cand_999',
          'throughlines' => [{ 'id' => 'tl_001', 'description' => 'test' }],
          'target_duration_s' => 60,
          'reasoning' => 'test'
        }])
        stdout, stderr, status = Open3.capture3(
          'ruby', THESIS_SCRIPT, '--fixture', tmp, '--mode', 'pending'
        )
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("unknown likely_hook 'cand_999'")
      end
    end

    it 'rejects thesis_statement over 50 words' do
      Dir.mktmpdir do |tmp|
        setup_thesis_tmp(tmp)
        long_statement = ('word ' * 51).strip
        write_thesis_response(tmp, [{
          'id' => 'thesis_001',
          'thesis_statement' => long_statement,
          'confidence' => 'high',
          'primary_candidates' => ['cand_001', 'cand_002'],
          'supporting_candidates' => [],
          'excluded_candidates' => [],
          'throughlines' => [{ 'id' => 'tl_001', 'description' => 'test' }],
          'target_duration_s' => 60,
          'reasoning' => 'test'
        }])
        stdout, stderr, status = Open3.capture3(
          'ruby', THESIS_SCRIPT, '--fixture', tmp, '--mode', 'pending'
        )
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('thesis_statement exceeds 50 words')
      end
    end
  end

  # ─── Error handling ─────────────────────────────────────────────────────────

  describe 'error handling' do
    it 'aborts when editorial_candidates.yaml is missing' do
      Dir.mktmpdir do |tmp|
        stdout, stderr, status = Open3.capture3('ruby', THESIS_SCRIPT, '--fixture', tmp)
        expect(status.exitstatus).to eq(1)
      end
    end

    it 'aborts when no relationship file exists' do
      Dir.mktmpdir do |tmp|
        File.write(File.join(tmp, 'editorial_candidates.yaml'), YAML.dump({
          'version' => '1.2', 'candidates' => []
        }))
        stdout, stderr, status = Open3.capture3('ruby', THESIS_SCRIPT, '--fixture', tmp)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('No relationship file found')
      end
    end
  end
end
