require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

MINE_SCRIPT = File.expand_path('../../scripts/mine_content.rb', __dir__)

def run_mine(segments_yaml, library_name: nil)
  Dir.mktmpdir do |dir|
    if library_name
      # Create library directory structure for --library mode
      lib_dir = File.join(dir, 'libraries', library_name)
      FileUtils.mkdir_p(lib_dir)
      segments_path = File.join(lib_dir, 'segments_classified.yaml')
      File.write(segments_path, segments_yaml.to_yaml)

      args = ['ruby', MINE_SCRIPT, '--library', library_name]
      stdout, stderr, status = Open3.capture3(*args, chdir: dir)
      output_path = File.join(lib_dir, 'content_inventory.yaml')
    else
      segments_path = File.join(dir, 'segments_classified.yaml')
      File.write(segments_path, segments_yaml.to_yaml)

      args = ['ruby', MINE_SCRIPT, segments_path]
      stdout, stderr, status = Open3.capture3(*args)
      output_path = File.join(dir, 'content_inventory.yaml')
    end

    result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result }
  end
end

def make_seg(t:, e:, states:, distillation:, dur: 'identity', confidence: 'high',
             roles: ['secondary'], signal: 'test', notes: 'test')
  { 't' => t, 'e' => e, 'states' => states, 'distillation' => distillation,
    'dur' => dur, 'roles' => roles, 'confidence' => confidence,
    'signal' => signal, 'notes' => notes, 'rationale' => 'test' }
end

# Base test data: segments spanning multiple thematic clusters
def mining_segments
  {
    'transcript_hash' => 'mine_test_123',
    'segments' => [
      # Cluster A: affiliate marketing (t=10-55, shared word "affiliate")
      make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'tried affiliate marketing first', dur: 'identity', confidence: 'high'),
      make_seg(t: 25.0, e: 35.0, states: %w[vindication], distillation: 'affiliate commissions too low', dur: 'mood', confidence: 'high'),
      make_seg(t: 40.0, e: 55.0, states: %w[competence], distillation: 'affiliate plans dead end', dur: 'identity', confidence: 'high'),

      # Cluster B: drop servicing (t=90-125, 35s gap from A, shared word "servicing")
      make_seg(t: 90.0, e: 105.0, states: %w[aspiration], distillation: 'discovered drop servicing opportunity', dur: 'identity', confidence: 'high'),
      make_seg(t: 108.0, e: 118.0, states: %w[competence], distillation: 'drop servicing first client', dur: 'mood', confidence: 'medium'),
      make_seg(t: 120.0, e: 130.0, states: %w[vindication], distillation: 'drop servicing scales fast', dur: 'identity', confidence: 'high'),

      # Gap > 30s, then isolated segment (no theme overlap with neighbors)
      make_seg(t: 170.0, e: 185.0, states: %w[amusement], distillation: 'funny client story disaster', dur: 'mood', confidence: 'high'),

      # Cluster C: numbers/revenue (t=220-260, 35s gap, shared word "revenue")
      make_seg(t: 220.0, e: 235.0, states: %w[aspiration], distillation: 'first thousand revenue milestone', dur: 'identity', confidence: 'high'),
      make_seg(t: 240.0, e: 260.0, states: %w[competence vindication], distillation: 'ten thousand revenue monthly', dur: 'identity', confidence: 'high'),

      # Low-signal segments (should be filtered out)
      make_seg(t: 300.0, e: 310.0, states: %w[calm], distillation: 'uh yeah basically', dur: 'spike', confidence: 'low'),
      make_seg(t: 315.0, e: 325.0, states: %w[curiosity], distillation: 'thinking about stuff', dur: 'spike', confidence: 'medium'),
      make_seg(t: 330.0, e: 340.0, states: %w[amusement], distillation: 'ok', dur: 'mood', confidence: 'high'),
    ]
  }
end

RSpec.describe 'mine_content.rb' do
  describe 'high-signal filtering' do
    it 'filters out low confidence segments' do
      result = run_mine(mining_segments)
      all_t_values = result[:result]['clusters'].flat_map { |c| c['segments'] }
      expect(all_t_values).not_to include(250.0) # low confidence
    end

    it 'filters out spike durability segments' do
      result = run_mine(mining_segments)
      all_t_values = result[:result]['clusters'].flat_map { |c| c['segments'] }
      expect(all_t_values).not_to include(265.0) # spike durability
    end

    it 'filters out short distillation filler' do
      result = run_mine(mining_segments)
      all_t_values = result[:result]['clusters'].flat_map { |c| c['segments'] }
      expect(all_t_values).not_to include(280.0) # "ok" is < 6 chars
    end

    it 'keeps high confidence identity segments' do
      result = run_mine(mining_segments)
      all_t_values = result[:result]['clusters'].flat_map { |c| c['segments'] }
      expect(all_t_values).to include(10.0)
    end

    it 'keeps medium confidence mood segments' do
      result = run_mine(mining_segments)
      all_t_values = result[:result]['clusters'].flat_map { |c| c['segments'] }
      expect(all_t_values).to include(108.0) # medium confidence, mood durability
    end

    it 'reports correct high-signal count' do
      result = run_mine(mining_segments)
      expect(result[:result]['high_signal_segments']).to eq(9)
    end

    it 'reports total classified segments' do
      result = run_mine(mining_segments)
      expect(result[:result]['total_classified_segments']).to eq(12)
    end
  end

  describe 'cluster merging' do
    it 'groups adjacent segments with shared theme words' do
      result = run_mine(mining_segments)
      clusters = result[:result]['clusters']

      # Find the affiliate cluster (has "affiliate" in distillations)
      affiliate = clusters.find { |c| c['distillations'].any? { |d| d.include?('affiliate') } }
      expect(affiliate).not_to be_nil
      expect(affiliate['segment_count']).to eq(3)
      expect(affiliate['segments']).to include(10.0, 25.0, 40.0)
    end

    it 'groups adjacent segments sharing drop servicing theme' do
      result = run_mine(mining_segments)
      clusters = result[:result]['clusters']

      drop = clusters.find { |c| c['distillations'].any? { |d| d.include?('drop servicing') } }
      expect(drop).not_to be_nil
      expect(drop['segment_count']).to eq(3)
      expect(drop['segments']).to include(90.0, 108.0, 120.0)
    end

    it 'creates standalone cluster for isolated segment with gap > 30s' do
      result = run_mine(mining_segments)
      clusters = result[:result]['clusters']

      funny = clusters.find { |c| c['distillations'].any? { |d| d.include?('funny') } }
      expect(funny).not_to be_nil
      expect(funny['segment_count']).to eq(1)
    end

    it 'splits clusters when gap exceeds 30s even with theme overlap' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'affiliate marketing intro'),
          make_seg(t: 60.0, e: 70.0, states: %w[curiosity], distillation: 'affiliate marketing conclusion'),
        ]
      }
      result = run_mine(segs)
      # Gap is 40s > 30s threshold, so two separate clusters despite theme overlap
      expect(result[:result]['clusters_found']).to eq(2)
    end

    it 'merges segments within 30s with shared content words' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'platform dependency problem'),
          make_seg(t: 45.0, e: 55.0, states: %w[vindication], distillation: 'platform fees too high'),
        ]
      }
      result = run_mine(segs)
      # Gap is 25s < 30s, shared word "platform" → one cluster
      expect(result[:result]['clusters_found']).to eq(1)
      expect(result[:result]['clusters'].first['segment_count']).to eq(2)
    end

    it 'does not merge adjacent segments with no theme overlap' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'affiliate marketing intro'),
          make_seg(t: 25.0, e: 35.0, states: %w[vindication], distillation: 'dropped servicing flywheel'),
        ]
      }
      result = run_mine(segs)
      # Adjacent (5s gap) but no shared content words → two clusters
      expect(result[:result]['clusters_found']).to eq(2)
    end
  end

  describe 'quality scoring' do
    it 'scores identity+high as 1.0' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 25.0, states: %w[curiosity], distillation: 'single high identity segment', dur: 'identity', confidence: 'high'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['quality']).to eq(1.0)
    end

    it 'scores mood+high as 0.8' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 25.0, states: %w[aspiration], distillation: 'single mood high segment', dur: 'mood', confidence: 'high'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['quality']).to eq(0.8)
    end

    it 'scores identity+medium as 0.7' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 25.0, states: %w[competence], distillation: 'single medium identity segment', dur: 'identity', confidence: 'medium'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['quality']).to eq(0.7)
    end

    it 'scores mood+medium as 0.56' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 25.0, states: %w[calm], distillation: 'single mood medium segment', dur: 'mood', confidence: 'medium'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['quality']).to eq(0.56)
    end

    it 'averages quality across cluster segments' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'platform dependency one', dur: 'identity', confidence: 'high'),   # 1.0
          make_seg(t: 25.0, e: 35.0, states: %w[vindication], distillation: 'platform dependency two', dur: 'mood', confidence: 'medium'), # 0.56
        ]
      }
      result = run_mine(segs)
      # (1.0 + 0.56) / 2 = 0.78
      expect(result[:result]['clusters'].first['quality']).to eq(0.78)
    end

    it 'sorts clusters by quality descending' do
      result = run_mine(mining_segments)
      qualities = result[:result]['clusters'].map { |c| c['quality'] }
      expect(qualities).to eq(qualities.sort.reverse)
    end
  end

  describe 'self-contained detection' do
    it 'marks cluster as self-contained when first and last are identity' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'topic strong opener here', dur: 'identity'),
          make_seg(t: 25.0, e: 35.0, states: %w[competence], distillation: 'topic middle content here', dur: 'mood'),
          make_seg(t: 40.0, e: 55.0, states: %w[vindication], distillation: 'topic strong closer here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['self_contained']).to be true
    end

    it 'marks cluster as not self-contained when first is mood' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'topic weak opener here', dur: 'mood'),
          make_seg(t: 25.0, e: 35.0, states: %w[vindication], distillation: 'topic strong closer here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['self_contained']).to be false
    end

    it 'marks cluster as not self-contained when last is mood' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'topic strong opener here', dur: 'identity'),
          make_seg(t: 25.0, e: 35.0, states: %w[vindication], distillation: 'topic weak closer here', dur: 'mood'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['self_contained']).to be false
    end

    it 'marks single-segment cluster as not self-contained' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 25.0, states: %w[curiosity], distillation: 'isolated identity segment here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['self_contained']).to be false
    end
  end

  describe 'standalone short eligibility' do
    it 'marks self-contained 30-90s cluster as standalone short candidate' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 25.0, states: %w[curiosity], distillation: 'topic opener content here', dur: 'identity'),
          make_seg(t: 30.0, e: 50.0, states: %w[competence], distillation: 'topic middle content here', dur: 'mood'),
          make_seg(t: 55.0, e: 70.0, states: %w[vindication], distillation: 'topic closer content here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      c = result[:result]['clusters'].first
      expect(c['duration']).to eq(60.0)
      expect(c['self_contained']).to be true
      expect(c['standalone_short_candidate']).to be true
    end

    it 'rejects standalone short when duration < 30s' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'topic opener content here', dur: 'identity'),
          make_seg(t: 22.0, e: 30.0, states: %w[vindication], distillation: 'topic closer content here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      c = result[:result]['clusters'].first
      expect(c['duration']).to eq(20.0)
      expect(c['self_contained']).to be true
      expect(c['standalone_short_candidate']).to be false
    end

    it 'rejects standalone short when duration > 90s' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 30.0, states: %w[curiosity], distillation: 'topic opener content here', dur: 'identity'),
          make_seg(t: 35.0, e: 60.0, states: %w[competence], distillation: 'topic middle content here', dur: 'mood'),
          make_seg(t: 65.0, e: 80.0, states: %w[aspiration], distillation: 'topic body content here', dur: 'mood'),
          make_seg(t: 85.0, e: 110.0, states: %w[vindication], distillation: 'topic closer content here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      c = result[:result]['clusters'].first
      expect(c['duration']).to eq(100.0)
      expect(c['self_contained']).to be true
      expect(c['standalone_short_candidate']).to be false
    end

    it 'rejects standalone short when not self-contained' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 30.0, states: %w[curiosity], distillation: 'topic mood opener here', dur: 'mood'),
          make_seg(t: 35.0, e: 70.0, states: %w[vindication], distillation: 'topic closer content here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      c = result[:result]['clusters'].first
      expect(c['standalone_short_candidate']).to be false
    end
  end

  describe 'output schema' do
    it 'includes all required top-level fields' do
      result = run_mine(mining_segments)
      %w[generated_at source total_classified_segments high_signal_segments clusters_found clusters].each do |field|
        expect(result[:result]).to have_key(field), "missing top-level field: #{field}"
      end
    end

    it 'includes all required per-cluster fields' do
      result = run_mine(mining_segments)
      c = result[:result]['clusters'].first
      %w[id theme theme_prompt segments duration segment_count quality self_contained standalone_short_candidate distillations].each do |field|
        expect(c).to have_key(field), "missing cluster field: #{field}"
      end
    end

    it 'sets theme to nil for agent to fill' do
      result = run_mine(mining_segments)
      result[:result]['clusters'].each do |c|
        expect(c['theme']).to be_nil
      end
    end

    it 'includes theme_prompt with distillations' do
      result = run_mine(mining_segments)
      c = result[:result]['clusters'].first
      expect(c['theme_prompt']).to include('theme label')
      expect(c['theme_prompt']).to include('Distilled segments')
    end

    it 'uses sequential cluster IDs' do
      result = run_mine(mining_segments)
      ids = result[:result]['clusters'].map { |c| c['id'] }
      expected = ids.size.times.map { |i| "cluster_#{i}" }
      expect(ids).to eq(expected)
    end

    it 'stores segment t-values as floats' do
      result = run_mine(mining_segments)
      c = result[:result]['clusters'].first
      expect(c['segments']).to all(be_a(Float))
    end

    it 'outputs path to stdout' do
      result = run_mine(mining_segments)
      expect(result[:stdout]).to end_with('content_inventory.yaml')
    end

    it 'shows inventory header in stderr' do
      result = run_mine(mining_segments)
      expect(result[:stderr]).to include('CONTENT INVENTORY')
      expect(result[:stderr]).to include('high-signal')
      expect(result[:stderr]).to include('thematic clusters')
    end

    it 'shows actions in stderr' do
      result = run_mine(mining_segments)
      expect(result[:stderr]).to include('Generate review reels')
      expect(result[:stderr]).to include('Run discovery on cluster N')
      expect(result[:stderr]).to include('Export inventory report')
    end
  end

  describe '--library flag' do
    it 'resolves segments_classified.yaml from library directory' do
      result = run_mine(mining_segments, library_name: 'test-lib')
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['source']).to eq('test-lib')
      expect(result[:result]['clusters_found']).to be > 0
    end

    it 'aborts when library directory not found' do
      Dir.mktmpdir do |dir|
        args = ['ruby', MINE_SCRIPT, '--library', 'nonexistent']
        _, stderr, status = Open3.capture3(*args, chdir: dir)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('Library not found')
      end
    end

    it 'aborts when no segments_classified.yaml in library' do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, 'libraries', 'empty-lib')
        FileUtils.mkdir_p(lib_dir)
        args = ['ruby', MINE_SCRIPT, '--library', 'empty-lib']
        _, stderr, status = Open3.capture3(*args, chdir: dir)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('No segments_classified.yaml')
      end
    end
  end

  describe 'edge cases' do
    it 'handles no high-signal segments gracefully' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[calm], distillation: 'um yeah ok', dur: 'spike', confidence: 'low'),
          make_seg(t: 25.0, e: 35.0, states: %w[calm], distillation: 'thinking maybe', dur: 'spike', confidence: 'low'),
        ]
      }
      result = run_mine(segs)
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['high_signal_segments']).to eq(0)
      expect(result[:result]['clusters_found']).to eq(0)
      expect(result[:result]['clusters']).to be_empty
    end

    it 'handles single high-signal segment' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 25.0, states: %w[curiosity], distillation: 'lone wolf segment here', dur: 'identity', confidence: 'high'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters_found']).to eq(1)
      expect(result[:result]['clusters'].first['segment_count']).to eq(1)
      expect(result[:result]['clusters'].first['self_contained']).to be false
    end

    it 'handles all segments in one cluster' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'revenue growth story here', dur: 'identity'),
          make_seg(t: 22.0, e: 32.0, states: %w[competence], distillation: 'revenue growth continued here', dur: 'mood'),
          make_seg(t: 35.0, e: 45.0, states: %w[vindication], distillation: 'revenue growth conclusion here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters_found']).to eq(1)
      expect(result[:result]['clusters'].first['segment_count']).to eq(3)
    end

    it 'aborts on empty segments array' do
      segs = { 'transcript_hash' => 'test', 'segments' => [] }
      result = run_mine(segs)
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include('No segments')
    end

    it 'aborts on missing file' do
      _, stderr, status = Open3.capture3('ruby', MINE_SCRIPT, '/nonexistent.yaml')
      expect(status.exitstatus).to eq(1)
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
      result = run_mine(segs)
      expect(result[:exit_code]).to eq(1)
      expect(result[:stderr]).to include('Branch A')
    end

    it 'handles segments with nil distillation' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          { 't' => 10.0, 'e' => 20.0, 'states' => %w[curiosity], 'distillation' => nil,
            'dur' => 'identity', 'roles' => %w[primary], 'confidence' => 'high',
            'signal' => 'test', 'notes' => 'test', 'rationale' => 'test' },
          make_seg(t: 25.0, e: 35.0, states: %w[competence], distillation: 'valid content segment here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      expect(result[:exit_code]).to eq(0)
      # Nil distillation filtered out, only 1 high-signal segment
      expect(result[:result]['high_signal_segments']).to eq(1)
    end

    it 'produces unique distillations per cluster (deduped)' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'same repeated content here'),
          make_seg(t: 25.0, e: 35.0, states: %w[competence], distillation: 'same repeated content here'),
        ]
      }
      result = run_mine(segs)
      c = result[:result]['clusters'].first
      expect(c['distillations'].size).to eq(1) # deduped
    end
  end

  describe 'duration calculation' do
    it 'computes duration from first t to last e' do
      segs = {
        'transcript_hash' => 'test',
        'segments' => [
          make_seg(t: 10.0, e: 20.0, states: %w[curiosity], distillation: 'platform topic opener here', dur: 'identity'),
          make_seg(t: 25.0, e: 35.0, states: %w[competence], distillation: 'platform topic middle here', dur: 'mood'),
          make_seg(t: 40.0, e: 55.5, states: %w[vindication], distillation: 'platform topic closer here', dur: 'identity'),
        ]
      }
      result = run_mine(segs)
      expect(result[:result]['clusters'].first['duration']).to eq(45.5)
    end
  end

  describe 'display format' do
    it 'shows cluster count and quality in stderr' do
      result = run_mine(mining_segments)
      expect(result[:stderr]).to match(/\d+\. \[theme pending\]/)
      expect(result[:stderr]).to include('quality')
    end

    it 'shows self-contained and standalone status' do
      result = run_mine(mining_segments)
      expect(result[:stderr]).to include('Self-contained:')
      expect(result[:stderr]).to include('Standalone short:')
    end

    it 'shows distillation previews' do
      result = run_mine(mining_segments)
      expect(result[:stderr]).to include('Distillations:')
    end
  end
end
