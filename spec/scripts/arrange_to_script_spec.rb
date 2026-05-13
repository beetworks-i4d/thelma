require 'open3'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'

ARRANGE_SCRIPT = File.expand_path('../../scripts/arrange_to_script.rb', __dir__)

# Build a minimal library fixture in a tmpdir.
# Returns the .thelma dir path.
def make_arrange_library(dir, short_beats: nil, transcript_words: nil, prosody: nil,
                         source_path: '/fake/video.mp4', sync_offset: 0.0,
                         source_duration: 300.0, script_format: 'multi_short',
                         speech_analysis: false, multi_source: false)
  lib_dir = File.join(dir, '.thelma')
  transcripts_dir = File.join(lib_dir, 'transcripts')
  FileUtils.mkdir_p(transcripts_dir)
  FileUtils.mkdir_p(File.join(lib_dir, 'pending_llm_calls'))

  videos = [{
    'path' => source_path,
    'duration' => source_duration,
    'transcript' => 'video.json',
    'cleaned_transcript' => 'video_cleaned.json'
  }]
  videos.first['sync_audio'] = { 'path' => '/fake/video.wav', 'offset' => sync_offset } if sync_offset != 0.0
  videos << { 'path' => '/fake/video2.mp4', 'duration' => 200.0, 'transcript' => 'video2.json' } if multi_source

  lib = {
    'library_name' => 'test-lib',
    'videos' => videos
  }
  File.write(File.join(lib_dir, 'library.yaml'), YAML.dump(lib))

  # Transcript
  words = transcript_words || [
    { 'word' => 'This', 'start' => 1.0, 'end' => 1.2 },
    { 'word' => 'is', 'start' => 1.3, 'end' => 1.4 },
    { 'word' => 'a', 'start' => 1.5, 'end' => 1.55 },
    { 'word' => 'test.', 'start' => 1.6, 'end' => 2.0 }
  ]
  tr = { 'segments' => [{ 'words' => words }] }
  File.write(File.join(transcripts_dir, 'video.json'), tr.to_json)
  File.write(File.join(transcripts_dir, 'video_cleaned.json'), tr.to_json)

  # Script parsed
  beats = short_beats || [
    { 'role' => 'hook', 'text' => 'This is a test hook line.' },
    { 'role' => 'close', 'text' => 'This is the closing line.' }
  ]

  if script_format == 'multi_short'
    sp = {
      'source_file' => 'test_script.txt',
      'source_hash' => 'abc123',
      'format' => 'multi_short',
      'shorts' => [{ 'number' => 1, 'title' => 'Test Short', 'section' => 'TEST', 'beats' => beats }]
    }
  else
    sp = {
      'source_file' => 'test_script.txt',
      'source_hash' => 'abc123',
      'format' => 'single',
      'beats' => beats
    }
  end
  File.write(File.join(transcripts_dir, 'script_parsed.yaml'), YAML.dump(sp))

  # Prosody (optional)
  if prosody
    File.write(File.join(lib_dir, 'prosody.yaml'), YAML.dump(prosody))
  end

  lib_dir
end

# Writes a canned LLM response so LLMClient picks it up (re-entrant path).
def seed_llm_response(lib_dir, short_id, response_json)
  pending_dir = File.join(lib_dir, 'pending_llm_calls')
  FileUtils.mkdir_p(pending_dir)
  response_path = File.join(pending_dir, "arrange_#{short_id}_response.yaml")
  File.write(response_path, YAML.dump({ 'response' => response_json.to_json }))
end

def run_arrange(dir, short_id: 'short_01', extra_args: [])
  env = { 'THELMA_LIBRARY_DIR' => File.join(dir, '.thelma') }
  args = ['ruby', ARRANGE_SCRIPT, '--library', 'test-lib', '--short', short_id, '--no-review'] + extra_args
  stdout, stderr, status = Open3.capture3(env, *args)
  output_path = File.join(dir, '.thelma', "arrangement_#{short_id}.yaml")
  arrangement = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, arrangement: arrangement }
end

RSpec.describe 'arrange_to_script.rb' do
  describe 'argument validation' do
    it 'exits with usage when no args given' do
      _stdout, stderr, status = Open3.capture3('ruby', ARRANGE_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits with usage when --short is missing' do
      _stdout, stderr, status = Open3.capture3('ruby', ARRANGE_SCRIPT, '--library', 'foo')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end
  end

  describe 'missing inputs' do
    it 'errors when library.yaml not found' do
      Dir.mktmpdir do |dir|
        env = { 'THELMA_LIBRARY_DIR' => File.join(dir, 'nonexistent') }
        _stdout, stderr, status = Open3.capture3(env, 'ruby', ARRANGE_SCRIPT, '--library', 'x', '--short', 's1', '--no-review')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('library.yaml not found')
      end
    end

    it 'errors when script_parsed.yaml not found' do
      Dir.mktmpdir do |dir|
        lib_dir = File.join(dir, '.thelma')
        FileUtils.mkdir_p(File.join(lib_dir, 'transcripts'))
        File.write(File.join(lib_dir, 'library.yaml'), YAML.dump({
          'library_name' => 'test', 'videos' => [{ 'path' => '/fake/v.mp4', 'duration' => 10.0, 'transcript' => 'v.json', 'cleaned_transcript' => 'v.json' }]
        }))
        File.write(File.join(lib_dir, 'transcripts', 'v.json'), { 'segments' => [{ 'words' => [{ 'word' => 'hi', 'start' => 0.0, 'end' => 0.5 }] }] }.to_json)

        env = { 'THELMA_LIBRARY_DIR' => lib_dir }
        _stdout, stderr, status = Open3.capture3(env, 'ruby', ARRANGE_SCRIPT, '--library', 'test', '--short', 's1', '--no-review')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('script_parsed.yaml not found')
      end
    end

    it 'errors on multi-source library' do
      Dir.mktmpdir do |dir|
        make_arrange_library(dir, multi_source: true)
        result = run_arrange(dir)
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('Multi-source')
      end
    end
  end

  describe 'LLM response parsing' do
    it 'parses valid JSON response and writes arrangement YAML' do
      Dir.mktmpdir do |dir|
        lib_dir = make_arrange_library(dir)
        response = {
          'beats' => [
            { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'This is a test hook line.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 1.0, 't_out' => 2.0,
                            'transcript_match' => 'This is a test.', 'take_id' => nil, 'notes' => nil }] },
            { 'beat_id' => 'close', 'type' => 'close', 'script_text' => 'This is the closing line.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 2.5, 't_out' => 4.0,
                            'transcript_match' => 'Closing words here.', 'take_id' => nil, 'notes' => nil }] }
          ]
        }
        seed_llm_response(lib_dir, 'short_01', response)
        result = run_arrange(dir)

        expect(result[:exit_code]).to eq(0)
        expect(result[:arrangement]).not_to be_nil
        expect(result[:arrangement]['short_id']).to eq('short_01')
        expect(result[:arrangement]['beats'].size).to eq(2)
        expect(result[:arrangement]['beats'][0]['beat_id']).to eq('hook')
        expect(result[:arrangement]['beats'][1]['beat_id']).to eq('close')
      end
    end

    it 'strips markdown fences from JSON response' do
      Dir.mktmpdir do |dir|
        lib_dir = make_arrange_library(dir)
        response = {
          'beats' => [
            { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'Hook.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 1.0, 't_out' => 2.0,
                            'transcript_match' => 'test', 'take_id' => nil, 'notes' => nil }] },
            { 'beat_id' => 'close', 'type' => 'close', 'script_text' => 'Close.',
              'clips' => [] }
          ]
        }
        # Wrap in markdown fences like an LLM might
        fenced = "```json\n#{response.to_json}\n```"
        pending_dir = File.join(lib_dir, 'pending_llm_calls')
        FileUtils.mkdir_p(pending_dir)
        File.write(File.join(pending_dir, 'arrange_short_01_response.yaml'),
                   YAML.dump({ 'response' => fenced }))

        result = run_arrange(dir)
        expect(result[:exit_code]).to eq(0)
        expect(result[:arrangement]['beats'].size).to eq(2)
      end
    end
  end

  describe 'validation' do
    it 'rejects t_in >= t_out' do
      Dir.mktmpdir do |dir|
        lib_dir = make_arrange_library(dir)
        response = {
          'beats' => [
            { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'Hook.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 5.0, 't_out' => 3.0,
                            'transcript_match' => 'bad', 'take_id' => nil, 'notes' => nil }] },
            { 'beat_id' => 'close', 'type' => 'close', 'script_text' => 'Close.', 'clips' => [] }
          ]
        }
        seed_llm_response(lib_dir, 'short_01', response)
        result = run_arrange(dir)

        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('t_in')
        expect(result[:stderr]).to include('t_out')
      end
    end

    it 'rejects negative t_in' do
      Dir.mktmpdir do |dir|
        lib_dir = make_arrange_library(dir)
        response = {
          'beats' => [
            { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'Hook.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => -1.0, 't_out' => 2.0,
                            'transcript_match' => 'bad', 'take_id' => nil, 'notes' => nil }] },
            { 'beat_id' => 'close', 'type' => 'close', 'script_text' => 'Close.', 'clips' => [] }
          ]
        }
        seed_llm_response(lib_dir, 'short_01', response)
        result = run_arrange(dir)

        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('negative')
      end
    end

    it 'rejects t_out exceeding source duration' do
      Dir.mktmpdir do |dir|
        lib_dir = make_arrange_library(dir, source_duration: 10.0)
        response = {
          'beats' => [
            { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'Hook.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 1.0, 't_out' => 999.0,
                            'transcript_match' => 'bad', 'take_id' => nil, 'notes' => nil }] },
            { 'beat_id' => 'close', 'type' => 'close', 'script_text' => 'Close.', 'clips' => [] }
          ]
        }
        seed_llm_response(lib_dir, 'short_01', response)
        result = run_arrange(dir)

        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('exceeds source duration')
      end
    end
  end

  describe 'output format' do
    it 'writes arrangement_<short_id>.yaml with correct schema' do
      Dir.mktmpdir do |dir|
        lib_dir = make_arrange_library(dir, sync_offset: 1.5)
        response = {
          'beats' => [
            { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'Hook.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 1.0, 't_out' => 2.0,
                            'transcript_match' => 'This is', 'take_id' => 'take_2', 'notes' => 'clean delivery' }] },
            { 'beat_id' => 'close', 'type' => 'close', 'script_text' => 'Close.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 3.0, 't_out' => 4.0,
                            'transcript_match' => 'closing', 'take_id' => nil, 'notes' => nil }] }
          ]
        }
        seed_llm_response(lib_dir, 'short_01', response)
        result = run_arrange(dir)

        expect(result[:exit_code]).to eq(0)
        arr = result[:arrangement]
        expect(arr['short_id']).to eq('short_01')
        expect(arr['source_video']).to eq('/fake/video.mp4')
        expect(arr['sync_offset']).to eq(1.5)
        expect(arr['beats'].size).to eq(2)

        clip = arr['beats'][0]['clips'][0]
        expect(clip['t_in']).to eq(1.0)
        expect(clip['t_out']).to eq(2.0)
        expect(clip['take_id']).to eq('take_2')
      end
    end

    it 'outputs file path to stdout' do
      Dir.mktmpdir do |dir|
        lib_dir = make_arrange_library(dir)
        response = {
          'beats' => [
            { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'Hook.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 1.0, 't_out' => 2.0,
                            'transcript_match' => 'test', 'take_id' => nil, 'notes' => nil }] },
            { 'beat_id' => 'close', 'type' => 'close', 'script_text' => 'Close.', 'clips' => [] }
          ]
        }
        seed_llm_response(lib_dir, 'short_01', response)
        result = run_arrange(dir)

        expect(result[:exit_code]).to eq(0)
        expect(result[:stdout]).to include('arrangement_short_01.yaml')
      end
    end
  end

  describe '--no-review' do
    it 'skips review gate and writes output directly' do
      Dir.mktmpdir do |dir|
        lib_dir = make_arrange_library(dir)
        response = {
          'beats' => [
            { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'Hook.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 1.0, 't_out' => 2.0,
                            'transcript_match' => 'test', 'take_id' => nil, 'notes' => nil }] },
            { 'beat_id' => 'close', 'type' => 'close', 'script_text' => 'Close.', 'clips' => [] }
          ]
        }
        seed_llm_response(lib_dir, 'short_01', response)
        result = run_arrange(dir)

        expect(result[:exit_code]).to eq(0)
        expect(result[:stderr]).not_to include('Accept?')
        expect(result[:arrangement]).not_to be_nil
      end
    end
  end

  describe 'single format script' do
    it 'loads beats from single-format script_parsed' do
      Dir.mktmpdir do |dir|
        beats = [{ 'role' => 'section', 'text' => 'All content in one section.' }]
        lib_dir = make_arrange_library(dir, short_beats: beats, script_format: 'single')
        response = {
          'beats' => [
            { 'beat_id' => 'section', 'type' => 'section', 'script_text' => 'All content.',
              'clips' => [{ 'source' => 'video.mp4', 't_in' => 1.0, 't_out' => 2.0,
                            'transcript_match' => 'test', 'take_id' => nil, 'notes' => nil }] }
          ]
        }
        seed_llm_response(lib_dir, 'short_01', response)
        result = run_arrange(dir)

        expect(result[:exit_code]).to eq(0)
        expect(result[:arrangement]['beats'].size).to eq(1)
      end
    end
  end
end
