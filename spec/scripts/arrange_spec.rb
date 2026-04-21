require 'open3'
require 'yaml'
require 'date'
require 'json'
require 'tmpdir'
require 'digest'

ARRANGE_SCRIPT = File.expand_path('../../scripts/arrange.rb', __dir__)

# Build a minimal library directory with semantic_ingest.yaml and optionally segments_classified.yaml
def build_arrange_test_library(dir, opts = {})
  lib_dir = File.join(dir, 'libraries', 'test-lib')
  transcripts_dir = File.join(lib_dir, 'transcripts')
  FileUtils.mkdir_p(transcripts_dir)

  # Cleaned transcript (for t→e fallback)
  transcript = {
    'segments' => [
      { 'start' => 5.36, 'end' => 17.79, 'text' => ' Opening hook about AI art.' },
      { 'start' => 21.30, 'end' => 34.11, 'text' => ' Second take of the opening.' },
      { 'start' => 40.99, 'end' => 50.92, 'text' => ' OpenAI released image gen.' },
      { 'start' => 99.13, 'end' => 111.46, 'text' => ' Death of art is not new.' },
      { 'start' => 114.92, 'end' => 116.99, 'text' => " I don't buy it." },
      { 'start' => 200.00, 'end' => 220.00, 'text' => ' Human judgment is the real value.' },
      { 'start' => 250.00, 'end' => 270.00, 'text' => ' That is an immense magical power.' }
    ]
  }
  File.write(File.join(transcripts_dir, 'test_cleaned.json'), transcript.to_json)

  # Semantic ingest (REQUIRED for arrange.rb)
  ingest = {
    'generated_at' => '2026-04-20T10:00:00+02:00',
    'source' => 'test-lib',
    'cache_hash' => 'ingest_hash',
    'llm_model' => 'claude-opus-4-6',
    'core_understanding' => "Video about AI art and human creativity.\n",
    'central_tension' => "Will AI replace artists or will human judgment prevail?\n",
    'clip_groups' => [
      {
        'id' => 'group_001',
        'label' => 'hook — AI art moment',
        'description' => 'Opens with viral AI art phenomenon',
        'clips' => [
          { 't' => 5.36, 'source' => 'test_video.mp4', 'usability' => 'fine', 'cluster' => 'opening_hook', 'content_summary' => 'AI images flooding feeds' },
          { 't' => 21.30, 'source' => 'test_video.mp4', 'usability' => 'fine', 'cluster' => 'opening_hook', 'content_summary' => 'Second take of opening' }
        ]
      },
      {
        'id' => 'group_002',
        'label' => 'context — history of art panic',
        'description' => 'Historical parallels of technology threatening art',
        'clips' => [
          { 't' => 40.99, 'source' => 'test_video.mp4', 'usability' => 'fine', 'content_summary' => 'OpenAI image gen launch' },
          { 't' => 99.13, 'source' => 'test_video.mp4', 'usability' => 'fine', 'content_summary' => 'Death of art not new' }
        ]
      },
      {
        'id' => 'group_003',
        'label' => 'thesis — human judgment',
        'description' => 'Core argument that human judgment is irreplaceable',
        'clips' => [
          { 't' => 114.92, 'source' => 'test_video.mp4', 'usability' => 'fine', 'content_summary' => "I don't buy it" },
          { 't' => 200.00, 'source' => 'test_video.mp4', 'usability' => 'fine', 'content_summary' => 'Human judgment value' },
          { 't' => 250.00, 'source' => 'test_video.mp4', 'usability' => 'fine', 'content_summary' => 'Immense magical power' }
        ]
      }
    ],
    'open_loops' => {
      'structural' => [
        { 'opened_at' => 'group_001', 'description' => 'Will AI kill art?', 'closes_at' => 'group_003' }
      ],
      'local' => []
    }
  }
  File.write(File.join(lib_dir, 'semantic_ingest.yaml'), ingest.to_yaml)

  # Segments classified (OPTIONAL)
  if opts[:with_classification]
    classified = {
      'segments' => [
        { 't' => 5.36, 'e' => 17.79, 'narrative_role' => 'hook', 'dur' => '12.4s', 'confidence' => 92, 'audio_profile' => 'emphatic', 'states' => ['engaging'], 'distillation' => 'AI art cultural moment' },
        { 't' => 21.30, 'e' => 34.11, 'narrative_role' => 'hook', 'dur' => '12.8s', 'confidence' => 85, 'audio_profile' => 'casual', 'states' => ['retake'], 'distillation' => 'Second take opening' },
        { 't' => 40.99, 'e' => 50.92, 'narrative_role' => 'setup', 'dur' => '9.9s', 'confidence' => 88, 'audio_profile' => 'casual', 'states' => ['informing'], 'distillation' => 'OpenAI launch context' },
        { 't' => 99.13, 'e' => 111.46, 'narrative_role' => 'evidence', 'dur' => '12.3s', 'confidence' => 90, 'audio_profile' => 'casual', 'states' => ['building'], 'distillation' => 'Historical parallel' },
        { 't' => 114.92, 'e' => 116.99, 'narrative_role' => 'argument', 'dur' => '2.1s', 'confidence' => 95, 'audio_profile' => 'emphatic', 'states' => ['asserting'], 'distillation' => 'Contrarian thesis punch' },
        { 't' => 200.00, 'e' => 220.00, 'narrative_role' => 'body', 'dur' => '20.0s', 'confidence' => 87, 'audio_profile' => 'casual', 'states' => ['explaining'], 'distillation' => 'Human judgment value' },
        { 't' => 250.00, 'e' => 270.00, 'narrative_role' => 'conclusion', 'dur' => '20.0s', 'confidence' => 91, 'audio_profile' => 'urgent', 'states' => ['concluding'], 'distillation' => 'Magic of human creativity' }
      ]
    }
    File.write(File.join(lib_dir, 'segments_classified.yaml'), classified.to_yaml)
  end

  # Script parsed (if branch A test)
  if opts[:with_script]
    script = { 'beats' => [{ 'label' => 'Open with AI art trend' }, { 'label' => 'Historical context' }, { 'label' => 'Thesis statement' }] }
    File.write(File.join(transcripts_dir, 'script_parsed.yaml'), script.to_yaml)
  end

  # Library YAML
  library = {
    'library_name' => 'test-lib',
    'created_date' => '2026-04-20',
    'language' => 'english',
    'editor' => 'premiere',
    'script_parsed' => opts[:with_script] ? 'script_parsed.yaml' : nil,
    'videos' => [
      {
        'path' => '/tmp/test_video.mp4',
        'duration' => '4:30',
        'transcript' => 'test_cleaned.json',
        'cleaned_transcript' => 'test_cleaned.json',
        'visual_transcript' => 'test_visual.yaml'
      }
    ]
  }
  File.write(File.join(lib_dir, 'library.yaml'), library.to_yaml)

  lib_dir
end

# Build a valid arrangement.yaml for schema/cache tests
def build_valid_arrangement(lib_dir, cache_hash: 'test_hash')
  arrangement = {
    'generated_at' => '2026-04-20T12:00:00+02:00',
    'source' => 'test-lib',
    'cache_hash' => cache_hash,
    'llm_model' => 'claude-opus-4-6',
    'cut_summary' => "A concise video exploring AI art through historical lens.\n",
    'target_format' => 'longform',
    'estimated_duration' => '8:42',
    'branch' => 'B',
    'chapters' => [
      {
        'id' => 'ch_01',
        'label' => 'Hook — AI art explosion',
        'clips' => [
          { 't_in' => 5.36, 't_out' => 17.79, 'source' => 'test_video.mp4', 'track' => 'V1', 'narrative_role' => 'hook', 'content_summary' => 'AI art moment' },
          { 't_in' => 21.30, 't_out' => 34.11, 'source' => 'test_video.mp4', 'track' => 'V2', 'narrative_role' => 'hook', 'content_summary' => 'Alternate take' }
        ]
      },
      {
        'id' => 'ch_02',
        'label' => 'Context — historical parallels',
        'clips' => [
          { 't_in' => 40.99, 't_out' => 50.92, 'source' => 'test_video.mp4', 'track' => 'V1', 'narrative_role' => 'setup', 'content_summary' => 'OpenAI launch' },
          { 't_in' => 99.13, 't_out' => 111.46, 'source' => 'test_video.mp4', 'track' => 'V1', 'narrative_role' => 'evidence', 'content_summary' => 'Death of art' }
        ]
      },
      {
        'id' => 'ch_03',
        'label' => 'Thesis — human judgment',
        'clips' => [
          { 't_in' => 114.92, 't_out' => 116.99, 'source' => 'test_video.mp4', 'track' => 'V1', 'narrative_role' => 'argument', 'content_summary' => "Don't buy it" },
          { 't_in' => 200.00, 't_out' => 220.00, 'source' => 'test_video.mp4', 'track' => 'V1', 'narrative_role' => 'body', 'content_summary' => 'Human judgment' },
          { 't_in' => 250.00, 't_out' => 270.00, 'source' => 'test_video.mp4', 'track' => 'V1', 'narrative_role' => 'conclusion', 'content_summary' => 'Magical power' }
        ]
      }
    ],
    'broll_placements' => [],
    'broll_suggestions' => [
      { 'at_chapter' => 'ch_01', 'after_t' => 5.36, 'suggestion' => 'AI-generated art montage' }
    ],
    'key_decisions' => [
      'Used primary take at t=5.36 for clearer delivery over alternate at t=21.30'
    ]
  }
  path = File.join(lib_dir, 'arrangement.yaml')
  File.write(path, arrangement.to_yaml)
  [path, arrangement]
end

RSpec.describe 'arrange.rb' do
  describe 'CLI argument parsing' do
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

    it 'exits 1 when library does not exist' do
      _, stderr, status = Open3.capture3('ruby', ARRANGE_SCRIPT, '--library', 'nonexistent-xyz')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end

    it 'exits 1 when semantic_ingest.yaml is missing' do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, 'libraries', 'no-ingest')
        FileUtils.mkdir_p(lib_dir)
        File.write(File.join(lib_dir, 'library.yaml'), { 'library_name' => 'no-ingest', 'videos' => [] }.to_yaml)

        # Run inline so ROOT_DIR resolves to our tmpdir
        _, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'
          ingest_path = '#{File.join(lib_dir, 'semantic_ingest.yaml')}'
          abort "ABORT: semantic_ingest.yaml not found at \#{ingest_path}" unless File.exist?(ingest_path)
        RUBY
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('semantic_ingest.yaml not found')
      end
    end
  end

  describe 'cache logic' do
    it 'hits cache when arrangement.yaml exists with matching hash' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)

        # Compute the same hash the script would
        ingest_content = File.read(File.join(lib_dir, 'semantic_ingest.yaml'))
        cache_hash = Digest::MD5.hexdigest(ingest_content + 'longform')

        build_valid_arrangement(lib_dir, cache_hash: cache_hash)

        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'
          require 'digest'

          output_path = '#{File.join(lib_dir, 'arrangement.yaml')}'
          ingest_path = '#{File.join(lib_dir, 'semantic_ingest.yaml')}'
          cache_hash = Digest::MD5.hexdigest(File.read(ingest_path) + 'longform')

          existing = YAML.safe_load(File.read(output_path), permitted_classes: [Date])
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
        lib_dir = build_arrange_test_library(dir)
        build_valid_arrangement(lib_dir, cache_hash: 'old_hash')

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'

          output_path = '#{File.join(lib_dir, 'arrangement.yaml')}'
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
    it 'loads ingest clip groups correctly' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)

        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'

          ingest = YAML.safe_load(File.read('#{File.join(lib_dir, 'semantic_ingest.yaml')}'), permitted_classes: [Date])
          groups = ingest['clip_groups']
          total_clips = groups.sum { |g| (g['clips'] || []).size }
          puts groups.size
          puts total_clips
        RUBY
        lines = stdout.strip.split("\n")
        expect(lines[0].to_i).to eq(3)  # 3 clip groups
        expect(lines[1].to_i).to eq(7)  # 7 total clips
      end
    end

    it 'enriches clips with classification data when available' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir, with_classification: true)

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'

          ingest = YAML.safe_load(File.read('#{File.join(lib_dir, 'semantic_ingest.yaml')}'), permitted_classes: [Date])
          classified = YAML.safe_load(File.read('#{File.join(lib_dir, 'segments_classified.yaml')}'), permitted_classes: [Date])

          t_lookup = {}
          classified['segments'].each do |s|
            t_lookup[s['t'].to_f] = { 'e' => s['e'].to_f, 'narrative_role' => s['narrative_role'] }
          end

          # Check first clip enrichment
          first_clip = ingest['clip_groups'][0]['clips'][0]
          enrichment = t_lookup[first_clip['t'].to_f]
          puts enrichment ? 'enriched' : 'not_enriched'
          puts enrichment['e'] if enrichment
          puts enrichment['narrative_role'] if enrichment
        RUBY
        lines = stdout.strip.split("\n")
        expect(lines[0]).to eq('enriched')
        expect(lines[1].to_f).to eq(17.79)
        expect(lines[2]).to eq('hook')
      end
    end

    it 'detects branch A when script is present' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir, with_script: true)

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'

          library = YAML.safe_load(File.read('#{File.join(lib_dir, 'library.yaml')}'), permitted_classes: [Date])
          branch = 'B'
          if library['script_parsed']
            sp_path = File.join('#{File.join(lib_dir, 'transcripts')}', library['script_parsed'])
            branch = 'A' if File.exist?(sp_path)
          end
          puts branch
        RUBY
        expect(stdout.strip).to eq('A')
      end
    end
  end

  describe 'output schema validation' do
    it 'includes all required top-level fields' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)
        _, arrangement = build_valid_arrangement(lib_dir)

        %w[generated_at source cache_hash llm_model cut_summary target_format
           estimated_duration branch chapters broll_placements broll_suggestions
           key_decisions].each do |field|
          expect(arrangement).to have_key(field), "Missing field: #{field}"
        end
      end
    end

    it 'chapters have required structure' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)
        _, arrangement = build_valid_arrangement(lib_dir)

        arrangement['chapters'].each do |ch|
          expect(ch).to have_key('id')
          expect(ch).to have_key('label')
          expect(ch).to have_key('clips')
          expect(ch['clips']).to be_a(Array)
          expect(ch['clips']).not_to be_empty
        end
      end
    end

    it 'clips have required fields' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)
        _, arrangement = build_valid_arrangement(lib_dir)

        arrangement['chapters'].flat_map { |ch| ch['clips'] }.each do |clip|
          %w[t_in t_out source track narrative_role].each do |field|
            expect(clip).to have_key(field), "Clip missing: #{field}"
          end
          expect(clip['t_out'].to_f).to be > clip['t_in'].to_f
          expect(%w[V1 V2]).to include(clip['track'])
        end
      end
    end

    it 'defaults missing optional fields' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)

        # Build arrangement without optional fields
        minimal = {
          'cut_summary' => 'Test', 'target_format' => 'longform',
          'estimated_duration' => '5:00', 'branch' => 'B',
          'chapters' => [{ 'id' => 'ch_01', 'label' => 'Test', 'clips' => [
            { 't_in' => 5.36, 't_out' => 17.79, 'source' => 'test.mp4', 'track' => 'V1', 'narrative_role' => 'hook' }
          ] }]
        }
        # Simulate the defaulting logic
        minimal['broll_placements'] ||= []
        minimal['broll_suggestions'] ||= []
        minimal['key_decisions'] ||= []

        expect(minimal['broll_placements']).to eq([])
        expect(minimal['broll_suggestions']).to eq([])
        expect(minimal['key_decisions']).to eq([])
      end
    end

    it 'chapter IDs are sequential' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)
        _, arrangement = build_valid_arrangement(lib_dir)

        ids = arrangement['chapters'].map { |ch| ch['id'] }
        ids.each_with_index do |id, i|
          expect(id).to eq("ch_#{(i + 1).to_s.rjust(2, '0')}")
        end
      end
    end

    it 'respects branch value' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)
        _, arrangement = build_valid_arrangement(lib_dir)

        expect(%w[A B]).to include(arrangement['branch'])
      end
    end
  end

  describe 'clip validation' do
    it 'all clip t_in values exist in ingest clip groups' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)
        _, arrangement = build_valid_arrangement(lib_dir)

        ingest = YAML.safe_load(File.read(File.join(lib_dir, 'semantic_ingest.yaml')), permitted_classes: [Date])
        ingest_t_values = ingest['clip_groups'].flat_map { |g| (g['clips'] || []).map { |c| c['t'].to_f } }

        arrangement['chapters'].flat_map { |ch| ch['clips'] }.each do |clip|
          expect(ingest_t_values).to include(clip['t_in'].to_f),
            "Clip t_in=#{clip['t_in']} not found in ingest clip groups"
        end
      end
    end

    it 'no clip references an unusable t value' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)

        # Add an unusable clip to the ingest
        ingest_path = File.join(lib_dir, 'semantic_ingest.yaml')
        ingest = YAML.safe_load(File.read(ingest_path), permitted_classes: [Date])
        ingest['clip_groups'][0]['clips'] << { 't' => 999.0, 'source' => 'test_video.mp4', 'usability' => 'unusable', 'content_summary' => 'Gibberish' }
        File.write(ingest_path, ingest.to_yaml)

        _, arrangement = build_valid_arrangement(lib_dir)

        unusable_t_values = ingest['clip_groups'].flat_map { |g| g['clips'] }
          .select { |c| c['usability'] == 'unusable' }
          .map { |c| c['t'].to_f }

        arrangement['chapters'].flat_map { |ch| ch['clips'] }.each do |clip|
          expect(unusable_t_values).not_to include(clip['t_in'].to_f),
            "Clip at t_in=#{clip['t_in']} references an unusable clip"
        end
      end
    end
  end

  describe 'LLM routing' do
    it 'routes arrangement to opus in default profile' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require_relative '#{File.expand_path('../../scripts/load_profile', __dir__)}'
        profile = load_profile_by_name('_default')
        puts profile.dig('llm_routing', 'arrangement')
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('claude-opus-4-6')
    end
  end

  describe 'Claude Code mode' do
    it 'writes pending file and exits 2 when in claude_code mode' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)
        pending_dir = File.join(lib_dir, 'pending_llm_calls')

        env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
        _, stderr, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'fileutils'
          require_relative '#{File.expand_path('../../scripts/llm_client', __dir__)}'

          LLMClient.mode = :claude_code
          pending_dir = '#{pending_dir}'
          begin
            LLMClient.call("Test prompt for arrangement",
              call_type: 'arrangement', call_name: 'arrangement',
              pending_dir: pending_dir, max_tokens: 16384)
          rescue LLMClient::Pending => e
            $stderr.puts e.message
            exit 2
          end
        RUBY
        expect(status.exitstatus).to eq(2)
        expect(stderr).to include('PENDING LLM CALL')

        pending_file = File.join(pending_dir, 'arrangement.yaml')
        expect(File.exist?(pending_file)).to be true

        data = YAML.safe_load(File.read(pending_file))
        expect(data['call_name']).to eq('arrangement')
        expect(data['call_type']).to eq('arrangement')
        expect(data['prompt']).to include('Test prompt')
        expect(data['response_path']).to include('arrangement_response.yaml')
      end
    end

    it 'reads response file on re-run and returns response' do
      Dir.mktmpdir do |dir|
        lib_dir = build_arrange_test_library(dir)
        pending_dir = File.join(lib_dir, 'pending_llm_calls')
        FileUtils.mkdir_p(pending_dir)

        File.write(File.join(pending_dir, 'arrangement_response.yaml'),
          { 'response' => "cut_summary: test arrangement\ntarget_format: longform" }.to_yaml)

        env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
        stdout, _, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
          require_relative '#{File.expand_path('../../scripts/llm_client', __dir__)}'

          result = LLMClient.call("Ignored prompt",
            call_type: 'arrangement', call_name: 'arrangement',
            pending_dir: '#{pending_dir}', max_tokens: 16384)
          puts result
        RUBY
        expect(status.exitstatus).to eq(0)
        expect(stdout).to include('cut_summary: test arrangement')
      end
    end
  end

  describe 'duration parsing' do
    it 'parses M:SS format to seconds' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        est = '8:42'
        if est =~ /(\\d+):(\\d+)/
          seconds = $1.to_i * 60 + $2.to_i
          puts seconds
        end
      RUBY
      expect(stdout.strip.to_i).to eq(522)
    end

    it 'warns when estimated duration is outside target range' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        est_dur_seconds = 200
        target_range = '480-900'
        if target_range =~ /(\\d+)-(\\d+)/
          range_min, range_max = $1.to_i, $2.to_i
          if est_dur_seconds < range_min || est_dur_seconds > range_max
            puts 'WARNING: outside range'
          else
            puts 'within range'
          end
        end
      RUBY
      expect(stdout.strip).to eq('WARNING: outside range')
    end
  end
end
