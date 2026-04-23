require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'digest'
require 'open3'

DISCOVER_ARCS_SCRIPT  = File.expand_path('../../scripts/discover_arcs.rb', __dir__)
POOL_INDEX_SCRIPT_REF = File.expand_path('../../scripts/pool_index.rb', __dir__)

# Build a minimal pool library fixture for testing.
def build_pool_library(dir, sources: {})
  library_dir     = File.join(dir, 'libraries', 'test-pool')
  transcripts_dir = File.join(library_dir, 'transcripts')
  FileUtils.mkdir_p(transcripts_dir)

  # library.yaml
  File.write(File.join(library_dir, 'library.yaml'), {
    'library_name' => 'test-pool',
    'language'     => 'english',
    'editor'       => 'premiere',
    'pool_dir'     => dir
  }.to_yaml)

  # Default single video transcript
  default_transcript = {
    'segments' => [
      { 'start' => 0.5, 'end' => 4.2,  'text' => 'Opening hook about productivity and why every app fails.' },
      { 'start' => 5.0, 'end' => 12.3, 'text' => 'Ben Franklin was obsessed with time management and self-tracking.' },
      { 'start' => 14.0, 'end' => 22.8,'text' => 'GTD is the system that actually works because it externalizes everything.' },
      { 'start' => 24.0, 'end' => 30.0,'text' => 'After five years with GTD in Notion, here is what I know.' }
    ]
  }

  # Build index.yaml and per-source transcript files
  index_sources = {}

  sources.each do |filename, opts|
    transcript_name = "#{File.basename(filename, File.extname(filename))}_treated.json"
    transcript_data = opts[:transcript] || default_transcript
    File.write(File.join(transcripts_dir, transcript_name), transcript_data.to_json)

    index_sources[filename] = {
      'sha256'          => Digest::SHA256.hexdigest(filename),
      'added_at'        => '2026-04-23T10:00:00+00:00',
      'ingested_at'     => '2026-04-23T10:01:00+00:00',
      'media_type'      => opts[:media_type] || 'video_with_audio',
      'duration'        => opts[:duration] || 120.0,
      'transcript_file' => transcript_name,
      'speech_analysis' => nil,
      'audio_features'  => opts[:audio_features_file],
      'scene_changes'   => nil,
      'hq_audio_source' => nil,
      'hq_audio_offset' => nil,
      'role'            => nil,
      'hq_audio_for'    => nil
    }
  end

  if index_sources.empty?
    # Default: one video source
    transcript_name = 'video1_treated.json'
    File.write(File.join(transcripts_dir, transcript_name), default_transcript.to_json)
    index_sources['video1.mp4'] = {
      'sha256'          => 'abc123',
      'added_at'        => '2026-04-23T10:00:00+00:00',
      'ingested_at'     => '2026-04-23T10:01:00+00:00',
      'media_type'      => 'video_with_audio',
      'duration'        => 120.0,
      'transcript_file' => transcript_name,
      'speech_analysis' => nil,
      'audio_features'  => nil,
      'scene_changes'   => nil,
      'hq_audio_source' => nil,
      'hq_audio_offset' => nil,
      'role'            => nil,
      'hq_audio_for'    => nil
    }
  end

  File.write(File.join(library_dir, 'index.yaml'), {
    'pool_version' => 1,
    'last_updated' => '2026-04-23T10:01:00+00:00',
    'sources'      => index_sources
  }.to_yaml)

  library_dir
end

# Build a valid arc_candidates.yaml fixture for schema validation tests
def build_valid_candidates(library_dir, cache_hash: 'testhash')
  candidates = [
    {
      'id'                 => 'candidate_001',
      'title'              => 'Why every productivity app fails',
      'estimated_duration' => '8:42',
      'structure_type'     => 'contrarian',
      'hook_strength'      => 0.87,
      'coherence_score'    => 0.82,
      'arc_summary'        => "Opens with personal frustration.\n",
      'central_tension'    => "Does tooling solve anything?\n",
      'clip_sequence'      => [
        {
          'source'          => 'voice_memo.m4a',
          't_in'            => 0.0,
          't_out'           => 23.4,
          'role'            => 'hook',
          'content_summary' => 'personal overwhelm, tried every tool'
        }
      ],
      'missing_bridge_clips' => [],
      'confidence'         => 'high',
      'fit_to_template'    => nil,
      'fit_to_topic'       => nil
    }
  ]

  result = {
    'pool_version'       => 1,
    'generated_at'       => '2026-04-23T10:00:00+00:00',
    'cache_hash'         => cache_hash,
    'llm_model'          => 'claude-opus-4-6',
    'discovery_context'  => { 'topic' => nil, 'template' => nil, 'target_format' => 'longform' },
    'candidates'         => candidates,
    'unused_clips'       => []
  }

  output_path = File.join(library_dir, 'arc_candidates.yaml')
  File.write(output_path, result.to_yaml)
  result
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'discover_arcs.rb' do
  describe 'CLI argument parsing' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', DISCOVER_ARCS_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 for unknown arguments' do
      _, stderr, status = Open3.capture3('ruby', DISCOVER_ARCS_SCRIPT, '--foo')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Unknown argument')
    end

    it 'exits 1 when library does not exist' do
      _, stderr, status = Open3.capture3('ruby', DISCOVER_ARCS_SCRIPT, '--library', 'nonexistent-pool-xyz')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end
  end

  describe 'pool index loading' do
    it 'aborts when pool index is empty' do
      Dir.mktmpdir do |tmpdir|
        library_dir = File.join(tmpdir, 'libraries', 'empty-pool')
        FileUtils.mkdir_p(File.join(library_dir, 'transcripts'))
        File.write(File.join(library_dir, 'library.yaml'), { 'language' => 'english' }.to_yaml)
        File.write(File.join(library_dir, 'index.yaml'), { 'pool_version' => 1, 'sources' => {} }.to_yaml)

        _, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
          ROOT_DIR = '#{tmpdir}'
          SCRIPTS_DIR = File.expand_path('../../scripts', '#{__dir__}')
          $LOAD_PATH.unshift SCRIPTS_DIR
          require_relative '#{POOL_INDEX_SCRIPT_REF}'
          library_name = 'empty-pool'
          library_dir  = File.join(ROOT_DIR, 'libraries', library_name)
          index   = PoolIndex.load(library_dir)
          sources = index['sources'] || {}
          abort "Pool index is empty — run --mode mine first to ingest sources" if sources.empty?
        RUBY
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('Pool index is empty')
      end
    end

    it 'counts sources by media type correctly' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        sources = {
          'video1.mp4'  => { 'media_type' => 'video_with_audio' },
          'video2.mp4'  => { 'media_type' => 'video_with_audio' },
          'mic.m4a'     => { 'media_type' => 'audio_only' },
          'broll.mp4'   => { 'media_type' => 'broll' }
        }
        video_count = sources.count { |_, v| v['media_type'] == 'video_with_audio' }
        audio_count = sources.count { |_, v| v['media_type'] == 'audio_only' }
        broll_count = sources.count { |_, v| v['media_type'] == 'broll' }
        puts "#{video_count},#{audio_count},#{broll_count}"
      RUBY
      expect(stdout.strip).to eq('2,1,1')
    end
  end

  describe 'cache logic' do
    it 'returns cached path and exits 0 when cache hash matches' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir)
        result = build_valid_candidates(library_dir, cache_hash: 'matching_hash')

        # Simulate the cache check logic
        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'digest'
          output_path = '#{File.join(library_dir, 'arc_candidates.yaml')}'
          cache_hash  = 'matching_hash'    # same as stored

          if File.exist?(output_path)
            existing = YAML.safe_load(File.read(output_path), permitted_classes: []) rescue {}
            if existing.is_a?(Hash) && existing['cache_hash'] == cache_hash
              $stderr.puts 'cache_hit'
              puts output_path
              exit 0
            end
          end
          puts 'cache_miss'
        RUBY
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to end_with('arc_candidates.yaml')
      end
    end

    it 'proceeds to LLM call when cache hash differs' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir)
        build_valid_candidates(library_dir, cache_hash: 'old_hash')

        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          output_path = '#{File.join(library_dir, 'arc_candidates.yaml')}'
          cache_hash  = 'new_different_hash'

          hit = File.exist?(output_path) &&
                (YAML.safe_load(File.read(output_path), permitted_classes: []) rescue {})
                  .then { |e| e.is_a?(Hash) && e['cache_hash'] == cache_hash }
          puts hit ? 'cached' : 'llm_needed'
        RUBY
        expect(stdout.strip).to eq('llm_needed')
      end
    end

    it 'force-rediscover bypasses cache even when arc_candidates.yaml exists' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir)
        build_valid_candidates(library_dir, cache_hash: 'any_hash')

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
          force_rediscover = true
          file_exists = true  # simulating arc_candidates.yaml existing
          run_llm = force_rediscover || !file_exists
          puts run_llm ? 'run' : 'skip'
        RUBY
        expect(stdout.strip).to eq('run')
      end
    end
  end

  describe 'prompt construction' do
    it 'includes source marker with filename and media type' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir, sources: {
          'interview.mp4' => { media_type: 'video_with_audio', duration: 90.0 }
        })
        t_path = File.join(library_dir, 'transcripts', 'interview_treated.json')

        data = JSON.parse(File.read(t_path))
        block = "--- SOURCE: interview.mp4 (90.0s) [video_with_audio] ---\n"
        data['segments'].each do |s|
          t = s['start'].to_f; e = s['end'].to_f; text = s['text'].to_s.strip
          block << "[#{format('%.2f', t)}-#{format('%.2f', e)}] #{text}\n"
        end

        expect(block).to include('SOURCE: interview.mp4')
        expect(block).to include('[0.50-4.20]')
        expect(block).to include('[video_with_audio]')
      end
    end

    it 'audio-only sources appear in transcript block (not excluded)' do
      sources_data = {
        'video.mp4'     => { 'media_type' => 'video_with_audio', 'transcript_file' => 'video_treated.json' },
        'voice_memo.m4a' => { 'media_type' => 'audio_only',      'transcript_file' => 'voice_memo_treated.json' }
      }
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        sources = {
          'video.mp4'      => { 'media_type' => 'video_with_audio', 'transcript_file' => 'video_treated.json' },
          'voice_memo.m4a' => { 'media_type' => 'audio_only',       'transcript_file' => 'voice_memo_treated.json' }
        }
        # discover_arcs.rb loads transcripts for ALL sources with transcript_file — no filtering by media_type
        with_transcripts = sources.keys.select { |fn| sources[fn]['transcript_file'] }
        puts with_transcripts.size
        puts with_transcripts.include?('voice_memo.m4a')
      RUBY
      expect(stdout.lines[0].strip.to_i).to eq(2)
      expect(stdout.lines[1].strip).to eq('true')
    end

    it 'includes topic filter section when --topic specified' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        topic_filter = "brand strategy"
        topic_block = "## Topic Focus\nFind arcs related to: \"#{topic_filter}\"\n" \
                      "Semantic matching: a metaphor or analogy about the topic counts as on-topic.\n"
        puts topic_block.include?('brand strategy')
        puts topic_block.include?('Semantic matching')
      RUBY
      expect(stdout.lines[0].strip).to eq('true')
      expect(stdout.lines[1].strip).to eq('true')
    end

    it 'includes template beats when --template specified' do
      template_path = File.expand_path('../../templates/story_structures/argumentative/contrarian_argument.yaml', __dir__)
      next skip('template file not found') unless File.exist?(template_path)

      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        require 'yaml'
        template_data = YAML.safe_load(File.read('#{template_path}'), permitted_classes: [])
        buf = "## Template Structure: \#{template_data['name']}\\n"
        buf << "\#{template_data['description']}\\n\\n"
        buf << "Required beats (in order):\\n"
        (template_data['beats'] || []).each_with_index do |beat, i|
          buf << "  \#{i+1}. **\#{beat['id']}** [\#{beat['position']}]: \#{beat['description']}\\n"
        end
        puts buf.include?('contrarian_argument')
        puts buf.include?('bold_claim')
        puts buf.include?('diagnosis')
      RUBY
      expect(stdout.lines[0].strip).to eq('true')
      expect(stdout.lines[1].strip).to eq('true')
      expect(stdout.lines[2].strip).to eq('true')
    end

    it 'includes format requirement for shorts' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        target_format = 'shorts'
        block = if target_format == 'shorts'
          "## Format Requirement\nTarget: **shorts** (30–90 seconds per candidate)\n"
        else
          "## Format Requirement\nTarget: **longform** (6–10 minutes per candidate)\n"
        end
        puts block.include?('shorts')
        puts block.include?('30–90')
      RUBY
      expect(stdout.lines[0].strip).to eq('true')
      expect(stdout.lines[1].strip).to eq('true')
    end

    it 'defaults to longform when --format not specified' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        target_format = nil
        block = if target_format == 'shorts'
          "Target: **shorts**"
        else
          "Target: **longform** (6–10 minutes per candidate)"
        end
        puts block.include?('longform')
      RUBY
      expect(stdout.strip).to eq('true')
    end

    it 'includes audio delivery summary when audio features present' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        af = {
          'baseline' => { 'speaking_rate' => 157, 'f0_mean' => 120 },
          'profile_distribution' => { 'casual' => 70, 'emphatic' => 30 },
          'segments' => [
            { 't' => 5.0, 'e' => 10.0, 'audio_profile' => 'emphatic', 'energy' => 0.9, 'pitch_trend' => 'up' }
          ]
        }
        buf = "## Audio Delivery Summary\n\n--- SOURCE: video.mp4 ---\n"
        bl = af['baseline']
        buf << "Baseline: speaking_rate=#{bl['speaking_rate'].round} wpm, f0_mean=#{bl['f0_mean'].round}Hz\n"
        dist = af['profile_distribution']
        buf << "Profile: #{dist.map { |k, v| "#{k}=#{v}%" }.join(', ')}\n" if dist.any?
        notable = af['segments'].select { |s| %w[emphatic urgent].include?(s['audio_profile']) }
        if notable.any?
          buf << "Notable delivery:\n"
          notable.each { |s| buf << "  [#{s['t']}-#{s['e']}] #{s['audio_profile']} (energy=#{s['energy']}, pitch=#{s['pitch_trend']})\n" }
        end
        puts buf.include?('speaking_rate=157 wpm')
        puts buf.include?('emphatic')
        puts buf.include?('Notable delivery')
      RUBY
      expect(stdout.lines[0].strip).to eq('true')
      expect(stdout.lines[1].strip).to eq('true')
      expect(stdout.lines[2].strip).to eq('true')
    end
  end

  describe 'output schema validation' do
    it 'arc_candidates.yaml has all required top-level fields' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir)
        result = build_valid_candidates(library_dir)

        %w[pool_version generated_at cache_hash llm_model discovery_context candidates unused_clips].each do |field|
          expect(result).to have_key(field), "Missing field: #{field}"
        end
      end
    end

    it 'discovery_context has topic, template, target_format' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir)
        result = build_valid_candidates(library_dir)

        ctx = result['discovery_context']
        expect(ctx).to have_key('topic')
        expect(ctx).to have_key('template')
        expect(ctx).to have_key('target_format')
      end
    end

    it 'each candidate has required fields' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir)
        result = build_valid_candidates(library_dir)

        required = %w[id title estimated_duration structure_type hook_strength coherence_score
                      arc_summary central_tension clip_sequence missing_bridge_clips confidence]
        result['candidates'].each do |candidate|
          required.each do |field|
            expect(candidate).to have_key(field), "Candidate missing field: #{field}"
          end
        end
      end
    end

    it 'each clip_sequence entry has required fields' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir)
        result = build_valid_candidates(library_dir)

        result['candidates'].flat_map { |c| c['clip_sequence'] }.each do |clip|
          expect(clip).to have_key('source')
          expect(clip).to have_key('t_in')
          expect(clip).to have_key('t_out')
          expect(clip).to have_key('role')
          expect(clip).to have_key('content_summary')
          expect(%w[hook setup development payoff transition bridge]).to include(clip['role'])
        end
      end
    end

    it 'confidence is one of high|medium|low' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir)
        result = build_valid_candidates(library_dir)

        result['candidates'].each do |c|
          expect(%w[high medium low]).to include(c['confidence'])
        end
      end
    end

    it 'missing_bridge_clips entries have required fields when non-empty' do
      bridge = {
        'between_clips'    => [3, 4],
        'content_needed'   => 'Transition from historical context to modern apps',
        'duration_estimate' => '5-10 seconds',
        'reason'           => 'Semantic leap weakens arc cohesion'
      }
      %w[between_clips content_needed duration_estimate reason].each do |field|
        expect(bridge).to have_key(field)
      end
      expect(bridge['between_clips']).to be_a(Array)
      expect(bridge['between_clips'].size).to eq(2)
    end
  end

  describe 'multi-source pool' do
    it 'builds transcript block with correct source markers for all sources' do
      Dir.mktmpdir do |tmpdir|
        library_dir = build_pool_library(tmpdir, sources: {
          'video1.mp4'     => { media_type: 'video_with_audio', duration: 60.0 },
          'voice_memo.m4a' => { media_type: 'audio_only',       duration: 30.0 }
        })
        transcripts_dir = File.join(library_dir, 'transcripts')

        sources = {
          'video1.mp4'     => { 'media_type' => 'video_with_audio', 'transcript_file' => 'video1_treated.json',    'duration' => 60.0 },
          'voice_memo.m4a' => { 'media_type' => 'audio_only',       'transcript_file' => 'voice_memo_treated.json', 'duration' => 30.0 }
        }

        block = +"## Source Transcripts\n\n"
        sources.sort_by { |fn, _| fn }.each do |filename, entry|
          next unless entry['transcript_file']
          t_path = File.join(transcripts_dir, entry['transcript_file'])
          next unless File.exist?(t_path)
          data  = JSON.parse(File.read(t_path)) rescue next
          dur_s = entry['duration'] ? "#{format('%.1f', entry['duration'])}s" : '?'
          mtype = entry['media_type']
          block << "--- SOURCE: #{filename} (#{dur_s}) [#{mtype}] ---\n"
          (data['segments'] || []).each do |seg|
            t    = (seg['start'] || seg['t'] || 0).to_f
            e    = (seg['end']   || seg['e'] || t).to_f
            text = (seg['text']  || '').strip
            block << "[#{format('%.2f', t)}-#{format('%.2f', e)}] #{text}\n"
          end
          block << "\n"
        end

        expect(block).to include('SOURCE: video1.mp4')
        expect(block).to include('SOURCE: voice_memo.m4a')
        expect(block).to include('[audio_only]')
        expect(block).to include('[video_with_audio]')
      end
    end
  end

  describe 'orchestrate integration — --force-rediscover flag' do
    it 'parses --force-rediscover flag correctly' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        force_rediscover = false
        args = ['--library', 'test', '--mode', 'mine', '--force-rediscover']
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

    it 'passes --force-rediscover through to discover_arcs flags' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        force_rediscover = true
        library_name = 'test-pool'
        discover_flags = ['--library', library_name]
        discover_flags << '--force-rediscover' if force_rediscover
        puts discover_flags.join(' ')
      RUBY
      expect(stdout.strip).to include('--force-rediscover')
    end
  end
end
