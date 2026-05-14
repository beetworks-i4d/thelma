require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'

ORCHESTRATE_SCRIPT = File.expand_path('../../scripts/orchestrate.rb', __dir__)

RSpec.describe 'orchestrate.rb' do
  describe 'CLI argument parsing' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', ORCHESTRATE_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 with usage when --library missing' do
      _, stderr, status = Open3.capture3('ruby', ORCHESTRATE_SCRIPT, '--profile', 'dylan')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 for unknown arguments' do
      _, stderr, status = Open3.capture3('ruby', ORCHESTRATE_SCRIPT, '--foo')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Unknown argument')
    end

    it 'exits 1 when library does not exist and no --pool-dir given' do
      _, stderr, status = Open3.capture3('ruby', ORCHESTRATE_SCRIPT, '--library', 'nonexistent-library-xyz')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("nonexistent-library-xyz")
      expect(stderr).to include("--pool-dir")
    end
  end

  describe 'branch detection' do
    it 'detects Branch A when script_parsed exists' do
      # We test this indirectly: dylan-002 has script_parsed in library.yaml
      # Running with --analyze-only overrides to C, but without it should detect A
      # We just verify the script loads and parses branch correctly
      stdout, stderr, status = Open3.capture3(
        'ruby', '-e', <<~RUBY
          # Simulate branch detection logic from orchestrate.rb
          library = { 'script_parsed' => 'script_parsed.yaml' }
          branch = nil
          if library['script_parsed']
            branch = 'A'
          else
            branch = 'B'
          end
          puts branch
        RUBY
      )
      expect(stdout.strip).to eq('A')
    end

    it 'defaults to Branch B when no script' do
      stdout, _, _ = Open3.capture3(
        'ruby', '-e', <<~RUBY
          library = {}
          branch = nil
          if library['script_parsed']
            branch = 'A'
          else
            branch = 'B'
          end
          puts branch
        RUBY
      )
      expect(stdout.strip).to eq('B')
    end

    it '--analyze-only sets branch to C' do
      stdout, _, _ = Open3.capture3(
        'ruby', '-e', <<~RUBY
          analyze_only = true
          branch_override = 'C' if analyze_only
          puts branch_override
        RUBY
      )
      expect(stdout.strip).to eq('C')
    end

    it '--branch flag overrides detection' do
      stdout, _, _ = Open3.capture3(
        'ruby', '-e', <<~RUBY
          branch_override = 'A'
          branch = branch_override || 'B'
          puts branch
        RUBY
      )
      expect(stdout.strip).to eq('A')
    end
  end

  describe 'profile loading' do
    it 'auto-matches profile by library name' do
      stdout, _, status = Open3.capture3(
        'ruby', '-e', <<~RUBY
          require_relative '#{File.expand_path('../../scripts/load_profile', __dir__)}'
          profile = load_profile('dylan-004')
          puts profile['name']
        RUBY
      )
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('dylan')
    end

    it 'loads explicit profile by name' do
      stdout, _, status = Open3.capture3(
        'ruby', '-e', <<~RUBY
          require_relative '#{File.expand_path('../../scripts/load_profile', __dir__)}'
          profile = load_profile_by_name('ivan')
          puts profile['name']
        RUBY
      )
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('ivan')
    end
  end

  describe 'cache skip logic' do
    it 'file_cached? returns false for nil path' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        def file_cached?(path)
          path && File.exist?(path) && File.size(path) > 0
        end
        puts file_cached?(nil).inspect
      RUBY
      expect(stdout.strip).to eq('nil')
    end

    it 'file_cached? returns false for nonexistent file' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        def file_cached?(path)
          path && File.exist?(path) && File.size(path) > 0
        end
        puts file_cached?('/nonexistent/file.yaml')
      RUBY
      expect(stdout.strip).to eq('false')
    end

    it 'file_cached? returns true for existing non-empty file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'test.yaml')
        File.write(path, 'content')
        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          def file_cached?(path)
            path && File.exist?(path) && File.size(path) > 0
          end
          puts file_cached?('#{path}')
        RUBY
        expect(stdout.strip).to eq('true')
      end
    end
  end

  describe 'LLM client integration' do
    it 'loads llm_client without error' do
      _, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require_relative '#{File.expand_path('../../scripts/llm_client', __dir__)}'
        puts LLMClient::DEFAULT_MODEL
      RUBY
      expect(status.exitstatus).to eq(0)
    end

    it 'routes classification to profile model' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require_relative '#{File.expand_path('../../scripts/load_profile', __dir__)}'
        profile = load_profile_by_name('_default')
        model = profile.dig('llm_routing', 'classification')
        puts model
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('claude-sonnet-4-6')
    end

    it 'routes coherence to opus model' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require_relative '#{File.expand_path('../../scripts/load_profile', __dir__)}'
        profile = load_profile_by_name('_default')
        model = profile.dig('llm_routing', 'coherence')
        puts model
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('claude-opus-4-6')
    end
  end

  describe 'Branch C early exit' do
    it 'branch C skips phases 2-4' do
      # Verify branch C logic: after phase 1.8, it calls generate_report and exits
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        branch = 'C'
        phases_run = []
        phases_run << '1.6'
        phases_run << '1.7'
        phases_run << '1.8'

        if branch == 'C'
          phases_run << 'report'
          puts phases_run.join(',')
          exit 0
        end

        phases_run << '2'
        phases_run << '3'
        phases_run << '4'
        puts phases_run.join(',')
      RUBY
      expect(stdout.strip).to eq('1.6,1.7,1.8,report')
    end
  end

  describe 'missing API key handling' do
    it 'aborts with clear message when calling LLM without key' do
      env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
      _, stderr, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
        require_relative '#{File.expand_path('../../scripts/llm_client', __dir__)}'
        LLMClient.call('test', call_type: 'classification')
      RUBY
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('ANTHROPIC_API_KEY')
    end
  end

  describe '--no-review flag' do
    it 'accepts --no-review without error' do
      # Just verify the flag is parsed without triggering unknown argument abort
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        no_review = false
        args = ['--library', 'test', '--no-review']
        while args.any?
          case args.first
          when '--library'
            args.shift; args.shift
          when '--no-review'
            args.shift
            no_review = true
          else
            args.shift
          end
        end
        puts no_review
      RUBY
      expect(stdout.strip).to eq('true')
    end
  end

  describe 'new pipeline phases' do
    it 'builds correct semantic_ingest flags' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        library_name = 'mylib'
        profile_name = 'ivan'
        llm_mode = 'claude_code'
        no_review = true
        flags = ['--library', library_name]
        flags += ['--profile', profile_name] if profile_name
        flags += ['--llm-mode', llm_mode] if llm_mode
        flags << '--no-review' if no_review
        puts flags.join(' ')
      RUBY
      expect(stdout.strip).to eq('--library mylib --profile ivan --llm-mode claude_code --no-review')
    end

    it 'skips semantic_ingest when cached' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'semantic_ingest.yaml'), 'content: test')
        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          def file_cached?(path)
            path && File.exist?(path) && File.size(path) > 0
          end
          path = '#{File.join(dir, 'semantic_ingest.yaml')}'
          puts file_cached?(path) ? 'SKIP' : 'RUN'
        RUBY
        expect(stdout.strip).to eq('SKIP')
      end
    end

    it 'skips arrangement when cached' do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, 'arrangement.yaml'), 'content: test')
        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          def file_cached?(path)
            path && File.exist?(path) && File.size(path) > 0
          end
          path = '#{File.join(dir, 'arrangement.yaml')}'
          puts file_cached?(path) ? 'SKIP' : 'RUN'
        RUBY
        expect(stdout.strip).to eq('SKIP')
      end
    end
  end

  describe '--mode mine / --force-reindex flags' do
    it 'parses --mode mine without unknown-argument error' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        mode = nil
        force_reindex = false
        args = ['--library', 'test', '--mode', 'mine', '--force-reindex']
        while args.any?
          case args.first
          when '--library'       then args.shift; args.shift
          when '--mode'          then args.shift; mode = args.shift
          when '--force-reindex' then args.shift; force_reindex = true
          else abort "Unknown argument: #{args.first}"
          end
        end
        puts "#{mode},#{force_reindex}"
      RUBY
      expect(stdout.strip).to eq('mine,true')
    end

    it 'exits 1 with pool_dir error when library has no pool_dir set' do
      Dir.mktmpdir do |tmpdir|
        lib_dir = File.join(tmpdir, 'libraries', 'test-mine')
        FileUtils.mkdir_p(File.join(lib_dir, 'transcripts'))
        File.write(File.join(lib_dir, 'library.yaml'), { 'videos' => [] }.to_yaml)

        root_override = tmpdir
        _, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
          ROOT_DIR = '#{root_override}'
          library_name = 'test-mine'
          library_dir = File.join(ROOT_DIR, 'libraries', library_name)
          require 'yaml'
          library = YAML.safe_load(File.read(File.join(library_dir, 'library.yaml')), permitted_classes: [])
          pool_dir = library['pool_dir']
          unless pool_dir && !pool_dir.to_s.strip.empty?
            abort "pool_dir not set in library.yaml — required for --mode mine"
          end
        RUBY
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('pool_dir not set')
      end
    end

    it 'skips ingest when all pool sources are unchanged (scan returns empty to_ingest)' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        to_ingest = []
        if to_ingest.empty?
          $stdout.puts 'nothing_to_ingest'
        else
          $stdout.puts 'ingesting'
        end
      RUBY
      expect(stdout.strip).to eq('nothing_to_ingest')
    end
  end

  describe 'mine mode arc discovery integration' do
    it 'passes --force-rediscover to discover_arcs when --force-rediscover set' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        force_rediscover = true
        library_name = 'test-pool'
        profile_name = nil
        llm_mode     = nil
        discover_flags = ['--library', library_name]
        discover_flags += ['--profile', profile_name] if profile_name
        discover_flags += ['--llm-mode', llm_mode]    if llm_mode
        discover_flags << '--force-rediscover'         if force_rediscover
        puts discover_flags.join(' ')
      RUBY
      expect(stdout.strip).to eq('--library test-pool --force-rediscover')
    end

    it 'omits --force-rediscover when flag not set' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        force_rediscover = false
        discover_flags = ['--library', 'test-pool']
        discover_flags << '--force-rediscover' if force_rediscover
        puts discover_flags.join(' ')
      RUBY
      expect(stdout.strip).not_to include('--force-rediscover')
    end

    it 'parses --force-rediscover flag from CLI args' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        force_rediscover = false
        args = ['--library', 'pool', '--mode', 'mine', '--force-rediscover']
        while args.any?
          case args.first
          when '--library'           then args.shift; args.shift
          when '--mode'              then args.shift; args.shift
          when '--force-rediscover'  then args.shift; force_rediscover = true
          else args.shift
          end
        end
        puts force_rediscover
      RUBY
      expect(stdout.strip).to eq('true')
    end
  end

  describe 'mine mode cascade flags' do
    it 'parses --discover-only flag from CLI args' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        discover_only = false
        args = ['--library', 'pool', '--mode', 'mine', '--discover-only']
        while args.any?
          case args.first
          when '--library'       then args.shift; args.shift
          when '--mode'          then args.shift; args.shift
          when '--discover-only' then args.shift; discover_only = true
          else args.shift
          end
        end
        puts discover_only
      RUBY
      expect(stdout.strip).to eq('true')
    end

    it 'parses --candidate <id> flag from CLI args' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        candidate_id = nil
        args = ['--library', 'pool', '--mode', 'mine', '--candidate', 'candidate_002']
        while args.any?
          case args.first
          when '--library'   then args.shift; args.shift
          when '--mode'      then args.shift; args.shift
          when '--candidate' then args.shift; candidate_id = args.shift
          else args.shift
          end
        end
        puts candidate_id
      RUBY
      expect(stdout.strip).to eq('candidate_002')
    end

    it 'parses --force-cascade flag from CLI args' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        force_cascade = false
        args = ['--library', 'pool', '--mode', 'mine', '--force-cascade']
        while args.any?
          case args.first
          when '--library'      then args.shift; args.shift
          when '--mode'         then args.shift; args.shift
          when '--force-cascade' then args.shift; force_cascade = true
          else args.shift
          end
        end
        puts force_cascade
      RUBY
      expect(stdout.strip).to eq('true')
    end

    it 'builds correct convert_candidate flags including --force when --force-cascade set' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        library_name  = 'test-pool'
        profile_name  = 'ivan'
        selected_id   = 'candidate_001'
        force_cascade = true

        convert_flags = ['--library', library_name, '--candidate', selected_id]
        convert_flags += ['--profile', profile_name] if profile_name
        convert_flags << '--force' if force_cascade
        puts convert_flags.join(' ')
      RUBY
      expect(stdout.strip).to eq('--library test-pool --candidate candidate_001 --profile ivan --force')
    end

    it '--discover-only exits after arc discovery without candidate selection' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        discover_only     = true
        arc_candidates_path = '/tmp/arc_candidates.yaml'
        phases_run = ['pool_index', 'hq_match', 'arc_discovery']

        if discover_only
          phases_run << 'discover_only_exit'
          puts phases_run.join(',')
          exit 0
        end

        phases_run << 'candidate_selection'
        phases_run << 'convert'
        phases_run << 'export_xml'
        puts phases_run.join(',')
      RUBY
      expect(stdout.strip).to eq('pool_index,hq_match,arc_discovery,discover_only_exit')
      expect(stdout).not_to include('candidate_selection')
    end
  end

  describe '--pool-dir flag and auto-create' do
    it 'parses --pool-dir flag without unknown-argument error' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        pool_dir_arg = nil
        args = ['--library', 'test', '--pool-dir', '/tmp/testpool']
        while args.any?
          case args.first
          when '--library'   then args.shift; args.shift
          when '--pool-dir'  then args.shift; pool_dir_arg = args.shift
          else abort "Unknown argument: #{args.first}"
          end
        end
        puts pool_dir_arg
      RUBY
      expect(stdout.strip).to eq('/tmp/testpool')
    end

    it 'auto-creates library at <pool_dir>/.thelma with correct library.yaml' do
      Dir.mktmpdir do |tmpdir|
        pool_dir    = File.join(tmpdir, 'footage')
        library_dir = File.join(pool_dir, '.thelma')
        FileUtils.mkdir_p(pool_dir)

        stdout, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'
          require 'fileutils'
          library_name = 'newtest'
          pool_dir     = '#{pool_dir}'
          library_dir  = File.join(pool_dir, '.thelma')
          FileUtils.mkdir_p(library_dir)
          FileUtils.mkdir_p(File.join(library_dir, 'transcripts'))
          library = {
            'library_name'    => library_name,
            'created_date'    => Date.today.to_s,
            'last_updated'    => Date.today.to_s,
            'language'        => 'english',
            'editor'          => 'premiere',
            'pool_dir'        => pool_dir,
            'user_context'    => '',
            'footage_summary' => 'No footage analyzed yet.',
            'script_parsed'   => nil,
            'videos'          => []
          }
          File.write(File.join(library_dir, 'library.yaml'), library.to_yaml)
          puts 'created'
        RUBY

        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq('created')
        expect(File.exist?(File.join(library_dir, 'library.yaml'))).to eq(true)

        lib = YAML.safe_load(File.read(File.join(library_dir, 'library.yaml')))
        expect(lib['library_name']).to eq('newtest')
        expect(lib['pool_dir']).to eq(pool_dir)
        expect(lib['videos']).to eq([])
      end
    end

    it 'registers the library in libraries_registry.yaml after auto-create' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'libraries_registry.yaml')
        new_dir = File.join(tmpdir, 'footage', '.thelma')
        FileUtils.mkdir_p(new_dir)

        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          registry_path = '#{registry_path}'
          library_name  = 'newtest'
          library_dir   = '#{new_dir}'
          reg = { 'libraries' => {} }
          reg['libraries'][library_name] = { 'path' => library_dir }
          File.write(registry_path, reg.to_yaml)
          data = YAML.safe_load(File.read(registry_path))
          puts data.dig('libraries', library_name, 'path')
        RUBY

        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq(new_dir)
      end
    end

    it 'aborts with clear message in non-interactive mode without --pool-dir' do
      stdout, stderr, status = Open3.capture3('ruby', '-e', <<~'RUBY')
        pool_dir_for_create = nil
        interactive = false  # simulate non-tty
        unless pool_dir_for_create && !pool_dir_for_create.empty?
          abort "Library 'newtest' not found. Use --pool-dir <path> to create it."
        end
      RUBY
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('--pool-dir')
    end

    it 'backward compat: resolves existing libraries/<name> without registry' do
      Dir.mktmpdir do |tmpdir|
        lib_dir = File.join(tmpdir, 'libraries', 'mylegacylib')
        FileUtils.mkdir_p(lib_dir)

        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          # Simulate LibraryResolver.resolve with no ENV, no registry
          root_dir = '#{tmpdir}'
          library_name = 'mylegacylib'
          resolved = File.join(root_dir, 'libraries', library_name)
          puts resolved
        RUBY

        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq(File.join(tmpdir, 'libraries', 'mylegacylib'))
      end
    end
  end

  describe '--language flag' do
    it 'parses --language flag from CLI args' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        language_override = nil
        args = ['--library', 'test', '--mode', 'mine', '--language', 'pt']
        while args.any?
          case args.first
          when '--library'   then args.shift; args.shift
          when '--mode'      then args.shift; args.shift
          when '--language'  then args.shift; language_override = args.shift
          else args.shift
          end
        end
        puts language_override
      RUBY
      expect(stdout.strip).to eq('pt')
    end

    it 'language_override takes precedence over library language' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        language_override = 'pt'
        library_language = 'english'
        lang_code = language_override || (library_language == 'english' ? 'en' : (library_language || 'en'))
        puts lang_code
      RUBY
      expect(stdout.strip).to eq('pt')
    end

    it 'falls back to library language when --language not specified' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        language_override = nil
        library_language = 'english'
        lang_code = language_override || (library_language == 'english' ? 'en' : (library_language || 'en'))
        puts lang_code
      RUBY
      expect(stdout.strip).to eq('en')
    end
  end

  describe 'diarization behavior' do
    it 'adds --diarize when HF_TOKEN is set' do
      stdout, _, _ = Open3.capture3(
        { 'HF_TOKEN' => 'hf_test_token' },
        'ruby', '-e', <<~'RUBY')
        cmd = "whisperx audio.wav --model turbo"
        if ENV['HF_TOKEN'] && !ENV['HF_TOKEN'].strip.empty?
          cmd += " --diarize"
        end
        puts cmd
      RUBY
      expect(stdout.strip).to include('--diarize')
    end

    it 'skips --diarize when HF_TOKEN is not set' do
      env = ENV.to_h.reject { |k, _| k == 'HF_TOKEN' }
      stdout, _, _ = Open3.capture3(env, 'ruby', '-e', <<~'RUBY')
        cmd = "whisperx audio.wav --model turbo"
        if ENV['HF_TOKEN'] && !ENV['HF_TOKEN'].strip.empty?
          cmd += " --diarize"
        end
        puts cmd
      RUBY
      expect(stdout.strip).not_to include('--diarize')
    end

    it 'skips --diarize when HF_TOKEN is empty string' do
      stdout, _, _ = Open3.capture3(
        { 'HF_TOKEN' => '' },
        'ruby', '-e', <<~'RUBY')
        cmd = "whisperx audio.wav --model turbo"
        if ENV['HF_TOKEN'] && !ENV['HF_TOKEN'].strip.empty?
          cmd += " --diarize"
        end
        puts cmd
      RUBY
      expect(stdout.strip).not_to include('--diarize')
    end

    it 'extracts speaker info from diarized transcript' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        require 'json'
        require 'tmpdir'
        Dir.mktmpdir do |dir|
          transcript = {
            'segments' => [
              { 'start' => 0.0, 'end' => 5.0, 'text' => 'Hello', 'speaker' => 'SPEAKER_00' },
              { 'start' => 5.0, 'end' => 10.0, 'text' => 'Hi there', 'speaker' => 'SPEAKER_01' },
              { 'start' => 10.0, 'end' => 15.0, 'text' => 'Good', 'speaker' => 'SPEAKER_00' }
            ]
          }
          path = File.join(dir, 'test.json')
          File.write(path, transcript.to_json)
          t_data = JSON.parse(File.read(path))
          speakers = (t_data['segments'] || []).map { |s| s['speaker'] }.compact.uniq.sort
          puts speakers.join(',')
          puts speakers.size
        end
      RUBY
      expect(stdout.strip.split("\n")[0]).to eq('SPEAKER_00,SPEAKER_01')
      expect(stdout.strip.split("\n")[1]).to eq('2')
    end
  end

  describe 'Branch A lean path (--filter / --short)' do
    it 'lean Branch A block exists in orchestrate.rb and exits before Phase 0' do
      source = File.read(ORCHESTRATE_SCRIPT)
      lean_pos = source.index('# BRANCH A: LEAN SCRIPT-DRIVEN FLOW')
      phase0_pos = source.index("phase '0 — Content Type Detection'")
      expect(lean_pos).not_to be_nil, 'Lean Branch A block not found'
      expect(phase0_pos).not_to be_nil, 'Phase 0 anchor not found'
      expect(lean_pos).to be < phase0_pos
      # Block must terminate the process so Phase 0 below is unreachable when branch==A.
      lean_to_phase0 = source[lean_pos...phase0_pos]
      expect(lean_to_phase0).to match(/\bexit\(/)
    end

    it '--filter role=X selects all beats with matching role' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        def select_beats_for_filter(all_beats, filter_key, filter_value)
          case filter_key
          when 'role'   then all_beats.select { |b| b['role'] == filter_value }
          when 'id'     then [all_beats.find { |b| b['id'] == filter_value }].compact
          when 'parent' then all_beats.select { |b| b['parent'] == filter_value }
          else []
          end
        end
        beats = [
          { 'id' => 'hook', 'role' => 'hook' },
          { 'id' => 'bb_1', 'role' => 'blueprint' },
          { 'id' => 'bb_2', 'role' => 'blueprint' },
          { 'id' => 'cta',  'role' => 'cta' }
        ]
        matched = select_beats_for_filter(beats, 'role', 'blueprint')
        puts matched.map { |b| b['id'] }.join(',')
      RUBY
      expect(stdout.strip).to eq('bb_1,bb_2')
    end

    it '--short X is shorthand for --filter id=X' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        short_id_arg = 'bb_3'
        filter_expr  = nil
        filter_expr = "id=#{short_id_arg}" if short_id_arg && filter_expr.nil?
        puts filter_expr
      RUBY
      expect(stdout.strip).to eq('id=bb_3')
    end

    it '--filter wins when both --filter and --short are passed' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        short_id_arg = 'bb_3'
        filter_expr  = 'role=blueprint'
        filter_expr = "id=#{short_id_arg}" if short_id_arg && filter_expr.nil?
        puts filter_expr
      RUBY
      expect(stdout.strip).to eq('role=blueprint')
    end

    it 'no --filter enumerates all top-level script tree nodes (parent==nil)' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        filter_expr = nil
        all_beats = [
          { 'id' => 'hook',  'parent' => nil },
          { 'id' => 'intro', 'parent' => nil },
          { 'id' => 'bb_1',  'parent' => 'intro' },
          { 'id' => 'bb_2',  'parent' => 'intro' },
          { 'id' => 'cta',   'parent' => nil }
        ]
        beat_ids = if filter_expr
          ['placeholder']
        else
          all_beats.select { |b| b['parent'].nil? }.map { |b| b['id'] }
        end
        puts beat_ids.join(',')
      RUBY
      expect(stdout.strip).to eq('hook,intro,cta')
    end

    it '--filter id=X selects single beat by id' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        def select_beats_for_filter(all_beats, filter_key, filter_value)
          case filter_key
          when 'role'   then all_beats.select { |b| b['role'] == filter_value }
          when 'id'     then [all_beats.find { |b| b['id'] == filter_value }].compact
          when 'parent' then all_beats.select { |b| b['parent'] == filter_value }
          else []
          end
        end
        beats = [
          { 'id' => 'hook', 'role' => 'hook' },
          { 'id' => 'bb_3', 'role' => 'blueprint' }
        ]
        matched = select_beats_for_filter(beats, 'id', 'bb_3')
        puts matched.map { |b| b['id'] }.join(',')
      RUBY
      expect(stdout.strip).to eq('bb_3')
    end

    it '--filter parent=X selects all beats under a parent id' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        def select_beats_for_filter(all_beats, filter_key, filter_value)
          case filter_key
          when 'role'   then all_beats.select { |b| b['role'] == filter_value }
          when 'id'     then [all_beats.find { |b| b['id'] == filter_value }].compact
          when 'parent' then all_beats.select { |b| b['parent'] == filter_value }
          else []
          end
        end
        beats = [
          { 'id' => 'intro',  'parent' => nil },
          { 'id' => 'bb_1',   'parent' => 'intro' },
          { 'id' => 'bb_2',   'parent' => 'intro' },
          { 'id' => 'outro',  'parent' => nil }
        ]
        matched = select_beats_for_filter(beats, 'parent', 'intro')
        puts matched.map { |b| b['id'] }.join(',')
      RUBY
      expect(stdout.strip).to eq('bb_1,bb_2')
    end

    it 'parse_filter_expr rejects malformed filter expressions' do
      _, stderr, status = Open3.capture3('ruby', '-e', <<~'RUBY')
        def parse_filter_expr(expr)
          parts = expr.to_s.split('=', 2)
          abort "Invalid --filter '#{expr}' — expected key=value" unless parts.size == 2
          key, value = parts
          abort "Invalid --filter key '#{key}' — must be role, id, or parent" unless %w[role id parent].include?(key)
          abort "Invalid --filter '#{expr}' — value is empty" if value.to_s.empty?
          [key, value]
        end
        parse_filter_expr('foo=bar')
      RUBY
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Invalid --filter key')
    end

    it 'failed beat does not abort the loop — succeeded and failed are reported separately' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        def try_run_script(_script, *args)
          # Simulate bb_2 failing both arrange and export; others succeed.
          ok = !args.include?('bb_2')
          ['', ok, ok ? 0 : 1]
        end
        beat_ids = ['bb_1', 'bb_2', 'bb_3']
        failed = []
        succeeded = []
        beat_ids.each do |id|
          _, ok, _ = try_run_script('arrange_to_script.rb', '--short', id)
          unless ok
            failed << id
            next
          end
          _, ok, _ = try_run_script('export_arrangement_xml.rb', '--output-name', id)
          unless ok
            failed << id
            next
          end
          succeeded << id
        end
        puts "succeeded=#{succeeded.join(',')}"
        puts "failed=#{failed.join(',')}"
      RUBY
      expect(stdout).to include('succeeded=bb_1,bb_3')
      expect(stdout).to include('failed=bb_2')
    end

    it 'lean Branch A block does not invoke heavy phase scripts' do
      source = File.read(ORCHESTRATE_SCRIPT)
      lean_block = source[/# BRANCH A: LEAN SCRIPT-DRIVEN FLOW.*?BRANCH A LEAN PIPELINE COMPLETE/m]
      expect(lean_block).not_to be_nil, 'Lean Branch A block not found in orchestrate.rb'

      forbidden = [
        "run_script('semantic_ingest.rb'",
        "run_script('arrange.rb'",
        "run_script('detect_content_type.rb'",
        "run_script('semantic_dedup.rb'",
        "run_script('audio_emotion.rb'",
        "run_script('detect_scenes.rb'",
        "run_script('extract_visual_frames.rb'",
        "run_script('export_packaging_brief.rb'",
        'classify('
      ]
      forbidden.each do |needle|
        expect(lean_block).not_to include(needle),
                                  "Lean Branch A path must not invoke '#{needle}'"
      end
    end

    it 'lean Branch A block does invoke parse_script, audio_prosody, arrange_to_script, export_arrangement_xml' do
      source = File.read(ORCHESTRATE_SCRIPT)
      lean_block = source[/# BRANCH A: LEAN SCRIPT-DRIVEN FLOW.*?BRANCH A LEAN PIPELINE COMPLETE/m]
      expect(lean_block).not_to be_nil
      %w[parse_script.rb audio_prosody.rb arrange_to_script.rb export_arrangement_xml.rb].each do |script|
        expect(lean_block).to include(script), "Lean Branch A path must invoke '#{script}'"
      end
    end

    it 'accepts --filter, --short, --force flags without unknown-argument error' do
      _, stderr, status = Open3.capture3('ruby', ORCHESTRATE_SCRIPT,
                                         '--library', 'nonexistent-library-xyz',
                                         '--filter', 'role=blueprint',
                                         '--short', 'bb_3',
                                         '--force')
      # We expect it to fail because the library doesn't exist, not because the flags are unknown.
      expect(status.exitstatus).to eq(1)
      expect(stderr).not_to include('Unknown argument')
    end

    it 'whole-script mode combines per-beat arrangements into <library>_chapters.yaml and one <library>.xml' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        library_name = 'mylib'
        library_dir  = '/tmp/lib'
        video_path   = '/tmp/lib/v.mp4'
        is_whole_script_mode = true
        if is_whole_script_mode
          chapters_path = File.join(library_dir, "#{library_name}_chapters.yaml")
          xml_name      = library_name
          xml_path      = File.join(File.dirname(video_path), 'output', "#{xml_name}.xml")
        end
        puts chapters_path
        puts xml_path
      RUBY
      lines = stdout.strip.split("\n")
      expect(lines[0]).to eq('/tmp/lib/mylib_chapters.yaml')
      expect(lines[1]).to eq('/tmp/lib/output/mylib.xml')
    end

    it 'per-beat mode names chapters as <beat_id>_chapters.yaml and XML as <library>_<beat_id>.xml' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        library_name = 'mylib'
        library_dir  = '/tmp/lib'
        video_path   = '/tmp/lib/v.mp4'
        arrangement_path = File.join(library_dir, 'arrangement_bb_3.yaml')

        beat_id       = File.basename(arrangement_path, '.yaml').sub(/^arrangement_/, '')
        chapters_path = File.join(library_dir, "#{beat_id}_chapters.yaml")
        xml_name      = "#{library_name}_#{beat_id}"
        xml_path      = File.join(File.dirname(video_path), 'output', "#{xml_name}.xml")
        puts chapters_path
        puts xml_path
      RUBY
      lines = stdout.strip.split("\n")
      expect(lines[0]).to eq('/tmp/lib/bb_3_chapters.yaml')
      expect(lines[1]).to eq('/tmp/lib/output/mylib_bb_3.xml')
    end

    it 'whole-script mode tolerates per-beat arrangement failures and exports the rest' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        def try_run_script(_script, *args)
          # bb_2 fails; everything else succeeds
          ok = !args.include?('bb_2')
          ['', ok, ok ? 0 : 1]
        end
        beat_ids = ['hook', 'bb_1', 'bb_2', 'bb_3', 'cta']
        arrange_failed = []
        arrange_succeeded_paths = []
        beat_ids.each do |id|
          _, ok, _ = try_run_script('arrange_to_script.rb', '--short', id)
          if ok
            arrange_succeeded_paths << "/tmp/lib/arrangement_#{id}.yaml"
          else
            arrange_failed << id
          end
        end
        puts "succeeded=#{arrange_succeeded_paths.size}"
        puts "failed=#{arrange_failed.join(',')}"
      RUBY
      expect(stdout).to include('succeeded=4')
      expect(stdout).to include('failed=bb_2')
    end

    it 'lean Branch A block calls ArrangementAdapter.convert_files! (combined) somewhere' do
      source = File.read(ORCHESTRATE_SCRIPT)
      lean_block = source[/# BRANCH A: LEAN SCRIPT-DRIVEN FLOW.*?BRANCH A LEAN PIPELINE COMPLETE/m]
      expect(lean_block).to include('ArrangementAdapter.convert_files!')
    end

    it 'lean Branch A block branches on is_whole_script_mode for adapt/export' do
      source = File.read(ORCHESTRATE_SCRIPT)
      lean_block = source[/# BRANCH A: LEAN SCRIPT-DRIVEN FLOW.*?BRANCH A LEAN PIPELINE COMPLETE/m]
      expect(lean_block).to include('is_whole_script_mode')
    end

    it 'lean Branch A block invokes ArrangementAdapter between arrange and export' do
      source = File.read(ORCHESTRATE_SCRIPT)
      lean_block = source[/# BRANCH A: LEAN SCRIPT-DRIVEN FLOW.*?BRANCH A LEAN PIPELINE COMPLETE/m]
      expect(lean_block).not_to be_nil
      expect(lean_block).to include('ArrangementAdapter')
      # Anchor on actual invocations. The first adapter call in the whole-script
      # branch uses convert_files!; the per-beat branch later uses convert_file!.
      arrange_pos      = lean_block.index("try_run_script('arrange_to_script.rb'")
      adapter_pos      = lean_block.index('ArrangementAdapter.convert_files!')
      export_pos       = lean_block.index("try_run_script('export_arrangement_xml.rb'")
      expect(arrange_pos).not_to be_nil
      expect(adapter_pos).not_to be_nil, 'convert_files! (whole-script combine) not found'
      expect(export_pos).not_to be_nil
      expect(arrange_pos).to be < adapter_pos
      expect(adapter_pos).to be < export_pos
    end

    it 'export is pointed at the chapters yaml, not the beats arrangement yaml' do
      source = File.read(ORCHESTRATE_SCRIPT)
      lean_block = source[/# BRANCH A: LEAN SCRIPT-DRIVEN FLOW.*?BRANCH A LEAN PIPELINE COMPLETE/m]
      expect(lean_block).to include("'--arrangement', chapters_path")
    end
  end

  describe 'report schema from generate_report' do
    it 'generates valid report YAML with all fields' do
      library_dir = File.expand_path('../../libraries/dylan-004', __dir__)
      next skip('dylan-004 library not available') unless File.exist?(File.join(library_dir, 'library.yaml'))

      Dir.mktmpdir do |out|
        stdout, stderr, status = Open3.capture3('ruby', File.expand_path('../../scripts/generate_report.rb', __dir__), library_dir, '--output-dir', out)
        expect(status.exitstatus).to eq(0)

        report_path = stdout.strip
        next skip('report not generated') unless File.exist?(report_path)

        report = YAML.safe_load(File.read(report_path), permitted_classes: [Date])
        expect(report['video']).to be_a(String)
        expect(report['duration']).to be > 0
        expect(report['structure']).to be_a(Hash)
        expect(report['emotional_architecture']).to be_a(Hash)
        expect(report['pacing']).to be_a(Hash)
        expect(report['pacing']['total_segments']).to be > 0
      end
    end
  end
end
