require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'

# Load the module under test
require_relative '../../scripts/load_profile'

RSpec.describe 'load_profile' do
  describe 'load_profile_by_name' do
    it 'returns default hash when name is _default' do
      profile = load_profile_by_name('_default')
      expect(profile['name']).to eq('_default')
      expect(profile['auto_remove_pauses_above']).to eq(800)
      expect(profile['min_segment_duration']).to eq(2)
      expect(profile['snap_end_tolerance_ms']).to eq(100)
      expect(profile['content_type']).to eq('auto')
    end

    it 'returns merged hash with dylan overrides' do
      profile = load_profile_by_name('dylan')
      expect(profile['name']).to eq('dylan')
      expect(profile['content_type']).to eq('talking_head_business')
      expect(profile['primary_state_preferences']).to eq(%w[vindication aspiration competence])
      expect(profile['template_affinities']).to include('three_item_framework')
    end

    it 'preserves default values not overridden by dylan' do
      profile = load_profile_by_name('dylan')
      expect(profile['auto_remove_pauses_above']).to eq(800)
      expect(profile['min_segment_duration']).to eq(2)
      expect(profile['snap_end_tolerance_ms']).to eq(100)
      expect(profile['closing_durability_preference']).to eq('identity')
      expect(profile['include_ctas']).to be true
    end

    it 'deep merges nested hashes' do
      profile = load_profile_by_name('_default')
      expect(profile.dig('format_defaults', 'shorts', 'orientation')).to eq('vertical')
      expect(profile.dig('format_defaults', 'longform', 'target_duration')).to eq('480-900')
    end

    it 'loads ivan profile' do
      profile = load_profile_by_name('ivan')
      expect(profile['name']).to eq('ivan')
      expect(profile['content_type']).to eq('talking_head_business')
      expect(profile['primary_state_preferences']).to eq(%w[competence vindication curiosity])
      expect(profile['template_affinities']).to include('hidden_truth_reveal')
    end

    it 'returns defaults with warning for nonexistent profile' do
      profile = load_profile_by_name('nonexistent-client')
      expect(profile['name']).to eq('_default')
      expect(profile['content_type']).to eq('auto')
    end
  end

  describe 'load_profile (auto-match)' do
    it 'auto-matches dylan from library name dylan-shorts-batch-1' do
      profile = load_profile('dylan-shorts-batch-1')
      expect(profile['name']).to eq('dylan')
      expect(profile['content_type']).to eq('talking_head_business')
    end

    it 'auto-matches dylan case-insensitively from folder name' do
      profile = load_profile('Dylan Shorts Batch 1')
      expect(profile['name']).to eq('dylan')
    end

    it 'returns _default for unknown project name' do
      profile = load_profile('unknown-project-xyz')
      expect(profile['name']).to eq('_default')
    end

    it 'auto-matches ivan from library name ivan-brand-strategy' do
      profile = load_profile('ivan-brand-strategy')
      expect(profile['name']).to eq('ivan')
    end
  end

  describe 'deep_merge' do
    it 'overrides scalar values' do
      base = { 'a' => 1, 'b' => 2 }
      override = { 'a' => 10 }
      result = deep_merge(base, override)
      expect(result['a']).to eq(10)
      expect(result['b']).to eq(2)
    end

    it 'recursively merges nested hashes' do
      base = { 'x' => { 'y' => 1, 'z' => 2 } }
      override = { 'x' => { 'y' => 99 } }
      result = deep_merge(base, override)
      expect(result['x']['y']).to eq(99)
      expect(result['x']['z']).to eq(2)
    end

    it 'adds new keys from override' do
      base = { 'a' => 1 }
      override = { 'b' => 2 }
      result = deep_merge(base, override)
      expect(result['a']).to eq(1)
      expect(result['b']).to eq(2)
    end

    it 'replaces arrays entirely (no array merge)' do
      base = { 'list' => [1, 2, 3] }
      override = { 'list' => [4, 5] }
      result = deep_merge(base, override)
      expect(result['list']).to eq([4, 5])
    end
  end

  describe 'find_profile_match' do
    it 'matches dylan from dylan-shorts-batch-1' do
      expect(find_profile_match('dylan-shorts-batch-1')).to eq('dylan')
    end

    it 'matches ivan from Ivan Brand Strategy' do
      expect(find_profile_match('Ivan Brand Strategy')).to eq('ivan')
    end

    it 'returns nil for no match' do
      expect(find_profile_match('totally-unknown-client')).to be_nil
    end
  end

  describe '--profile flag on build_structure_cut.rb' do
    let(:build_script) { File.expand_path('../../scripts/build_structure_cut.rb', __dir__) }
    let(:fixture_video) { File.expand_path('../fixtures/media/MVI_0309_720p.mov', __dir__) }

    it 'accepts --profile flag without error' do
      Dir.mktmpdir do |dir|
        config = {
          'video_path' => fixture_video,
          'output_dir' => dir,
          'editor' => 'fcp7',
          'name' => 'Test Cut',
          'clips' => [{ 'video_start' => 1.0, 'video_end' => 3.0 }]
        }
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', build_script, '--profile', 'dylan', yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('Profile: dylan')
      end
    end
  end
end
