require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

DETECT_SCRIPT = File.expand_path('../../scripts/detect_structure.rb', __dir__)
TEMPLATES_DIR = File.expand_path('../../templates/story_structures', __dir__)

def run_detect(segments_yaml, best_fit_score: nil)
  Dir.mktmpdir do |dir|
    segments_path = File.join(dir, 'segments_classified.yaml')
    File.write(segments_path, segments_yaml.to_yaml)

    args = ['ruby', DETECT_SCRIPT, segments_path]
    args += ['--best-fit-score', best_fit_score.to_s] if best_fit_score

    stdout, stderr, status = Open3.capture3(*args)
    output_path = File.join(dir, 'structure_detected.yaml')
    result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result }
  end
end

def run_save_template(detected_yaml)
  Dir.mktmpdir do |dir|
    detected_path = File.join(dir, 'structure_detected.yaml')
    File.write(detected_path, detected_yaml.to_yaml)

    # Create a local templates dir to avoid polluting real templates
    templates_dir = File.join(dir, 'templates', 'story_structures')
    FileUtils.mkdir_p(templates_dir)

    # We need to run with the script pointing to our temp templates dir.
    # Since the script uses __FILE__ relative path, we'll copy the script and adjust.
    # Simpler: just run the save and check what it tries to write.
    args = ['ruby', DETECT_SCRIPT, '--save-template', detected_path]
    stdout, stderr, status = Open3.capture3(*args)

    # The script writes to the real templates dir, so we check there
    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus }
  end
end

def make_seg(t:, e:, states:, distillation:, dur: 'identity', confidence: 'high',
             roles: ['secondary'], signal: 'test', notes: 'test')
  { 't' => t, 'e' => e, 'states' => states, 'distillation' => distillation,
    'dur' => dur, 'roles' => roles, 'confidence' => confidence,
    'signal' => signal, 'notes' => notes, 'rationale' => 'test' }
end

# Coherent walkthrough structure (like dylan-002)
def coherent_segments
  {
    'transcript_hash' => 'coherent_test',
    'segments' => [
      make_seg(t: 10.0, e: 22.0, states: %w[curiosity aspiration], distillation: 'ranking five business models', dur: 'identity'),
      make_seg(t: 25.0, e: 38.0, states: %w[competence], distillation: 'framework for comparison criteria', dur: 'mood'),
      make_seg(t: 42.0, e: 55.0, states: %w[vindication], distillation: 'affiliate marketing low ceiling', dur: 'identity'),
      make_seg(t: 58.0, e: 72.0, states: %w[curiosity], distillation: 'dropshipping oversaturated market risk', dur: 'mood'),
      make_seg(t: 75.0, e: 88.0, states: %w[competence], distillation: 'FBA inventory capital trap', dur: 'identity'),
      make_seg(t: 92.0, e: 106.0, states: %w[aspiration competence], distillation: 'freelancing scales but slowly', dur: 'mood'),
      make_seg(t: 110.0, e: 125.0, states: %w[vindication aspiration], distillation: 'drop servicing wins ranking', dur: 'identity'),
      make_seg(t: 128.0, e: 140.0, states: %w[competence], distillation: 'start drop servicing today', dur: 'identity'),
    ]
  }
end

# All filler — distillations too short to be substantive (< 6 chars)
def incoherent_segments
  {
    'transcript_hash' => 'incoherent_test',
    'segments' => [
      make_seg(t: 10.0, e: 20.0, states: %w[calm], distillation: 'um ok', dur: 'spike', confidence: 'low'),
      make_seg(t: 25.0, e: 35.0, states: %w[amusement], distillation: 'yeah', dur: 'spike', confidence: 'low'),
      make_seg(t: 40.0, e: 50.0, states: %w[calm], distillation: 'hmm', dur: 'spike', confidence: 'low'),
    ]
  }
end

# Single segment
def single_segment
  {
    'transcript_hash' => 'single_test',
    'segments' => [
      make_seg(t: 10.0, e: 25.0, states: %w[curiosity], distillation: 'interesting observation about markets', dur: 'identity'),
    ]
  }
end

# All same state
def uniform_state_segments
  {
    'transcript_hash' => 'uniform_test',
    'segments' => [
      make_seg(t: 10.0, e: 22.0, states: %w[competence], distillation: 'step one find freelancer', dur: 'identity'),
      make_seg(t: 25.0, e: 38.0, states: %w[competence], distillation: 'step two pick niche', dur: 'identity'),
      make_seg(t: 42.0, e: 55.0, states: %w[competence], distillation: 'step three send outreach', dur: 'identity'),
      make_seg(t: 58.0, e: 70.0, states: %w[competence], distillation: 'step four close client', dur: 'identity'),
    ]
  }
end

RSpec.describe 'detect_structure.rb' do
  describe 'viability prompt generation' do
    it 'generates viability prompt from distillation list' do
      result = run_detect(coherent_segments)
      expect(result[:exit_code]).to eq(0)
      prompt = result[:result]['viability_prompt']
      expect(prompt).to include('coherent through-line')
      expect(prompt).to include('YES')
      expect(prompt).to include('PARTIAL')
      expect(prompt).to include('NO')
    end

    it 'includes distillations in transcript order' do
      result = run_detect(coherent_segments)
      prompt = result[:result]['viability_prompt']
      expect(prompt).to include('ranking five business models')
      expect(prompt).to include('drop servicing wins ranking')
      # First distillation should appear before last
      first_pos = prompt.index('ranking five business models')
      last_pos = prompt.index('drop servicing wins ranking')
      expect(first_pos).to be < last_pos
    end

    it 'includes durability tags in distillation lines' do
      result = run_detect(coherent_segments)
      prompt = result[:result]['viability_prompt']
      expect(prompt).to include('[identity]')
      expect(prompt).to include('[mood]')
    end

    it 'leaves viability nil for agent to fill' do
      result = run_detect(coherent_segments)
      expect(result[:result]['viability']).to be_nil
      expect(result[:result]['viability_reason']).to be_nil
    end
  end

  describe 'viability response parsing (YES/PARTIAL/NO)' do
    # The script generates prompts; it doesn't parse LLM responses.
    # These tests verify the output schema supports all three viability states.

    it 'output schema supports YES viability (agent fills)' do
      result = run_detect(coherent_segments)
      expect(result[:result]).to have_key('viability')
      expect(result[:result]).to have_key('viability_reason')
    end

    it 'output schema supports synthesis prompt for YES/PARTIAL' do
      result = run_detect(coherent_segments)
      expect(result[:result]).to have_key('synthesis_prompt')
      expect(result[:result]['synthesis_prompt']).not_to be_nil
    end

    it 'output schema supports synthesized_template (agent fills)' do
      result = run_detect(coherent_segments)
      expect(result[:result]).to have_key('synthesized_template')
      expect(result[:result]['synthesized_template']).to be_nil
    end

    it 'auto-sets viability NO when no substantive distillations' do
      result = run_detect(incoherent_segments)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['viability']).to eq('NO')
      expect(result[:result]['viability_reason']).to include('No substantive')
      expect(result[:result]['viability_prompt']).to be_nil
      expect(result[:result]['synthesis_prompt']).to be_nil
    end
  end

  describe 'synthesis prompt generation' do
    it 'generates synthesis prompt with state and durability data' do
      result = run_detect(coherent_segments)
      prompt = result[:result]['synthesis_prompt']
      expect(prompt).to include('narrative structure')
      expect(prompt).to include('beats')
      expect(prompt).to include('position')
    end

    it 'includes state labels in synthesis prompt' do
      result = run_detect(coherent_segments)
      prompt = result[:result]['synthesis_prompt']
      expect(prompt).to include('curiosity')
      expect(prompt).to include('competence')
      expect(prompt).to include('vindication')
    end

    it 'includes confidence levels in synthesis prompt' do
      result = run_detect(coherent_segments)
      prompt = result[:result]['synthesis_prompt']
      expect(prompt).to include('high')
    end

    it 'includes normalized positions in synthesis prompt' do
      result = run_detect(coherent_segments)
      prompt = result[:result]['synthesis_prompt']
      # Should have position values like 0.0, 0.5, 1.0
      expect(prompt).to match(/position: \d+\.\d+/)
    end

    it 'specifies valid position labels' do
      result = run_detect(coherent_segments)
      prompt = result[:result]['synthesis_prompt']
      expect(prompt).to include('early')
      expect(prompt).to include('early_mid')
      expect(prompt).to include('mid')
      expect(prompt).to include('late_mid')
      expect(prompt).to include('late')
    end

    it 'requests 4-8 beats' do
      result = run_detect(coherent_segments)
      prompt = result[:result]['synthesis_prompt']
      expect(prompt).to include('4-8 beats')
    end
  end

  describe 'synthesized template schema validation' do
    # Test that --save-template validates the schema

    it 'aborts when synthesized_template is missing' do
      detected = { 'viability' => 'YES', 'synthesized_template' => nil }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'structure_detected.yaml')
        File.write(path, detected.to_yaml)
        _, stderr, status = Open3.capture3('ruby', DETECT_SCRIPT, '--save-template', path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('No synthesized_template')
      end
    end

    it 'aborts when template has no name' do
      detected = {
        'viability' => 'YES',
        'synthesized_template' => {
          'name' => '',
          'description' => 'test',
          'beats' => [{ 'id' => 'hook', 'description' => 'test', 'keywords' => ['test'], 'position' => 'early' }]
        }
      }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'structure_detected.yaml')
        File.write(path, detected.to_yaml)
        _, stderr, status = Open3.capture3('ruby', DETECT_SCRIPT, '--save-template', path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('no name')
      end
    end

    it 'aborts when template has no beats' do
      detected = {
        'viability' => 'YES',
        'synthesized_template' => {
          'name' => 'test_template',
          'description' => 'test',
          'beats' => []
        }
      }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'structure_detected.yaml')
        File.write(path, detected.to_yaml)
        _, stderr, status = Open3.capture3('ruby', DETECT_SCRIPT, '--save-template', path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('no beats')
      end
    end
  end

  describe 'save-to-library file writing' do
    after(:each) do
      # Clean up any test templates that were saved to the real templates dir
      test_file = File.join(TEMPLATES_DIR, 'test_comparative_walkthrough.yaml')
      File.delete(test_file) if File.exist?(test_file)
    end

    it 'writes template to templates/story_structures/' do
      detected = {
        'viability' => 'YES',
        'synthesized_template' => {
          'name' => 'test_comparative_walkthrough',
          'description' => 'Compare multiple items and reveal ranking',
          'beats' => [
            { 'id' => 'hook', 'description' => 'Set up comparison', 'keywords' => %w[ranking compare five], 'position' => 'early' },
            { 'id' => 'item_one', 'description' => 'First comparison', 'keywords' => %w[affiliate marketing], 'position' => 'early_mid' },
            { 'id' => 'reveal', 'description' => 'Ranking payoff', 'keywords' => %w[wins best ranking], 'position' => 'late' }
          ],
          'confidence' => 0.8,
          'reasoning' => 'Clear comparative structure'
        }
      }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'structure_detected.yaml')
        File.write(path, detected.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', DETECT_SCRIPT, '--save-template', path)
        expect(status.exitstatus).to eq(0)

        saved_path = File.join(TEMPLATES_DIR, 'test_comparative_walkthrough.yaml')
        expect(File.exist?(saved_path)).to be true

        saved = YAML.safe_load(File.read(saved_path))
        expect(saved['name']).to eq('test_comparative_walkthrough')
        expect(saved['beats'].size).to eq(3)
        expect(saved['beats'].first['id']).to eq('hook')
        expect(saved['beats'].first['keywords']).to include('ranking')
        expect(saved['beats'].first['position']).to eq('early')
      end
    end

    it 'produces match_templates.rb-compatible schema' do
      detected = {
        'viability' => 'YES',
        'synthesized_template' => {
          'name' => 'test_comparative_walkthrough',
          'description' => 'Test template for validation',
          'beats' => [
            { 'id' => 'hook', 'description' => 'Opening', 'keywords' => %w[ranking], 'position' => 'early' },
            { 'id' => 'close', 'description' => 'Closing', 'keywords' => %w[wins], 'position' => 'late' }
          ]
        }
      }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'structure_detected.yaml')
        File.write(path, detected.to_yaml)
        Open3.capture3('ruby', DETECT_SCRIPT, '--save-template', path)

        saved_path = File.join(TEMPLATES_DIR, 'test_comparative_walkthrough.yaml')
        saved = YAML.safe_load(File.read(saved_path))

        # Verify all fields match_templates.rb expects
        expect(saved).to have_key('name')
        expect(saved).to have_key('description')
        expect(saved).to have_key('beats')
        saved['beats'].each do |beat|
          expect(beat).to have_key('id')
          expect(beat).to have_key('description')
          expect(beat).to have_key('keywords')
          expect(beat).to have_key('position')
          expect(beat['keywords']).to be_an(Array)
          expect(%w[early early_mid mid late_mid late]).to include(beat['position'])
        end

        # Should NOT have confidence/reasoning (those are detection metadata, not template fields)
        expect(saved).not_to have_key('confidence')
        expect(saved).not_to have_key('reasoning')
      end
    end

    it 'aborts if template file already exists' do
      detected = {
        'viability' => 'YES',
        'synthesized_template' => {
          'name' => 'test_comparative_walkthrough',
          'description' => 'test',
          'beats' => [{ 'id' => 'hook', 'description' => 'test', 'keywords' => ['test'], 'position' => 'early' }]
        }
      }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'structure_detected.yaml')
        File.write(path, detected.to_yaml)

        # First save succeeds
        _, _, status1 = Open3.capture3('ruby', DETECT_SCRIPT, '--save-template', path)
        expect(status1.exitstatus).to eq(0)

        # Second save aborts (file exists)
        _, stderr, status2 = Open3.capture3('ruby', DETECT_SCRIPT, '--save-template', path)
        expect(status2.exitstatus).to eq(1)
        expect(stderr).to include('already exists')
      end
    end
  end

  describe 'trigger conditions' do
    it 'includes best_fit_score when provided' do
      result = run_detect(coherent_segments, best_fit_score: 52)
      expect(result[:result]['best_fit_score']).to eq(52)
    end

    it 'reports best_fit_score in stderr' do
      result = run_detect(coherent_segments, best_fit_score: 48)
      expect(result[:stderr]).to include('48%')
      expect(result[:stderr]).to include('threshold')
    end

    it 'works without --best-fit-score flag' do
      result = run_detect(coherent_segments)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['best_fit_score']).to be_nil
    end
  end

  describe 'output schema' do
    it 'includes all required top-level fields' do
      result = run_detect(coherent_segments)
      %w[generated_at source total_segments substantive_segments viability viability_reason
         viability_prompt synthesis_prompt synthesized_template best_fit_score
         distillation_sequence].each do |field|
        expect(result[:result]).to have_key(field), "missing field: #{field}"
      end
    end

    it 'includes distillation_sequence with correct fields' do
      result = run_detect(coherent_segments)
      seq = result[:result]['distillation_sequence']
      expect(seq).to be_an(Array)
      expect(seq.size).to be > 0
      seq.each do |d|
        expect(d).to have_key('t')
        expect(d).to have_key('distillation')
        expect(d).to have_key('dur')
        expect(d).to have_key('states')
      end
    end

    it 'reports segment counts correctly' do
      result = run_detect(coherent_segments)
      expect(result[:result]['total_segments']).to eq(8)
      expect(result[:result]['substantive_segments']).to eq(8)
    end

    it 'outputs path to stdout' do
      result = run_detect(coherent_segments)
      expect(result[:stdout]).to end_with('structure_detected.yaml')
    end

    it 'shows report in stderr' do
      result = run_detect(coherent_segments)
      expect(result[:stderr]).to include('STRUCTURE DETECTION')
      expect(result[:stderr]).to include('Viability prompt generated')
      expect(result[:stderr]).to include('Synthesis prompt generated')
    end
  end

  describe 'edge cases' do
    it 'handles empty segments array' do
      segs = { 'transcript_hash' => 'test', 'segments' => [] }
      result = run_detect(segs)
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include('No segments')
    end

    it 'handles single segment' do
      result = run_detect(single_segment)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['substantive_segments']).to eq(1)
      expect(result[:result]['viability_prompt']).to be_a(String)
      expect(result[:result]['synthesis_prompt']).to be_a(String)
    end

    it 'handles all segments with same state' do
      result = run_detect(uniform_state_segments)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['substantive_segments']).to eq(4)
      # Should still generate prompts — the LLM decides viability
      expect(result[:result]['viability_prompt']).to include('step one')
      expect(result[:result]['synthesis_prompt']).to include('competence')
    end

    it 'filters filler distillations from prompts' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[calm], distillation: 'um ok', dur: 'spike'),
          make_seg(t: 25.0, e: 38.0, states: %w[curiosity], distillation: 'ranking five business models', dur: 'identity'),
          make_seg(t: 42.0, e: 55.0, states: %w[calm], distillation: 'yeah', dur: 'spike'),
        ]
      }
      result = run_detect(segs)
      expect(result[:result]['total_segments']).to eq(3)
      expect(result[:result]['substantive_segments']).to eq(1) # only "ranking five business models"
      expect(result[:result]['viability_prompt']).to include('ranking five business models')
      expect(result[:result]['viability_prompt']).not_to include('um ok')
    end

    it 'aborts on Branch A classification' do
      segs = {
        'framework' => 'content_psychopharmacology',
        'branch' => 'A',
        'scope' => 'Short #01',
        'segments_used' => [
          { 't' => 10.0, 'e' => 25.0, 'beat' => 'hook', 'states' => %w[curiosity],
            'signal' => 'test', 'confidence' => 'high', 'rationale' => 'test' }
        ]
      }
      result = run_detect(segs)
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include('Branch A')
    end

    it 'aborts on missing file' do
      _, stderr, status = Open3.capture3('ruby', DETECT_SCRIPT, '/nonexistent.yaml')
      expect(status.exitstatus).to eq(1)
    end

    it 'handles segments with nil distillation gracefully' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          { 't' => 10.0, 'e' => 20.0, 'states' => %w[curiosity], 'distillation' => nil,
            'dur' => 'identity', 'roles' => %w[primary], 'confidence' => 'high',
            'signal' => 'test', 'notes' => 'test', 'rationale' => 'test' },
          make_seg(t: 25.0, e: 38.0, states: %w[competence], distillation: 'valid distillation content here'),
        ]
      }
      result = run_detect(segs)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['total_segments']).to eq(2)
      expect(result[:result]['substantive_segments']).to eq(1)
    end

    it 'handles all filler segments (no substantive content)' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[calm], distillation: 'um', dur: 'spike'),
          make_seg(t: 25.0, e: 35.0, states: %w[calm], distillation: 'ok so', dur: 'spike'),
        ]
      }
      result = run_detect(segs)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['viability']).to eq('NO')
      expect(result[:result]['viability_prompt']).to be_nil
      expect(result[:result]['synthesis_prompt']).to be_nil
    end
  end

  describe 'distillation sequence' do
    it 'preserves transcript order in distillation_sequence' do
      result = run_detect(coherent_segments)
      seq = result[:result]['distillation_sequence']
      t_values = seq.map { |d| d['t'] }
      expect(t_values).to eq(t_values.sort)
    end

    it 'excludes filler from distillation_sequence' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[calm], distillation: 'um', dur: 'spike'),
          make_seg(t: 25.0, e: 38.0, states: %w[curiosity], distillation: 'ranking business models here', dur: 'identity'),
        ]
      }
      result = run_detect(segs)
      seq = result[:result]['distillation_sequence']
      expect(seq.size).to eq(1)
      expect(seq.first['distillation']).to eq('ranking business models here')
    end
  end
end
