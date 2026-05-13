require 'open3'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'

PROSODY_SCRIPT = File.expand_path('../../scripts/audio_prosody.rb', __dir__)

def make_library(dir, videos:)
  lib_dir = File.join(dir, '.thelma')
  transcripts_dir = File.join(lib_dir, 'transcripts')
  FileUtils.mkdir_p(transcripts_dir)

  lib = {
    'library_name' => 'test-lib',
    'videos' => videos.map { |v| v[:yaml] }
  }
  File.write(File.join(lib_dir, 'library.yaml'), YAML.dump(lib))

  videos.each do |v|
    if v[:speech_analysis]
      File.write(File.join(transcripts_dir, v[:yaml]['speech_analysis']), v[:speech_analysis].to_json)
    end
    tr_key = v[:yaml]['cleaned_transcript'] || v[:yaml]['transcript']
    if tr_key && v[:transcript]
      File.write(File.join(transcripts_dir, tr_key), v[:transcript].to_json)
    end
  end

  lib_dir
end

def run_prosody(dir)
  env = { 'THELMA_LIBRARY_DIR' => File.join(dir, '.thelma') }
  stdout, stderr, status = Open3.capture3(env, 'ruby', PROSODY_SCRIPT, '--library', 'test-lib')
  prosody_path = File.join(dir, '.thelma', 'prosody.yaml')
  prosody = File.exist?(prosody_path) ? YAML.safe_load(File.read(prosody_path)) : nil
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, prosody: prosody }
end

RSpec.describe 'audio_prosody.rb' do
  it 'exits with usage when no --library given' do
    _stdout, stderr, status = Open3.capture3('ruby', PROSODY_SCRIPT)
    expect(status.exitstatus).to eq(1)
    expect(stderr).to include('Usage')
  end

  it 'exits gracefully if no speech_analysis exists' do
    Dir.mktmpdir do |dir|
      make_library(dir, videos: [
        {
          yaml: { 'path' => '/fake/video.mp4', 'transcript' => 'video.json' },
          transcript: { 'segments' => [{ 'words' => [{ 'word' => 'hello', 'start' => 0.0, 'end' => 0.5 }] }] }
        }
      ])
      result = run_prosody(dir)
      expect(result[:exit_code]).to eq(0)
      expect(result[:stderr]).to include('No speech analysis found')
      expect(result[:prosody]).to be_nil
    end
  end

  it 'loads existing speech_analysis and produces prosody.yaml' do
    Dir.mktmpdir do |dir|
      make_library(dir, videos: [
        {
          yaml: {
            'path' => '/fake/video.mp4',
            'speech_analysis' => 'video_speech_analysis.json',
            'transcript' => 'video.json'
          },
          speech_analysis: {
            'speech_segments' => [
              { 'start' => 0.0, 'end' => 2.0 },
              { 'start' => 3.0, 'end' => 5.0 }
            ],
            'long_pauses' => []
          },
          transcript: {
            'segments' => [{
              'words' => [
                { 'word' => 'Hello', 'start' => 0.1, 'end' => 0.5 },
                { 'word' => 'world', 'start' => 0.6, 'end' => 1.0 }
              ]
            }]
          }
        }
      ])
      result = run_prosody(dir)
      expect(result[:exit_code]).to eq(0)
      expect(result[:prosody]).to be_a(Hash)
      expect(result[:prosody].keys).to eq(['/fake/video.mp4'])
      words = result[:prosody]['/fake/video.mp4']['words']
      expect(words.size).to eq(2)
      expect(words[0]['text']).to eq('Hello')
      expect(words[1]['text']).to eq('world')
    end
  end

  it 'flags mid_word_break when silence spans a word' do
    Dir.mktmpdir do |dir|
      # Speech segments: [0.0-1.0] gap [1.5-3.0]
      # Word at 0.8-1.8 straddles the gap (1.0-1.5)
      make_library(dir, videos: [
        {
          yaml: {
            'path' => '/fake/v.mp4',
            'speech_analysis' => 'sa.json',
            'transcript' => 'tr.json'
          },
          speech_analysis: {
            'speech_segments' => [
              { 'start' => 0.0, 'end' => 1.0 },
              { 'start' => 1.5, 'end' => 3.0 }
            ],
            'long_pauses' => []
          },
          transcript: {
            'segments' => [{
              'words' => [
                { 'word' => 'clean', 'start' => 0.1, 'end' => 0.5 },
                { 'word' => 'broken', 'start' => 0.8, 'end' => 1.8 },
                { 'word' => 'after', 'start' => 2.0, 'end' => 2.5 }
              ]
            }]
          }
        }
      ])
      result = run_prosody(dir)
      words = result[:prosody]['/fake/v.mp4']['words']

      expect(words[0]['mid_word_break']).to be false
      expect(words[1]['mid_word_break']).to be true
      expect(words[2]['mid_word_break']).to be false
    end
  end

  it 'computes trailing_pause_ms correctly' do
    Dir.mktmpdir do |dir|
      # Speech: [0.0-1.0], [1.8-3.0]
      # Word "hello" ends at 0.9, inside segment [0.0-1.0]
      #   → gap after containing segment = 1.8 - 1.0 = 800ms
      # Word "world" ends at 2.5, inside segment [1.8-3.0]
      #   → no next segment → nil
      make_library(dir, videos: [
        {
          yaml: {
            'path' => '/fake/v.mp4',
            'speech_analysis' => 'sa.json',
            'transcript' => 'tr.json'
          },
          speech_analysis: {
            'speech_segments' => [
              { 'start' => 0.0, 'end' => 1.0 },
              { 'start' => 1.8, 'end' => 3.0 }
            ],
            'long_pauses' => []
          },
          transcript: {
            'segments' => [{
              'words' => [
                { 'word' => 'hello', 'start' => 0.1, 'end' => 0.9 },
                { 'word' => 'world', 'start' => 2.0, 'end' => 2.5 }
              ]
            }]
          }
        }
      ])
      result = run_prosody(dir)
      words = result[:prosody]['/fake/v.mp4']['words']

      # "hello" is in segment [0.0-1.0], gap to next segment [1.8-3.0] = 800ms
      expect(words[0]['trailing_pause_ms']).to eq(800)
      # "world" is in segment [1.8-3.0], no next segment
      expect(words[1]['trailing_pause_ms']).to be_nil
    end
  end

  it 'handles multi-source library' do
    Dir.mktmpdir do |dir|
      make_library(dir, videos: [
        {
          yaml: {
            'path' => '/fake/a.mp4',
            'speech_analysis' => 'a_sa.json',
            'transcript' => 'a.json'
          },
          speech_analysis: {
            'speech_segments' => [{ 'start' => 0.0, 'end' => 2.0 }],
            'long_pauses' => []
          },
          transcript: {
            'segments' => [{ 'words' => [{ 'word' => 'alpha', 'start' => 0.1, 'end' => 0.5 }] }]
          }
        },
        {
          yaml: {
            'path' => '/fake/b.mp4',
            'speech_analysis' => 'b_sa.json',
            'transcript' => 'b.json'
          },
          speech_analysis: {
            'speech_segments' => [{ 'start' => 0.0, 'end' => 1.5 }],
            'long_pauses' => []
          },
          transcript: {
            'segments' => [{ 'words' => [{ 'word' => 'bravo', 'start' => 0.2, 'end' => 0.8 }] }]
          }
        }
      ])
      result = run_prosody(dir)
      expect(result[:exit_code]).to eq(0)
      expect(result[:prosody].keys).to contain_exactly('/fake/a.mp4', '/fake/b.mp4')
      expect(result[:prosody]['/fake/a.mp4']['words'][0]['text']).to eq('alpha')
      expect(result[:prosody]['/fake/b.mp4']['words'][0]['text']).to eq('bravo')
    end
  end

  it 'detects stumble_marker on repeated word with short gap' do
    Dir.mktmpdir do |dir|
      make_library(dir, videos: [
        {
          yaml: {
            'path' => '/fake/v.mp4',
            'speech_analysis' => 'sa.json',
            'transcript' => 'tr.json'
          },
          speech_analysis: {
            'speech_segments' => [{ 'start' => 0.0, 'end' => 3.0 }],
            'long_pauses' => []
          },
          transcript: {
            'segments' => [{
              'words' => [
                { 'word' => 'the', 'start' => 0.1, 'end' => 0.2 },
                { 'word' => 'the', 'start' => 0.25, 'end' => 0.35 },
                { 'word' => 'thing', 'start' => 0.4, 'end' => 0.7 }
              ]
            }]
          }
        }
      ])
      result = run_prosody(dir)
      words = result[:prosody]['/fake/v.mp4']['words']

      expect(words[0]['stumble_marker']).to be true   # "the" repeated 50ms later
      expect(words[1]['stumble_marker']).to be false   # "the" → "thing" not a repeat
      expect(words[2]['stumble_marker']).to be false
    end
  end
end
