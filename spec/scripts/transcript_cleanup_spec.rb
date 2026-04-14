require 'open3'
require 'json'
require 'tmpdir'

CLEANUP_SCRIPT = File.expand_path('../../scripts/transcript_cleanup.rb', __dir__)

def make_transcript_segment(text:, start_t:, end_t:, words: nil)
  words ||= text.split.each_with_index.map do |w, i|
    dur = (end_t - start_t) / text.split.size.to_f
    { 'word' => w, 'start' => (start_t + i * dur).round(3), 'end' => (start_t + (i + 1) * dur).round(3) }
  end
  { 'text' => text, 'start' => start_t, 'end' => end_t, 'words' => words }
end

def make_transcript(segments)
  { 'segments' => segments }
end

def run_cleanup(transcript, speech_analysis: nil, protect_rhetorical: false)
  Dir.mktmpdir do |dir|
    input_path = File.join(dir, 'transcript.json')
    File.write(input_path, transcript.to_json)

    args = ['ruby', CLEANUP_SCRIPT, input_path]

    if speech_analysis
      sa_path = File.join(dir, 'speech_analysis.json')
      File.write(sa_path, speech_analysis.to_json)
      args += ['--speech-analysis', sa_path]
    end

    args << '--protect-rhetorical' if protect_rhetorical

    stdout, stderr, status = Open3.capture3(*args)

    output_path = File.join(dir, 'transcript_cleaned.json')
    cleaned = File.exist?(output_path) ? JSON.parse(File.read(output_path)) : nil

    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, cleaned: cleaned }
  end
end

RSpec.describe 'transcript_cleanup.rb' do
  describe 'segment-level dedup' do
    it 'drops first segment when 70%+ word overlap with next' do
      transcript = make_transcript([
        make_transcript_segment(text: 'The most important thing about building a business is consistency and focus', start_t: 10.0, end_t: 15.0),
        make_transcript_segment(text: 'The most important thing about building a business is consistency and dedication', start_t: 16.0, end_t: 21.0),
        make_transcript_segment(text: 'Something completely different about cooking pasta', start_t: 25.0, end_t: 30.0)
      ])
      result = run_cleanup(transcript)
      expect(result[:exit_code]).to eq(0)
      expect(result[:cleaned]['segments'].size).to eq(2)
      # First segment (the retake) should be dropped, second kept
      expect(result[:cleaned]['segments'][0]['start']).to eq(16.0)
    end
  end

  describe 'false start removal' do
    it 'drops a trailing-conjunction segment followed by similar content' do
      transcript = make_transcript([
        make_transcript_segment(text: 'So the thing about marketing and', start_t: 10.0, end_t: 12.5),
        make_transcript_segment(text: 'So the thing about marketing is that you need to be persistent.', start_t: 13.0, end_t: 18.0),
        make_transcript_segment(text: 'Another topic entirely about science.', start_t: 20.0, end_t: 25.0)
      ])
      result = run_cleanup(transcript)
      expect(result[:exit_code]).to eq(0)
      # First segment is a false start (ends on "and", similar opening)
      expect(result[:cleaned]['segments'].size).to eq(2)
      expect(result[:cleaned]['segments'][0]['start']).to eq(13.0)
    end
  end

  describe 'filler removal' do
    it 'drops short segments that are entirely filler words' do
      transcript = make_transcript([
        make_transcript_segment(text: 'um yeah okay', start_t: 5.0, end_t: 6.0),
        make_transcript_segment(text: 'The real content starts here with something meaningful.', start_t: 7.0, end_t: 12.0)
      ])
      result = run_cleanup(transcript)
      expect(result[:exit_code]).to eq(0)
      expect(result[:cleaned]['segments'].size).to eq(1)
      expect(result[:cleaned]['segments'][0]['start']).to eq(7.0)
    end

    it 'keeps long filler segments (>1.5s) even if all filler' do
      transcript = make_transcript([
        make_transcript_segment(text: 'um yeah well okay so', start_t: 5.0, end_t: 7.0),
        make_transcript_segment(text: 'The content after.', start_t: 8.0, end_t: 10.0)
      ])
      result = run_cleanup(transcript)
      expect(result[:exit_code]).to eq(0)
      # 2 seconds duration > 1.5s threshold, so the filler is kept
      expect(result[:cleaned]['segments'].size).to eq(2)
    end
  end

  describe 'within-segment de-stutter' do
    it 'removes repeated consecutive words within a segment' do
      words = [
        { 'word' => 'The', 'start' => 10.0, 'end' => 10.2 },
        { 'word' => 'most', 'start' => 10.2, 'end' => 10.4 },
        { 'word' => 'most', 'start' => 10.4, 'end' => 10.6 },
        { 'word' => 'most', 'start' => 10.6, 'end' => 10.8 },
        { 'word' => 'important', 'start' => 10.8, 'end' => 11.2 },
        { 'word' => 'thing', 'start' => 11.2, 'end' => 11.5 },
        { 'word' => 'is', 'start' => 11.5, 'end' => 11.7 },
        { 'word' => 'consistency.', 'start' => 11.7, 'end' => 12.2 }
      ]
      transcript = make_transcript([
        { 'text' => 'The most most most important thing is consistency.', 'start' => 10.0, 'end' => 12.2, 'words' => words }
      ])
      result = run_cleanup(transcript)
      expect(result[:exit_code]).to eq(0)
      seg = result[:cleaned]['segments'][0]
      # "most most most" should become just "most"
      expect(seg['text']).not_to match(/most most/)
      expect(seg['words'].count { |w| w['word'].downcase.gsub(/[^a-z]/, '') == 'most' }).to eq(1)
    end
  end

  describe 'rhetorical protection' do
    it 'removes repeats when --protect-rhetorical is not set' do
      words = [
        { 'word' => 'No', 'start' => 10.0, 'end' => 10.3 },
        { 'word' => 'no', 'start' => 10.8, 'end' => 11.1 },
        { 'word' => 'no', 'start' => 11.5, 'end' => 11.8 },
        { 'word' => 'that', 'start' => 12.0, 'end' => 12.2 },
        { 'word' => 'is', 'start' => 12.2, 'end' => 12.4 },
        { 'word' => 'not', 'start' => 12.4, 'end' => 12.6 },
        { 'word' => 'acceptable.', 'start' => 12.6, 'end' => 13.2 }
      ]
      transcript = make_transcript([
        { 'text' => 'No no no that is not acceptable.', 'start' => 10.0, 'end' => 13.2, 'words' => words }
      ])
      # No --protect-rhetorical, no speech analysis → repeats removed
      result = run_cleanup(transcript)
      expect(result[:exit_code]).to eq(0)
      seg = result[:cleaned]['segments'][0]
      no_count = seg['words'].count { |w| w['word'].downcase.gsub(/[^a-z]/, '') == 'no' }
      expect(no_count).to eq(1)
    end

    it 'preserves rhetorical repeats when --protect-rhetorical and speech analysis show pause' do
      words = [
        { 'word' => 'No', 'start' => 10.0, 'end' => 10.3 },
        { 'word' => 'no', 'start' => 10.8, 'end' => 11.1 },
        { 'word' => 'no', 'start' => 11.5, 'end' => 11.8 },
        { 'word' => 'that', 'start' => 12.0, 'end' => 12.2 },
        { 'word' => 'is', 'start' => 12.2, 'end' => 12.4 },
        { 'word' => 'not', 'start' => 12.4, 'end' => 12.6 },
        { 'word' => 'acceptable.', 'start' => 12.6, 'end' => 13.2 }
      ]
      transcript = make_transcript([
        { 'text' => 'No no no that is not acceptable.', 'start' => 10.0, 'end' => 13.2, 'words' => words }
      ])
      # Speech analysis shows silence gaps between each "no"
      speech_analysis = {
        'speech_segments' => [
          { 'start' => 10.0, 'end' => 10.3 },
          { 'start' => 10.8, 'end' => 11.1 },
          { 'start' => 11.5, 'end' => 13.2 }
        ]
      }
      result = run_cleanup(transcript, speech_analysis: speech_analysis, protect_rhetorical: true)
      expect(result[:exit_code]).to eq(0)
      seg = result[:cleaned]['segments'][0]
      # With 500ms gaps and protection on, "no no no" should be preserved
      no_count = seg['words'].count { |w| w['word'].downcase.gsub(/[^a-z]/, '') == 'no' }
      expect(no_count).to eq(3)
    end
  end

  describe 'edge cases' do
    it 'aborts on empty segments array' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'empty.json')
        File.write(path, { 'segments' => [] }.to_json)
        _stdout, stderr, status = Open3.capture3('ruby', CLEANUP_SCRIPT, path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('No segments found')
      end
    end

    it 'handles single-segment transcript without crashing' do
      transcript = make_transcript([
        make_transcript_segment(text: 'Just one segment with enough words to process properly.', start_t: 0.0, end_t: 5.0)
      ])
      result = run_cleanup(transcript)
      expect(result[:exit_code]).to eq(0)
      expect(result[:cleaned]['segments'].size).to eq(1)
    end

    it 'exits non-zero on corrupted JSON input' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'bad.json')
        File.write(path, '{ not valid json at all }}}')
        _stdout, _stderr, status = Open3.capture3('ruby', CLEANUP_SCRIPT, path)
        expect(status.exitstatus).not_to eq(0)
      end
    end
  end
end
