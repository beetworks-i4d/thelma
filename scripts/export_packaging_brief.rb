#!/usr/bin/env ruby
# Export Packaging Brief — Generates a packaging handoff document alongside the XML.
# Reads classification, scoring, and audio data to produce thumbnail/title direction,
# hook analysis, peak map, and structural notes.
#
# Usage:
#   ruby scripts/export_packaging_brief.rb --library <name> [--output <xml-path>] [--profile <name>] [--llm-mode api|claude_code] [--no-review]
#   ruby scripts/export_packaging_brief.rb --library-dir <dir> --output <xml-path> [--profile <name>]  (deprecated)

require 'yaml'
require 'date'
require 'fileutils'
require_relative 'load_profile'
require_relative 'llm_client'
require_relative 'library_resolver'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR = File.expand_path('..', SCRIPTS_DIR)

# --- CLI parsing ---

library_dir = nil
library_name_arg = nil
output_xml = nil
profile_name = nil
llm_mode = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'
    args.shift
    library_name_arg = args.shift
  when '--library-dir'
    args.shift
    library_dir = args.shift
    $stderr.puts "  DEPRECATED: --library-dir flag. Use --library <name> instead."
  when '--output'
    args.shift
    output_xml = args.shift
  when '--profile'
    args.shift
    profile_name = args.shift
  when '--llm-mode'
    args.shift
    llm_mode = args.shift
  when '--no-review'
    args.shift
    # accepted for CLI consistency, no-op in this script
  else
    args.shift
  end
end

LLMClient.mode = llm_mode.to_sym if llm_mode

# Resolve library_dir from --library if provided
if library_name_arg && !library_dir
  library_dir = LibraryResolver.resolve(library_name_arg)
end

unless library_dir
  $stderr.puts "Usage: ruby scripts/export_packaging_brief.rb --library <name> [--output <xml-path>] [--profile <name>] [--llm-mode api|claude_code]"
  exit 1
end

unless File.directory?(library_dir)
  $stderr.puts "ERROR: Library directory not found: #{library_dir}"
  exit 1
end

# --- Load data ---

library_yaml_path = File.join(library_dir, 'library.yaml')
unless File.exist?(library_yaml_path)
  $stderr.puts "ERROR: library.yaml not found in #{library_dir}"
  exit 1
end

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
library_name = library['library_name'] || File.basename(library_dir)

# Auto-detect output XML if --output not provided
unless output_xml
  video_entry = library['videos']&.first
  if video_entry && video_entry['path']
    out_dir = File.join(File.dirname(video_entry['path']), 'output')
    latest_xml = Dir.glob(File.join(out_dir, '*_arrangement_*.xml')).max_by { |f| File.mtime(f) }
    output_xml = latest_xml
  end
  unless output_xml
    $stderr.puts "ERROR: No --output XML specified and no arrangement XML found in output directory"
    exit 1
  end
  $stderr.puts "  Auto-detected XML: #{File.basename(output_xml)}"
end

profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)
tone_guide = load_tone_guide(profile)
tone_context = build_tone_context(profile, tone_guide)
# Compact tone context for lightweight LLM calls (thumbnail/title)
compact_tone_context = build_compact_tone_context(profile)

# Check profile setting
unless profile.fetch('generate_packaging_brief', true)
  $stderr.puts "  Packaging brief disabled by profile"
  exit 0
end

classified_path = File.join(library_dir, 'segments_classified.yaml')
unless File.exist?(classified_path)
  $stderr.puts "ERROR: segments_classified.yaml not found — classification required for brief"
  exit 1
end

classified = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])
all_segments = classified['segments'] || []

if all_segments.empty?
  $stderr.puts "ERROR: No segments in classification"
  exit 1
end

# Optional data
scored_path = File.join(library_dir, 'storylines_scored.yaml')
scored_data = File.exist?(scored_path) ? YAML.safe_load(File.read(scored_path), permitted_classes: [Date]) : nil

audio_features_path = File.join(library_dir, 'audio_features.yaml')
audio_features = File.exist?(audio_features_path) ? YAML.safe_load(File.read(audio_features_path), permitted_classes: [Date]) : nil

# --- Derive storyline from XML filename ---

xml_basename = File.basename(output_xml, '.xml')
# Pattern: {library}_{storyline_id}_{YYYYMMDD-HHMMSS}
# Strip timestamp suffix (last _YYYYMMDD-HHMMSS)
storyline_id = xml_basename.sub(/_\d{8}-\d{6}$/, '')
# Strip library name prefix
storyline_id = storyline_id.sub(/^#{Regexp.escape(library_name)}_/, '') if storyline_id.start_with?("#{library_name}_")

storyline = nil
if scored_data
  storylines = scored_data['storylines'] || []
  storyline = storylines.find { |s| s['id'] == storyline_id }
  storyline ||= storylines.find { |s| storyline_id.include?(s['id']) }
  storyline ||= storylines.first
end

# --- Determine segments for this storyline ---

if storyline
  hook_t = storyline['hook_segment'].to_f
  close_t = storyline['close_segment']&.to_f
  seg_by_t = {}
  all_segments.each { |s| seg_by_t[s['t'].to_f] = s }

  hook_seg = seg_by_t[hook_t]
  close_seg = close_t ? seg_by_t[close_t] : nil

  body_segs = if close_t
    all_segments.select { |s| s['t'].to_f > hook_t && s['t'].to_f < close_t }
  else
    all_segments.select { |s| s['t'].to_f > hook_t }
  end.sort_by { |s| s['t'].to_f }

  arranged = []
  arranged << hook_seg if hook_seg
  arranged += body_segs
  arranged << close_seg if close_seg && close_seg != hook_seg
  arranged = arranged.compact.uniq { |s| s['t'] }
else
  # No storyline data — use all segments
  arranged = all_segments
end

if arranged.empty?
  $stderr.puts "ERROR: No segments to analyze"
  exit 1
end

# --- Format detection ---

def detect_format(storyline_id, storyline, arranged)
  return :short if storyline_id&.include?('short')
  if storyline
    duration = storyline['duration_estimate'].to_f
    return :medium if duration > 0 && duration < 180
  else
    total = arranged.sum { |s| (s['e'].to_f - s['t'].to_f).abs }
    return :medium if total < 180
  end
  :longform
end

brief_format = detect_format(storyline_id, storyline, arranged)

# --- Content type ---

content_type = library.dig('content_type', 'detected') || 'unknown'

# --- Video duration ---

video = library['videos']&.first
video_duration_raw = video&.dig('duration') || '0'
# Duration might be "MM:SS" or seconds
video_duration_s = if video_duration_raw.to_s.include?(':')
  parts = video_duration_raw.to_s.split(':').map(&:to_f)
  parts.length == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : parts[0] * 60 + parts[1]
else
  video_duration_raw.to_f
end
video_duration_display = if video_duration_s >= 3600
  "%d:%02d:%02d" % [video_duration_s / 3600, (video_duration_s % 3600) / 60, video_duration_s % 60]
else
  "%d:%02d" % [video_duration_s / 60, video_duration_s % 60]
end

# --- Helper functions ---

DUR_WEIGHT = { 'identity' => 3, 'mood' => 2, 'spike' => 1 }.freeze
CONF_WEIGHT = { 'high' => 3, 'medium' => 2, 'low' => 1 }.freeze

def segment_score(seg)
  dur_w = DUR_WEIGHT[seg['dur']] || 1
  conf_w = CONF_WEIGHT[seg['confidence']] || 1
  dur_w * conf_w
end

def format_time(seconds)
  s = seconds.to_f
  if s >= 3600
    "%d:%02d:%02d" % [s / 3600, (s % 3600) / 60, s % 60]
  else
    "%d:%02d" % [s / 60, s % 60]
  end
end

def cold_viability_label(storyline)
  return 'unknown' unless storyline
  cv = storyline.dig('scores', 'cold_viability').to_i
  if cv >= 12
    'yes'
  elsif cv >= 8
    'maybe'
  else
    'no'
  end
end

# --- Build sections ---

hook = arranged.first
close = arranged.last

# == Hook Cash ==

def build_hook_cash(hook, storyline, audio_features, arranged)
  lines = []
  states = hook['states'] || []
  dur = hook['dur'] || 'unknown'
  lines << "- Opening state: #{states.first}(#{dur})" + (states.length > 1 ? " — #{states[1..].join(', ')} secondary" : "")

  # Audio delivery
  ap = hook['audio_profile']
  if ap
    parts = [ap]
    parts << "#{hook['audio_pitch_trend']} pitch" if hook['audio_pitch_trend']
    if hook['audio_speaking_rate']
      rate = hook['audio_speaking_rate'].to_f
      parts << "#{rate}x speaking rate" if rate > 0
    end
    lines << "- Audio delivery: #{parts.join(', ')}"
  elsif audio_features
    lines << "- Audio delivery: see audio analysis"
  else
    lines << "- Audio delivery: audio analysis unavailable"
  end

  lines << "- Promise: \"#{hook['distillation']}\""
  lines << "- Cold-viable: #{cold_viability_label(storyline)}" + (storyline ? "" : " — no storyline scoring available")

  lines
end

# == Primary Spine ==

def build_spine(arranged)
  state_counts = Hash.new(0)
  arranged.each do |seg|
    (seg['states'] || []).each_with_index do |state, i|
      state_counts[state] += (i == 0 ? 2 : 1) # primary state counts double
    end
  end

  return ["- Spine state: unknown (no state data)"] if state_counts.empty?

  sorted = state_counts.sort_by { |_, v| -v }
  spine_state = sorted.first[0]
  total_weight = state_counts.values.sum.to_f
  pct = ((sorted.first[1] / total_weight) * 100).round

  secondaries = sorted[1..3]&.map { |s, _| s } || []

  lines = []
  lines << "- Spine state: #{spine_state}"
  lines << "- Why: #{pct}% weighted state presence across #{arranged.size} segments"
  lines << "- Compatible secondaries: #{secondaries.join(', ')}" unless secondaries.empty?
  lines
end

# == Peak Map ==

def build_peak_map(arranged)
  scored = arranged.map { |seg| [seg, segment_score(seg)] }
    .sort_by { |_, score| -score }
    .first(5)

  return ["- No peak moments identified"] if scored.empty?

  top_score = scored.first[1]
  lines = scored.map do |seg, score|
    star = score == top_score ? "★" : " "
    t = format_time(seg['t'])
    states = (seg['states'] || ['unknown']).first
    dur = seg['dur'] || '?'
    ap = seg['audio_profile'] || 'unknown delivery'
    "- #{star} t=#{seg['t'].to_f.round}s \"#{seg['distillation']}\" — #{states}(#{dur}), #{ap}"
  end

  lines
end

# == Structural Notes ==

def build_structural_notes(arranged, storyline, content_type, video_duration_display, library_name)
  lines = []
  lines << "- Video duration: #{video_duration_display}"

  if storyline
    tm = storyline['template_match'] || {}
    if tm['template']
      lines << "- Template: #{tm['template']} (#{tm['fit_score']}% fit)"
    else
      lines << "- Template: no template matched"
    end
  else
    lines << "- Template: no scoring data available"
  end

  lines << "- Content type: #{content_type}"

  # Durability arc
  if arranged.size >= 2
    hook_dur = arranged.first['dur'] || '?'
    close_dur = arranged.last['dur'] || '?'
    body = arranged[1..-2] || []
    body_durs = body.map { |s| s['dur'] }.compact
    body_mode = body_durs.max_by { |d| body_durs.count(d) } || '?'
    lines << "- Durability arc: #{hook_dur} hook → #{body_mode} body → #{close_dur} close"
  end

  # Re-hook points from template matched beats
  if storyline
    beats = storyline.dig('template_match', 'matched_beats') || {}
    if beats.size > 1
      rehook_lines = beats.map do |beat_id, info|
        next if beat_id == beats.keys.first # skip first beat (it's the hook)
        t = info['segment_t']
        "t=#{t.to_f.round}s (#{beat_id.tr('_', ' ')})"
      end.compact.first(3)
      lines << "- Re-hook points: #{rehook_lines.join(', ')}" unless rehook_lines.empty?
    end
  end

  lines
end

# == Alignment ==

def build_alignment(hook, arranged, storyline)
  lines = []
  hook_end = hook['e'].to_f
  lines << "- Hook delivers on promise within: #{hook_end.round}s"

  hook_state = (hook['states'] || []).first
  # Find spine state from body
  body_states = Hash.new(0)
  arranged[1..].each { |s| (s['states'] || []).each { |st| body_states[st] += 1 } } if arranged.size > 1
  spine_state = body_states.max_by { |_, v| v }&.first

  if hook_state && spine_state && hook_state != spine_state
    lines << "- Risk: hook #{hook_state} differs from body spine #{spine_state} — ensure packaging matches body tone"
  else
    lines << "- Risk: low — hook and body states aligned"
  end

  # Payoff: highest-confidence identity segment
  identity_segs = arranged.select { |s| s['dur'] == 'identity' && s['confidence'] == 'high' }
  best = identity_segs.max_by { |s| segment_score(s) }
  if best
    lines << "- Payoff: t=#{best['t'].to_f.round}s \"#{best['distillation']}\" — strongest identity moment"
  end

  lines
end

# == LLM sections ==

def build_thumbnail_prompt(hook, peaks, content_type, arranged, tone_context = '')
  distillations = arranged.first(5).map { |s| s['distillation'] }.compact.join('; ')
  hook_state = (hook['states'] || ['unknown']).first
  peak_states = peaks.map { |s, _| (s['states'] || ['unknown']).first }.uniq.join(', ')

  tone_block = tone_context.empty? ? '' : "\n#{tone_context}\nEnsure thumbnail language matches the creator's voice.\n"

  <<~PROMPT
    You are a YouTube packaging specialist. Based on the following video analysis, suggest thumbnail direction.

    Content type: #{content_type}
    Hook emotional state: #{hook_state}
    Peak moment states: #{peak_states}
    Key distillations: #{distillations}
    #{tone_block}
    Respond with EXACTLY this format (no extra text):
    Primary emotion: [emotion to induce in viewer]
    Visual suggestion: [2-3 sentence visual/composition direction]
    Text overlay: [short text suggestion for thumbnail]
    Avoid: [what NOT to do, 1 sentence]
  PROMPT
end

def build_title_prompt(hook, spine_state, content_type, template_name, tone_context = '')
  hook_distillation = hook['distillation'] || 'unknown'
  hook_state = (hook['states'] || ['unknown']).first

  tone_block = tone_context.empty? ? '' : "\n#{tone_context}\nEnsure titles match the creator's voice — direct, specific, no hustle-guru energy.\n"

  <<~PROMPT
    You are a YouTube packaging specialist. Based on the following video analysis, suggest 3 title angles.

    Content type: #{content_type}
    Hook promise: "#{hook_distillation}"
    Hook state: #{hook_state}
    Primary spine state: #{spine_state}
    Template: #{template_name || 'none matched'}
    #{tone_block}
    Respond with EXACTLY this format (no extra text):
    Promise type: [transformation/comparison/revelation/instruction/story]
    1. [Title option] — [5-word reasoning]
    2. [Title option] — [5-word reasoning]
    3. [Title option] — [5-word reasoning]
  PROMPT
end

def call_llm(prompt, profile, pending_dir: nil, call_name: nil)
  if ENV['THELMA_LLM_STUB']
    return "[LLM stub — packaging suggestion placeholder]"
  end
  LLMClient.call(prompt, call_type: 'packaging', profile: profile, max_tokens: 500,
                 pending_dir: pending_dir, call_name: call_name)
rescue LLMClient::Pending
  raise  # propagate to caller for batch handling
rescue => e
  $stderr.puts "  LLM call failed: #{e.message}"
  "[LLM unavailable — generate manually]"
end

# == Short format: first-frame brief ==

def build_short_brief(hook, content_type, profile, pending_dir:)
  lines = []
  lines << "# First-Frame Brief"
  lines << ""
  states = hook['states'] || ['unknown']
  lines << "- Frame 1 state: #{states.first}(#{hook['dur'] || '?'})"
  lines << "- Delivery: #{hook['audio_profile'] || 'unknown'}"
  lines << "- Distillation: \"#{hook['distillation']}\""
  lines << "- Vertical framing: speaker centered, text safe zone top 20%"
  lines << ""

  # One LLM call for text overlay suggestion
  prompt = <<~PROMPT
    You are a YouTube Shorts packaging specialist. Based on this opening frame analysis, suggest a text overlay.

    Opening state: #{states.first}
    Distillation: "#{hook['distillation']}"
    Content type: #{content_type}

    Respond with EXACTLY this format (no extra text):
    Text overlay: [short punchy text for first frame, max 6 words]
    Hook type: [curiosity/shock/promise/question]
  PROMPT

  response = call_llm(prompt, profile, pending_dir: pending_dir, call_name: 'packaging_short_text')
  # LLMClient::Pending propagates up to caller
  lines << "## Text Direction"
  lines << ""
  response.strip.split("\n").each { |l| lines << "- #{l.strip}" unless l.strip.empty? }

  lines
end

# --- Assemble brief ---

$stderr.puts "  Packaging brief: #{brief_format} format for #{storyline_id || 'all segments'}"

sections = []

# Title
title_name = library_name.tr('-', ' ').split.map(&:capitalize).join(' ')
storyline_desc = storyline ? (storyline['arc'] || storyline_id) : 'Full Video'
sections << "# Packaging Brief: #{title_name} — #{storyline_desc}"
sections << ""

brief_pending_dir = File.join(library_dir, 'pending_llm_calls')
pending_count = 0

if brief_format == :short
  begin
    sections += build_short_brief(hook, content_type, profile, pending_dir: brief_pending_dir)
  rescue LLMClient::Pending
    pending_count += 1
  end
else
  # Hook Cash
  sections << "## Hook Cash"
  sections << "What the viewer gets in the first 10 seconds."
  sections += build_hook_cash(hook, storyline, audio_features, arranged)
  sections << ""

  # Primary Spine
  sections << "## Primary Spine"
  sections << "The emotional through-line that carries the video."
  sections += build_spine(arranged)
  sections << ""

  if brief_format == :longform
    # Peak Map
    scored_peaks = arranged.map { |seg| [seg, segment_score(seg)] }
      .sort_by { |_, score| -score }
      .first(5)

    sections << "## Peak Map"
    sections << "The 3-5 highest-intensity moments. Star = strongest."
    sections += build_peak_map(arranged)
    sections << ""
  end

  # Thumbnail Direction (LLM) — batch: catch Pending, continue to next call
  scored_peaks_for_thumb = arranged.map { |seg| [seg, segment_score(seg)] }
    .sort_by { |_, score| -score }
    .first(5)
  thumb_prompt = build_thumbnail_prompt(hook, scored_peaks_for_thumb, content_type, arranged, compact_tone_context)
  thumb_response = nil
  begin
    thumb_response = call_llm(thumb_prompt, profile, pending_dir: brief_pending_dir, call_name: 'packaging_thumbnail')
  rescue LLMClient::Pending
    pending_count += 1
  end

  # Title Direction (LLM) — batch: catch Pending, continue
  spine_state = build_spine(arranged).first&.sub('- Spine state: ', '') || 'unknown'
  template_name = storyline&.dig('template_match', 'template')
  title_prompt = build_title_prompt(hook, spine_state, content_type, template_name, compact_tone_context)
  title_response = nil
  begin
    title_response = call_llm(title_prompt, profile, pending_dir: brief_pending_dir, call_name: 'packaging_title')
  rescue LLMClient::Pending
    pending_count += 1
  end

  # Exit 2 if any LLM calls are pending — all pending files have been written
  if pending_count > 0
    $stderr.puts "  #{pending_count} LLM call(s) pending — fill response files and re-run"
    exit 2
  end

  sections << "## Thumbnail Direction"
  sections << "Based on hook state + peak moments + content type."
  thumb_response.strip.split("\n").each { |l| sections << "- #{l.strip}" unless l.strip.empty? }
  sections << ""

  sections << "## Title Direction"
  sections << "Based on hook promise + spine + content type."
  title_response.strip.split("\n").each { |l| sections << "- #{l.strip}" unless l.strip.empty? }
  sections << ""

  if brief_format == :longform
    # Alignment
    sections << "## Packaging-to-Content Alignment"
    sections << "Does the package match what the video delivers?"
    sections += build_alignment(hook, arranged, storyline)
    sections << ""

    # Structural Notes
    sections << "## Structural Notes for Packaging"
    sections += build_structural_notes(arranged, storyline, content_type, video_duration_display, library_name)
    sections << ""
  end
end

# Short format also exits 2 if pending
if pending_count > 0
  $stderr.puts "  #{pending_count} LLM call(s) pending — fill response files and re-run"
  exit 2
end

# --- Write output ---

output_dir = File.dirname(output_xml)
brief_filename = "#{xml_basename}_packaging_brief.md"
brief_path = File.join(output_dir, brief_filename)

FileUtils.mkdir_p(output_dir)
File.write(brief_path, sections.join("\n") + "\n")

$stderr.puts "  Brief: #{brief_path}"
puts brief_path
