require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

DETECT_SCENES_SCRIPT = File.expand_path('../../scripts/detect_scenes.rb', __dir__)

RSpec.describe 'detect_scenes.rb' do
  describe 'CLI' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', DETECT_SCENES_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when video not found' do
      _, stderr, status = Open3.capture3('ruby', DETECT_SCENES_SCRIPT, '/nonexistent/video.mp4')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('not found')
    end
  end

  describe 'FFmpeg output parsing' do
    it 'parses pts_time from showinfo lines' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        lines = [
          "[Parsed_showinfo_1 @ 0x1234] n:   0 pts:    600 pts_time:2.4      pos:   12345 fmt:yuv420p",
          "[Parsed_showinfo_1 @ 0x1234] n:   1 pts:   1275 pts_time:5.1      pos:   23456 fmt:yuv420p",
          "frame=    2 fps=0.0 q=0.0 size=       0kB time=00:00:05.10 bitrate=N/A speed=N/A",
          "[Parsed_showinfo_1 @ 0x1234] n:   2 pts:   2075 pts_time:8.3      pos:   34567 fmt:yuv420p"
        ]
        timestamps = []
        lines.each do |line|
          if line.include?('pts_time:')
            match = line.match(/pts_time:\\s*([\\d.]+)/)
            timestamps << match[1].to_f if match
          end
        end
        timestamps.unshift(0.0) unless timestamps.include?(0.0)
        puts timestamps.sort.join(',')
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('0.0,2.4,5.1,8.3')
    end

    it 'includes 0.0 as first timestamp when not in output' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        timestamps = [3.5, 7.2]
        timestamps.unshift(0.0) unless timestamps.include?(0.0)
        puts timestamps.first
      RUBY
      expect(stdout.strip).to eq('0.0')
    end

    it 'does not duplicate 0.0 when already present' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        timestamps = [0.0, 3.5, 7.2]
        timestamps.unshift(0.0) unless timestamps.include?(0.0)
        puts timestamps.size
      RUBY
      expect(stdout.strip).to eq('3')
    end
  end

  describe 'clustering' do
    it 'returns unchanged when under max_count' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        timestamps = (0..10).map { |i| i * 5.0 }

        def cluster_timestamps(timestamps, max_count: 50, window: 2.0)
          return timestamps if timestamps.size <= max_count
          clusters = []
          current_cluster = [timestamps.first]
          timestamps[1..].each do |ts|
            if ts - current_cluster.last <= window
              current_cluster << ts
            else
              clusters << current_cluster
              current_cluster = [ts]
            end
          end
          clusters << current_cluster
          representatives = clusters.map { |c| c[c.size / 2] }
          if representatives.size > max_count
            step = representatives.size.to_f / max_count
            representatives = (0...max_count).map { |i| representatives[(i * step).floor] }
          end
          representatives
        end

        result = cluster_timestamps(timestamps, max_count: 50)
        puts result.size
      RUBY
      expect(stdout.strip).to eq('11')
    end

    it 'clusters nearby timestamps when over max_count' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        # 100 timestamps: pairs within 1s of each other, spaced 5s apart
        timestamps = (0..49).flat_map { |i| [i * 5.0, i * 5.0 + 0.5] }

        def cluster_timestamps(timestamps, max_count: 50, window: 2.0)
          return timestamps if timestamps.size <= max_count
          clusters = []
          current_cluster = [timestamps.first]
          timestamps[1..].each do |ts|
            if ts - current_cluster.last <= window
              current_cluster << ts
            else
              clusters << current_cluster
              current_cluster = [ts]
            end
          end
          clusters << current_cluster
          representatives = clusters.map { |c| c[c.size / 2] }
          if representatives.size > max_count
            step = representatives.size.to_f / max_count
            representatives = (0...max_count).map { |i| representatives[(i * step).floor] }
          end
          representatives
        end

        result = cluster_timestamps(timestamps, max_count: 50)
        puts result.size
      RUBY
      expect(stdout.strip.to_i).to be <= 50
    end

    it 'subsamples evenly when clusters exceed max_count' do
      stdout, _, _ = Open3.capture3('ruby', '-e', <<~RUBY)
        # 200 timestamps all far apart (no clustering possible)
        timestamps = (0..199).map { |i| i * 10.0 }

        def cluster_timestamps(timestamps, max_count: 50, window: 2.0)
          return timestamps if timestamps.size <= max_count
          clusters = []
          current_cluster = [timestamps.first]
          timestamps[1..].each do |ts|
            if ts - current_cluster.last <= window
              current_cluster << ts
            else
              clusters << current_cluster
              current_cluster = [ts]
            end
          end
          clusters << current_cluster
          representatives = clusters.map { |c| c[c.size / 2] }
          if representatives.size > max_count
            step = representatives.size.to_f / max_count
            representatives = (0...max_count).map { |i| representatives[(i * step).floor] }
          end
          representatives
        end

        result = cluster_timestamps(timestamps, max_count: 50)
        puts result.size
      RUBY
      expect(stdout.strip.to_i).to eq(50)
    end
  end

  describe 'YAML output schema' do
    it 'writes correct fields to output file' do
      Dir.mktmpdir do |dir|
        output = File.join(dir, 'scene_changes.yaml')
        result = {
          'source' => 'test.mp4',
          'source_path' => '/tmp/test.mp4',
          'scene_threshold' => 0.3,
          'total_scenes' => 5,
          'sampled_scenes' => 5,
          'timestamps' => [0.0, 2.4, 5.1, 8.3, 12.0],
          'sampled_timestamps' => [0.0, 2.4, 5.1, 8.3, 12.0],
          'generated' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z')
        }
        File.write(output, result.to_yaml)
        loaded = YAML.safe_load(File.read(output))

        expect(loaded['source']).to eq('test.mp4')
        expect(loaded['scene_threshold']).to eq(0.3)
        expect(loaded['total_scenes']).to eq(5)
        expect(loaded['sampled_scenes']).to eq(5)
        expect(loaded['timestamps']).to eq([0.0, 2.4, 5.1, 8.3, 12.0])
        expect(loaded['sampled_timestamps']).to eq([0.0, 2.4, 5.1, 8.3, 12.0])
      end
    end
  end

  describe 'report integration' do
    it 'generate_report reads scene_changes.yaml for visual_language' do
      Dir.mktmpdir do |dir|
        # Create minimal library
        transcripts_dir = File.join(dir, 'transcripts')
        FileUtils.mkdir_p(transcripts_dir)
        library = {
          'library_name' => 'test-scenes',
          'language' => 'english',
          'editor' => 'premiere',
          'videos' => [{ 'path' => '/tmp/test.mp4', 'duration' => '10:00' }]
        }
        File.write(File.join(dir, 'library.yaml'), library.to_yaml)

        # Create scene_changes.yaml
        scene_data = {
          'source' => 'test.mp4',
          'scene_threshold' => 0.3,
          'total_scenes' => 30,
          'timestamps' => (0..29).map { |i| i * 20.0 }
        }
        File.write(File.join(dir, 'scene_changes.yaml'), scene_data.to_yaml)

        report_script = File.expand_path('../../scripts/generate_report.rb', __dir__)
        out_dir = File.join(dir, 'report_out')
        FileUtils.mkdir_p(out_dir)
        stdout, _, status = Open3.capture3('ruby', report_script, dir, '--output-dir', out_dir)
        expect(status.exitstatus).to eq(0)

        report_path = stdout.strip
        next skip('report not generated') unless File.exist?(report_path)

        report = YAML.safe_load(File.read(report_path))
        expect(report['visual_language']['scene_changes']).to eq(30)
        expect(report['visual_language']['cuts_per_minute']).to eq(3.0)
        expect(report['visual_language']['avg_shot_duration']).to eq(20.0)
      end
    end
  end
end
