require 'open3'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'nokogiri'

BUILD_SCRIPT = File.expand_path('../../scripts/build_structure_cut.rb', __dir__)
FIXTURE_VIDEO = File.expand_path('../fixtures/media/MVI_0309_720p.mov', __dir__)

def run_build(yaml_data, extra_files: {})
  Dir.mktmpdir do |dir|
    yaml_path = File.join(dir, 'structure_cut.yaml')
    File.write(yaml_path, yaml_data.to_yaml)

    extra_files.each do |name, content|
      File.write(File.join(dir, name.to_s), content.is_a?(String) ? content : content.to_json)
    end

    stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)

    xml_files = Dir.glob(File.join(dir, '*.xml'))
    xml_content = xml_files.first ? File.read(xml_files.first) : nil
    doc = xml_content ? Nokogiri::XML(xml_content) : nil

    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus,
      xml: xml_content, doc: doc, xml_path: xml_files.first, dir: dir }
  end
end

def base_config(dir, video_path: FIXTURE_VIDEO)
  {
    'video_path' => video_path,
    'output_dir' => dir,
    'editor' => 'fcp7',
    'name' => 'Test Cut',
    'clips' => [
      { 'video_start' => 1.0, 'video_end' => 3.0 },
      { 'video_start' => 5.0, 'video_end' => 8.0 }
    ]
  }
end

RSpec.describe 'build_structure_cut.rb' do
  describe 'error handling' do
    it 'exits 1 with usage when no argument provided' do
      _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when YAML file not found' do
      _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, '/nonexistent/path.yaml')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('YAML not found')
    end

    it 'exits 1 when required fields are missing' do
      Dir.mktmpdir do |dir|
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, { 'video_path' => '/tmp/v.mp4' }.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('Missing required field')
      end
    end

    it 'exits 1 when video file does not exist' do
      Dir.mktmpdir do |dir|
        config = base_config(dir, video_path: '/nonexistent/video.mp4')
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('Video not found')
      end
    end

    it 'exits 1 when clip end is before start' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['clips'] = [{ 'video_start' => 5.0, 'video_end' => 2.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('must be after start')
      end
    end

    it 'exits 1 when clip has no time fields' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['clips'] = [{ 'label' => 'broken' }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('missing time fields')
      end
    end

    it 'exits 1 when audio_start used without sync_audio' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['clips'] = [{ 'audio_start' => 10.0, 'audio_end' => 15.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('sync_audio required')
      end
    end
  end

  describe 'backward compatibility' do
    it 'exits 1 when bare start/end used without time_domain' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['clips'] = [{ 'start' => 1.0, 'end' => 3.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include("bare 'start'/'end' without time_domain")
      end
    end

    it 'accepts legacy time_domain: video with deprecation warning' do
      result = run_build(nil) # placeholder, real test below
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['time_domain'] = 'video'
        config['clips'] = [{ 'start' => 1.0, 'end' => 3.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('DEPRECATION')
        expect(stdout.strip).to match(/\.xml$/)
      end
    end
  end

  describe 'basic XML generation' do
    it 'produces valid xmeml output with video_start/video_end clips' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        xml_path = stdout.strip
        expect(xml_path).to match(/\.xml$/)
        expect(File.exist?(xml_path)).to be true

        doc = Nokogiri::XML(File.read(xml_path))
        expect(doc.at_xpath('//xmeml')).not_to be_nil
        expect(doc.at_xpath('//sequence')).not_to be_nil

        clipitems = doc.xpath('//sequence/media/video/track/clipitem')
        expect(clipitems.size).to eq(2)
      end
    end
  end

  describe 'breathing room buffer' do
    it 'applies default 3-frame buffer to clip start and duration' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['clips'] = [{ 'video_start' => 2.0, 'video_end' => 5.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        clip = doc.at_xpath('//sequence/media/video/track/clipitem')
        in_val = clip.at_xpath('in').text.to_i
        out_val = clip.at_xpath('out').text.to_i
        duration_frames = out_val - in_val

        # With 3-frame buffer on both ends at ~24fps, duration should be
        # longer than base 3.0s * 24fps = 72 frames
        expect(duration_frames).to be > 72
      end
    end

    it 'respects custom breathing_room_frames setting' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['breathing_room_frames'] = 0
        config['clips'] = [{ 'video_start' => 2.0, 'video_end' => 5.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        clip = doc.at_xpath('//sequence/media/video/track/clipitem')
        in_val = clip.at_xpath('in').text.to_i
        out_val = clip.at_xpath('out').text.to_i
        duration_frames = out_val - in_val

        # With 0 buffer, duration should be ~3.0s * 24fps = ~72 frames
        # Allow small rounding tolerance
        expect(duration_frames).to be_within(2).of(72)
      end
    end
  end

  describe 'markers' do
    it 'includes user-defined markers in the XML output' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['markers'] = [
          { 'name' => 'TITLE', 'comment' => 'Show title here', 'time' => 0.0, 'color' => 'blue' },
          { 'name' => 'NOTE', 'comment' => 'Check audio', 'time' => 1.5, 'color' => 'yellow' }
        ]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        markers = doc.xpath('//sequence/marker')
        expect(markers.size).to be >= 2
        comments = markers.map { |m| m.at_xpath('comment').text }
        expect(comments).to include('Show title here')
        expect(comments).to include('Check audio')
      end
    end
  end

  describe 'format detection' do
    it 'detects source video dimensions and frame rate' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['clips'] = [{ 'video_start' => 1.0, 'video_end' => 2.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        # Fixture is 1280x720 at 23.976fps
        expect(stderr).to match(/1280.*720|720p/)
        expect(stderr).to match(/23\.976|24/)
      end
    end
  end

  describe 'emotion markers' do
    let(:classification_data) do
      {
        'segments' => [
          {
            't' => 1.5,
            'e' => 3.0,
            'states' => %w[vindication curiosity],
            'distillation' => 'system rigged but you win',
            'signal' => 'named target, specific claim',
            'dur' => 'identity',
            'narrative_role' => 'primary',
            'confidence' => 'high'
          },
          {
            't' => 5.5,
            'e' => 7.0,
            'states' => %w[competence aspiration],
            'distillation' => 'three-step framework reveal',
            'signal' => 'framework reveal',
            'dur' => 'spike',
            'narrative_role' => 'secondary',
            'confidence' => 'medium'
          }
        ]
      }
    end

    it 'generates markers with correct name format: primary_state | distillation' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, classification_data.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        marker_names = doc.xpath('//sequence/marker/name').map(&:text)
        expect(marker_names).to include('vindication | system rigged but you win')
        expect(marker_names).to include('competence | three-step framework reveal')
      end
    end

    it 'generates comments with all pipe-separated payload fields' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, classification_data.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        comments = doc.xpath('//sequence/marker/comment').map(&:text)
        emotion_comment = comments.find { |c| c.include?('vindication(identity)') }
        expect(emotion_comment).not_to be_nil
        expect(emotion_comment).to include('states: vindication(identity), curiosity(identity)')
        expect(emotion_comment).to include('role: primary')
        expect(emotion_comment).to include('signal: named target, specific claim')
        expect(emotion_comment).to include('confidence: high')
        expect(emotion_comment).to include('t=1.5')
      end
    end

    it 'produces no crash and no emotion markers when classification is absent' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['markers'] = [
          { 'name' => 'NOTE', 'comment' => 'Existing marker', 'time' => 0.0, 'color' => 'yellow' }
        ]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).not_to include('emotion markers')

        doc = Nokogiri::XML(File.read(stdout.strip))
        comments = doc.xpath('//sequence/marker/comment').map(&:text)
        expect(comments).to include('Existing marker')
      end
    end

    it 'skips emotion markers when --no-emotion-markers flag is set' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, classification_data.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, '--no-emotion-markers', yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).not_to include('Added')
        expect(stderr).not_to include('emotion markers')

        doc = Nokogiri::XML(File.read(stdout.strip))
        marker_names = doc.xpath('//sequence/marker/name').map(&:text)
        emotion_markers = marker_names.select { |n| n.include?('|') }
        expect(emotion_markers).to be_empty
      end
    end

  end

  describe 'snap-to-boundary tolerance' do
    it 'snaps clip boundaries within 100ms of speech segments' do
      Dir.mktmpdir do |dir|
        speech_data = {
          'speech_segments' => [
            { 'start' => 1.05, 'end' => 2.95 }
          ],
          'long_pauses' => []
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        config['clips'] = [{ 'video_start' => 1.0, 'video_end' => 3.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('snapped')
      end
    end

    it 'does not snap when boundary is beyond 100ms tolerance' do
      Dir.mktmpdir do |dir|
        speech_data = {
          'speech_segments' => [
            { 'start' => 1.2, 'end' => 2.7 }
          ],
          'long_pauses' => []
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        config['clips'] = [{ 'video_start' => 1.0, 'video_end' => 3.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        _stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).not_to include('snapped')
      end
    end
  end

  describe 'auto-split long segments' do
    it 'splits a segment exceeding max_segment_duration at a sentence boundary' do
      Dir.mktmpdir do |dir|
        speech_data = {
          'speech_segments' => [
            { 'start' => 0.5, 'end' => 3.8 }
          ],
          'long_pauses' => [
            { 'start' => 2.0, 'end' => 2.4, 'duration' => 0.4 }
          ]
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        config['max_segment_duration'] = 2
        config['auto_remove_pauses_above'] = false
        config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 3.8 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('auto-split')

        doc = Nokogiri::XML(File.read(stdout.strip))
        clipitems = doc.xpath('//sequence/media/video/track/clipitem')
        expect(clipitems.size).to eq(2)
      end
    end

    it 'does not split when no pauses >300ms exist' do
      Dir.mktmpdir do |dir|
        speech_data = {
          'speech_segments' => [
            { 'start' => 0.5, 'end' => 3.8 }
          ],
          'long_pauses' => [
            { 'start' => 2.0, 'end' => 2.2, 'duration' => 0.2 }
          ]
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        config['max_segment_duration'] = 2
        config['auto_remove_pauses_above'] = false
        config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 3.8 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).not_to include('Auto-split:')

        doc = Nokogiri::XML(File.read(stdout.strip))
        clipitems = doc.xpath('//sequence/media/video/track/clipitem')
        expect(clipitems.size).to eq(1)
      end
    end

    it 'disables auto-split when max_segment_duration is 0' do
      Dir.mktmpdir do |dir|
        speech_data = {
          'speech_segments' => [
            { 'start' => 0.5, 'end' => 3.8 }
          ],
          'long_pauses' => [
            { 'start' => 2.0, 'end' => 2.4, 'duration' => 0.4 }
          ]
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        config['max_segment_duration'] = 0
        config['auto_remove_pauses_above'] = false
        config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 3.8 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        clipitems = doc.xpath('//sequence/media/video/track/clipitem')
        expect(clipitems.size).to eq(1)
      end
    end
  end

  describe 'emotion markers (continued)' do
    it 'preserves NOTE markers alongside emotion markers' do
      Dir.mktmpdir do |dir|
        class_data = {
          'segments' => [
            { 't' => 1.5, 'e' => 3.0, 'states' => %w[vindication curiosity],
              'distillation' => 'system rigged but you win', 'signal' => 'named target',
              'dur' => 'identity', 'narrative_role' => 'primary', 'confidence' => 'high' }
          ]
        }
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, class_data.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        config['markers'] = [
          { 'name' => 'NOTE', 'comment' => 'Check audio levels', 'time' => 0.0, 'color' => 'yellow' },
          { 'name' => 'TITLE', 'comment' => 'Insert title card', 'time' => 0.0, 'color' => 'blue' }
        ]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        comments = doc.xpath('//sequence/marker/comment').map(&:text)
        # User-defined markers preserved
        expect(comments).to include('Check audio levels')
        expect(comments).to include('Insert title card')
        # Emotion markers also present
        emotion_comments = comments.select { |c| c.include?('states:') }
        expect(emotion_comments.size).to be >= 1
      end
    end
  end
end
