require 'yaml'
require 'json'
require 'tmpdir'
require 'open3'
require 'date'
require 'fileutils'

DETECT_CONTENT_TYPE_SCRIPT = File.expand_path('../../scripts/detect_content_type.rb', __dir__)

RSpec.describe 'detect_content_type.rb' do
  # --- Helpers ---

  def make_library(dir, overrides = {})
    transcripts_dir = File.join(dir, 'transcripts')
    FileUtils.mkdir_p(transcripts_dir)

    library = {
      'library_name' => 'test-lib',
      'language' => 'english',
      'editor' => 'premiere',
      'videos' => [{
        'path' => '/tmp/test_video.mp4',
        'duration' => '10:00'
      }]
    }.merge(overrides)

    yaml_path = File.join(dir, 'library.yaml')
    File.write(yaml_path, YAML.dump(library))
    [yaml_path, transcripts_dir, library]
  end

  def make_transcript(dir, segments, name: 'test_treated_cleaned.json')
    path = File.join(dir, name)
    File.write(path, JSON.generate({ 'segments' => segments }))
    name
  end

  def make_visual_transcript(dir, segments, name: 'visual_test_treated.json')
    path = File.join(dir, name)
    File.write(path, JSON.generate({ 'language' => 'en', 'segments' => segments }))
    name
  end

  def make_scene_changes(dir, timestamps)
    path = File.join(dir, 'scene_changes.yaml')
    data = {
      'source' => 'test_video.mp4',
      'total_scenes' => timestamps.size,
      'sampled_scenes' => timestamps.size,
      'timestamps' => timestamps
    }
    File.write(path, YAML.dump(data))
    path
  end

  def run_detect_ct(library_yaml, profile: nil)
    args = [library_yaml]
    args.unshift('--profile', profile) if profile
    stdout, stderr, status = Open3.capture3('ruby', DETECT_CONTENT_TYPE_SCRIPT, *args)
    [stdout.strip, stderr, status]
  end

  def talking_head_transcript_segments(start: 0.0, duration: 600.0, wpm: 155)
    # Generate business talking head content
    words_total = (wpm * duration / 60.0).to_i
    text = "So a guy in my community hit 10,000 a month in recurring revenue his first month in business. " \
           "And you know what he had? He had no experience, no marketing budget, no connections. " \
           "The strategy is simple. You find a niche, you create an offer, and you do outreach. " \
           "Most entrepreneurs overthink this. They spend months on branding and website design. " \
           "But the fastest path to your first client is direct outreach to businesses that need help. " \
           "I made my first $2,550 from a Hotmail account. No fancy tools, no CRM, just hustle. " \
           "The key is to focus on revenue-generating activities from day one. " \
           "Stop procrastinating on things that feel productive but don't actually grow your business."

    seg_count = 20
    seg_duration = duration / seg_count
    (0...seg_count).map { |i|
      {
        'start' => start + i * seg_duration,
        'end' => start + (i + 1) * seg_duration,
        'text' => text
      }
    }
  end

  def interview_transcript_segments
    texts = [
      "So tell me about your background? How did you get started in this field?",
      "Well I've been doing this for about 15 years now.",
      "What do you think makes your approach unique? Why is it different?",
      "I think it's the combination of traditional methods with new technology.",
      "Can you explain that a bit more for our audience? How does it work?",
      "Sure so what we do is we take the old school approach and we layer in AI.",
      "How do you see the industry changing in the next five years? What trends?",
      "Great question I think we'll see a massive shift toward automation.",
      "What advice would you give someone just starting out? Where should they begin?",
      "Don't try to do everything at once. Focus on one thing and master it.",
      "That's really helpful. You said earlier that you started with nothing?",
      "Right I had zero clients and zero reputation. It was all cold outreach.",
      "What was the turning point for you? When did things start clicking?",
      "I asked myself that same question. The answer was persistence.",
      "How do you handle failure? What keeps you going?",
      "I just try to learn from every mistake and keep moving forward.",
    ]
    texts.each_with_index.map { |text, i|
      { 'start' => i * 30.0, 'end' => (i + 1) * 30.0, 'text' => text }
    }
  end

  def tutorial_transcript_segments
    texts = [
      "Welcome to this tutorial. Today we're going to learn how to build a website from scratch.",
      "Step one: open your code editor. I'm using VS Code, but you can use any editor you like.",
      "Now we need to create a new file. Click here on the new file button.",
      "Step two: type in the HTML boilerplate. Let me show you what that looks like.",
      "Make sure you save the file with a .html extension. Go ahead and do that now.",
      "Next you need to open the terminal. Go to View, then Terminal.",
      "Step three: we'll install our dependencies. Type npm install in the terminal.",
      "Now let's add some CSS. First you need to create a styles.css file.",
      "Drag the file into your project folder. Select the link tag and paste it in.",
      "Step four: let's add JavaScript. Open up the script.js file.",
      "Here's how you make it responsive. Watch this — I'll resize the browser window.",
      "Step five: deploy to production. Click here to push your code to GitHub.",
    ]
    texts.each_with_index.map { |text, i|
      { 'start' => i * 30.0, 'end' => (i + 1) * 30.0, 'text' => text }
    }
  end

  def podcast_transcript_segments
    texts = [
      "Welcome back to the show everyone. Today we have two special guests.",
      "Thanks for having us. It's great to be here. We've been looking forward to this.",
      "So let's dive right in. What do you guys think about the current state of the market?",
      "I think it's fascinating honestly. The interviewer asked me this last week too.",
      "Yeah the panelist from the conference said the same thing. The host agreed.",
      "He said quote the market is overvalued and we need to be careful end quote.",
      "I asked him about that and he said well you need to look at fundamentals.",
      "The guest on the previous episode had a completely different take.",
      "That's what makes these conversations so interesting. Everyone has a different angle.",
      "Tell me about your new book. What do you think readers will take away?",
      "Well, she said she loved it. He said it changed his perspective entirely.",
      "You asked a great question earlier about the future of podcasting.",
    ]
    texts.each_with_index.map { |text, i|
      { 'start' => i * 120.0, 'end' => (i + 1) * 120.0, 'text' => text }
    }
  end

  # --- Tests ---

  describe 'CLI validation' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', DETECT_CONTENT_TYPE_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 when library.yaml not found' do
      _, stderr, status = Open3.capture3('ruby', DETECT_CONTENT_TYPE_SCRIPT, '/nonexistent/library.yaml')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end
  end

  describe 'talking_head_business detection' do
    it 'detects single speaker business content' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)

        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        stdout, stderr, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('talking_head_business')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['detected']).to eq('talking_head_business')
        expect(result['content_type']['confidence']).to be > 0.0
        expect(result['content_type']['signals']['speaker_count']).to eq(1)
        expect(result['content_type']['signals']['topic_signal']).to eq('business')
      end
    end

    it 'boosts confidence with visual_transcript confirming static single shot' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)

        visual_segs = 10.times.map { |i|
          {
            'start' => i * 60.0, 'end' => (i + 1) * 60.0,
            'text' => 'Business content here.',
            'visual' => 'Dylan seated at desk, medium shot, direct to camera. Living room background.'
          }
        }
        visual_name = make_visual_transcript(transcripts_dir, visual_segs)

        library['videos'][0]['cleaned_transcript'] = transcript_name
        library['videos'][0]['visual_transcript'] = visual_name
        File.write(yaml_path, YAML.dump(library))

        stdout, _, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('talking_head_business')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['visual_type']).to eq('static_single_shot')
        expect(result['content_type']['signals']['talking_head_ratio']).to be > 0.5
      end
    end
  end

  describe 'talking_head_personal detection' do
    it 'detects personal lifestyle content' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)

        personal_text = "Today I want to talk about my morning routine and self care habits. " \
                        "I've been on this fitness journey for six months now. " \
                        "My relationship with food has completely changed. " \
                        "I started meditation and it transformed my wellness. " \
                        "Travel has always been a huge part of my lifestyle. " \
                        "I went on vacation with my family and friends last month."
        segments = 10.times.map { |i|
          { 'start' => i * 60.0, 'end' => (i + 1) * 60.0, 'text' => personal_text }
        }
        transcript_name = make_transcript(transcripts_dir, segments)

        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        stdout, _, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('talking_head_personal')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['topic_signal']).to eq('personal')
      end
    end
  end

  describe 'tutorial_screencast detection' do
    it 'detects screencast with instructional language and screen visuals' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, tutorial_transcript_segments)

        visual_segs = 10.times.map { |i|
          {
            'start' => i * 30.0, 'end' => (i + 1) * 30.0,
            'text' => 'Tutorial content',
            'visual' => 'Screen recording of code editor with cursor hovering over toolbar menu. Browser window visible.'
          }
        }
        visual_name = make_visual_transcript(transcripts_dir, visual_segs)

        library['videos'][0]['cleaned_transcript'] = transcript_name
        library['videos'][0]['visual_transcript'] = visual_name
        File.write(yaml_path, YAML.dump(library))

        stdout, _, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('tutorial_screencast')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['instructional_language']).to eq('high')
        expect(result['content_type']['signals']['visual_type']).to eq('screencast')
      end
    end
  end

  describe 'tutorial_demonstration detection' do
    it 'detects tutorial without screencast visuals' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, tutorial_transcript_segments)

        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        stdout, _, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        # Without screencast visuals, should detect tutorial_demonstration
        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        detected = result['content_type']['detected']
        expect(%w[tutorial_demonstration tutorial_screencast]).to include(detected)
        expect(result['content_type']['signals']['instructional_language']).to eq('high')
      end
    end
  end

  describe 'interview detection' do
    it 'detects interview with Q&A pattern' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, interview_transcript_segments)

        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        stdout, _, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('interview')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['question_density']).to eq('high')
        expect(result['content_type']['signals']['speaker_count']).to be_truthy
      end
    end
  end

  describe 'podcast detection' do
    it 'detects podcast with multiple speakers and long duration' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        library['videos'][0]['duration'] = '45:00'  # > 40 min

        transcript_name = make_transcript(transcripts_dir, podcast_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        stdout, _, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('podcast')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(%w[multiple likely_multiple]).to include(result['content_type']['signals']['speaker_count'].to_s)
      end
    end
  end

  describe 'vlog detection' do
    it 'detects vlog with multiple locations and frequent scene changes' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)

        text = "Today I'm taking you around the city. Let's explore this new cafe I found."
        segments = 10.times.map { |i|
          { 'start' => i * 60.0, 'end' => (i + 1) * 60.0, 'text' => text }
        }
        transcript_name = make_transcript(transcripts_dir, segments)

        visual_segs = [
          { 'start' => 0, 'end' => 60, 'text' => 'Vlog', 'visual' => 'Wide shot outdoor street scene, handheld camera following speaker' },
          { 'start' => 60, 'end' => 120, 'text' => 'Vlog', 'visual' => 'Indoor cafe scene, close-up of coffee being made' },
          { 'start' => 120, 'end' => 180, 'text' => 'Vlog', 'visual' => 'Outdoor park setting, wide shot of trees' },
          { 'start' => 180, 'end' => 240, 'text' => 'Vlog', 'visual' => 'Indoor gym with workout equipment visible, tracking shot' },
          { 'start' => 240, 'end' => 300, 'text' => 'Vlog', 'visual' => 'Car interior, POV driving shot through city streets' },
          { 'start' => 300, 'end' => 360, 'text' => 'Vlog', 'visual' => 'Rooftop at sunset, aerial wide shot of skyline' },
        ]
        visual_name = make_visual_transcript(transcripts_dir, visual_segs)

        # Many scene changes
        make_scene_changes(dir, (0...40).map { |i| i * 15.0 })

        library['videos'][0]['cleaned_transcript'] = transcript_name
        library['videos'][0]['visual_transcript'] = visual_name
        File.write(yaml_path, YAML.dump(library))

        stdout, _, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('vlog')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['visual_type']).to eq('multi_location')
        expect(result['content_type']['signals']['cuts_per_minute']).to be > 3
      end
    end
  end

  describe 'commentary detection' do
    it 'detects commentary with fast speech and single speaker' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        library['videos'][0]['duration'] = '1:30'  # Short

        # Very fast speech — dense text packed into short segments to push WPM > 180
        # Also avoid business keywords to prevent talking_head_business from winning
        fast_text = "This is absolutely insane look at what they just did this is " \
                    "the worst take I have ever seen and honestly I cannot believe anyone " \
                    "would think this is a good idea let me break down exactly why " \
                    "this is wrong and why everyone is losing their minds over this " \
                    "so basically what happened is they completely botched the whole thing " \
                    "and now everyone is scrambling to figure out what went wrong and " \
                    "it is actually hilarious because they were so confident about it " \
                    "and it just blew up in their face like nobody could have predicted " \
                    "this level of incompetence it truly is something else entirely " \
                    "and the reactions from the community have been absolutely priceless " \
                    "people are roasting them left and right calling them out on every " \
                    "single mistake they made throughout this entire debacle "
        segments = 3.times.map { |i|
          { 'start' => i * 30.0, 'end' => (i + 1) * 30.0, 'text' => fast_text }
        }
        transcript_name = make_transcript(transcripts_dir, segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        stdout, _, status = run_detect_ct(yaml_path)
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('commentary')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['wpm']).to be > 180
      end
    end
  end

  describe 'confidence scoring' do
    it 'produces higher confidence with more signals' do
      Dir.mktmpdir do |dir|
        # Minimal signals — transcript only
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        run_detect_ct(yaml_path)
        result_minimal = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        confidence_minimal = result_minimal['content_type']['confidence']

        # Reset
        library.delete('content_type')
        library.delete('last_updated')

        # Rich signals — add visual transcript + scene changes
        visual_segs = 10.times.map { |i|
          { 'start' => i * 60.0, 'end' => (i + 1) * 60.0, 'text' => 'Content',
            'visual' => 'Speaker at desk, medium shot, direct to camera. Static office setup.' }
        }
        visual_name = make_visual_transcript(transcripts_dir, visual_segs)
        library['videos'][0]['visual_transcript'] = visual_name

        make_scene_changes(dir, [0.0, 120.0, 350.0])

        File.write(yaml_path, YAML.dump(library))
        run_detect_ct(yaml_path)
        result_rich = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        confidence_rich = result_rich['content_type']['confidence']

        expect(confidence_rich).to be >= confidence_minimal
      end
    end

    it 'confidence is between 0 and 1' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        run_detect_ct(yaml_path)
        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        conf = result['content_type']['confidence']
        expect(conf).to be >= 0.0
        expect(conf).to be <= 1.0
      end
    end
  end

  describe 'signal extraction' do
    it 'extracts WPM from transcript' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        run_detect_ct(yaml_path)
        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['wpm']).to be_a(Integer)
        expect(result['content_type']['signals']['wpm']).to be > 0
      end
    end

    it 'extracts duration_seconds from library' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir, { 'videos' => [{ 'path' => '/tmp/test.mp4', 'duration' => '15:30' }] })
        transcript_name = make_transcript(transcripts_dir, [{ 'start' => 0, 'end' => 930, 'text' => 'test' }])
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        run_detect_ct(yaml_path)
        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['duration_seconds']).to eq(930)
      end
    end

    it 'extracts scene_changes count' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, [{ 'start' => 0, 'end' => 600, 'text' => 'test content about business' }])
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        make_scene_changes(dir, [0.0, 30.0, 60.0, 120.0, 250.0])

        run_detect_ct(yaml_path)
        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']['scene_changes']).to eq(5)
      end
    end
  end

  describe 'profile override' do
    it 'uses profile content_type when not auto' do
      Dir.mktmpdir do |dir|
        yaml_path, _, _ = make_library(dir)

        stdout, stderr, status = run_detect_ct(yaml_path, profile: 'dylan')
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('talking_head_business')
        expect(stderr).to include('set by profile')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['detected']).to eq('talking_head_business')
        expect(result['content_type']['confidence']).to eq(1.0)
        expect(result['content_type']['source']).to eq('profile')
      end
    end

    it 'runs detection when profile says auto' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        stdout, stderr, status = run_detect_ct(yaml_path, profile: '_default')
        expect(status.exitstatus).to eq(0)
        expect(stderr).to include('Content type detected')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['source']).to eq('detection')
      end
    end

    it 'ivan profile overrides to talking_head_business' do
      Dir.mktmpdir do |dir|
        yaml_path, _, _ = make_library(dir)

        stdout, _, status = run_detect_ct(yaml_path, profile: 'ivan')
        expect(status.exitstatus).to eq(0)
        expect(stdout).to eq('talking_head_business')

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['source']).to eq('profile')
      end
    end
  end

  describe 'unknown fallback' do
    it 'returns unknown with low confidence when no transcript available' do
      Dir.mktmpdir do |dir|
        yaml_path, _, _ = make_library(dir)

        stdout, _, status = run_detect_ct(yaml_path, profile: '_default')
        expect(status.exitstatus).to eq(0)

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        detected = result['content_type']['detected']
        # With no signals, should get unknown or very low confidence
        if detected == 'unknown'
          expect(result['content_type']['confidence']).to be < 0.3
        else
          # If it guesses something, confidence should be low
          expect(result['content_type']['confidence']).to be < 0.5
        end
      end
    end

    it 'does not crash with empty transcript' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, [])
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        _, _, status = run_detect_ct(yaml_path, profile: '_default')
        expect(status.exitstatus).to eq(0)
      end
    end

    it 'handles missing visual_transcript gracefully' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        library['videos'][0]['visual_transcript'] = 'nonexistent.json'
        File.write(yaml_path, YAML.dump(library))

        _, _, status = run_detect_ct(yaml_path, profile: '_default')
        expect(status.exitstatus).to eq(0)
      end
    end

    it 'handles missing scene_changes gracefully' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        # No scene_changes.yaml — should still work
        _, _, status = run_detect_ct(yaml_path, profile: '_default')
        expect(status.exitstatus).to eq(0)

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['content_type']['signals']).not_to have_key('scene_changes')
      end
    end
  end

  describe 'library.yaml integration' do
    it 'writes content_type block to library.yaml' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        run_detect_ct(yaml_path)

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        ct = result['content_type']
        expect(ct).to be_a(Hash)
        expect(ct).to have_key('detected')
        expect(ct).to have_key('confidence')
        expect(ct).to have_key('source')
        expect(ct).to have_key('signals')
        expect(ct['signals']).to be_a(Hash)
      end
    end

    it 'updates last_updated in library.yaml' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir)
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        run_detect_ct(yaml_path)

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['last_updated']).to eq(Date.today.to_s)
      end
    end

    it 'preserves existing library.yaml fields' do
      Dir.mktmpdir do |dir|
        yaml_path, transcripts_dir, library = make_library(dir, {
          'user_context' => 'Important context here',
          'footage_summary' => 'Summary of footage'
        })
        transcript_name = make_transcript(transcripts_dir, talking_head_transcript_segments)
        library['videos'][0]['cleaned_transcript'] = transcript_name
        File.write(yaml_path, YAML.dump(library))

        run_detect_ct(yaml_path)

        result = YAML.safe_load(File.read(yaml_path), permitted_classes: [Date])
        expect(result['user_context']).to eq('Important context here')
        expect(result['footage_summary']).to eq('Summary of footage')
        expect(result['library_name']).to eq('test-lib')
      end
    end
  end

  describe 'load_profile helpers' do
    before(:all) do
      require_relative '../../scripts/load_profile'
    end

    describe 'effective_content_type' do
      it 'returns profile content_type when not auto' do
        profile = { 'content_type' => 'talking_head_business' }
        expect(effective_content_type(profile)).to eq('talking_head_business')
      end

      it 'returns detected type when profile is auto' do
        profile = { 'content_type' => 'auto' }
        library = { 'content_type' => { 'detected' => 'interview' } }
        expect(effective_content_type(profile, library)).to eq('interview')
      end

      it 'returns auto when no detection available' do
        profile = { 'content_type' => 'auto' }
        expect(effective_content_type(profile)).to eq('auto')
      end
    end

    describe 'template_categories_for' do
      it 'uses profile template_categories when set' do
        profile = { 'content_type' => 'auto', 'template_categories' => %w[narrative] }
        expect(template_categories_for(profile)).to eq(%w[narrative])
      end

      it 'maps talking_head_business to argumentative + explainer' do
        profile = { 'content_type' => 'talking_head_business', 'template_categories' => [] }
        expect(template_categories_for(profile)).to eq(%w[argumentative explainer])
      end

      it 'maps tutorial_screencast to explainer' do
        profile = { 'content_type' => 'tutorial_screencast', 'template_categories' => [] }
        expect(template_categories_for(profile)).to eq(%w[explainer])
      end

      it 'maps interview to narrative' do
        profile = { 'content_type' => 'interview', 'template_categories' => [] }
        expect(template_categories_for(profile)).to eq(%w[narrative])
      end

      it 'maps commentary to argumentative' do
        profile = { 'content_type' => 'commentary', 'template_categories' => [] }
        expect(template_categories_for(profile)).to eq(%w[argumentative])
      end

      it 'returns empty for unknown content type' do
        profile = { 'content_type' => 'unknown', 'template_categories' => [] }
        expect(template_categories_for(profile)).to eq([])
      end

      it 'uses detected content type when profile is auto' do
        profile = { 'content_type' => 'auto', 'template_categories' => [] }
        library = { 'content_type' => { 'detected' => 'vlog' } }
        expect(template_categories_for(profile, library)).to eq(%w[narrative])
      end
    end

    describe 'CONTENT_TYPE_TEMPLATE_MAP' do
      it 'has entries for all content types' do
        expected_types = %w[talking_head_business talking_head_personal tutorial_screencast
                           tutorial_demonstration interview podcast vlog commentary narrative unknown]
        expected_types.each do |ct|
          expect(CONTENT_TYPE_TEMPLATE_MAP).to have_key(ct), "Missing mapping for #{ct}"
        end
      end
    end
  end
end
