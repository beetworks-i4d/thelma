require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'
require 'fileutils'

VISUAL_FRAMES_SCRIPT = File.expand_path('../../scripts/extract_visual_frames.rb', __dir__)
ROOT_FOR_FRAMES = File.expand_path('../..', __dir__)
FRAMES_FIXTURE_VIDEO = File.expand_path('../fixtures/media/MVI_0309_720p.mov', __dir__)

def setup_frames_library(lib_name, scene_data: nil, per_source_scene: nil)
  lib_dir = File.join(ROOT_FOR_FRAMES, 'libraries', lib_name)
  transcripts_dir = File.join(lib_dir, 'transcripts')
  FileUtils.mkdir_p(transcripts_dir)

  library = {
    'library_name' => lib_name,
    'editor' => 'fcp7',
    'videos' => [{ 'path' => FRAMES_FIXTURE_VIDEO, 'duration' => '00:00:05' }]
  }
  File.write(File.join(lib_dir, 'library.yaml'), library.to_yaml)

  if scene_data
    File.write(File.join(lib_dir, 'scene_changes.yaml'), scene_data.to_yaml)
  end

  if per_source_scene
    basename = File.basename(FRAMES_FIXTURE_VIDEO, File.extname(FRAMES_FIXTURE_VIDEO))
    File.write(File.join(transcripts_dir, "#{basename}_scenes.yaml"), per_source_scene.to_yaml)
  end

  lib_dir
end

def cleanup_frames_library(lib_name)
  lib_dir = File.join(ROOT_FOR_FRAMES, 'libraries', lib_name)
  FileUtils.rm_rf(lib_dir)
end

def run_frames(lib_name, video_path: FRAMES_FIXTURE_VIDEO, extra_args: [])
  stdout, stderr, status = Open3.capture3(
    'ruby', VISUAL_FRAMES_SCRIPT,
    '--library', lib_name,
    '--video', video_path,
    *extra_args
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
  let(:video_basename) { File.basename(FRAMES_FIXTURE_VIDEO, File.extname(FRAMES_FIXTURE_VIDEO)) }

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

  describe 'single-shot fallback (≤1 scene change)' do
    it 'creates a single shot spanning the file when no scene data' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)
      expect(r[:exit_code]).to eq(0)
      shots = r[:result]['shots']
      expect(shots.size).to eq(1)
      expect(shots.first['shot_id']).to eq('s001')
      expect(shots.first['t_start']).to eq(0.0)
      expect(shots.first['t_end']).to be > 0
    end

    it 'extracts 3 frames for the single shot' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)
      frames = r[:result]['shots'].first['frames_sampled']
      expect(frames.size).to eq(3)
    end

    it 'produces opening/middle/closing frame timestamps' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)
      shot = r[:result]['shots'].first
      frames = shot['frames_sampled']
      # Opening near start, middle near center, closing near end
      expect(frames[0]['t']).to be < shot['t_end'] * 0.3
      expect(frames[1]['t']).to be_within(shot['t_end'] * 0.3).of(shot['t_end'] / 2.0)
      expect(frames[2]['t']).to be > shot['t_end'] * 0.7
    end
  end

  describe 'multi-shot extraction from scene timestamps' do
    it 'creates one shot per scene boundary' do
      setup_frames_library(test_lib, scene_data: {
        'source' => File.basename(FRAMES_FIXTURE_VIDEO),
        'total_scenes' => 3,
        'sampled_scenes' => 3,
        'timestamps' => [0.0, 1.5, 3.0],
        'sampled_timestamps' => [0.0, 1.5, 3.0]
      })
      r = run_frames(test_lib)
      expect(r[:exit_code]).to eq(0)
      shots = r[:result]['shots']
      expect(shots.size).to eq(3)
      expect(shots.map { |s| s['shot_id'] }).to eq(%w[s001 s002 s003])
    end

    it 'sets correct shot boundaries' do
      setup_frames_library(test_lib, scene_data: {
        'source' => File.basename(FRAMES_FIXTURE_VIDEO),
        'total_scenes' => 3,
        'sampled_scenes' => 3,
        'timestamps' => [0.0, 1.5, 3.0],
        'sampled_timestamps' => [0.0, 1.5, 3.0]
      })
      r = run_frames(test_lib)
      shots = r[:result]['shots']
      expect(shots[0]['t_start']).to eq(0.0)
      expect(shots[0]['t_end']).to eq(1.5)
      expect(shots[1]['t_start']).to eq(1.5)
      expect(shots[1]['t_end']).to eq(3.0)
      expect(shots[2]['t_start']).to eq(3.0)
      # Last shot ends at file duration
      expect(shots[2]['t_end']).to be > 3.0
    end

    it 'extracts 3 frames per shot' do
      setup_frames_library(test_lib, scene_data: {
        'source' => File.basename(FRAMES_FIXTURE_VIDEO),
        'total_scenes' => 2,
        'sampled_scenes' => 2,
        'timestamps' => [0.0, 2.5],
        'sampled_timestamps' => [0.0, 2.5]
      })
      r = run_frames(test_lib)
      r[:result]['shots'].each do |shot|
        shot_dur = shot['t_end'] - shot['t_start']
        next if shot_dur < 0.6  # very short shots may have fewer
        expect(shot['frames_sampled'].size).to eq(3)
      end
    end
  end

  describe '--scene-file flag (mine mode)' do
    it 'reads per-source scene data from explicit file' do
      lib_dir = setup_frames_library(test_lib)
      basename = File.basename(FRAMES_FIXTURE_VIDEO, File.extname(FRAMES_FIXTURE_VIDEO))
      scene_path = File.join(lib_dir, 'transcripts', "#{basename}_scenes.yaml")
      File.write(scene_path, {
        'source' => File.basename(FRAMES_FIXTURE_VIDEO),
        'total_scenes' => 2,
        'sampled_scenes' => 2,
        'timestamps' => [0.0, 2.0],
        'sampled_timestamps' => [0.0, 2.0]
      }.to_yaml)

      r = run_frames(test_lib, extra_args: ['--scene-file', scene_path])
      expect(r[:exit_code]).to eq(0)
      expect(r[:result]['shots'].size).to eq(2)
    end
  end

  describe 'output schema' do
    before { setup_frames_library(test_lib) }

    it 'includes all required top-level fields' do
      r = run_frames(test_lib)
      %w[source source_duration source_fps cache_key generated shots pacing b_roll_correlation visual_hook].each do |key|
        expect(r[:result]).to have_key(key), "Missing key: #{key}"
      end
    end

    it 'has correct source metadata' do
      r = run_frames(test_lib)
      expect(r[:result]['source']).to eq(File.basename(FRAMES_FIXTURE_VIDEO))
      expect(r[:result]['source_duration']).to be > 0
      expect(r[:result]['source_fps']).to be > 0
    end

    it 'shot entries have all classification fields (null for Session 1)' do
      r = run_frames(test_lib)
      shot = r[:result]['shots'].first
      %w[shot_id t_start t_end shot_type composition camera_motion subject_motion
         lighting dominant_colors text_overlay_present motion_graphic_present
         b_roll_semantic_tag frames_sampled].each do |key|
        expect(shot).to have_key(key), "Shot missing key: #{key}"
      end
      # Classification fields are null in Session 1
      expect(shot['shot_type']).to be_nil
      expect(shot['composition']).to be_nil
      expect(shot['camera_motion']).to be_nil
    end

    it 'pacing section has distribution and rhythm_moments' do
      r = run_frames(test_lib)
      pacing = r[:result]['pacing']
      expect(pacing['shot_duration_distribution']).to include('mean' => nil, 'median' => nil)
      expect(pacing['rhythm_moments']).to eq([])
    end

    it 'b_roll_correlation section has coverage and matches' do
      r = run_frames(test_lib)
      expect(r[:result]['b_roll_correlation']['coverage']).to be_nil
      expect(r[:result]['b_roll_correlation']['matches']).to eq([])
    end

    it 'visual_hook section has first_3_seconds' do
      r = run_frames(test_lib)
      expect(r[:result]['visual_hook']['first_3_seconds']).to be_nil
    end
  end

  describe 'frame files' do
    it 'creates JPEG files on disk' do
      lib_dir = setup_frames_library(test_lib)
      r = run_frames(test_lib)
      r[:result]['shots'].each do |shot|
        shot['frames_sampled'].each do |f|
          abs = File.join(lib_dir, f['frame_path'])
          expect(File.exist?(abs)).to be(true), "Frame missing: #{f['frame_path']}"
          expect(File.size(abs)).to be > 0
        end
      end
    end

    it 'uses relative paths from library root' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)
      frame = r[:result]['shots'].first['frames_sampled'].first
      expect(frame['frame_path']).to start_with('visual_frames/')
      expect(frame['frame_path']).to include(video_basename)
      expect(frame['frame_path']).to end_with('.jpg')
    end

    it 'stores frames in per-source subdirectory' do
      lib_dir = setup_frames_library(test_lib)
      r = run_frames(test_lib)
      frames_dir = File.join(lib_dir, 'visual_frames', video_basename)
      expect(File.directory?(frames_dir)).to be true
      jpgs = Dir.glob(File.join(frames_dir, '*.jpg'))
      expect(jpgs.size).to be > 0
    end
  end

  describe 'output file location' do
    it 'writes visual_analysis.yaml to transcripts directory' do
      lib_dir = setup_frames_library(test_lib)
      r = run_frames(test_lib)
      expected = File.join(lib_dir, 'transcripts', "#{video_basename}_visual_analysis.yaml")
      expect(r[:stdout]).to eq(expected)
      expect(File.exist?(expected)).to be true
    end
  end

  describe 'cache behavior' do
    it 'skips extraction when cache key matches and all frames exist' do
      setup_frames_library(test_lib)
      r1 = run_frames(test_lib)
      expect(r1[:exit_code]).to eq(0)

      r2 = run_frames(test_lib)
      expect(r2[:exit_code]).to eq(0)
      expect(r2[:stderr]).to include('cached')
    end

    it 're-extracts when scene data changes' do
      setup_frames_library(test_lib, scene_data: {
        'source' => File.basename(FRAMES_FIXTURE_VIDEO),
        'total_scenes' => 2,
        'sampled_scenes' => 2,
        'timestamps' => [0.0, 2.0],
        'sampled_timestamps' => [0.0, 2.0]
      })

      r1 = run_frames(test_lib)
      expect(r1[:exit_code]).to eq(0)

      # Update scene data
      lib_dir = File.join(ROOT_FOR_FRAMES, 'libraries', test_lib)
      File.write(File.join(lib_dir, 'scene_changes.yaml'), {
        'source' => File.basename(FRAMES_FIXTURE_VIDEO),
        'total_scenes' => 3,
        'sampled_scenes' => 3,
        'timestamps' => [0.0, 1.5, 3.0],
        'sampled_timestamps' => [0.0, 1.5, 3.0]
      }.to_yaml)

      r2 = run_frames(test_lib)
      expect(r2[:exit_code]).to eq(0)
      expect(r2[:stderr]).not_to include('cached')
      expect(r2[:result]['shots'].size).to eq(3)
    end

    it '--force flag regenerates even when cached' do
      setup_frames_library(test_lib)
      r1 = run_frames(test_lib)
      expect(r1[:exit_code]).to eq(0)

      r2 = run_frames(test_lib, extra_args: ['--force'])
      expect(r2[:exit_code]).to eq(0)
      expect(r2[:stderr]).not_to include('cached')
    end
  end

  describe 'audio-only sources' do
    it 'are skipped by the caller (script requires video file)' do
      # The script itself requires a valid video file — audio-only skipping
      # happens in orchestrate.rb (is_audio_only guard). Verify the script
      # fails gracefully on a non-video file.
      setup_frames_library(test_lib)
      dummy_audio = File.join(ROOT_FOR_FRAMES, 'libraries', test_lib, 'fake.wav')
      File.write(dummy_audio, 'not a real wav')
      r = run_frames(test_lib, video_path: dummy_audio)
      expect(r[:exit_code]).not_to eq(0)
    ensure
      File.delete(dummy_audio) if dummy_audio && File.exist?(dummy_audio)
    end
  end

  describe 'missing scene_changes.yaml' do
    it 'falls back to single shot without scene data' do
      setup_frames_library(test_lib)
      r = run_frames(test_lib)
      expect(r[:exit_code]).to eq(0)
      expect(r[:result]['shots'].size).to eq(1)
    end
  end
end
