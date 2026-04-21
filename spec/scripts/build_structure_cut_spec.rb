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

    it 'generates Tier 3 markers with state(dur) | distillation format' do
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
        # Tier 3 markers use format: "state(dur) | distillation"
        expect(marker_names).to include('vindication(identity) | system rigged but you win')
        expect(marker_names).to include('competence(spike) | three-step framework reveal')
      end
    end

    it 'generates Tier 3 comments with all pipe-separated payload fields' do
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
        # Find Tier 3 reference marker comment (contains "states:")
        ref_comment = comments.find { |c| c.include?('states: vindication(identity)') }
        expect(ref_comment).not_to be_nil
        expect(ref_comment).to include('states: vindication(identity), curiosity(identity)')
        expect(ref_comment).to include('role: primary')
        expect(ref_comment).to include('signal: named target, specific claim')
        expect(ref_comment).to include('confidence: high')
        expect(ref_comment).to include('t=1.5')
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

    it 'skips Tier 3 markers when --no-emotion-markers flag is set but keeps Tier 1/2' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, classification_data.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, '--no-emotion-markers', yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        marker_names = doc.xpath('//sequence/marker/name').map(&:text)
        # Tier 3 (reference) markers should NOT be present
        tier3 = marker_names.select { |n| n.match?(/^\w+\(\w+\) \|/) }
        expect(tier3).to be_empty

        # Tier 1 (structure) markers SHOULD still be present
        tier1 = marker_names.select { |n| n.start_with?('HOOK:') || n.start_with?('CLOSE:') }
        expect(tier1).not_to be_empty
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
        # Tier 3 reference markers also present
        ref_comments = comments.select { |c| c.include?('states:') }
        expect(ref_comments.size).to be >= 1
      end
    end
  end

  describe 'three-tier marker system' do
    let(:multi_segment_classification) do
      {
        'segments' => [
          { 't' => 1.0, 'e' => 3.0, 'states' => %w[vindication curiosity],
            'distillation' => 'system rigged against you', 'signal' => 'bold claim',
            'dur' => 'identity', 'narrative_role' => 'primary', 'confidence' => 'high' },
          { 't' => 3.5, 'e' => 5.0, 'states' => %w[competence aspiration],
            'distillation' => 'three step framework', 'signal' => 'framework reveal',
            'dur' => 'mood', 'narrative_role' => 'secondary', 'confidence' => 'high' },
          { 't' => 5.5, 'e' => 7.0, 'states' => %w[fear outrage],
            'distillation' => 'year of failing hard', 'signal' => 'vulnerability',
            'dur' => 'identity', 'narrative_role' => 'primary', 'confidence' => 'medium' },
          { 't' => 7.5, 'e' => 9.0, 'states' => %w[aspiration competence],
            'distillation' => 'finally found the path', 'signal' => 'resolution',
            'dur' => 'identity', 'narrative_role' => 'primary', 'confidence' => 'high',
            'signpost' => true },
          { 't' => 9.5, 'e' => 11.0, 'states' => %w[aspiration],
            'distillation' => 'your turn to start', 'signal' => 'CTA',
            'dur' => 'identity', 'narrative_role' => 'primary', 'confidence' => 'high' }
        ]
      }
    end

    describe 'Tier 1 structure markers' do
      it 'generates HOOK marker for first segment' do
        Dir.mktmpdir do |dir|
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, multi_segment_classification.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 11.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          hook_markers = doc.xpath('//sequence/marker').select { |m| m.at_xpath('name').text.start_with?('HOOK:') }
          expect(hook_markers.size).to eq(1)
          expect(hook_markers.first.at_xpath('name').text).to include('system rigged')
          # Range marker: out should not be -1
          expect(hook_markers.first.at_xpath('out').text.to_i).not_to eq(-1)
        end
      end

      it 'generates CLOSE marker for last identity segment' do
        Dir.mktmpdir do |dir|
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, multi_segment_classification.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 11.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          close_markers = doc.xpath('//sequence/marker').select { |m| m.at_xpath('name').text.start_with?('CLOSE:') }
          expect(close_markers.size).to eq(1)
          expect(close_markers.first.at_xpath('out').text.to_i).not_to eq(-1)
        end
      end

      it 'includes pproColor tag on structure markers' do
        Dir.mktmpdir do |dir|
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, multi_segment_classification.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 11.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          hook = doc.xpath('//sequence/marker').find { |m| m.at_xpath('name').text.start_with?('HOOK:') }
          expect(hook).not_to be_nil
          ppro = hook.at_xpath('pproColor')
          expect(ppro).not_to be_nil
          expect(ppro.text.to_i).to eq(4279486782)
        end
      end
    end

    describe 'Tier 2 alert markers' do
      it 'generates TRANSITION markers for state changes' do
        Dir.mktmpdir do |dir|
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, multi_segment_classification.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 11.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          transitions = doc.xpath('//sequence/marker').select { |m|
            m.at_xpath('name').text.start_with?('TRANSITION:')
          }
          expect(transitions.size).to be >= 1
          # Should detect vindication → competence at minimum
          transition_names = transitions.map { |m| m.at_xpath('name').text }
          expect(transition_names.any? { |n| n.include?('vindication') && n.include?('competence') }).to be true
          # Point markers (out = -1)
          transitions.each { |t| expect(t.at_xpath('out').text.to_i).to eq(-1) }
        end
      end

      it 'generates SIGNPOST markers for cut candidates' do
        Dir.mktmpdir do |dir|
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, multi_segment_classification.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 11.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          signposts = doc.xpath('//sequence/marker').select { |m|
            m.at_xpath('name').text.start_with?('SIGNPOST:')
          }
          expect(signposts.size).to eq(1)
          expect(signposts.first.at_xpath('comment').text).to include('meta-commentary')
        end
      end
    end

    describe 'Tier 3 reference markers' do
      it 'generates per-segment reference markers with grey pproColor' do
        Dir.mktmpdir do |dir|
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, multi_segment_classification.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 11.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          ref_markers = doc.xpath('//sequence/marker').select { |m|
            m.at_xpath('name').text.match?(/^\w+\(\w+\) \|/)
          }
          # Should have one per classification segment
          expect(ref_markers.size).to eq(5)

          # Check pproColor is grey (4286611584)
          ref_markers.each do |rm|
            ppro = rm.at_xpath('pproColor')
            expect(ppro).not_to be_nil
            expect(ppro.text.to_i).to eq(4286611584)
          end
        end
      end
    end

    describe 'marker ordering' do
      it 'places Tier 1 before Tier 2 before Tier 3 in XML' do
        Dir.mktmpdir do |dir|
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, multi_segment_classification.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 11.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          all_markers = doc.xpath('//sequence/marker')
          names = all_markers.map { |m| m.at_xpath('name').text }

          # Find indices
          tier1_idx = names.each_index.select { |i| names[i].match?(/^(HOOK|CLOSE|SECTION|PIVOT|REVEAL):/) }
          tier2_idx = names.each_index.select { |i| names[i].match?(/^(TRANSITION|SHIFT|SIGNPOST|SPLIT|REVIEW):/) }
          tier3_idx = names.each_index.select { |i| names[i].match?(/^\w+\(\w+\) \|/) }

          # Tier 1 should come before Tier 2, which should come before Tier 3
          if tier1_idx.any? && tier2_idx.any?
            expect(tier1_idx.max).to be < tier2_idx.min
          end
          if tier2_idx.any? && tier3_idx.any?
            expect(tier2_idx.max).to be < tier3_idx.min
          end
        end
      end
    end

    describe '--markers-only-structure flag' do
      it 'generates only Tier 1 markers' do
        Dir.mktmpdir do |dir|
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, multi_segment_classification.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 11.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, '--markers-only-structure', yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          all_markers = doc.xpath('//sequence/marker')
          names = all_markers.map { |m| m.at_xpath('name').text }

          # Only Tier 1 markers
          tier1 = names.select { |n| n.match?(/^(HOOK|CLOSE|SECTION|PIVOT|REVEAL):/) }
          tier2 = names.select { |n| n.match?(/^(TRANSITION|SHIFT|SIGNPOST|SPLIT|REVIEW):/) }
          tier3 = names.select { |n| n.match?(/^\w+\(\w+\) \|/) }

          expect(tier1).not_to be_empty
          expect(tier2).to be_empty
          expect(tier3).to be_empty
        end
      end
    end

    describe 'graceful degradation' do
      it 'generates no tiered markers when classification is absent' do
        Dir.mktmpdir do |dir|
          config = base_config(dir)
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          all_markers = doc.xpath('//sequence/marker')
          # No tiered markers, no crash
          tier1 = all_markers.select { |m| m.at_xpath('name').text.match?(/^(HOOK|CLOSE|SECTION|PIVOT|REVEAL):/) }
          expect(tier1).to be_empty
        end
      end

      it 'generates Tier 1 markers even with single segment' do
        Dir.mktmpdir do |dir|
          single_seg = {
            'segments' => [{
              't' => 1.5, 'e' => 3.0,
              'states' => %w[vindication],
              'distillation' => 'only segment',
              'dur' => 'identity',
              'confidence' => 'high'
            }]
          }
          class_path = File.join(dir, 'segments_classified.yaml')
          File.write(class_path, single_seg.to_yaml)

          config = base_config(dir)
          config['clips'] = [{ 'video_start' => 1.0, 'video_end' => 3.5 }]
          config['classification'] = class_path
          yaml_path = File.join(dir, 'test.yaml')
          File.write(yaml_path, config.to_yaml)

          stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
          expect(status.exitstatus).to eq(0)

          doc = Nokogiri::XML(File.read(stdout.strip))
          hooks = doc.xpath('//sequence/marker').select { |m| m.at_xpath('name').text.start_with?('HOOK:') }
          expect(hooks.size).to eq(1)
        end
      end
    end
  end

  describe 'checklist markers from edit patterns' do
    let(:checklist_classification) do
      {
        'segments' => [
          {
            't' => 1.5, 'e' => 3.0,
            'states' => %w[aspiration competence],
            'distillation' => 'seven months to quitting',
            'signal' => 'specific timeline', 'dur' => 'identity',
            'narrative_role' => 'claim', 'confidence' => 'high'
          },
          {
            't' => 5.5, 'e' => 7.0,
            'states' => %w[competence],
            'distillation' => 'framework explained',
            'signal' => 'teaching moment', 'dur' => 'mood',
            'narrative_role' => 'evidence', 'confidence' => 'high'
          }
        ]
      }
    end

    let(:edit_patterns) do
      {
        'patterns_from' => 1,
        'video_overlay_patterns' => [
          { 'trigger' => 'narrative_role = claim', 'frequency' => '4/7', 'typical_duration' => 3.2, 'note' => 'overlays on claim segments' },
          { 'trigger' => 'dur = identity', 'frequency' => '6/10', 'typical_duration' => 3.5, 'note' => 'overlays on identity segments' }
        ],
        'audio_overlay_patterns' => [],
        'pacing_observations' => {}
      }
    end

    it 'generates SUGGEST markers when edit_patterns.yaml exists' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, checklist_classification.to_yaml)
        patterns_path = File.join(dir, 'edit_patterns.yaml')
        File.write(patterns_path, edit_patterns.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        config['edit_patterns'] = patterns_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        suggest_markers = doc.xpath('//sequence/marker').select { |m| m.at_xpath('name').text.start_with?('SUGGEST:') }
        expect(suggest_markers.size).to be >= 1
      end
    end

    it 'matches narrative_role trigger to correct segments' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, checklist_classification.to_yaml)
        patterns_path = File.join(dir, 'edit_patterns.yaml')
        File.write(patterns_path, edit_patterns.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        config['edit_patterns'] = patterns_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, _, _ = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        doc = Nokogiri::XML(File.read(stdout.strip))

        suggest_comments = doc.xpath('//sequence/marker').select { |m|
          m.at_xpath('name').text.start_with?('SUGGEST:')
        }.map { |m| m.at_xpath('comment').text }

        # First segment (claim) should match narrative_role = claim
        claim_matches = suggest_comments.select { |c| c.include?('narrative_role = claim') }
        expect(claim_matches.size).to be >= 1
        expect(claim_matches.first).to include('4/7')
      end
    end

    it 'matches dur trigger to correct segments' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, checklist_classification.to_yaml)
        patterns_path = File.join(dir, 'edit_patterns.yaml')
        File.write(patterns_path, edit_patterns.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        config['edit_patterns'] = patterns_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, _, _ = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        doc = Nokogiri::XML(File.read(stdout.strip))

        suggest_comments = doc.xpath('//sequence/marker').select { |m|
          m.at_xpath('name').text.start_with?('SUGGEST:')
        }.map { |m| m.at_xpath('comment').text }

        # First segment (identity) should match dur = identity
        identity_matches = suggest_comments.select { |c| c.include?('dur = identity') }
        expect(identity_matches.size).to be >= 1
        expect(identity_matches.first).to include('6/10')
      end
    end

    it 'sets correct pproColor on SUGGEST markers' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, checklist_classification.to_yaml)
        patterns_path = File.join(dir, 'edit_patterns.yaml')
        File.write(patterns_path, edit_patterns.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        config['edit_patterns'] = patterns_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, _, _ = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        doc = Nokogiri::XML(File.read(stdout.strip))

        suggest = doc.xpath('//sequence/marker').find { |m| m.at_xpath('name').text.start_with?('SUGGEST:') }
        expect(suggest).not_to be_nil
        ppro = suggest.at_xpath('pproColor')&.text&.to_i
        expect(ppro).to eq(4292131840)  # PPRO_SUGGEST (Cyan)
      end
    end

    it 'generates no SUGGEST markers without edit_patterns' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, checklist_classification.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, _, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        suggest_markers = doc.xpath('//sequence/marker').select { |m| m.at_xpath('name').text.start_with?('SUGGEST:') }
        expect(suggest_markers.size).to eq(0)
      end
    end

    it 'suppresses SUGGEST markers with --markers-only-structure' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, checklist_classification.to_yaml)
        patterns_path = File.join(dir, 'edit_patterns.yaml')
        File.write(patterns_path, edit_patterns.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        config['edit_patterns'] = patterns_path
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, _, _ = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path, '--markers-only-structure')
        doc = Nokogiri::XML(File.read(stdout.strip))

        suggest_markers = doc.xpath('//sequence/marker').select { |m| m.at_xpath('name').text.start_with?('SUGGEST:') }
        expect(suggest_markers.size).to eq(0)
      end
    end

    it 'auto-detects edit_patterns.yaml from classification directory' do
      Dir.mktmpdir do |dir|
        class_path = File.join(dir, 'segments_classified.yaml')
        File.write(class_path, checklist_classification.to_yaml)
        # Write patterns in same dir as classification (auto-detect)
        patterns_path = File.join(dir, 'edit_patterns.yaml')
        File.write(patterns_path, edit_patterns.to_yaml)

        config = base_config(dir)
        config['classification'] = class_path
        # NOT setting config['edit_patterns'] — should auto-detect
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)

        stdout, stderr, _ = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        doc = Nokogiri::XML(File.read(stdout.strip))

        suggest_markers = doc.xpath('//sequence/marker').select { |m| m.at_xpath('name').text.start_with?('SUGGEST:') }
        expect(suggest_markers.size).to be >= 1
        expect(stderr).to include('Auto-loaded edit patterns')
      end
    end
  end

  describe 'multi-track support' do
    it 'places V2 clips on a separate video track' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['clips'] = [
          { 'video_start' => 1.0, 'video_end' => 3.0, 'track' => 'V1' },
          { 'video_start' => 5.0, 'video_end' => 8.0, 'track' => 'V1' },
          { 'video_start' => 2.0, 'video_end' => 4.0, 'track' => 'V2', 'timeline_offset' => 0.0 }
        ]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        video_tracks = doc.xpath('//sequence/media/video/track')
        expect(video_tracks.size).to eq(2)

        # V1 track has 2 clips, V2 track has 1 clip
        expect(video_tracks[0].xpath('clipitem').size).to eq(2)
        expect(video_tracks[1].xpath('clipitem').size).to eq(1)
      end
    end

    it 'defaults to V1 when track field is absent' do
      Dir.mktmpdir do |dir|
        config = base_config(dir)
        config['clips'] = [
          { 'video_start' => 1.0, 'video_end' => 3.0 },
          { 'video_start' => 5.0, 'video_end' => 8.0 }
        ]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        video_tracks = doc.xpath('//sequence/media/video/track')
        expect(video_tracks.size).to eq(1)
        expect(video_tracks[0].xpath('clipitem').size).to eq(2)
      end
    end
  end

  describe 'natural segmentation' do
    it 'does not auto-split long clips when max_segment_duration is not set' do
      Dir.mktmpdir do |dir|
        speech_data = {
          'speech_segments' => [
            { 'start' => 0.5, 'end' => 20.0 }
          ],
          'long_pauses' => [
            { 'start' => 8.0, 'end' => 8.5, 'duration' => 0.5 }
          ]
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        config['auto_remove_pauses_above'] = false
        config['clips'] = [{ 'video_start' => 0.5, 'video_end' => 20.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).not_to include('auto-split')
        expect(stderr).not_to include('Auto-split')

        doc = Nokogiri::XML(File.read(stdout.strip))
        clipitems = doc.xpath('//sequence/media/video/track/clipitem')
        expect(clipitems.size).to eq(1)
      end
    end

    it 'merges segments shorter than min_segment_duration with neighbors' do
      Dir.mktmpdir do |dir|
        # Create speech data with two pauses that would create a 1-second middle segment
        speech_data = {
          'speech_segments' => [
            { 'start' => 1.0, 'end' => 10.0 }
          ],
          'long_pauses' => [
            { 'start' => 4.0, 'end' => 4.9, 'duration' => 0.9 },
            { 'start' => 5.5, 'end' => 6.4, 'duration' => 0.9 }
          ]
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        config['auto_remove_pauses_above'] = 900
        config['min_segment_duration'] = 2
        config['clips'] = [{ 'video_start' => 1.0, 'video_end' => 10.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)

        doc = Nokogiri::XML(File.read(stdout.strip))
        clipitems = doc.xpath('//sequence/media/video/track/clipitem')
        # Middle segment (4.9-5.5 = 0.6s) should be merged, resulting in 2 clips not 3
        expect(clipitems.size).to eq(2)
      end
    end

    it 'disables pause removal by default (no --remove-pauses flag)' do
      Dir.mktmpdir do |dir|
        speech_data = {
          'speech_segments' => [
            { 'start' => 1.0, 'end' => 8.0 }
          ],
          'long_pauses' => [
            { 'start' => 4.0, 'end' => 5.0, 'duration' => 1.0 }
          ]
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        # No auto_remove_pauses_above, no --remove-pauses flag
        config['clips'] = [{ 'video_start' => 1.0, 'video_end' => 8.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('Pause removal: disabled')

        doc = Nokogiri::XML(File.read(stdout.strip))
        clipitems = doc.xpath('//sequence/media/video/track/clipitem')
        # 1000ms pause should NOT be removed — pause removal is off
        expect(clipitems.size).to eq(1)
      end
    end

    it 'enables pause removal with --remove-pauses flag' do
      Dir.mktmpdir do |dir|
        speech_data = {
          'speech_segments' => [
            { 'start' => 1.0, 'end' => 8.0 }
          ],
          'long_pauses' => [
            { 'start' => 4.0, 'end' => 5.0, 'duration' => 1.0 }
          ]
        }
        sa_path = File.join(dir, 'speech_analysis.json')
        File.write(sa_path, speech_data.to_json)

        config = base_config(dir)
        config['speech_analysis'] = sa_path
        config['clips'] = [{ 'video_start' => 1.0, 'video_end' => 8.0 }]
        yaml_path = File.join(dir, 'test.yaml')
        File.write(yaml_path, config.to_yaml)
        stdout, stderr, status = Open3.capture3('ruby', BUILD_SCRIPT, '--remove-pauses', yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('Pause removal: enabled')

        doc = Nokogiri::XML(File.read(stdout.strip))
        clipitems = doc.xpath('//sequence/media/video/track/clipitem')
        # 1000ms pause SHOULD be removed — flag is set, above 800ms threshold
        expect(clipitems.size).to eq(2)
      end
    end
  end
end
