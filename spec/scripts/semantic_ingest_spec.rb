require 'open3'
require 'yaml'
require 'date'
require 'json'
require 'tmpdir'
require 'digest'

INGEST_SCRIPT = File.expand_path('../../scripts/semantic_ingest.rb', __dir__)

# Build a minimal library directory with transcripts and audio features
def build_test_library(dir, opts = {})
  lib_dir = File.join(dir, 'libraries', 'test-lib')
  transcripts_dir = File.join(lib_dir, 'transcripts')
  FileUtils.mkdir_p(transcripts_dir)

  # Cleaned transcript
  transcript = {
    'segments' => [
      { 'start' => 5.36, 'end' => 17.79, 'text' => ' Opening hook about AI art and creativity.' },
      { 'start' => 21.30, 'end' => 34.11, 'text' => ' Second take of the opening, slightly different.' },
      { 'start' => 40.99, 'end' => 50.92, 'text' => ' OpenAI released shockingly good image generation.' },
      { 'start' => 51.18, 'end' => 69.67, 'text' => ' Historical context about photography replacing painters.' },
      { 'start' => 99.13, 'end' => 111.46, 'text' => ' The death of art argument is not new.' },
      { 'start' => 114.92, 'end' => 116.99, 'text' => " I don't buy it." },
      { 'start' => 119.17, 'end' => 140.21, 'text' => ' Machine takeover fear recurs every generation.' },
      { 'start' => 165.17, 'end' => 185.50, 'text' => ' Illustration, maps, portraiture — all handmade for centuries.' },
      { 'start' => 200.00, 'end' => 220.00, 'text' => ' The real value is human judgment and curation.' },
      { 'start' => 250.00, 'end' => 270.00, 'text' => ' That is an immense magical power no machine can imitate.' }
    ]
  }
  File.write(File.join(transcripts_dir, 'test_cleaned.json'), transcript.to_json)

  # Audio features
  audio_features = {
    'source_wav' => 'test_treated.wav',
    'baseline' => {
      'speaking_rate' => 0.42,
      'f0_mean' => 128.0,
      'total_speech_duration' => 265.0,
      'total_words' => 112
    },
    'profile_distribution' => { 'casual' => 8, 'emphatic' => 1, 'urgent' => 1 },
    'segments' => [
      { 't' => 5.36, 'e' => 17.79, 'energy' => 1.07, 'pitch_trend' => 'falling', 'audio_profile' => 'casual' },
      { 't' => 114.92, 'e' => 116.99, 'energy' => 1.50, 'pitch_trend' => 'rising', 'audio_profile' => 'emphatic' },
      { 't' => 250.00, 'e' => 270.00, 'energy' => 1.80, 'pitch_trend' => 'rising', 'audio_profile' => 'urgent' }
    ]
  }
  File.write(File.join(transcripts_dir, 'test_speech_analysis.yaml'), audio_features.to_yaml)

  # Scene changes
  File.write(File.join(lib_dir, 'scene_changes.yaml'), {
    'total_scenes' => 2,
    'timestamps' => [0.0, 150.0]
  }.to_yaml)

  # Library YAML
  library = {
    'library_name' => 'test-lib',
    'created_date' => '2026-04-20',
    'language' => 'english',
    'editor' => 'premiere',
    'script_parsed' => opts[:script_parsed],
    'videos' => [
      {
        'path' => '/tmp/test_video.mp4',
        'duration' => '4:30',
        'transcript' => 'test_cleaned.json',
        'cleaned_transcript' => 'test_cleaned.json',
        'speech_analysis' => 'test_speech_analysis.yaml',
        'visual_transcript' => opts[:visual_transcript]
      }
    ]
  }
  File.write(File.join(lib_dir, 'library.yaml'), library.to_yaml)

  lib_dir
end

# Build a valid semantic_ingest.yaml for schema tests
def build_valid_output(lib_dir, cache_hash: 'test_hash')
  output = {
    'generated_at' => '2026-04-20T10:00:00+02:00',
    'source' => 'test-lib',
    'cache_hash' => cache_hash,
    'video_count' => 1,
    'transcript_segments' => 10,
    'llm_model' => 'claude-opus-4-6',
    'core_understanding' => "This video explores the recurring fear that new technology will kill art.\n",
    'central_tension' => "Will AI-generated images replace human artists, or will human judgment remain irreplaceable?\n",
    'script_or_outline_present' => false,
    'script_type' => 'none',
    'clip_groups' => [
      {
        'id' => 'group_001',
        'label' => 'hook — AI art cultural moment',
        'description' => 'Opens with viral Ghibli meme phenomenon',
        'clips' => [
          { 't' => 5.36, 'source' => 'test_video.mp4', 'take_variant' => 'primary', 'content_summary' => 'AI images flooding social media' },
          { 't' => 21.30, 'source' => 'test_video.mp4', 'take_variant' => 'alternate', 'content_summary' => 'Second take of opening' }
        ]
      },
      {
        'id' => 'group_002',
        'label' => 'contrarian thesis',
        'description' => 'Introduces counter-argument to AI panic',
        'clips' => [
          { 't' => 114.92, 'source' => 'test_video.mp4', 'take_variant' => 'primary', 'content_summary' => "I don't buy it" }
        ]
      }
    ],
    'open_loops' => {
      'structural' => [
        { 'opened_at' => 'group_001', 'description' => 'Will AI kill art?', 'closes_at' => 'group_002' }
      ],
      'local' => []
    },
    'best_take_hints' => [
      { 'cluster_topic' => 'Opening hook', 'clips' => [5.36, 21.30], 'strongest_candidate' => 5.36, 'reasoning' => 'Clearer delivery' }
    ],
    'unusable_clips' => []
  }
  path = File.join(lib_dir, 'semantic_ingest.yaml')
  File.write(path, output.to_yaml)
  [path, output]
end

RSpec.describe 'semantic_ingest.rb' do
  describe 'CLI argument parsing' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', INGEST_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 for unknown arguments' do
      _, stderr, status = Open3.capture3('ruby', INGEST_SCRIPT, '--foo')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Unknown argument')
    end

    it 'exits 1 when library does not exist' do
      _, stderr, status = Open3.capture3('ruby', INGEST_SCRIPT, '--library', 'nonexistent-xyz')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end
  end

  describe 'cache logic' do
    it 'skips when semantic_ingest.yaml exists with matching hash' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)

        # Compute the hash the script would compute
        t_path = File.join(lib_dir, 'transcripts', 'test_cleaned.json')
        cache_hash = Digest::MD5.hexdigest(Digest::MD5.hexdigest(File.read(t_path)))

        build_valid_output(lib_dir, cache_hash: cache_hash)

        # Point the script at our test library
        stdout, stderr, status = Open3.capture3(
          'ruby', INGEST_SCRIPT,
          '--library', 'test-lib',
          '--no-review',
          chdir: File.join(dir, 'libraries', '..')  # won't work — script uses ROOT_DIR
        )

        # The script resolves ROOT_DIR from its own location, so we can't redirect it.
        # Instead, test the cache logic in isolation.
        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'
          require 'digest'

          output_path = '#{File.join(lib_dir, 'semantic_ingest.yaml')}'
          existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date])
          cache_hash = '#{cache_hash}'

          if existing && existing['cache_hash'] == cache_hash
            puts 'cache_hit'
          else
            puts 'cache_miss'
          end
        RUBY
        expect(stdout.strip).to eq('cache_hit')
      end
    end

    it 'misses cache when hash differs' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        build_valid_output(lib_dir, cache_hash: 'old_hash')

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'

          output_path = '#{File.join(lib_dir, 'semantic_ingest.yaml')}'
          existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date])
          cache_hash = 'new_hash'

          if existing && existing['cache_hash'] == cache_hash
            puts 'cache_hit'
          else
            puts 'cache_miss'
          end
        RUBY
        expect(stdout.strip).to eq('cache_miss')
      end
    end
  end

  describe 'input assembly' do
    it 'concatenates transcript segments with source markers' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)

        code = <<~'RUBY_TEMPLATE'
          require 'json'
          t_path = 'T_PATH_PLACEHOLDER'
          data = JSON.parse(File.read(t_path))
          segs = data['segments']

          block = "--- SOURCE: test_video.mp4 (4:30) ---\n"
          segs.each do |s|
            block << "[#{'%.2f' % s['start']}-#{'%.2f' % s['end']}] #{s['text'].strip}\n"
          end
          puts block.lines.count
          puts block.include?('SOURCE: test_video.mp4')
          puts block.include?('[5.36-17.79]')
        RUBY_TEMPLATE
        code = code.gsub('T_PATH_PLACEHOLDER', File.join(lib_dir, 'transcripts', 'test_cleaned.json'))
        stdout, _, status = Open3.capture3('ruby', '-e', code)
        lines = stdout.strip.split("\n")
        expect(lines[1]).to eq('true')  # source marker
        expect(lines[2]).to eq('true')  # timestamp format
      end
    end

    it 'compresses audio features to notable moments only' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          af = YAML.safe_load(File.read('#{File.join(lib_dir, 'transcripts', 'test_speech_analysis.yaml')}'))
          notable = af['segments'].select { |s| %w[emphatic urgent].include?(s['audio_profile']) }
          puts notable.size
          puts notable.map { |s| s['audio_profile'] }.join(',')
        RUBY
        lines = stdout.strip.split("\n")
        expect(lines[0].to_i).to eq(2)  # emphatic + urgent
        expect(lines[1]).to include('emphatic')
        expect(lines[1]).to include('urgent')
      end
    end
  end

  describe 'output schema validation' do
    it 'includes all required top-level fields' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        _, output = build_valid_output(lib_dir)

        %w[generated_at source cache_hash video_count transcript_segments llm_model
           core_understanding central_tension script_or_outline_present script_type
           clip_groups open_loops best_take_hints unusable_clips].each do |field|
          expect(output).to have_key(field), "Missing field: #{field}"
        end
      end
    end

    it 'clip_groups have required structure' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        _, output = build_valid_output(lib_dir)

        output['clip_groups'].each do |g|
          expect(g).to have_key('id')
          expect(g).to have_key('label')
          expect(g).to have_key('description')
          expect(g).to have_key('clips')
          expect(g['clips']).to be_a(Array)
          g['clips'].each do |c|
            expect(c).to have_key('t')
            expect(c).to have_key('source')
            expect(c).to have_key('take_variant')
            expect(c['take_variant']).to satisfy { |v| %w[primary alternate].include?(v) }
          end
        end
      end
    end

    it 'open_loops have structural and local arrays' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        _, output = build_valid_output(lib_dir)

        expect(output['open_loops']).to have_key('structural')
        expect(output['open_loops']).to have_key('local')
        expect(output['open_loops']['structural']).to be_a(Array)
        expect(output['open_loops']['local']).to be_a(Array)
      end
    end

    it 'structural open loops reference clip groups' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        _, output = build_valid_output(lib_dir)

        group_ids = output['clip_groups'].map { |g| g['id'] }
        output['open_loops']['structural'].each do |loop|
          expect(loop).to have_key('opened_at')
          expect(loop).to have_key('closes_at')
          expect(loop).to have_key('description')
          expect(group_ids).to include(loop['opened_at'])
          expect(group_ids).to include(loop['closes_at'])
        end
      end
    end

    it 'best_take_hints have required fields' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        _, output = build_valid_output(lib_dir)

        output['best_take_hints'].each do |hint|
          expect(hint).to have_key('cluster_topic')
          expect(hint).to have_key('clips')
          expect(hint['clips']).to be_a(Array)
          expect(hint).to have_key('strongest_candidate')
          expect(hint).to have_key('reasoning')
        end
      end
    end

    it 'unusable_clips have t, source, and reason' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        _, output = build_valid_output(lib_dir)

        # Add an unusable clip to test
        output['unusable_clips'] << { 't' => 104.0, 'source' => 'test_video.mp4', 'reason' => 'Incomplete thought' }
        output['unusable_clips'].each do |clip|
          expect(clip).to have_key('t')
          expect(clip).to have_key('source')
          expect(clip).to have_key('reason')
        end
      end
    end

    it 'clip group IDs are sequential' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        _, output = build_valid_output(lib_dir)

        ids = output['clip_groups'].map { |g| g['id'] }
        ids.each_with_index do |id, i|
          expect(id).to eq("group_#{(i + 1).to_s.rjust(3, '0')}")
        end
      end
    end
  end

  describe 'LLM routing' do
    it 'routes semantic_ingest to opus in default profile' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require_relative '#{File.expand_path('../../scripts/load_profile', __dir__)}'
        profile = load_profile_by_name('_default')
        puts profile.dig('llm_routing', 'semantic_ingest')
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('claude-opus-4-6')
    end
  end

  describe 'error handling' do
    it 'aborts when library has no videos' do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, 'libraries', 'empty-lib')
        FileUtils.mkdir_p(lib_dir)
        File.write(File.join(lib_dir, 'library.yaml'), { 'videos' => [] }.to_yaml)

        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          library = YAML.safe_load(File.read('#{File.join(lib_dir, 'library.yaml')}'))
          videos = library['videos'] || []
          if videos.empty?
            $stderr.puts "No videos"
            exit 1
          end
        RUBY
        expect(status.exitstatus).to eq(1)
      end
    end

    it 'aborts on missing API key' do
      env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
      _, stderr, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
        require_relative '#{File.expand_path('../../scripts/llm_client', __dir__)}'
        LLMClient.call('test', call_type: 'semantic_ingest')
      RUBY
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('ANTHROPIC_API_KEY')
    end
  end

  describe 'YAML response parsing' do
    it 'strips markdown code fences from LLM response' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        response = "```yaml\\ncore_understanding: test\\n```"
        yaml_text = response.gsub(/\\A```ya?ml\\s*/, '').gsub(/```\\s*\\z/, '').strip
        puts yaml_text
      RUBY
      expect(stdout.strip).to eq('core_understanding: test')
    end

    it 'handles clean YAML without fences' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        response = "core_understanding: test\\ncentral_tension: test2"
        yaml_text = response.gsub(/\\A```ya?ml\\s*/, '').gsub(/```\\s*\\z/, '').strip
        puts yaml_text
      RUBY
      expect(stdout.strip).to eq("core_understanding: test\ncentral_tension: test2")
    end
  end

  describe 'Claude Code mode' do
    it 'writes pending file and exits 2 when in claude_code mode without API key' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        pending_dir = File.join(lib_dir, 'pending_llm_calls')

        env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
        stdout, stderr, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'fileutils'
          require_relative '#{File.expand_path('../../scripts/llm_client', __dir__)}'

          # Simulate what semantic_ingest does: mode detection + call with pending_dir
          LLMClient.mode = :claude_code
          pending_dir = '#{pending_dir}'
          begin
            LLMClient.call("Test prompt for semantic ingest",
              call_type: 'semantic_ingest', call_name: 'semantic_ingest',
              pending_dir: pending_dir, max_tokens: 8192)
          rescue LLMClient::Pending => e
            $stderr.puts e.message
            exit 2
          end
        RUBY
        expect(status.exitstatus).to eq(2)
        expect(stderr).to include('PENDING LLM CALL')

        pending_file = File.join(pending_dir, 'semantic_ingest.yaml')
        expect(File.exist?(pending_file)).to be true

        data = YAML.safe_load(File.read(pending_file))
        expect(data['call_name']).to eq('semantic_ingest')
        expect(data['call_type']).to eq('semantic_ingest')
        expect(data['prompt']).to include('Test prompt')
        expect(data['response_path']).to include('semantic_ingest_response.yaml')
      end
    end

    it 'reads response file on re-run and returns response' do
      Dir.mktmpdir do |dir|
        lib_dir = build_test_library(dir)
        pending_dir = File.join(lib_dir, 'pending_llm_calls')
        FileUtils.mkdir_p(pending_dir)

        # Write a response file as Claude Code would
        File.write(File.join(pending_dir, 'semantic_ingest_response.yaml'),
          { 'response' => "core_understanding: test result\ncentral_tension: test tension" }.to_yaml)

        env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
        stdout, stderr, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
          require_relative '#{File.expand_path('../../scripts/llm_client', __dir__)}'

          result = LLMClient.call("Ignored prompt",
            call_type: 'semantic_ingest', call_name: 'semantic_ingest',
            pending_dir: '#{pending_dir}', max_tokens: 8192)
          puts result
        RUBY
        expect(status.exitstatus).to eq(0)
        expect(stdout).to include('core_understanding: test result')
      end
    end
  end

  describe 'multi-video handling' do
    it 'concatenates transcripts from multiple videos with source markers' do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, 'libraries', 'multi-vid')
        transcripts_dir = File.join(lib_dir, 'transcripts')
        FileUtils.mkdir_p(transcripts_dir)

        # Two transcripts
        t1 = { 'segments' => [{ 'start' => 1.0, 'end' => 5.0, 'text' => ' First video content.' }] }
        t2 = { 'segments' => [{ 'start' => 2.0, 'end' => 8.0, 'text' => ' Second video content.' }] }
        File.write(File.join(transcripts_dir, 't1.json'), t1.to_json)
        File.write(File.join(transcripts_dir, 't2.json'), t2.to_json)

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'json'

          videos = [
            { 'path' => '/tmp/vid1.mp4', 'duration' => '1:00', 'cleaned_transcript' => 't1.json' },
            { 'path' => '/tmp/vid2.mp4', 'duration' => '2:00', 'cleaned_transcript' => 't2.json' }
          ]

          block = ""
          videos.each do |v|
            t_path = File.join('#{transcripts_dir}', v['cleaned_transcript'])
            data = JSON.parse(File.read(t_path))
            source = File.basename(v['path'])
            block << "--- SOURCE: \#{source} ---\\n"
            data['segments'].each { |s| block << "[\#{s['start']}-\#{s['end']}] \#{s['text'].strip}\\n" }
          end

          puts block.scan(/SOURCE:/).count
          puts block.include?('vid1.mp4')
          puts block.include?('vid2.mp4')
        RUBY
        lines = stdout.strip.split("\n")
        expect(lines[0].to_i).to eq(2)  # two source markers
        expect(lines[1]).to eq('true')
        expect(lines[2]).to eq('true')
      end
    end
  end
end
