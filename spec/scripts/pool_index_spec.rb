require 'tmpdir'
require 'yaml'
require 'digest'
require 'fileutils'

POOL_INDEX_SCRIPT = File.expand_path('../../scripts/pool_index.rb', __dir__)

require POOL_INDEX_SCRIPT

RSpec.describe 'PoolIndex' do
  describe '.empty_index' do
    it 'returns correct schema' do
      idx = PoolIndex.empty_index
      expect(idx['pool_version']).to eq(1)
      expect(idx['sources']).to eq({})
      expect(idx['last_updated']).to be_nil
    end
  end

  describe '.load / .save round-trip' do
    it 'returns empty_index when no file exists' do
      Dir.mktmpdir do |dir|
        idx = PoolIndex.load(dir)
        expect(idx['pool_version']).to eq(1)
        expect(idx['sources']).to eq({})
      end
    end

    it 'saves and reloads index with sources intact' do
      Dir.mktmpdir do |dir|
        idx = PoolIndex.empty_index
        idx['sources']['foo.mp4'] = {
          'sha256' => 'abc123',
          'media_type' => 'video_with_audio',
          'duration' => 42.5
        }
        PoolIndex.save(dir, idx)

        reloaded = PoolIndex.load(dir)
        expect(reloaded['sources']['foo.mp4']['sha256']).to eq('abc123')
        expect(reloaded['sources']['foo.mp4']['duration']).to eq(42.5)
      end
    end

    it 'stamps last_updated on save' do
      Dir.mktmpdir do |dir|
        idx = PoolIndex.empty_index
        PoolIndex.save(dir, idx)
        reloaded = PoolIndex.load(dir)
        expect(reloaded['last_updated']).not_to be_nil
        expect(reloaded['last_updated'].to_s).to match(/\d{4}-\d{2}-\d{2}/)
      end
    end
  end

  describe '.compute_sha256' do
    it 'returns hex digest' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'test.txt')
        File.write(path, 'hello world')
        sha = PoolIndex.compute_sha256(path)
        expect(sha).to eq(Digest::SHA256.file(path).hexdigest)
        expect(sha.length).to eq(64)
      end
    end

    it 'returns different digest after content change' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'test.txt')
        File.write(path, 'version 1')
        sha1 = PoolIndex.compute_sha256(path)
        File.write(path, 'version 2')
        sha2 = PoolIndex.compute_sha256(path)
        expect(sha1).not_to eq(sha2)
      end
    end
  end

  describe '.detect_media_type' do
    it 'returns audio_only for .m4a' do
      expect(PoolIndex.detect_media_type('/pool/voice_memo.m4a')).to eq('audio_only')
    end

    it 'returns audio_only for .mp3' do
      expect(PoolIndex.detect_media_type('/pool/recording.mp3')).to eq('audio_only')
    end

    it 'returns audio_only for .wav' do
      expect(PoolIndex.detect_media_type('/pool/audio.wav')).to eq('audio_only')
    end

    it 'returns audio_only for .aac' do
      expect(PoolIndex.detect_media_type('/pool/audio.aac')).to eq('audio_only')
    end

    it 'returns broll for video in B Roll folder' do
      expect(PoolIndex.detect_media_type('/pool/B Roll/clip.mp4')).to eq('broll')
    end

    it 'returns broll for video in b-roll folder' do
      expect(PoolIndex.detect_media_type('/pool/b-roll/clip.mov')).to eq('broll')
    end

    it 'returns broll for video in broll folder' do
      expect(PoolIndex.detect_media_type('/pool/broll/clip.mp4')).to eq('broll')
    end

    it 'returns video_with_audio for normal video' do
      expect(PoolIndex.detect_media_type('/pool/20250120_camera.mov')).to eq('video_with_audio')
    end

    it 'returns video_with_audio for .mkv outside broll folder' do
      expect(PoolIndex.detect_media_type('/pool/interview.mkv')).to eq('video_with_audio')
    end
  end

  describe '.audio_only?' do
    it 'returns true for audio extensions' do
      %w[.m4a .mp3 .wav .aac].each do |ext|
        expect(PoolIndex.audio_only?("/path/file#{ext}")).to be true
      end
    end

    it 'returns false for video extensions' do
      %w[.mp4 .mov .mkv].each do |ext|
        expect(PoolIndex.audio_only?("/path/file#{ext}")).to be false
      end
    end
  end

  describe '.scan_pool' do
    it 'finds new files not in index' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'clip.mp4'))
        FileUtils.touch(File.join(dir, 'memo.m4a'))
        idx = PoolIndex.empty_index
        result = PoolIndex.scan_pool(dir, idx)
        expect(result[:new].map { |f| File.basename(f) }).to contain_exactly('clip.mp4', 'memo.m4a')
        expect(result[:changed]).to be_empty
        expect(result[:unchanged]).to be_empty
        expect(result[:removed]).to be_empty
      end
    end

    it 'marks unchanged files when sha256 matches' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'clip.mp4')
        File.write(path, 'fake video content')
        sha = PoolIndex.compute_sha256(path)

        idx = PoolIndex.empty_index
        idx['sources']['clip.mp4'] = { 'sha256' => sha }
        result = PoolIndex.scan_pool(dir, idx)

        expect(result[:unchanged].map { |f| File.basename(f) }).to include('clip.mp4')
        expect(result[:new]).to be_empty
        expect(result[:changed]).to be_empty
      end
    end

    it 'sha256 change detection triggers re-ingest (changed list)' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'clip.mp4')
        File.write(path, 'original content')

        idx = PoolIndex.empty_index
        idx['sources']['clip.mp4'] = { 'sha256' => 'stale_sha256_does_not_match' }
        result = PoolIndex.scan_pool(dir, idx)

        expect(result[:changed].map { |f| File.basename(f) }).to include('clip.mp4')
        expect(result[:unchanged]).to be_empty
      end
    end

    it 'detects removed files (in index but not on disk)' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'present.mp4'))
        idx = PoolIndex.empty_index
        idx['sources']['present.mp4']  = { 'sha256' => 'x' }
        idx['sources']['deleted.mp4']  = { 'sha256' => 'y' }
        result = PoolIndex.scan_pool(dir, idx)
        expect(result[:removed]).to include('deleted.mp4')
        expect(result[:removed]).not_to include('present.mp4')
      end
    end

    it 'force: true marks all files as new regardless of sha256' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'clip.mp4')
        File.write(path, 'content')
        sha = PoolIndex.compute_sha256(path)

        idx = PoolIndex.empty_index
        idx['sources']['clip.mp4'] = { 'sha256' => sha }

        result = PoolIndex.scan_pool(dir, idx, force: true)
        expect(result[:new].map { |f| File.basename(f) }).to include('clip.mp4')
        expect(result[:unchanged]).to be_empty
      end
    end

    it 'ignores non-media files' do
      Dir.mktmpdir do |dir|
        FileUtils.touch(File.join(dir, 'notes.txt'))
        FileUtils.touch(File.join(dir, 'thumbnail.jpg'))
        FileUtils.touch(File.join(dir, 'clip.mp4'))
        idx = PoolIndex.empty_index
        result = PoolIndex.scan_pool(dir, idx)
        found_names = result[:new].map { |f| File.basename(f) }
        expect(found_names).to contain_exactly('clip.mp4')
      end
    end

    it 'scans subdirectories (B Roll folder)' do
      Dir.mktmpdir do |dir|
        broll_dir = File.join(dir, 'B Roll')
        FileUtils.mkdir_p(broll_dir)
        FileUtils.touch(File.join(broll_dir, 'broll_clip.mp4'))
        FileUtils.touch(File.join(dir, 'main.mp4'))
        idx = PoolIndex.empty_index
        result = PoolIndex.scan_pool(dir, idx)
        found_names = result[:new].map { |f| File.basename(f) }
        expect(found_names).to include('broll_clip.mp4', 'main.mp4')
      end
    end
  end

  describe '.add_source' do
    it 'creates new entry with correct schema' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'video.mp4')
        File.write(path, 'fake video')
        idx = PoolIndex.empty_index
        entry = PoolIndex.add_source(idx, path)
        expect(entry['sha256']).to eq(PoolIndex.compute_sha256(path))
        expect(entry['media_type']).to eq('video_with_audio')
        expect(entry['transcript_file']).to be_nil
        expect(entry['visual_analysis']).to be_nil
        expect(entry['speakers_detected']).to be_nil
        expect(entry['speaker_count']).to eq(1)
        expect(entry['diarization_enabled']).to eq(false)
        expect(entry['hq_audio_source']).to be_nil
        expect(entry['added_at']).not_to be_nil
        expect(idx['sources']['video.mp4']).to eq(entry)
      end
    end

    it 'detects audio_only media type' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'memo.m4a')
        File.write(path, 'fake audio')
        idx = PoolIndex.empty_index
        entry = PoolIndex.add_source(idx, path)
        expect(entry['media_type']).to eq('audio_only')
      end
    end

    it 'merges extra attrs' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'clip.mp4')
        File.write(path, 'fake video')
        idx = PoolIndex.empty_index
        PoolIndex.add_source(idx, path, 'transcript_file' => 'clip.json')
        expect(idx['sources']['clip.mp4']['transcript_file']).to eq('clip.json')
      end
    end

    it 'preserves added_at when re-adding existing entry' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'clip.mp4')
        File.write(path, 'content')
        idx = PoolIndex.empty_index
        first  = PoolIndex.add_source(idx, path)
        added1 = first['added_at']
        sleep(0.01)
        PoolIndex.add_source(idx, path)
        expect(idx['sources']['clip.mp4']['added_at']).to eq(added1)
      end
    end
  end

  describe '.mark_ingested' do
    it 'sets ingested_at and merges output fields' do
      idx = PoolIndex.empty_index
      idx['sources']['clip.mp4'] = { 'sha256' => 'abc' }
      PoolIndex.mark_ingested(idx, 'clip.mp4', 'transcript_file' => 'clip.json', 'speech_analysis' => 'clip_sa.json')
      entry = idx['sources']['clip.mp4']
      expect(entry['ingested_at']).not_to be_nil
      expect(entry['transcript_file']).to eq('clip.json')
      expect(entry['speech_analysis']).to eq('clip_sa.json')
    end

    it 'records visual_analysis field' do
      idx = PoolIndex.empty_index
      idx['sources']['clip.mp4'] = { 'sha256' => 'abc' }
      PoolIndex.mark_ingested(idx, 'clip.mp4', 'visual_analysis' => 'clip_visual_analysis.yaml')
      expect(idx['sources']['clip.mp4']['visual_analysis']).to eq('clip_visual_analysis.yaml')
    end

    it 'records speaker tracking fields' do
      idx = PoolIndex.empty_index
      idx['sources']['podcast.mp4'] = { 'sha256' => 'abc' }
      PoolIndex.mark_ingested(idx, 'podcast.mp4',
        'speakers_detected' => ['SPEAKER_00', 'SPEAKER_01'],
        'speaker_count' => 2,
        'diarization_enabled' => true)
      entry = idx['sources']['podcast.mp4']
      expect(entry['speakers_detected']).to eq(['SPEAKER_00', 'SPEAKER_01'])
      expect(entry['speaker_count']).to eq(2)
      expect(entry['diarization_enabled']).to eq(true)
    end
  end

  describe '.set_hq_pair' do
    it 'records HQ pair on both video and audio entries' do
      idx = PoolIndex.empty_index
      idx['sources']['clip.mp4']   = { 'media_type' => 'video_with_audio' }
      idx['sources']['mic.m4a']    = { 'media_type' => 'audio_only' }
      PoolIndex.set_hq_pair(idx, 'clip.mp4', 'mic.m4a', 0.342)
      expect(idx['sources']['clip.mp4']['hq_audio_source']).to eq('mic.m4a')
      expect(idx['sources']['clip.mp4']['hq_audio_offset']).to be_within(0.0001).of(0.342)
      expect(idx['sources']['mic.m4a']['role']).to eq('hq_audio_for')
      expect(idx['sources']['mic.m4a']['hq_audio_for']).to eq('clip.mp4')
    end
  end
end
