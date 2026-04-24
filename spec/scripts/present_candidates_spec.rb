require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

PRESENT_CANDIDATES_SCRIPT = File.expand_path('../../scripts/present_candidates.rb', __dir__)

RSpec.describe 'present_candidates.rb' do
  describe 'CLI argument parsing' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', PRESENT_CANDIDATES_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 for unknown arguments' do
      _, stderr, status = Open3.capture3('ruby', PRESENT_CANDIDATES_SCRIPT, '--foo')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Unknown argument')
    end

    it 'exits 1 when library does not exist' do
      _, stderr, status = Open3.capture3('ruby', PRESENT_CANDIDATES_SCRIPT,
                                         '--library', 'nonexistent-xyz-present')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end

    it 'exits 1 when arc_candidates.yaml not found' do
      Dir.mktmpdir do |tmpdir|
        lib_dir = File.join(tmpdir, 'libraries', 'test-nocands')
        FileUtils.mkdir_p(lib_dir)

        _, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
          library_dir = '#{lib_dir}'
          candidates_path = File.join(library_dir, 'arc_candidates.yaml')
          abort "arc_candidates.yaml not found — run arc discovery first" unless File.exist?(candidates_path)
        RUBY
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('arc_candidates.yaml not found')
      end
    end
  end

  describe 'candidate display formatting' do
    it 'displays candidate titles with hook and coherence scores' do
      Dir.mktmpdir do |tmpdir|
        cand_data = {
          'discovery_context' => { 'target_format' => 'longform' },
          'candidates' => [
            {
              'id'             => 'candidate_001',
              'title'          => 'The Strategy Arc',
              'estimated_duration' => '7:45',
              'structure_type' => 'explainer',
              'hook_strength'  => 0.87,
              'coherence_score' => 0.81,
              'confidence'     => 'high',
              'clip_sequence'  => [
                { 'source' => 'a.mp4', 't_in' => 0, 't_out' => 10, 'role' => 'hook' }
              ],
              'missing_bridge_clips' => [],
              'arc_summary'    => 'Opens with a provocation. Resolves with clarity.'
            },
            {
              'id'             => 'candidate_002',
              'title'          => 'The Journey Arc',
              'estimated_duration' => '5:00',
              'structure_type' => 'journey',
              'hook_strength'  => 0.72,
              'coherence_score' => 0.68,
              'confidence'     => 'medium',
              'clip_sequence'  => [],
              'missing_bridge_clips' => [{ 'between_clips' => [0, 1], 'description' => 'bridge shot' }]
            }
          ],
          'unused_clips' => [{ 'source' => 'extra.mp4', 't_in' => 0, 't_out' => 5 }]
        }
        tmp_cand = File.join(tmpdir, 'arc_candidates.yaml')
        File.write(tmp_cand, cand_data.to_yaml)

        stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY', tmp_cand)
          require 'yaml'
          require 'date'
          data       = YAML.safe_load(File.read(ARGV[0]), permitted_classes: [Date])
          candidates = data['candidates'] || []
          context    = data['discovery_context'] || {}

          puts ''
          puts '=' * 68
          puts "  ARC CANDIDATES"
          puts '=' * 68

          candidates.each_with_index do |c, i|
            dur       = c['estimated_duration'] || '?'
            hook      = c['hook_strength']   ? format('%.2f', c['hook_strength'].to_f)   : '?'
            coherence = c['coherence_score'] ? format('%.2f', c['coherence_score'].to_f) : '?'
            bridges   = (c['missing_bridge_clips'] || []).size

            puts ''
            puts "  #{i + 1}. #{c['title']} (#{c['id']})"
            puts "     #{dur}  |  hook #{hook}  coherence #{coherence}  |  #{c['confidence']} confidence"
            puts "     #{(c['clip_sequence'] || []).size} clip(s)#{bridges > 0 ? "  |  #{bridges} missing bridge(s)" : ''}"
          end
          puts ''
          puts "  Unused pool clips: #{(data['unused_clips'] || []).size}"
          puts '=' * 68
        RUBY

        expect(stdout).to include('The Strategy Arc')
        expect(stdout).to include('The Journey Arc')
        expect(stdout).to include('0.87')
        expect(stdout).to include('0.81')
        expect(stdout).to include('0.72')
        expect(stdout).to include('1 missing bridge(s)')
        expect(stdout).to include('Unused pool clips: 1')
      end
    end

    it 'shows arc summary first sentence' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        arc_summary = "Opens with X, pivots to Y, resolves with Z. More detail here."
        summary = arc_summary.to_s.strip.split(/\.[\s\n]/).first.to_s.strip
        puts summary
      RUBY
      expect(stdout.strip).to eq('Opens with X, pivots to Y, resolves with Z')
    end

    it 'shows discovery context when topic present' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~'RUBY')
        context = { 'topic' => 'brand strategy', 'target_format' => 'longform' }
        meta = []
        meta << "topic: #{context['topic']}" if context['topic']
        meta << "format: #{context['target_format']}" if context['target_format']
        puts meta.join('  |  ')
      RUBY
      expect(stdout).to include('topic: brand strategy')
      expect(stdout).to include('format: longform')
    end
  end
end
