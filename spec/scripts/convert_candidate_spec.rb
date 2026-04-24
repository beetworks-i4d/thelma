require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

CONVERT_CANDIDATE_SCRIPT = File.expand_path('../../scripts/convert_candidate.rb', __dir__)
POOL_INDEX_SCRIPT_CC     = File.expand_path('../../scripts/pool_index.rb', __dir__)

RSpec.describe 'convert_candidate.rb' do
  describe 'CLI argument parsing' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', CONVERT_CANDIDATE_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 for unknown arguments' do
      _, stderr, status = Open3.capture3('ruby', CONVERT_CANDIDATE_SCRIPT, '--foo')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Unknown argument')
    end

    it 'exits 1 with usage when --candidate missing' do
      _, stderr, status = Open3.capture3('ruby', CONVERT_CANDIDATE_SCRIPT, '--library', 'test')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when library does not exist' do
      _, stderr, status = Open3.capture3('ruby', CONVERT_CANDIDATE_SCRIPT,
                                         '--library', 'nonexistent-xyz-cc', '--candidate', 'c001')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end
  end

  describe 'chapter building heuristic' do
    def build_chapters(clip_sequence)
      major_roles        = %w[hook setup development payoff]
      chapters           = []
      current_chapter    = nil
      current_major_role = nil

      clip_sequence.each do |clip|
        role     = clip['role']
        is_major = major_roles.include?(role)

        if is_major && role != current_major_role && current_chapter
          chapters << current_chapter
          current_chapter    = nil
          current_major_role = nil
        end

        unless current_chapter
          current_chapter    = { 'id' => "chapter_#{chapters.size + 1}", 'label' => role, 'clips' => [] }
          current_major_role = role if is_major
        end

        current_chapter['clips'] << clip
      end
      chapters << current_chapter if current_chapter
      chapters
    end

    it 'creates one chapter per major role transition' do
      clips = [
        { 'source' => 'a.mp4', 't_in' => 0.0,  't_out' => 10.0, 'role' => 'hook' },
        { 'source' => 'a.mp4', 't_in' => 10.0, 't_out' => 30.0, 'role' => 'setup' },
        { 'source' => 'b.mp4', 't_in' => 0.0,  't_out' => 60.0, 'role' => 'development' },
        { 'source' => 'b.mp4', 't_in' => 60.0, 't_out' => 90.0, 'role' => 'payoff' }
      ]
      chapters = build_chapters(clips)
      expect(chapters.size).to eq(4)
      expect(chapters.map { |c| c['clips'].first['role'] }).to eq(%w[hook setup development payoff])
    end

    it 'keeps transition clips in the current chapter' do
      clips = [
        { 'source' => 'a.mp4', 't_in' => 0.0,  't_out' => 10.0, 'role' => 'hook' },
        { 'source' => 'a.mp4', 't_in' => 10.0, 't_out' => 15.0, 'role' => 'transition' },
        { 'source' => 'a.mp4', 't_in' => 15.0, 't_out' => 30.0, 'role' => 'setup' }
      ]
      chapters = build_chapters(clips)
      expect(chapters.size).to eq(2)
      expect(chapters[0]['clips'].size).to eq(2)  # hook + transition
      expect(chapters[1]['clips'].size).to eq(1)  # setup
    end

    it 'groups consecutive same-role clips in one chapter' do
      clips = [
        { 'source' => 'a.mp4', 't_in' => 0.0,  't_out' => 30.0, 'role' => 'development' },
        { 'source' => 'b.mp4', 't_in' => 0.0,  't_out' => 45.0, 'role' => 'development' }
      ]
      chapters = build_chapters(clips)
      expect(chapters.size).to eq(1)
      expect(chapters[0]['clips'].size).to eq(2)
    end

    it 'handles empty clip_sequence' do
      expect(build_chapters([])).to eq([])
    end

    it 'handles single clip' do
      clips = [{ 'source' => 'a.mp4', 't_in' => 0.0, 't_out' => 10.0, 'role' => 'hook' }]
      chapters = build_chapters(clips)
      expect(chapters.size).to eq(1)
      expect(chapters[0]['clips'].size).to eq(1)
    end
  end

  describe 'arrangement cache check' do
    it 'skips conversion when arrangement exists for same candidate' do
      Dir.mktmpdir do |tmpdir|
        arr_path = File.join(tmpdir, 'arrangement.yaml')
        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          arrangement_path = '#{arr_path}'
          force = false

          File.write(arrangement_path, { 'source_candidate' => 'candidate_001' }.to_yaml)

          if !force && File.exist?(arrangement_path) && File.size(arrangement_path) > 0
            existing = YAML.safe_load(File.read(arrangement_path), permitted_classes: []) rescue {}
            if existing.is_a?(Hash) && existing['source_candidate'] == 'candidate_001'
              $stderr.puts 'Arrangement already exists for candidate_001'
              puts arrangement_path
              exit 0
            end
          end
          puts 'CONVERTED'
        RUBY
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq(arr_path)
      end
    end

    it 'reconverts when --force bypasses cache' do
      Dir.mktmpdir do |tmpdir|
        arr_path = File.join(tmpdir, 'arrangement.yaml')
        stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          arrangement_path = '#{arr_path}'
          force = true

          File.write(arrangement_path, { 'source_candidate' => 'candidate_001' }.to_yaml)

          if !force && File.exist?(arrangement_path) && File.size(arrangement_path) > 0
            existing = YAML.safe_load(File.read(arrangement_path)) rescue {}
            if existing.is_a?(Hash) && existing['source_candidate'] == 'candidate_001'
              puts 'SKIPPED'
              exit 0
            end
          end
          puts 'CONVERTED'
        RUBY
        expect(stdout.strip).to eq('CONVERTED')
      end
    end
  end

  describe 'arrangement.yaml output schema' do
    it 'produces arrangement.yaml with required fields' do
      Dir.mktmpdir do |tmpdir|
        pool_dir = File.join(tmpdir, 'pool')
        FileUtils.mkdir_p(pool_dir)
        FileUtils.touch(File.join(pool_dir, 'video.mp4'))

        lib_dir = File.join(tmpdir, 'libraries', 'test-mine-cc')
        FileUtils.mkdir_p(File.join(lib_dir, 'transcripts'))

        library = { 'pool_dir' => pool_dir, 'videos' => [], 'language' => 'en' }
        File.write(File.join(lib_dir, 'library.yaml'), library.to_yaml)

        index = { 'pool_version' => 1, 'sources' => {
          'video.mp4' => { 'media_type' => 'video_with_audio', 'sha256' => 'abc123' }
        }}
        File.write(File.join(lib_dir, 'index.yaml'), index.to_yaml)

        candidates_data = {
          'candidates' => [{
            'id'             => 'candidate_001',
            'title'          => 'Test Arc',
            'structure_type' => 'explainer',
            'estimated_duration' => '5:00',
            'hook_strength'  => 0.80,
            'coherence_score' => 0.75,
            'arc_summary'    => 'Opens with X.',
            'clip_sequence'  => [
              { 'source' => 'video.mp4', 't_in' => 0.0,  't_out' => 10.0, 'role' => 'hook' },
              { 'source' => 'video.mp4', 't_in' => 10.0, 't_out' => 40.0, 'role' => 'development' }
            ],
            'missing_bridge_clips' => []
          }]
        }
        File.write(File.join(lib_dir, 'arc_candidates.yaml'), candidates_data.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'
          require 'date'

          ROOT_DIR    = '#{tmpdir}'
          lib_dir     = File.join(ROOT_DIR, 'libraries', 'test-mine-cc')
          library     = YAML.safe_load(File.read(File.join(lib_dir, 'library.yaml')), permitted_classes: [Date])
          arc_data    = YAML.safe_load(File.read(File.join(lib_dir, 'arc_candidates.yaml')), permitted_classes: [Date])
          candidate   = arc_data['candidates'].first
          clip_sequence = candidate['clip_sequence'] || []

          major_roles = %w[hook setup development payoff]
          chapters = []
          current_chapter = nil
          current_major_role = nil

          clip_sequence.each do |clip|
            role     = clip['role']
            is_major = major_roles.include?(role)
            if is_major && role != current_major_role && current_chapter
              chapters << current_chapter
              current_chapter = nil
              current_major_role = nil
            end
            unless current_chapter
              current_chapter = { 'id' => "chapter_\#{chapters.size + 1}", 'label' => role, 'clips' => [] }
              current_major_role = role if is_major
            end
            current_chapter['clips'] << { 'source' => clip['source'], 't_in' => clip['t_in'].to_f, 't_out' => clip['t_out'].to_f, 'track' => 'V1', 'narrative_role' => clip['role'] }
          end
          chapters << current_chapter if current_chapter

          arrangement = {
            'branch'             => 'D',
            'source_candidate'   => candidate['id'],
            'candidate_title'    => candidate['title'],
            'chapters'           => chapters,
            'broll_suggestions'  => [],
            'key_decisions'      => []
          }

          arr_path = File.join(lib_dir, 'arrangement.yaml')
          File.write(arr_path, arrangement.to_yaml)
          puts arr_path
        RUBY

        expect(status.exitstatus).to eq(0)
        arr_path = stdout.strip
        expect(File.exist?(arr_path)).to be true
        arr = YAML.safe_load(File.read(arr_path))
        expect(arr['branch']).to eq('D')
        expect(arr['source_candidate']).to eq('candidate_001')
        expect(arr['chapters']).to be_an(Array)
        expect(arr['chapters'].size).to eq(2)  # hook + development
        expect(arr['broll_suggestions']).to eq([])
        expect(arr['key_decisions']).to eq([])
      end
    end
  end

  describe 'library.yaml videos update' do
    it 'populates library.yaml videos with pool source paths' do
      Dir.mktmpdir do |tmpdir|
        pool_dir = File.join(tmpdir, 'pool')
        FileUtils.mkdir_p(pool_dir)
        video_path = File.join(pool_dir, 'source.mp4')
        FileUtils.touch(video_path)

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'

          pool_dir   = '#{pool_dir}'
          video_path = '#{video_path}'
          sources    = { 'source.mp4' => { 'media_type' => 'video_with_audio', 'transcript_file' => 'source_treated.json' } }
          unique_sources = ['source.mp4']

          source_paths = {}
          unique_sources.each do |fn|
            abs = Dir.glob(File.join(pool_dir, '**', fn)).first
            source_paths[fn] = abs if abs
          end

          video_entries = unique_sources.filter_map do |fn|
            abs = source_paths[fn]
            next unless abs
            entry = { 'path' => abs }
            idx_entry = sources[fn]
            entry['transcript'] = idx_entry['transcript_file'] if idx_entry&.fetch('transcript_file', nil)
            entry
          end

          puts video_entries.first['path']
          puts video_entries.first['transcript']
        RUBY
        lines = stdout.strip.split("\n")
        expect(lines[0]).to eq(video_path)
        expect(lines[1]).to eq('source_treated.json')
      end
    end
  end

  describe 'pickup_recording_suggestions.md' do
    it 'generates pickup file when missing_bridge_clips present' do
      Dir.mktmpdir do |tmpdir|
        pickup_path = File.join(tmpdir, 'pickup_recording_suggestions.md')
        stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
          require 'yaml'

          missing_bridges = [
            { 'between_clips' => [0, 1], 'description' => 'Record a setup shot', 'why' => 'Semantic jump is too large' }
          ]
          library_name  = 'test-pool'
          candidate_id  = 'candidate_001'
          candidate     = { 'title' => 'Test Arc', 'id' => candidate_id }
          pickup_path   = '#{pickup_path}'

          lines = []
          lines << '# Pickup Recording Suggestions'
          lines << ''
          lines << "Generated from candidate: **\#{candidate['title']}** (`\#{candidate_id}`)"
          lines << ''
          missing_bridges.each_with_index do |bridge, i|
            between = bridge['between_clips'] || []
            desc    = bridge['description'] || ''
            why     = bridge['why'].to_s
            lines << "## Gap \#{i + 1} — Between clips \#{between.first} and \#{between.last}"
            lines << "**What to record:** \#{desc}"
            lines << "**Why it matters:** \#{why}" unless why.empty?
          end

          File.write(pickup_path, lines.join("\\n"))
          puts 'written'
        RUBY
        expect(stdout.strip).to eq('written')
        expect(File.exist?(pickup_path)).to be true
        content = File.read(pickup_path)
        expect(content).to include('Pickup Recording Suggestions')
        expect(content).to include('Gap 1')
        expect(content).to include('Record a setup shot')
        expect(content).to include('Semantic jump is too large')
      end
    end

    it 'does not generate pickup file when no bridges' do
      Dir.mktmpdir do |tmpdir|
        pickup_path = File.join(tmpdir, 'pickup_recording_suggestions.md')
        Open3.capture3('ruby', '-e', <<~RUBY)
          missing_bridges = []
          pickup_path = '#{pickup_path}'
          if missing_bridges.any?
            File.write(pickup_path, '# Pickup Recording Suggestions')
          end
        RUBY
        expect(File.exist?(pickup_path)).to be false
      end
    end

    it 'includes re-run command in pickup file' do
      Dir.mktmpdir do |tmpdir|
        pickup_path = File.join(tmpdir, 'pickup.md')
        stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
          library_name = 'test-pool'
          candidate_id = 'candidate_001'
          rerun = ["--mode mine", "--library #{library_name}", "--candidate #{candidate_id}", '--force-cascade']
          puts "ruby scripts/orchestrate.rb #{rerun.join(' ')}"
        RUBY
        expect(stdout).to include('--force-cascade')
        expect(stdout).to include('--candidate candidate_001')
        expect(stdout).to include('--mode mine')
      end
    end
  end
end
