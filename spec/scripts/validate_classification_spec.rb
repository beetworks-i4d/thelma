require 'open3'
require 'json'
require 'yaml'
require 'tmpdir'

VALIDATOR_SCRIPT = File.expand_path('../../scripts/validate_classification.rb', __dir__)

def run_validator(yaml_content)
  Dir.mktmpdir do |dir|
    path = File.join(dir, 'segments_classified.yaml')
    File.write(path, yaml_content)
    stdout, stderr, status = Open3.capture3('ruby', VALIDATOR_SCRIPT, path)
    report = JSON.parse(stdout) rescue nil
    { stdout: stdout, stderr: stderr, exit_code: status.exitstatus, report: report }
  end
end

def clean_branch_b
  {
    'transcript_hash' => 'abc123',
    'segments' => [
      { 't' => 10.0, 'e' => 20.0,
        'states' => %w[curiosity aspiration],
        'distillation' => 'guy made ten grand',
        'signal' => 'specific outcome claim',
        'dur' => 'spike',
        'roles' => %w[primary],
        'notes' => 'hook lead',
        'rationale' => 'creates aspiration spike',
        'confidence' => 'high' },
      { 't' => 25.0, 'e' => 35.0,
        'states' => %w[competence],
        'distillation' => 'three step framework',
        'signal' => 'framework reveal',
        'dur' => 'identity',
        'roles' => %w[secondary],
        'notes' => 'framework payoff',
        'rationale' => 'framework creates competence',
        'confidence' => 'medium' }
    ]
  }
end

def clean_branch_a
  {
    'framework' => 'content_psychopharmacology',
    'branch' => 'A',
    'scope' => 'Short #01 — Test short',
    'segments_used' => [
      { 't' => 10.0, 'e' => 25.0,
        'beat' => 'hook',
        'states' => %w[curiosity vindication],
        'signal' => 'revelation hook',
        'confidence' => 'high',
        'rationale' => 'hook matched to script' },
      { 't' => 30.0, 'e' => 40.0,
        'beat' => 'close',
        'states' => %w[competence aspiration],
        'signal' => 'prescription close',
        'confidence' => 'high',
        'rationale' => 'close matched to script' }
    ]
  }
end

RSpec.describe 'validate_classification.rb' do
  describe 'clean input' do
    it 'passes Branch B with exit 0' do
      result = run_validator(clean_branch_b.to_yaml)
      expect(result[:exit_code]).to eq(0)
      expect(result[:report]['valid']).to be true
      expect(result[:report]['branch']).to eq('B')
      expect(result[:report]['violation_counts']['total']).to eq(0)
    end

    it 'passes Branch A with exit 0' do
      result = run_validator(clean_branch_a.to_yaml)
      expect(result[:exit_code]).to eq(0)
      expect(result[:report]['valid']).to be true
      expect(result[:report]['branch']).to eq('A')
    end
  end

  describe 'structural errors (exit 1)' do
    it 'fails when required Branch B field is missing' do
      data = clean_branch_b
      data['segments'][0].delete('dur')
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(1)
      expect(result[:report]['violations']['structural']).to include(
        a_string_matching(/missing required field 'dur'/)
      )
    end

    it 'fails when transcript_hash is missing' do
      data = clean_branch_b
      data.delete('transcript_hash')
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(1)
      expect(result[:report]['violations']['structural']).to include(
        a_string_matching(/missing 'transcript_hash'/)
      )
    end

    it 'fails when segments array is missing' do
      data = { 'transcript_hash' => 'abc' }
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(1)
      expect(result[:report]['violations']['structural']).to include(
        a_string_matching(/missing or invalid 'segments' array/)
      )
    end

    it 'fails when Branch A scope is missing' do
      data = clean_branch_a
      data.delete('scope')
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(1)
      expect(result[:report]['violations']['structural']).to include(
        a_string_matching(/missing 'scope'/)
      )
    end

    it 'fails when scope tag missing on scoped recording' do
      data = clean_branch_b
      data['scopes'] = { 'short_01' => { 'range' => [10, 40] } }
      # segments don't have scope field
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(1)
      expect(result[:report]['violations']['structural']).to include(
        a_string_matching(/missing 'scope'/)
      )
    end
  end

  describe 'taxonomy violations (exit 2)' do
    it 'fails on invalid state name' do
      data = clean_branch_b
      data['segments'][0]['states'] = %w[curiosity hype]
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(2)
      expect(result[:report]['violations']['taxonomy']).to include(
        a_string_matching(/invalid state 'hype'/)
      )
    end

    it 'fails on too many states' do
      data = clean_branch_b
      data['segments'][0]['states'] = %w[curiosity aspiration awe competence]
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(2)
      expect(result[:report]['violations']['taxonomy']).to include(
        a_string_matching(/too many states/)
      )
    end

    it 'fails on invalid durability' do
      data = clean_branch_b
      data['segments'][0]['dur'] = 'permanent'
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(2)
      expect(result[:report]['violations']['taxonomy']).to include(
        a_string_matching(/invalid durability 'permanent'/)
      )
    end

    it 'fails on invalid confidence' do
      data = clean_branch_b
      data['segments'][0]['confidence'] = 'maybe'
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(2)
      expect(result[:report]['violations']['taxonomy']).to include(
        a_string_matching(/invalid confidence 'maybe'/)
      )
    end

    it 'fails on invalid role' do
      data = clean_branch_b
      data['segments'][0]['roles'] = %w[primary hook]
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(2)
      expect(result[:report]['violations']['taxonomy']).to include(
        a_string_matching(/invalid role 'hook'/)
      )
    end

    it 'fails on distillation over 5 words' do
      data = clean_branch_b
      data['segments'][0]['distillation'] = 'this is way too many words here'
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(2)
      expect(result[:report]['violations']['taxonomy']).to include(
        a_string_matching(/distillation too long/)
      )
    end

    it 'fails on invalid narrative_role when present' do
      data = clean_branch_b
      data['segments'][0]['narrative_role'] = 'climax'
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(2)
      expect(result[:report]['violations']['taxonomy']).to include(
        a_string_matching(/invalid narrative_role 'climax'/)
      )
    end

    it 'passes when narrative_role is valid' do
      data = clean_branch_b
      data['segments'][0]['narrative_role'] = 'claim'
      data['segments'][1]['narrative_role'] = 'evidence'
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(0)
    end

    it 'fails on invalid Branch A beat' do
      data = clean_branch_a
      data['segments_used'][0]['beat'] = 'intro'
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(2)
      expect(result[:report]['violations']['taxonomy']).to include(
        a_string_matching(/invalid beat 'intro'/)
      )
    end
  end

  describe 'data errors (exit 3)' do
    it 'fails when t >= e' do
      data = clean_branch_b
      data['segments'][0]['t'] = 20.0
      data['segments'][0]['e'] = 10.0
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(3)
      expect(result[:report]['violations']['data']).to include(
        a_string_matching(/t .* >= e/)
      )
    end

    it 'fails on overlapping segments' do
      data = clean_branch_b
      data['segments'][0]['t'] = 10.0
      data['segments'][0]['e'] = 30.0
      data['segments'][1]['t'] = 25.0
      data['segments'][1]['e'] = 35.0
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(3)
      expect(result[:report]['violations']['data']).to include(
        a_string_matching(/overlap/)
      )
    end

    it 'allows adjacent segments within 10ms tolerance' do
      data = clean_branch_b
      data['segments'][0]['e'] = 25.005
      data['segments'][1]['t'] = 25.0
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(0)
    end
  end

  describe 'exit code priority' do
    it 'returns 1 when both structural and taxonomy errors exist' do
      data = clean_branch_b
      data.delete('transcript_hash')
      data['segments'][0]['states'] = %w[hype]
      result = run_validator(data.to_yaml)
      expect(result[:exit_code]).to eq(1)
    end
  end

  describe 'malformed YAML' do
    it 'returns exit 1 for unparseable YAML' do
      result = run_validator(":\n  - :\n  bad: [unterminated")
      expect(result[:exit_code]).to eq(1)
      expect(result[:report]['violations']['structural'].first).to match(/YAML parse error/)
    end
  end
end
