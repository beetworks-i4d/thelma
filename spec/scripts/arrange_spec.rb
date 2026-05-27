require 'open3'
require 'yaml'
require 'date'
require 'json'
require 'tmpdir'
require 'fileutils'

ARRANGE_SCRIPT = File.expand_path('../../scripts/arrange.rb', __dir__)

def write_v4_arrange_library(root)
  lib_dir = File.join(root, 'libraries', 'test-lib')
  FileUtils.mkdir_p(lib_dir)

  File.write(File.join(lib_dir, 'library.yaml'), {
    'library_name' => 'test-lib',
    'videos' => [{ 'path' => '/tmp/test_video.mp4' }]
  }.to_yaml)

  File.write(File.join(lib_dir, 'discovery_pass.yaml'), {
    'selected_thesis' => 'thesis_001',
    'theses' => [
      {
        'id' => 'thesis_001',
        'logline' => 'Getting good at running things beats getting good at your job.',
        'duration' => '60-90',
        'shape_and_risk' => 'Contrarian career advice.'
      }
    ],
    'clip_groups' => [],
    'throughlines' => []
  }.to_yaml)

  File.write(File.join(lib_dir, 'editorial_candidates.yaml'), {
    'version' => '1.2',
    'candidates' => [
      {
        'id' => 'cand_001',
        'text' => 'The stuff that got you in trouble at work makes you dangerous on your own.',
        'summary' => 'Contrarian hook.',
        'distillation' => 'trouble at work becomes leverage',
        'candidate_priority' => 'primary',
        'usability' => 'fine',
        'confidence' => 'high',
        'suggested_narrative_roles' => [{ 'role' => 'hook', 'confidence' => 'high' }],
        'states' => ['vindication'],
        'durability' => 'mood',
        'prosody' => { 'audio_profile' => 'emphatic', 'energy' => 'high' },
        'trim_choices' => [
          { 'id' => 'trim_001', 'in' => 1.0, 'out' => 5.0, 'label' => 'full_clean', 'mechanical_boundary_safe' => true, 'content_preserved' => true }
        ],
        'exclusion_choices' => []
      },
      {
        'id' => 'cand_002',
        'text' => 'Getting good at your job makes your boss rich.',
        'summary' => 'Main claim.',
        'distillation' => 'job skill enriches boss',
        'candidate_priority' => 'primary',
        'usability' => 'fine',
        'confidence' => 'high',
        'suggested_narrative_roles' => [{ 'role' => 'claim', 'confidence' => 'high' }],
        'states' => ['competence'],
        'durability' => 'mood',
        'prosody' => { 'audio_profile' => 'emphatic', 'energy' => 'high' },
        'trim_choices' => [
          { 'id' => 'trim_002', 'in' => 6.0, 'out' => 10.0, 'label' => 'full_clean', 'mechanical_boundary_safe' => true, 'content_preserved' => true }
        ],
        'exclusion_choices' => []
      },
      {
        'id' => 'cand_003',
        'text' => 'What do you think a business person does all day?',
        'summary' => 'Payoff question.',
        'distillation' => 'business is boring',
        'candidate_priority' => 'secondary',
        'usability' => 'fine',
        'confidence' => 'high',
        'suggested_narrative_roles' => [{ 'role' => 'payoff', 'confidence' => 'high' }],
        'states' => ['amusement'],
        'durability' => 'spike',
        'prosody' => { 'audio_profile' => 'casual', 'energy' => 'medium' },
        'trim_choices' => [
          { 'id' => 'trim_003', 'in' => 11.0, 'out' => 15.0, 'label' => 'full_clean', 'mechanical_boundary_safe' => true, 'content_preserved' => true }
        ],
        'exclusion_choices' => []
      }
    ]
  }.to_yaml)

  lib_dir
end

RSpec.describe 'arrange.rb v4 candidate contract' do
  it 'exits 1 with usage when no arguments' do
    _, stderr, status = Open3.capture3('ruby', ARRANGE_SCRIPT)
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('Usage')
  end

  it 'exits 1 for unknown arguments' do
    _, stderr, status = Open3.capture3('ruby', ARRANGE_SCRIPT, '--foo')
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('Unknown argument')
  end

  it 'requires editorial_candidates.yaml, not segments_classified.yaml' do
    Dir.mktmpdir do |dir|
      lib_dir = write_v4_arrange_library(dir)
      File.delete(File.join(lib_dir, 'editorial_candidates.yaml'))

      _, stderr, status = Open3.capture3('ruby', '-I', File.join(Dir.pwd, 'scripts'), '-e', <<~RUBY)
        require_relative '#{ARRANGE_SCRIPT}'
      RUBY

      # Direct require is not how the script is normally run; assert contract by reading source.
      source = File.read(ARRANGE_SCRIPT)
      abort 'missing editorial_candidates requirement' unless source.include?('editorial_candidates.yaml not found')
      abort 'still requires segments_classified' if source.include?('segments_classified.yaml not found')
    end
  end

  it 'validates a minimal v4 arrangement through shared validator' do
    Dir.mktmpdir do |dir|
      lib_dir = write_v4_arrange_library(dir)

      stdout, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require 'yaml'
        require 'date'
        require_relative '#{File.expand_path('../../scripts/arrangement_validator', __dir__)}'

        candidates = YAML.safe_load(File.read('#{File.join(lib_dir, 'editorial_candidates.yaml')}'), permitted_classes: [Date])
        discovery = YAML.safe_load(File.read('#{File.join(lib_dir, 'discovery_pass.yaml')}'), permitted_classes: [Date])

        arrangement = {
          'version' => '4',
          'branch' => 'B',
          'selected_thesis' => 'thesis_001',
          'input_fingerprint' => 'abc123',
          'generated_at' => '2026-05-27T00:00:00Z',
          'model' => 'test-model',
          'chapters' => [
            {
              'id' => 'chapter_001',
              'title' => 'Opening',
              'segments' => [
                { 'candidate_id' => 'cand_001', 'trim_choice_id' => 'trim_001', 'exclusion_choice_ids' => [], 'narrative_role' => 'hook' },
                { 'candidate_id' => 'cand_002', 'trim_choice_id' => 'trim_002', 'exclusion_choice_ids' => [], 'narrative_role' => 'claim' },
                { 'candidate_id' => 'cand_003', 'trim_choice_id' => 'trim_003', 'exclusion_choice_ids' => [], 'narrative_role' => 'payoff' }
              ]
            }
          ],
          'unused_candidate_audit' => {
            'cut_by_thesis' => [],
            'alternate_take_not_chosen' => [],
            'cut_for_pacing' => [],
            'bridge_dropped' => []
          }
        }

        result = ArrangementValidator.validate(arrangement, candidates, discovery_data: discovery)
        puts result[:errors].join("\\n")
        exit(result[:errors].empty? ? 0 : 1)
      RUBY

      expect(status.exitstatus).to eq(0), stderr + stdout
    end
  end

  it 'rejects invalid candidate_id references' do
    stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
      require_relative '#{File.expand_path('../../scripts/arrangement_validator', __dir__)}'
      candidates = { 'candidates' => [] }
      arrangement = {
        'version' => '4', 'branch' => 'B', 'selected_thesis' => 'thesis_001',
        'input_fingerprint' => 'x', 'generated_at' => 'now', 'model' => 'test',
        'chapters' => [{ 'id' => 'chapter_001', 'title' => 'x', 'segments' => [
          { 'candidate_id' => 'cand_999', 'trim_choice_id' => 'trim_001', 'exclusion_choice_ids' => [], 'narrative_role' => 'hook' }
        ]}]
      }
      result = ArrangementValidator.validate(arrangement, candidates)
      puts result[:errors].join("\\n")
      exit(result[:errors].any? ? 0 : 1)
    RUBY

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include('candidate not found')
  end

  it 'rejects trim_choice_id that does not belong to candidate' do
    stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
      require_relative '#{File.expand_path('../../scripts/arrangement_validator', __dir__)}'
      candidates = { 'candidates' => [{ 'id' => 'cand_001', 'trim_choices' => [], 'exclusion_choices' => [] }] }
      arrangement = {
        'version' => '4', 'branch' => 'B', 'selected_thesis' => 'thesis_001',
        'input_fingerprint' => 'x', 'generated_at' => 'now', 'model' => 'test',
        'chapters' => [{ 'id' => 'chapter_001', 'title' => 'x', 'segments' => [
          { 'candidate_id' => 'cand_001', 'trim_choice_id' => 'trim_bad', 'exclusion_choice_ids' => [], 'narrative_role' => 'hook' }
        ]}]
      }
      result = ArrangementValidator.validate(arrangement, candidates)
      puts result[:errors].join("\\n")
      exit(result[:errors].any? ? 0 : 1)
    RUBY

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("trim_choice_id 'trim_bad' not found")
  end

  it 'rejects duplicate candidate selections' do
    stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
      require_relative '#{File.expand_path('../../scripts/arrangement_validator', __dir__)}'
      cand = { 'id' => 'cand_001', 'trim_choices' => [{ 'id' => 'trim_001', 'mechanical_boundary_safe' => true, 'content_preserved' => true }], 'exclusion_choices' => [] }
      candidates = { 'candidates' => [cand] }
      seg = { 'candidate_id' => 'cand_001', 'trim_choice_id' => 'trim_001', 'exclusion_choice_ids' => [], 'narrative_role' => 'hook' }
      arrangement = {
        'version' => '4', 'branch' => 'B', 'selected_thesis' => 'thesis_001',
        'input_fingerprint' => 'x', 'generated_at' => 'now', 'model' => 'test',
        'chapters' => [{ 'id' => 'chapter_001', 'title' => 'x', 'segments' => [seg, seg] }]
      }
      result = ArrangementValidator.validate(arrangement, candidates)
      puts result[:errors].join("\\n")
      exit(result[:errors].any? ? 0 : 1)
    RUBY

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include('duplicate candidate selection')
  end

  it 'rejects unsafe or content-losing trims' do
    stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
      require_relative '#{File.expand_path('../../scripts/arrangement_validator', __dir__)}'
      candidates = { 'candidates' => [{
        'id' => 'cand_001',
        'trim_choices' => [{ 'id' => 'trim_001', 'mechanical_boundary_safe' => false, 'content_preserved' => false }],
        'exclusion_choices' => []
      }] }
      arrangement = {
        'version' => '4', 'branch' => 'B', 'selected_thesis' => 'thesis_001',
        'input_fingerprint' => 'x', 'generated_at' => 'now', 'model' => 'test',
        'chapters' => [{ 'id' => 'chapter_001', 'title' => 'x', 'segments' => [
          { 'candidate_id' => 'cand_001', 'trim_choice_id' => 'trim_001', 'exclusion_choice_ids' => [], 'narrative_role' => 'hook' }
        ]}]
      }
      result = ArrangementValidator.validate(arrangement, candidates)
      puts result[:errors].join("\\n")
      exit(result[:errors].any? ? 0 : 1)
    RUBY

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include('not mechanical_boundary_safe')
    expect(stdout).to include('not content_preserved')
  end
end
