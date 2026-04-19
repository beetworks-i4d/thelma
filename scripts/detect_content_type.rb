#!/usr/bin/env ruby
# Phase 0 — Content Type Detection
# Analyzes available signals (transcript, audio features, visual transcript, scene detection, metadata)
# to automatically detect content type and route downstream defaults.
#
# Usage: ruby scripts/detect_content_type.rb <library.yaml>
#        ruby scripts/detect_content_type.rb <library.yaml> --profile <name>
#
# Output: updates library.yaml with content_type block. Prints detected type to stdout.

require 'yaml'
require 'json'
require 'date'

CONTENT_TYPES = {
  'talking_head_business'   => 'Single speaker, direct to camera, business/educational topic',
  'talking_head_personal'   => 'Single speaker, direct to camera, personal/lifestyle topic',
  'tutorial_screencast'     => 'Screen recording with voiceover, instructional',
  'tutorial_demonstration'  => 'Speaker demonstrating something on camera',
  'interview'               => 'Two speakers, question-and-answer format',
  'podcast'                 => 'Multiple speakers, conversational, long-form',
  'vlog'                    => 'Single speaker, multiple locations/scenes, narrative',
  'commentary'              => 'Single speaker reacting to or analyzing other content',
  'narrative'               => 'Scripted storytelling with produced visuals',
  'unknown'                 => 'Could not determine content type'
}.freeze

# --- CLI parsing ---

profile_name = nil
positional = []
args = ARGV.dup
while args.any?
  case args.first
  when '--profile'
    args.shift
    profile_name = args.shift
  else
    positional << args.shift
  end
end

library_yaml_path = positional.first
abort "Usage: ruby scripts/detect_content_type.rb <library.yaml> [--profile <name>]" unless library_yaml_path
abort "Library not found: #{library_yaml_path}" unless File.exist?(library_yaml_path)

# --- Check profile override ---

require_relative 'load_profile'

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
library_name = library['library_name'] || File.basename(File.dirname(library_yaml_path))
profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)

profile_content_type = profile['content_type']
if profile_content_type && profile_content_type != 'auto'
  $stderr.puts "Content type set by profile: #{profile_content_type} (skipping detection)"
  # Write to library.yaml
  library['content_type'] = {
    'detected' => profile_content_type,
    'confidence' => 1.0,
    'source' => 'profile',
    'signals' => {}
  }
  File.write(library_yaml_path, YAML.dump(library))
  puts profile_content_type
  exit 0
end

# --- Gather signals ---

signals = {}
video = library['videos']&.first
abort "No videos in library.yaml" unless video

library_dir = File.dirname(library_yaml_path)
transcripts_dir = File.join(library_dir, 'transcripts')

# --- Signal: Transcript analysis ---

transcript_name = video['cleaned_transcript'] || video['transcript']
transcript_path = transcript_name ? File.join(transcripts_dir, transcript_name) : nil

transcript_text = ''
transcript_segments = []
total_duration = 0.0

if transcript_path && File.exist?(transcript_path)
  data = JSON.parse(File.read(transcript_path))
  transcript_segments = data['segments'] || []

  transcript_text = transcript_segments.map { |s| s['text'].to_s.strip }.join(' ')

  if transcript_segments.any?
    first_start = transcript_segments.first['start'].to_f
    last_end = transcript_segments.last['end'].to_f
    total_duration = last_end - first_start
  end
end

if transcript_text.length > 0 && total_duration > 0
  # Word count and WPM
  word_count = transcript_text.split(/\s+/).size
  wpm = (word_count / (total_duration / 60.0)).round
  signals['wpm'] = wpm

  # Speaker count estimate (heuristic: dialogue patterns)
  dialogue_markers = transcript_text.scan(/(?:you said|he said|she said|they said|I asked|you asked|"[^"]{5,}")/i).size
  vocabulary_clusters = transcript_text.scan(/\b(?:interviewer|host|guest|caller|panelist)\b/i).size
  question_to_others = transcript_text.scan(/\b(?:what do you think|how do you|tell me about|can you explain)\b/i).size

  speaker_clues = dialogue_markers + vocabulary_clusters + question_to_others
  if speaker_clues >= 5
    signals['speaker_count'] = 'multiple'
  elsif speaker_clues >= 2
    signals['speaker_count'] = 'likely_multiple'
  else
    signals['speaker_count'] = 1
  end

  # Question density
  sentences = transcript_text.split(/[.!?]+/).reject(&:empty?)
  questions = transcript_text.scan(/\?/).size
  question_ratio = sentences.any? ? (questions.to_f / sentences.size) : 0
  signals['question_density'] = if question_ratio > 0.3
    'high'
  elsif question_ratio > 0.15
    'medium'
  else
    'low'
  end

  # Instructional language frequency
  instructional_patterns = transcript_text.scan(
    /\b(?:step\s+(?:one|two|three|four|five|1|2|3|4|5)|click\s+(?:here|on|the)|now\s+we|you\s+need\s+to|first\s+you|next\s+you|go\s+(?:to|ahead)|open\s+(?:up|the)|make\s+sure|let\s+me\s+show|watch\s+(?:this|how)|here's\s+how|drag\s+(?:and|the)|select\s+the|type\s+in)\b/i
  ).size
  instructional_ratio = word_count > 0 ? (instructional_patterns.to_f / (word_count / 100.0)) : 0
  signals['instructional_language'] = if instructional_ratio > 2.0
    'high'
  elsif instructional_ratio > 0.5
    'medium'
  else
    'low'
  end
end

# --- Signal: Duration ---

duration_str = video['duration'].to_s
if duration_str.include?(':')
  parts = duration_str.split(':').map(&:to_f)
  video_duration_sec = parts.length == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts[0] * 60 + parts[1]
else
  video_duration_sec = duration_str.to_f
end
signals['duration_seconds'] = video_duration_sec.round

# --- Signal: Script presence ---

project_dir = File.dirname(video['path'].to_s)
has_script = false
if Dir.exist?(project_dir)
  script_files = Dir.glob(File.join(project_dir, '*.{txt,md,pdf,docx}'))
                    .reject { |f| f.include?('output/') || f.include?('_treated') || f.include?('_cleaned') }
  has_script = script_files.any?
end
signals['script_present'] = has_script

# --- Signal: Audio features ---

audio_features_name = video['audio_features']
if audio_features_name
  audio_features_path = File.join(transcripts_dir, audio_features_name)
  if File.exist?(audio_features_path)
    af_data = YAML.safe_load(File.read(audio_features_path), permitted_classes: [Date])
    if af_data && af_data['segments']
      energies = af_data['segments'].map { |s| s['energy'].to_f }.compact
      if energies.any?
        mean_energy = energies.sum / energies.size
        variance = energies.map { |e| (e - mean_energy) ** 2 }.sum / energies.size
        signals['energy_variance'] = variance.round(4)
        signals['energy_variance_level'] = variance > 0.1 ? 'high' : 'low'
      end

      pitch_trends = af_data['segments'].map { |s| s['pitch_trend'] }.compact
      if pitch_trends.any?
        unique_trends = pitch_trends.uniq
        signals['pitch_variation'] = unique_trends.size > 2 ? 'varied' : 'steady'
      end
    end

    # Global summary if available
    if af_data['summary']
      signals['audio_dominant_profile'] = af_data['summary']['dominant_profile'] if af_data['summary']['dominant_profile']
    end
  end
end

# --- Signal: Visual transcript ---

visual_name = video['visual_transcript']
if visual_name && visual_name.to_s.strip != ''
  visual_path = File.join(transcripts_dir, visual_name)
  if File.exist?(visual_path)
    visual_data = JSON.parse(File.read(visual_path))
    visual_segments = visual_data['segments'] || []

    if visual_segments.any?
      visuals = visual_segments.map { |s| s['visual'].to_s.downcase }.compact

      # Screen recording detection
      screen_keywords = %w[screen desktop browser cursor toolbar menu window code terminal editor spreadsheet]
      screen_hits = visuals.count { |v| screen_keywords.any? { |kw| v.include?(kw) } }
      screen_ratio = screen_hits.to_f / visuals.size
      signals['screen_recording_ratio'] = screen_ratio.round(3)

      # Talking head detection
      head_keywords = ['to camera', 'direct to camera', 'talking head', 'medium shot', 'seated', 'close-up', 'headshot']
      head_hits = visuals.count { |v| head_keywords.any? { |kw| v.include?(kw) } }
      head_ratio = head_hits.to_f / visuals.size
      signals['talking_head_ratio'] = head_ratio.round(3)

      # Multiple locations/angles
      location_markers = visuals.map { |v|
        v.scan(/(?:indoor|outdoor|studio|office|street|kitchen|bedroom|living room|park|cafe|gym|car|rooftop)/i)
      }.flatten
      unique_locations = location_markers.uniq.size
      signals['unique_locations'] = unique_locations

      # Camera angle variety
      angle_markers = visuals.map { |v|
        v.scan(/(?:wide shot|medium shot|close-up|overhead|aerial|pov|tracking|handheld|tripod|static)/i)
      }.flatten
      unique_angles = angle_markers.uniq.size
      signals['unique_camera_angles'] = unique_angles

      # Determine visual type
      if screen_ratio > 0.5
        signals['visual_type'] = 'screencast'
      elsif head_ratio > 0.5 && unique_locations <= 1
        signals['visual_type'] = 'static_single_shot'
      elsif unique_locations >= 3 || unique_angles >= 3
        signals['visual_type'] = 'multi_location'
      else
        signals['visual_type'] = 'mixed'
      end
    end
  end
end

# --- Signal: Scene detection ---

scene_changes_path = File.join(library_dir, 'scene_changes.yaml')
if File.exist?(scene_changes_path)
  scene_data = YAML.safe_load(File.read(scene_changes_path), permitted_classes: [Date])
  total_scenes = scene_data['total_scenes'] || 0
  signals['scene_changes'] = total_scenes

  if video_duration_sec > 0
    cuts_per_minute = (total_scenes.to_f / (video_duration_sec / 60.0)).round(2)
    signals['cuts_per_minute'] = cuts_per_minute
  end
end

# --- Scoring ---

scores = Hash.new(0.0)

# Speaker count scoring
case signals['speaker_count']
when 1
  scores['talking_head_business'] += 2
  scores['talking_head_personal'] += 2
  scores['tutorial_screencast'] += 2
  scores['tutorial_demonstration'] += 2
  scores['commentary'] += 2
  scores['vlog'] += 1.5
when 'likely_multiple'
  scores['interview'] += 1
  scores['podcast'] += 1
when 'multiple'
  scores['interview'] += 3
  scores['podcast'] += 3
end

# WPM scoring
wpm = signals['wpm'] || 0
if wpm > 0
  if wpm > 180
    scores['commentary'] += 1.5
    scores['podcast'] += 0.5
  elsif wpm > 150
    scores['talking_head_business'] += 1
    scores['commentary'] += 0.5
  elsif wpm < 120
    scores['tutorial_screencast'] += 1
    scores['tutorial_demonstration'] += 1
    scores['narrative'] += 0.5
  else
    scores['talking_head_business'] += 0.5
    scores['talking_head_personal'] += 0.5
  end
end

# Question density scoring
case signals['question_density']
when 'high'
  scores['interview'] += 2
  scores['podcast'] += 1
when 'medium'
  scores['talking_head_business'] += 0.5
  scores['interview'] += 0.5
end

# Instructional language scoring
case signals['instructional_language']
when 'high'
  scores['tutorial_screencast'] += 3
  scores['tutorial_demonstration'] += 3
when 'medium'
  scores['tutorial_screencast'] += 1
  scores['tutorial_demonstration'] += 1
  scores['talking_head_business'] += 0.5
end

# Visual type scoring
case signals['visual_type']
when 'screencast'
  scores['tutorial_screencast'] += 4
when 'static_single_shot'
  scores['talking_head_business'] += 2
  scores['talking_head_personal'] += 2
  scores['commentary'] += 1
when 'multi_location'
  scores['vlog'] += 3
  scores['narrative'] += 1.5
when 'mixed'
  scores['tutorial_demonstration'] += 1
  scores['vlog'] += 0.5
end

# Scene changes scoring
if signals['cuts_per_minute']
  cpm = signals['cuts_per_minute']
  if cpm < 1
    scores['talking_head_business'] += 1.5
    scores['talking_head_personal'] += 1.5
    scores['podcast'] += 1
  elsif cpm < 3
    scores['tutorial_demonstration'] += 1
    scores['interview'] += 0.5
  elsif cpm > 5
    scores['vlog'] += 2
    scores['narrative'] += 1.5
    scores['commentary'] += 0.5
  end
elsif signals['scene_changes']
  sc = signals['scene_changes']
  if sc <= 5
    scores['talking_head_business'] += 1
    scores['talking_head_personal'] += 1
  elsif sc > 20
    scores['vlog'] += 1.5
    scores['narrative'] += 1
  end
end

# Script presence scoring
if signals['script_present']
  scores['talking_head_business'] += 1
  scores['narrative'] += 1
end

# Duration scoring
dur = signals['duration_seconds'] || 0
if dur > 0
  if dur > 2400 # > 40 min
    scores['podcast'] += 2
    scores['interview'] += 1
  elsif dur > 600 # > 10 min
    scores['talking_head_business'] += 0.5
    scores['podcast'] += 0.5
  elsif dur < 120 # < 2 min
    scores['commentary'] += 0.5
  end
end

# Audio features scoring
if signals['energy_variance_level']
  if signals['energy_variance_level'] == 'high'
    scores['commentary'] += 1
    scores['vlog'] += 0.5
  else
    scores['talking_head_business'] += 0.5
    scores['tutorial_screencast'] += 0.5
    scores['podcast'] += 0.5
  end
end

# --- Business vs Personal topic detection (from transcript) ---

if transcript_text.length > 0
  business_keywords = transcript_text.scan(
    /\b(?:revenue|client|business|company|startup|entrepreneur|freelanc|profit|market|brand|strateg|invest|sales|income|money|pricing|customer|growth|agency|consultants?|niche|outreach|roi|kpi|saas|b2b|b2c)\b/i
  ).size

  personal_keywords = transcript_text.scan(
    /\b(?:relationship|travel|lifestyle|cooking|recipe|fitness|workout|health|wellness|meditation|fashion|beauty|hobby|journal|family|friends|vacation|morning routine|self[- ]care)\b/i
  ).size

  word_count = transcript_text.split(/\s+/).size
  biz_ratio = word_count > 0 ? (business_keywords.to_f / (word_count / 100.0)) : 0
  personal_ratio = word_count > 0 ? (personal_keywords.to_f / (word_count / 100.0)) : 0

  if biz_ratio > personal_ratio && biz_ratio > 0.5
    scores['talking_head_business'] += 2
    signals['topic_signal'] = 'business'
  elsif personal_ratio > biz_ratio && personal_ratio > 0.5
    scores['talking_head_personal'] += 2
    signals['topic_signal'] = 'personal'
  else
    signals['topic_signal'] = 'neutral'
  end
end

# --- Pick winner ---

sorted = scores.sort_by { |_, v| -v }
best_type = sorted.first
runner_up = sorted[1]

if best_type.nil? || best_type[1] == 0
  detected = 'unknown'
  confidence = 0.0
else
  detected = best_type[0]
  max_score = best_type[1]

  # Confidence based on margin over runner-up and absolute score
  margin = runner_up ? (max_score - runner_up[1]) : max_score
  signal_count = signals.keys.size

  # Higher margin = higher confidence; more signals = higher confidence
  raw_confidence = [margin / [max_score, 1].max, 1.0].min * 0.6 +
                   [[signal_count / 10.0, 1.0].min, 0.0].max * 0.4

  confidence = [[raw_confidence, 0.1].max, 0.99].min.round(2)
end

# --- Output ---

result = {
  'detected' => detected,
  'confidence' => confidence,
  'source' => 'detection',
  'signals' => signals
}

$stderr.puts "Content type detected: #{detected} (confidence: #{confidence})"
$stderr.puts "  Signals: #{signals.keys.join(', ')}"
$stderr.puts "  Top scores: #{sorted.first(3).map { |k, v| "#{k}=#{v.round(1)}" }.join(', ')}"

# Write to library.yaml
library['content_type'] = result
library['last_updated'] = Date.today.to_s
File.write(library_yaml_path, YAML.dump(library))
$stderr.puts "  Written to #{library_yaml_path}"

puts detected
