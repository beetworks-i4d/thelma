require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

BATCH_SCRIPT = File.expand_path('../../scripts/branch_a_batch.rb', __dir__)

def make_library_yaml(videos: true, script_parsed: true)
  data = {}
  if videos
    data['videos'] = [
      { 'path' => '/tmp/fake_video.mp4', 'duration' => '05:00', 'transcript' => 'fake_transcript.json' }
    ]
  end
  data['script_parsed'] = 'script_parsed.yaml' if script_parsed
  data
end

def make_script_parsed(shorts_count: 3)
  {
    'source_file' => 'test.pdf',
    'format' => 'multi_short',
    'shorts' => (1..shorts_count).map do |n|
      {
        'number' => n,
        'title' => "Test Short #{n}",
        'section' => 'TEST',
        'beats' => [
          { 'role' => 'hook', 'text' => "Hook text for short #{n}" },
          { 'role' => 'close', 'text' => "Close text for short #{n}" }
        ]
      }
    end
  }
end

def setup_library(dir, library_yaml: nil, script_parsed: nil)
  lib_dir = File.join(dir, 'libraries', 'test-lib')
  transcripts_dir = File.join(lib_dir, 'transcripts')
  FileUtils.mkdir_p(transcripts_dir)

  File.write(File.join(lib_dir, 'library.yaml'), (library_yaml || make_library_yaml).to_yaml)
  File.write(File.join(transcripts_dir, 'script_parsed.yaml'), (script_parsed || make_script_parsed).to_yaml) if script_parsed != :skip

  lib_dir
end

def run_batch(args, dir: nil)
  Dir.mktmpdir do |tmpdir|
    root = dir || tmpdir
    setup_library(root) unless dir
    env = { 'BUTTERCUT_ROOT' => root }
    stdout, stderr, status = Open3.capture3(env, 'ruby', BATCH_SCRIPT, *args)
    yield(stdout, stderr, status) if block_given?
    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus }
  end
end

RSpec.describe 'branch_a_batch.rb' do
  describe 'CLI parsing' do
    it 'exits 1 with usage when --library not provided' do
      _stdout, stderr, status = Open3.capture3('ruby', BATCH_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('--library is required')
    end

    it 'exits 1 when library does not exist' do
      _stdout, stderr, status = Open3.capture3('ruby', BATCH_SCRIPT, '--library', 'nonexistent-library-xyz')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end
  end

  describe 'library.yaml validation' do
    it 'exits 1 when script_parsed field is missing' do
      Dir.mktmpdir do |dir|
        setup_library(dir, library_yaml: make_library_yaml(script_parsed: false), script_parsed: :skip)
        env = { 'BUTTERCUT_ROOT' => dir }
        _stdout, stderr, status = Open3.capture3(env, 'ruby', BATCH_SCRIPT, '--library', 'test-lib')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('script_parsed')
      end
    end

    it 'exits 1 when videos field is missing' do
      Dir.mktmpdir do |dir|
        setup_library(dir, library_yaml: make_library_yaml(videos: false))
        env = { 'BUTTERCUT_ROOT' => dir }
        _stdout, stderr, status = Open3.capture3(env, 'ruby', BATCH_SCRIPT, '--library', 'test-lib')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('videos')
      end
    end
  end

  describe '--shorts range parsing' do
    it 'accepts valid range and proceeds past CLI parsing' do
      Dir.mktmpdir do |dir|
        setup_library(dir)
        env = { 'BUTTERCUT_ROOT' => dir }
        _stdout, stderr, status = Open3.capture3(env, 'ruby', BATCH_SCRIPT,
          '--library', 'test-lib', '--shorts', '1..2')
        # Script will fail later (no real video files), but should get past CLI validation
        expect(stderr).not_to include('--library is required')
        expect(stderr).not_to include('Library not found')
        expect(stderr).not_to include('Invalid --shorts')
        expect(stderr).to include('Processing 2 shorts')
      end
    end

    it 'defaults to all shorts from script_parsed when --shorts not given' do
      Dir.mktmpdir do |dir|
        setup_library(dir, script_parsed: make_script_parsed(shorts_count: 5))
        env = { 'BUTTERCUT_ROOT' => dir }
        _stdout, stderr, status = Open3.capture3(env, 'ruby', BATCH_SCRIPT, '--library', 'test-lib')
        expect(stderr).not_to include('--library is required')
        expect(stderr).to include('Processing 5 shorts')
      end
    end
  end
end
