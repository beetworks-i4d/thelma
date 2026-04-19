require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'
require 'fileutils'

VISUAL_FRAMES_SCRIPT = File.expand_path('../../scripts/extract_visual_frames.rb', __dir__)
ROOT_FOR_FRAMES = File.expand_path('../..', __dir__)
FRAMES_FIXTURE_VIDEO = File.expand_path('../fixtures/media/MVI_0309_720p.mov', __dir__)

def setup_frames_library(lib_name, scene_data: nil)
  lib_dir = File.join(ROOT_FOR_FRAMES, 'libraries', lib_name)
  FileUtils.mkdir_p(lib_dir)

  library = {
    'library_name' => lib_name,
    'editor' => 'fcp7',
    'videos' => [{ 'path' => FRAMES_FIXTURE_VIDEO, 'duration' => '00:00:05' }]
  }
  File.write(File.join(lib_dir, 'library.yaml'), library.to_yaml)

  if scene_data
    File.write(File.join(lib_dir, 'scene_changes.yaml'), scene_data.to_yaml)
  end

  lib_dir
end

def cleanup_frames_library(lib_name)
  lib_dir = File.join(ROOT_FOR_FRAMES, 'libraries', lib_name)
  FileUtils.rm_rf(lib_dir)
end

def run_frames(lib_name, video_path: FRAMES_FIXTURE_VIDEO)
  stdout, stderr, status = Open3.capture3(
    'ruby', VISUAL_FRAMES_SCRIPT,
    '--library', lib_name,
    '--video', video_path
  )
  result = nil
  if status.success? && !stdout.strip.empty?
    result_path = stdout.strip
    result = YAML.safe_load(File.read(result_path), permitted_classes: [Date]) if File.exist?(result_path)
  end
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result }
end

RSpec.describe 'extract_visual_frames.rb' do
  let(:test_lib) { "_test_visual_frames_#{$$}" }

  before do
    skip "Fixture video not found" unless File.exist?(FRAMES_FIXTURE_VIDEO)
  end

  after { cleanup_frames_library(test_lib) }

  describe 'CLI validation' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', VISUAL_FRAMES_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when video does not exist' do
      setup_frames_library(test_lib)
      _, stderr, status = Open3.capture3(
        'ruby', VISUAL_FRAMES_SCRIPT,
        '--library', test_lib, '--video', '/nonexistent/video.mp4'
      )
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('not found')
    end

    it 'exits 1 when library does not exist' do
      _, stderr, status = Open3.capture3(
        'ruby', VISUAL_FRAMES_SCRIPT,
        '--library', '_nonexistent_lib_999', '--video', FRAMES_FIXTURE_VIDEO
      )
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('not found')
    end
  end

  describe 'fallback for ≤1 scene change' do
    it 'extracts 3 frames when no scene_changes.yaml exists' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)
      expect(r[:exit_code]).to eq(0)
      expect(r[:result]['strategy']).to eq('fallback_3_frame')
      expect(r[:result]['frame_count']).to eq(3)
    end

    it 'extracts 3 frames when scene_changes has only 1 timestamp' do
      setup_frames_library(test_lib, scene_data: {
        'source' => 'test.mp4',
        'total_scenes' => 1,
        'sampled_scenes' => 1,
        'timestamps' => [0.0],
        'sampled_timestamps' => [0.0]
      })
      r = run_frames(test_lib)
      expect(r[:exit_code]).to eq(0)
      expect(r[:result]['strategy']).to eq('fallback_3_frame')
      expect(r[:result]['frame_count']).to eq(3)
    end

    it 'places fallback frames at start, middle, and end' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)
      timestamps = r[:result]['frames'].map { |f| f['timestamp'] }
      duration = r[:result]['duration']

      # Start should be near beginning
      expect(timestamps[0]).to be < duration * 0.2
      # Middle should be near center
      expect(timestamps[1]).to be_within(duration * 0.2).of(duration / 2.0)
      # End should be near the end
      expect(timestamps[2]).to be > duration * 0.7
    end
  end

  describe 'scene-driven extraction (2-50 scenes)' do
    it 'extracts one frame per scene timestamp' do
      setup_frames_library(test_lib, scene_data: {
        'source' => 'test.mp4',
        'total_scenes' => 3,
        'sampled_scenes' => 3,
        'timestamps' => [0.0, 1.5, 3.0],
        'sampled_timestamps' => [0.0, 1.5, 3.0]
      })
      r = run_frames(test_lib)
      expect(r[:exit_code]).to eq(0)
      expect(r[:result]['strategy']).to eq('scene_driven')
      expect(r[:result]['frame_count']).to eq(3)

      timestamps = r[:result]['frames'].map { |f| f['timestamp'] }
      expect(timestamps).to eq([0.0, 1.5, 3.0])
    end
  end

  describe 'clustered extraction (50+ scenes)' do
    it 'uses sampled_timestamps when available' do
      # Create 60 timestamps but only 5 sampled
      all_ts = (0..59).map { |i| (i * 0.1).round(3) }
      sampled = [0.0, 1.5, 3.0, 4.0, 5.0]
      setup_frames_library(test_lib, scene_data: {
        'source' => 'test.mp4',
        'total_scenes' => 60,
        'sampled_scenes' => 5,
        'timestamps' => all_ts,
        'sampled_timestamps' => sampled
      })
      r = run_frames(test_lib)
      expect(r[:exit_code]).to eq(0)
      # Should use sampled_timestamps (5), not all 60
      expect(r[:result]['frame_count']).to be <= 5
      expect(r[:result]['strategy']).to eq('scene_driven')
    end
  end

  describe 'cache behavior' do
    it 'skips extraction when cache key matches' do
      setup_frames_library(test_lib, scene_data: {
        'source' => 'test.mp4',
        'total_scenes' => 3,
        'sampled_scenes' => 3,
        'timestamps' => [0.0, 1.5, 3.0],
        'sampled_timestamps' => [0.0, 1.5, 3.0]
      })

      # First run
      r1 = run_frames(test_lib)
      expect(r1[:exit_code]).to eq(0)

      # Second run — should hit cache
      r2 = run_frames(test_lib)
      expect(r2[:exit_code]).to eq(0)
      expect(r2[:stderr]).to include('cached')
    end

    it 're-extracts when scene data changes' do
      setup_frames_library(test_lib, scene_data: {
        'source' => 'test.mp4',
        'total_scenes' => 2,
        'sampled_scenes' => 2,
        'timestamps' => [0.0, 2.0],
        'sampled_timestamps' => [0.0, 2.0]
      })

      r1 = run_frames(test_lib)
      expect(r1[:exit_code]).to eq(0)
      original_count = r1[:result]['frame_count']

      # Update scene data
      lib_dir = File.join(ROOT_FOR_FRAMES, 'libraries', test_lib)
      File.write(File.join(lib_dir, 'scene_changes.yaml'), {
        'source' => 'test.mp4',
        'total_scenes' => 3,
        'sampled_scenes' => 3,
        'timestamps' => [0.0, 1.5, 3.0],
        'sampled_timestamps' => [0.0, 1.5, 3.0]
      }.to_yaml)

      r2 = run_frames(test_lib)
      expect(r2[:exit_code]).to eq(0)
      expect(r2[:stderr]).not_to include('cached')
      expect(r2[:result]['frame_count']).to eq(3)
    end
  end

  describe 'output format' do
    it 'includes all required fields' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)

      expect(r[:result]).to have_key('library')
      expect(r[:result]).to have_key('video')
      expect(r[:result]).to have_key('video_path')
      expect(r[:result]).to have_key('duration')
      expect(r[:result]).to have_key('strategy')
      expect(r[:result]).to have_key('frame_count')
      expect(r[:result]).to have_key('cache_key')
      expect(r[:result]).to have_key('generated')
      expect(r[:result]).to have_key('frames')
    end

    it 'frame entries have index, timestamp, path, filename' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)
      frame = r[:result]['frames'].first

      expect(frame).to have_key('index')
      expect(frame).to have_key('timestamp')
      expect(frame).to have_key('path')
      expect(frame).to have_key('filename')
      expect(File.exist?(frame['path'])).to be true
    end

    it 'writes output to library directory' do
      lib_dir = setup_frames_library(test_lib)
      r = run_frames(test_lib)
      expect(r[:stdout]).to eq(File.join(lib_dir, 'visual_frames.yaml'))
    end

    it 'creates frames in library frames subdirectory' do
      lib_dir = setup_frames_library(test_lib)
      r = run_frames(test_lib)
      frames_dir = File.join(lib_dir, 'frames')
      expect(File.directory?(frames_dir)).to be true
      jpgs = Dir.glob(File.join(frames_dir, '*.jpg'))
      expect(jpgs.size).to eq(r[:result]['frame_count'])
    end
  end

  describe 'missing scene_changes.yaml' do
    it 'falls back gracefully without scene data' do
      setup_frames_library(test_lib)
      # No scene_changes.yaml written
      r = run_frames(test_lib)
      expect(r[:exit_code]).to eq(0)
      expect(r[:stderr]).to include('not found')
      expect(r[:result]['strategy']).to eq('fallback_3_frame')
    end
  end
end
