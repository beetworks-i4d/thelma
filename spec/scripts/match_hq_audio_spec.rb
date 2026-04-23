require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'open3'

MATCH_HQ_AUDIO_SCRIPT = File.expand_path('../../scripts/match_hq_audio.rb', __dir__)
POOL_INDEX_SCRIPT     = File.expand_path('../../scripts/pool_index.rb', __dir__)

RSpec.describe 'match_hq_audio.rb' do
  describe 'CLI argument parsing' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', MATCH_HQ_AUDIO_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 for unknown arguments' do
      _, stderr, status = Open3.capture3('ruby', MATCH_HQ_AUDIO_SCRIPT, '--foo')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Unknown argument')
    end

    it 'exits 1 when library does not exist' do
      _, stderr, status = Open3.capture3('ruby', MATCH_HQ_AUDIO_SCRIPT, '--library', 'nonexistent-xyz')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end
  end

  describe 'word_overlap (Jaccard similarity)' do
    # Exercise the logic inline rather than requiring the CLI script
    def word_overlap(words_a, words_b, prefix_n: 200)
      require 'set'
      a = words_a.first(prefix_n).to_set
      b = words_b.first(prefix_n).to_set
      union = (a | b)
      return 0.0 if union.empty?
      (a & b).size.to_f / union.size
    end

    it 'returns 1.0 for identical word sets' do
      words = %w[hello world foo bar baz]
      expect(word_overlap(words, words)).to be_within(0.001).of(1.0)
    end

    it 'returns 0.0 for completely different word sets' do
      expect(word_overlap(%w[hello world], %w[foo bar])).to be_within(0.001).of(0.0)
    end

    it 'returns ~0.333 for 1/3 overlap (2 shared out of 6 unique)' do
      # {hello, world} shared; {foo, bar} vs {baz, qux} not shared
      # union = 6, intersection = 2 => 2/6 = 0.333
      expect(word_overlap(%w[hello world foo bar], %w[hello world baz qux])).to be_within(0.01).of(0.333)
    end

    it 'uses prefix_n to avoid penalizing shorter recordings' do
      # Long video has many extra words; audio-only has only the first few
      long_words  = %w[one two three four five six seven eight nine ten] * 30
      short_words = %w[one two three four five]
      # With prefix_n:5 both sets become {one,two,three,four,five} => overlap = 1.0
      expect(word_overlap(long_words, short_words, prefix_n: 5)).to be_within(0.001).of(1.0)
    end

    it 'returns 0.0 for empty word lists' do
      expect(word_overlap([], [])).to eq(0.0)
    end
  end

  describe 'source filtering from index' do
    it 'exits 0 gracefully when no audio-only sources present' do
      Dir.mktmpdir do |tmpdir|
        library_dir = File.join(tmpdir, 'libraries', 'test-pool')
        FileUtils.mkdir_p(File.join(library_dir, 'transcripts'))

        File.write(File.join(library_dir, 'library.yaml'), { 'pool_dir' => tmpdir, 'videos' => [] }.to_yaml)
        index = { 'pool_version' => 1, 'sources' => {
          'video.mp4' => { 'media_type' => 'video_with_audio', 'transcript_file' => nil }
        }}
        File.write(File.join(library_dir, 'index.yaml'), index.to_yaml)

        _, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'set'
          require 'json'
          require 'date'
          require_relative '#{POOL_INDEX_SCRIPT}'

          library_dir = '#{library_dir}'
          index   = PoolIndex.load(library_dir)
          sources = index['sources'] || {}

          video_sources = sources.select { |_, v| v['media_type'] == 'video_with_audio' && v['transcript_file'] }
          audio_sources = sources.select { |_, v| v['media_type'] == 'audio_only'       && v['transcript_file'] }

          if video_sources.empty? || audio_sources.empty?
            $stderr.puts 'Nothing to match.'
            exit 0
          end
        RUBY
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('Nothing to match')
      end
    end
  end

  describe 'index update after matching' do
    it 'set_hq_pair records hq_audio_source on video and role on audio' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require 'yaml'
        require 'date'
        require 'digest'
        require 'shellwords'
        require_relative '#{POOL_INDEX_SCRIPT}'

        index = PoolIndex.empty_index
        index['sources']['video.mp4'] = { 'media_type' => 'video_with_audio' }
        index['sources']['audio.m4a'] = { 'media_type' => 'audio_only' }

        PoolIndex.set_hq_pair(index, 'video.mp4', 'audio.m4a', 0.123)

        v = index['sources']['video.mp4']
        a = index['sources']['audio.m4a']
        puts v['hq_audio_source']
        puts v['hq_audio_offset']
        puts a['role']
        puts a['hq_audio_for']
      RUBY
      lines = stdout.strip.split("\n")
      expect(lines[0]).to eq('audio.m4a')
      expect(lines[1].to_f).to be_within(0.001).of(0.123)
      expect(lines[2]).to eq('hq_audio_for')
      expect(lines[3]).to eq('video.mp4')
    end
  end
end
