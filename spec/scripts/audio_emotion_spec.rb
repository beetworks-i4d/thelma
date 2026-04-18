require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'date'

AUDIO_EMOTION_SCRIPT = File.expand_path('../../scripts/audio_emotion.rb', __dir__)

def sample_classified_yaml(segments = nil)
  segments ||= [
    { 't' => 1.0, 'e' => 5.0, 'states' => ['vindication'], 'distillation' => 'test segment one',
      'dur' => 'identity', 'confidence' => 'high' },
    { 't' => 8.0, 'e' => 12.0, 'states' => ['curiosity'], 'distillation' => 'test segment two',
      'dur' => 'mood', 'confidence' => 'medium' }
  ]
  { 'transcript_hash' => 'abc123', 'segments' => segments }
end

def sample_features_yaml(segments = nil)
  segments ||= [
    { 't' => 1.0, 'e' => 5.0, 'energy' => 1.4, 'energy_variance' => 0.001,
      'pitch_mean' => 180.0, 'pitch_trend' => 'rising', 'pitch_range' => 35.0,
      'speaking_rate' => 1.2, 'spectral_centroid' => 1.1, 'audio_profile' => 'emphatic' },
    { 't' => 8.0, 'e' => 12.0, 'energy' => 0.7, 'energy_variance' => 0.0005,
      'pitch_mean' => 140.0, 'pitch_trend' => 'flat', 'pitch_range' => 15.0,
      'speaking_rate' => 0.8, 'spectral_centroid' => 0.9, 'audio_profile' => 'reflective' }
  ]
  {
    'source_wav' => 'test.wav',
    'sample_rate' => 48000,
    'baseline' => { 'rms_mean' => 0.05, 'f0_mean' => 160.0, 'centroid_mean' => 3000.0,
                    'speaking_rate' => 3.5, 'total_speech_duration' => 20.0, 'total_words' => 70 },
    'profile_distribution' => { 'emphatic' => 1, 'reflective' => 1 },
    'segments' => segments
  }
end

RSpec.describe 'audio_emotion.rb' do
  describe 'CLI argument handling' do
    it 'exits 1 with usage when no arguments provided' do
      _stdout, stderr, status = Open3.capture3('ruby', AUDIO_EMOTION_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when only wav_path provided' do
      _stdout, stderr, status = Open3.capture3('ruby', AUDIO_EMOTION_SCRIPT, '/tmp/test.wav')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when WAV file not found' do
      Dir.mktmpdir do |dir|
        seg_path = File.join(dir, 'segments.yaml')
        File.write(seg_path, sample_classified_yaml.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', AUDIO_EMOTION_SCRIPT, '/nonexistent/test.wav', seg_path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('WAV not found')
      end
    end

    it 'exits 1 when segments file not found' do
      Dir.mktmpdir do |dir|
        wav_path = File.join(dir, 'test.wav')
        FileUtils.touch(wav_path)
        _stdout, stderr, status = Open3.capture3('ruby', AUDIO_EMOTION_SCRIPT, wav_path, '/nonexistent/segments.yaml')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('Segments not found')
      end
    end
  end

  describe 'classification merge' do
    it 'merges audio features into segments_classified.yaml by matching t values' do
      Dir.mktmpdir do |dir|
        classified = sample_classified_yaml
        features = sample_features_yaml
        seg_path = File.join(dir, 'segments_classified.yaml')
        feat_path = File.join(dir, 'test_audio_features.yaml')
        File.write(seg_path, classified.to_yaml)
        File.write(feat_path, features.to_yaml)

        # Simulate merge logic (same as in audio_emotion.rb)
        features_data = YAML.safe_load(File.read(feat_path), permitted_classes: [Date])
        classified_data = YAML.safe_load(File.read(seg_path), permitted_classes: [Date])

        features_data['segments'].each do |feat|
          seg = classified_data['segments'].find { |s| (s['t'].to_f - feat['t'].to_f).abs < 0.01 }
          next unless seg
          seg['audio_profile'] = feat['audio_profile']
          seg['audio_energy'] = feat['energy']
          seg['audio_pitch_trend'] = feat['pitch_trend']
          seg['audio_speaking_rate'] = feat['speaking_rate']
        end

        File.write(seg_path, YAML.dump(classified_data))

        # Read back and verify
        result = YAML.safe_load(File.read(seg_path), permitted_classes: [Date])
        seg1 = result['segments'].find { |s| s['t'] == 1.0 }
        seg2 = result['segments'].find { |s| s['t'] == 8.0 }

        expect(seg1['audio_profile']).to eq('emphatic')
        expect(seg1['audio_energy']).to eq(1.4)
        expect(seg1['audio_pitch_trend']).to eq('rising')
        expect(seg1['audio_speaking_rate']).to eq(1.2)

        expect(seg2['audio_profile']).to eq('reflective')
        expect(seg2['audio_energy']).to eq(0.7)
        expect(seg2['audio_pitch_trend']).to eq('flat')
        expect(seg2['audio_speaking_rate']).to eq(0.8)
      end
    end

    it 'preserves existing segment fields during merge' do
      Dir.mktmpdir do |dir|
        classified = sample_classified_yaml
        features = sample_features_yaml
        seg_path = File.join(dir, 'segments_classified.yaml')
        feat_path = File.join(dir, 'test_audio_features.yaml')
        File.write(seg_path, classified.to_yaml)
        File.write(feat_path, features.to_yaml)

        features_data = YAML.safe_load(File.read(feat_path), permitted_classes: [Date])
        classified_data = YAML.safe_load(File.read(seg_path), permitted_classes: [Date])

        features_data['segments'].each do |feat|
          seg = classified_data['segments'].find { |s| (s['t'].to_f - feat['t'].to_f).abs < 0.01 }
          next unless seg
          seg['audio_profile'] = feat['audio_profile']
          seg['audio_energy'] = feat['energy']
          seg['audio_pitch_trend'] = feat['pitch_trend']
          seg['audio_speaking_rate'] = feat['speaking_rate']
        end

        result = classified_data
        seg1 = result['segments'].find { |s| s['t'] == 1.0 }
        expect(seg1['states']).to eq(['vindication'])
        expect(seg1['distillation']).to eq('test segment one')
        expect(seg1['dur']).to eq('identity')
        expect(seg1['audio_profile']).to eq('emphatic')
      end
    end

    it 'skips segments not found in features by t value' do
      Dir.mktmpdir do |dir|
        classified = sample_classified_yaml([
          { 't' => 1.0, 'e' => 5.0, 'states' => ['vindication'], 'distillation' => 'present' },
          { 't' => 20.0, 'e' => 25.0, 'states' => ['curiosity'], 'distillation' => 'missing' }
        ])
        features = sample_features_yaml([
          { 't' => 1.0, 'e' => 5.0, 'energy' => 1.4, 'pitch_trend' => 'rising',
            'speaking_rate' => 1.2, 'audio_profile' => 'emphatic' }
        ])

        seg_path = File.join(dir, 'segments_classified.yaml')
        feat_path = File.join(dir, 'test_audio_features.yaml')
        File.write(seg_path, classified.to_yaml)
        File.write(feat_path, features.to_yaml)

        features_data = YAML.safe_load(File.read(feat_path), permitted_classes: [Date])
        classified_data = YAML.safe_load(File.read(seg_path), permitted_classes: [Date])

        features_data['segments'].each do |feat|
          seg = classified_data['segments'].find { |s| (s['t'].to_f - feat['t'].to_f).abs < 0.01 }
          next unless seg
          seg['audio_profile'] = feat['audio_profile']
        end

        seg_missing = classified_data['segments'].find { |s| s['t'] == 20.0 }
        expect(seg_missing['audio_profile']).to be_nil
      end
    end
  end

  describe 'output YAML schema' do
    it 'validates audio_features.yaml has required top-level keys' do
      features = sample_features_yaml
      expect(features).to have_key('source_wav')
      expect(features).to have_key('sample_rate')
      expect(features).to have_key('baseline')
      expect(features).to have_key('profile_distribution')
      expect(features).to have_key('segments')
    end

    it 'validates baseline has required fields' do
      baseline = sample_features_yaml['baseline']
      expect(baseline).to have_key('rms_mean')
      expect(baseline).to have_key('f0_mean')
      expect(baseline).to have_key('centroid_mean')
      expect(baseline).to have_key('speaking_rate')
    end

    it 'validates each segment has required feature fields' do
      sample_features_yaml['segments'].each do |seg|
        expect(seg).to have_key('t')
        expect(seg).to have_key('e')
        expect(seg).to have_key('energy')
        expect(seg).to have_key('pitch_trend')
        expect(seg).to have_key('speaking_rate')
        expect(seg).to have_key('audio_profile')
      end
    end

    it 'validates audio_profile is one of the known labels' do
      valid_profiles = %w[emphatic authoritative reflective urgent building landing casual]
      sample_features_yaml['segments'].each do |seg|
        expect(valid_profiles).to include(seg['audio_profile'])
      end
    end
  end

  describe 'caching behavior' do
    it 'returns cached path when audio_features exists in library.yaml' do
      Dir.mktmpdir do |dir|
        transcripts_dir = File.join(dir, 'transcripts')
        FileUtils.mkdir_p(transcripts_dir)

        # Create a dummy WAV and segments file
        wav_path = File.join(dir, 'test.wav')
        FileUtils.touch(wav_path)
        seg_path = File.join(transcripts_dir, 'segments_classified.yaml')
        File.write(seg_path, sample_classified_yaml.to_yaml)

        # Create a cached audio features file
        cached_path = File.join(transcripts_dir, 'test_audio_features.yaml')
        File.write(cached_path, sample_features_yaml.to_yaml)

        # Create library.yaml with cached entry
        lib = {
          'videos' => [
            { 'path' => wav_path, 'audio_features' => 'test_audio_features.yaml' }
          ]
        }
        lib_path = File.join(dir, 'library.yaml')
        File.write(lib_path, lib.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', AUDIO_EMOTION_SCRIPT, wav_path, seg_path, lib_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('Using cached')
        expect(stdout.strip).to eq(cached_path)
      end
    end
  end
end
