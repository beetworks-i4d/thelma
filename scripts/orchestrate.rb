#!/usr/bin/env ruby
# Thelma Pipeline Orchestrator
# Deterministic pipeline runner. Replaces SKILL.md as pipeline brain.
# Checks cache at each step, skips completed phases, aborts loud on failure.
#
# Usage:
#   ruby scripts/orchestrate.rb --library <name> [--profile <name>] [--branch A|B]
#                               [--duration mm:ss] [--no-review] [--llm-mode api|claude_code]
#
# Session 5 pipeline: Phase 1 → 1.35 (semantic_segment) → 1.4 (extract_segments) →
# 1.5c (audio_emotion) → 1.5d (scene/visual) → Phase 2 (discovery_pass) →
# Phase 3 (arrange) → Phase 4 (export)
# Branch C deprecated as of v4.1 (will be redesigned in P5).

require 'yaml'
require 'date'
require 'json'
require 'open3'
require 'digest'
require 'fileutils'
require 'shellwords'
require_relative 'load_profile'
require_relative 'llm_client'
require_relative 'pool_index'
require_relative 'library_resolver'
require_relative 'arrangement_adapter'

SCRIPTS_DIR = File.dirname(__FILE__)
ROOT_DIR = File.expand_path('..', SCRIPTS_DIR)

# --- CLI parsing ---

library_name = nil
profile_name = nil
branch_override = nil
analyze_only = false
no_review = false
llm_mode = nil
mode = nil
force_reindex    = false
force_rediscover = false
discover_only    = false
candidate_id     = nil
force_cascade      = false
force_revisualize  = false
pool_dir_arg       = nil
language_override  = nil
filter_expr        = nil
short_id_arg       = nil
force              = false
diarize            = false
duration_target    = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--library'
    args.shift
    library_name = args.shift
  when '--profile'
    args.shift
    profile_name = args.shift
  when '--branch'
    args.shift
    branch_override = args.shift&.upcase
  when '--analyze-only'
    args.shift
    analyze_only = true
  when '--no-review'
    args.shift
    no_review = true
  when '--llm-mode'
    args.shift
    llm_mode = args.shift
  when '--mode'
    args.shift
    mode = args.shift
  when '--force-reindex'
    args.shift
    force_reindex = true
  when '--force-rediscover'
    args.shift
    force_rediscover = true
  when '--discover-only'
    args.shift
    discover_only = true
  when '--candidate'
    args.shift
    candidate_id = args.shift
  when '--force-cascade'
    args.shift
    force_cascade = true
  when '--force-revisualize'
    args.shift
    force_revisualize = true
  when '--pool-dir'
    args.shift
    pool_dir_arg = args.shift
  when '--language'
    args.shift
    language_override = args.shift
  when '--filter'
    args.shift
    filter_expr = args.shift
  when '--short'
    args.shift
    short_id_arg = args.shift
  when '--force'
    args.shift
    force = true
  when '--diarize'
    args.shift
    diarize = true
  when '--duration'
    args.shift
    duration_target = args.shift
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/orchestrate.rb --library <name> [--profile <name>] [--branch A|B|C] [--analyze-only] [--no-review] [--llm-mode api|claude_code] [--mode mine] [--force-reindex] [--force-rediscover] [--discover-only] [--candidate <id>] [--force-cascade] [--force-revisualize] [--pool-dir <path>] [--language <code>] [--filter <expr>] [--short <id>] [--force] [--diarize]"
  end
end

abort "Usage: ruby scripts/orchestrate.rb --library <name> [--profile <name>] [--branch A|B|C] [--analyze-only] [--no-review] [--llm-mode api|claude_code] [--mode mine] [--force-reindex] [--force-rediscover] [--discover-only] [--candidate <id>] [--force-cascade] [--force-revisualize] [--pool-dir <path>] [--language <code>] [--filter <expr>] [--short <id>] [--force] [--diarize]" unless library_name

if diarize && (!ENV['HF_TOKEN'] || ENV['HF_TOKEN'].strip.empty?)
  abort "PIPELINE ABORT: --diarize requires HF_TOKEN environment variable.\n" \
        "Get a token at https://huggingface.co/settings/tokens and export HF_TOKEN=<your_token>"
end

# --short is shorthand for --filter id=<id>. --filter wins if both are set.
filter_expr = "id=#{short_id_arg}" if short_id_arg && filter_expr.nil?

LLMClient.mode = llm_mode.to_sym if llm_mode

if analyze_only
  abort "PIPELINE ABORT: --analyze-only (Branch C) deprecated as of v4.1; will be redesigned in P5.\n" \
        "Branch C scripts (discover_storylines, match_templates, score_coherence, etc.) are no longer in active routing."
end

if branch_override == 'C'
  abort "PIPELINE ABORT: --branch C deprecated as of v4.1; will be redesigned in P5.\n" \
        "Branch C scripts (discover_storylines, match_templates, score_coherence, etc.) are no longer in active routing."
end

# --- Helpers ---

def phase(name)
  $stderr.puts "\n#{'=' * 60}"
  $stderr.puts "PHASE: #{name}"
  $stderr.puts '=' * 60
end

def step(name)
  $stderr.puts "  >> #{name}"
end

def skip(name, reason = 'cached')
  $stderr.puts "  -- #{name} [SKIP: #{reason}]"
end

def run_script(script, *args, forward_stdin: false)
  cmd = ['ruby', File.join(SCRIPTS_DIR, script)] + args.map(&:to_s)
  $stderr.puts "  $ #{cmd.join(' ')}"
  if forward_stdin
    # Use system() to inherit stdin for interactive prompts (e.g., review gate)
    system(*cmd)
    exitstatus = $?.exitstatus
    if exitstatus == 2
      $stderr.puts "PIPELINE PAUSED: #{script} awaiting LLM input"
      exit 2
    end
    unless $?.success?
      abort "\nPIPELINE ABORT: #{script} failed (exit #{exitstatus})\n" \
            "RUN SESSION INTEGRITY: If running inside Claude Code, do not attempt to patch this defect. End the session. Open a dev session to investigate and fix."
    end
    return ''
  end
  stdout, stderr, status = Open3.capture3(*cmd)
  $stderr.puts stderr unless stderr.strip.empty?
  if status.exitstatus == 2
    $stderr.puts "PIPELINE PAUSED: #{script} awaiting LLM input"
    exit 2
  end
  unless status.success?
    abort "\nPIPELINE ABORT: #{script} failed (exit #{status.exitstatus})\n#{stderr}\n" \
          "RUN SESSION INTEGRITY: If running inside Claude Code, do not attempt to patch this defect. End the session. Open a dev session to investigate and fix."
  end
  stdout.strip
end

def run_command(cmd_str)
  $stderr.puts "  $ #{cmd_str}"
  stdout, stderr, status = Open3.capture3(cmd_str)
  $stderr.puts stderr unless stderr.strip.empty?
  unless status.success?
    abort "\nPIPELINE ABORT: command failed (exit #{status.exitstatus})\n  #{cmd_str}\n#{stderr}"
  end
  stdout.strip
end

# Like run_script but never aborts on failure — returns [stdout, ok, exitstatus].
# Used by the lean Branch A loop so one bad beat doesn't kill the whole run.
def try_run_script(script, *args)
  cmd = ['ruby', File.join(SCRIPTS_DIR, script)] + args.map(&:to_s)
  $stderr.puts "  $ #{cmd.join(' ')}"
  stdout, stderr, status = Open3.capture3(*cmd)
  $stderr.puts stderr unless stderr.strip.empty?
  [stdout.strip, status.success?, status.exitstatus]
end

def parse_filter_expr(expr)
  parts = expr.to_s.split('=', 2)
  abort "Invalid --filter '#{expr}' — expected key=value" unless parts.size == 2
  key, value = parts
  abort "Invalid --filter key '#{key}' — must be role, id, or parent" unless %w[role id parent].include?(key)
  abort "Invalid --filter '#{expr}' — value is empty" if value.to_s.empty?
  [key, value]
end

def select_beats_for_filter(all_beats, filter_key, filter_value)
  case filter_key
  when 'role'   then all_beats.select { |b| b['role'] == filter_value }
  when 'id'     then [all_beats.find { |b| b['id'] == filter_value }].compact
  when 'parent' then all_beats.select { |b| b['parent'] == filter_value }
  else []
  end
end

def file_cached?(path)
  path && File.exist?(path) && File.size(path) > 0
end

def create_library!(library_name, library_dir, pool_dir)
  FileUtils.mkdir_p(library_dir)
  FileUtils.mkdir_p(File.join(library_dir, 'transcripts'))
  settings_path = File.join(ROOT_DIR, 'libraries', 'settings.yaml')
  editor = if File.exist?(settings_path)
    (YAML.safe_load(File.read(settings_path)) || {})['editor']
  end
  library = {
    'library_name'    => library_name,
    'created_date'    => Date.today.to_s,
    'last_updated'    => Date.today.to_s,
    'language'        => 'english',
    'editor'          => editor || 'premiere',
    'pool_dir'        => pool_dir,
    'user_context'    => '',
    'footage_summary' => 'No footage analyzed yet.',
    'script_parsed'   => nil,
    'videos'          => []
  }
  File.write(File.join(library_dir, 'library.yaml'), library.to_yaml)
  $stderr.puts "Created library: #{library_dir}"
end

# --- Resolve or auto-create library ---

library_dir = LibraryResolver.resolve(library_name)

unless File.exist?(File.join(library_dir, 'library.yaml'))
  pool_dir_for_create = pool_dir_arg

  if pool_dir_for_create.nil? && $stdin.tty?
    $stderr.puts "Library '#{library_name}' doesn't exist. Creating new library."
    $stderr.print "Pool folder path (where your footage lives):\n> "
    pool_dir_for_create = $stdin.gets&.strip
  end

  unless pool_dir_for_create && !pool_dir_for_create.empty?
    abort "Library '#{library_name}' not found. Use --pool-dir <path> to create it."
  end

  pool_dir_for_create = File.expand_path(pool_dir_for_create)
  abort "Pool directory not found: #{pool_dir_for_create}" unless File.directory?(pool_dir_for_create)

  library_dir = File.join(pool_dir_for_create, '.thelma')
  create_library!(library_name, library_dir, pool_dir_for_create)
  LibraryResolver.register(library_name, library_dir)
end

ENV['THELMA_LIBRARY_DIR'] = library_dir

library_yaml_path = File.join(library_dir, 'library.yaml')

library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
videos = library['videos']

transcripts_dir = File.join(library_dir, 'transcripts')
FileUtils.mkdir_p(transcripts_dir)

# ============================================================
# MINE MODE: pool-based incremental ingestion
# ============================================================

if mode == 'mine'
  pool_dir = library['pool_dir']
  abort "pool_dir not set in library.yaml — required for --mode mine" unless pool_dir && !pool_dir.to_s.strip.empty?
  pool_dir = File.expand_path(pool_dir)
  abort "pool_dir not found: #{pool_dir}" unless File.directory?(pool_dir)

  # Language + tone profile warning
  effective_lang = language_override || (library['language'] == 'english' ? 'en' : (library['language'] || 'en'))
  if effective_lang != 'en' && profile_name && !%w[_default].include?(profile_name)
    $stderr.puts "  WARNING: Language '#{effective_lang}' with tone profile '#{profile_name}' — " \
                 "tone profiles are English-tuned and may not apply optimally."
  end

  phase 'MINE — Pool Indexing'
  $stderr.puts "Pool: #{pool_dir}"

  index = PoolIndex.load(library_dir)
  scan = PoolIndex.scan_pool(pool_dir, index, force: force_reindex)

  $stderr.puts "  Scan: #{scan[:new].size} new, #{scan[:changed].size} changed, " \
               "#{scan[:unchanged].size} unchanged, #{scan[:removed].size} removed"

  to_ingest = scan[:new] + scan[:changed]

  if to_ingest.empty?
    $stderr.puts "  All sources up to date — nothing to ingest"
  else
    to_ingest.each do |full_path|
      filename = File.basename(full_path)
      $stderr.puts "\n  --- Ingesting: #{filename} ---"

      PoolIndex.add_source(index, full_path)
      is_audio_only = PoolIndex.audio_only?(full_path)
      attrs = {}

      # Audio cleanup
      src_basename = File.basename(full_path, File.extname(full_path))
      treated_wav = File.join(transcripts_dir, "#{src_basename}_treated.wav")
      if file_cached?(treated_wav)
        skip 'audio_cleanup', 'treated WAV exists'
      else
        step 'audio_cleanup'
        run_script('audio_cleanup.rb', full_path, transcripts_dir)
      end

      # WhisperX transcription
      expected_transcript = File.join(transcripts_dir, "#{src_basename}_treated.json")
      if file_cached?(expected_transcript)
        skip 'whisperx', 'transcript exists'
      else
        step 'whisperx transcription'
        whisperx_bin = File.expand_path('~/.thelma/whisperx')
        whisperx_bin = 'whisperx' unless File.exist?(whisperx_bin)
        lang_code = language_override || (library['language'] == 'english' ? 'en' : (library['language'] || 'en'))
        whisperx_cmd = "#{Shellwords.shellescape(whisperx_bin)} #{Shellwords.shellescape(treated_wav)} " \
                       "--model turbo --language #{lang_code} " \
                       "--output_format json --output_dir #{Shellwords.shellescape(transcripts_dir)} " \
                       "--compute_type int8"
        whisperx_cmd += " --diarize" if diarize
        run_command(whisperx_cmd)
        abort "PIPELINE ABORT: WhisperX did not produce: #{expected_transcript}" unless File.exist?(expected_transcript)
      end
      attrs[:transcript_file] = File.basename(expected_transcript) if File.exist?(expected_transcript)

      # Extract speaker info from diarized transcript
      if File.exist?(expected_transcript)
        t_data = JSON.parse(File.read(expected_transcript)) rescue {}
        speakers = (t_data['segments'] || []).map { |s| s['speaker'] }.compact.uniq.sort
        attrs[:diarization_enabled] = diarize
        attrs[:speakers_detected] = speakers.empty? ? nil : speakers
        attrs[:speaker_count] = speakers.empty? ? 1 : speakers.size
      end

      # Scene detection (video only)
      unless is_audio_only
        sc_path = File.join(transcripts_dir, "#{src_basename}_scenes.yaml")
        if file_cached?(sc_path)
          skip 'detect_scenes', 'scene data cached'
        else
          step 'detect_scenes'
          run_script('detect_scenes.rb', full_path, '--output', sc_path)
        end
        attrs[:scene_changes] = File.basename(sc_path) if File.exist?(sc_path)

        # Visual analysis: per-shot frame extraction
        va_path = File.join(transcripts_dir, "#{src_basename}_visual_analysis.yaml")
        if !force_revisualize && file_cached?(va_path)
          skip 'visual_analysis', 'visual_analysis.yaml cached'
        else
          step 'visual_analysis'
          va_flags = ['--library', library_name, '--video', full_path]
          va_flags += ['--scene-file', sc_path] if File.exist?(sc_path)
          va_flags << '--force' if force_revisualize
          run_script('extract_visual_frames.rb', *va_flags)
        end
        attrs[:visual_analysis] = File.basename(va_path) if File.exist?(va_path)
      end

      PoolIndex.mark_ingested(index, filename, attrs)
      PoolIndex.save(library_dir, index)
    end
  end

  # Visual analysis: per-shot frame extraction for all video sources
  # Runs as a separate pass so already-ingested sources also get visual analysis.
  phase 'MINE — Visual Analysis'
  index = PoolIndex.load(library_dir)  # reload in case ingestion updated it
  va_count = 0
  (index['sources'] || {}).each do |filename, entry|
    next if entry['media_type'] == 'audio_only'
    next unless entry['ingested_at']  # skip un-ingested sources

    src_base = File.basename(filename, File.extname(filename))
    va_path = File.join(transcripts_dir, "#{src_base}_visual_analysis.yaml")
    sc_path = File.join(transcripts_dir, "#{src_base}_scenes.yaml")

    if !force_revisualize && file_cached?(va_path)
      next  # already done
    end

    # Resolve full path from pool
    full_path = Dir.glob(File.join(pool_dir, '**', filename)).first
    unless full_path && File.exist?(full_path)
      $stderr.puts "  SKIP #{filename}: file not found in pool"
      next
    end

    step "visual_analysis: #{filename}"
    va_flags = ['--library', library_name, '--video', full_path]
    va_flags += ['--scene-file', sc_path] if File.exist?(sc_path)
    va_flags << '--force' if force_revisualize
    run_script('extract_visual_frames.rb', *va_flags)

    if File.exist?(va_path)
      PoolIndex.mark_ingested(index, filename, 'visual_analysis' => File.basename(va_path))
      va_count += 1
    end
  end
  PoolIndex.save(library_dir, index) if va_count > 0
  $stderr.puts va_count > 0 ? "  Generated #{va_count} visual analysis file(s)" : "  All sources up to date"

  # HQ audio matching
  phase 'MINE — HQ Audio Matching'
  run_script('match_hq_audio.rb', '--library', library_name)

  # ── Discover-only exit ────────────────────────────────────────────────────
  if discover_only
    $stderr.puts "\n#{'=' * 60}"
    $stderr.puts "POOL INDEXING COMPLETE (--discover-only)"
    $stderr.puts "  Index: #{PoolIndex.index_path(library_dir)}"
    $stderr.puts '=' * 60
    exit 0
  end

  # Bridge: populate library.yaml['videos'] from index.yaml so shared pipeline
  # (extract_segments, audio_emotion, etc.) can find the sources.
  phase 'MINE — Register Sources in library.yaml'
  index = PoolIndex.load(library_dir)
  pool_videos = []
  (index['sources'] || {}).each do |filename, entry|
    next unless entry['ingested_at']  # skip un-ingested sources
    full_path = Dir.glob(File.join(pool_dir, '**', filename)).first
    next unless full_path && File.exist?(full_path)

    v_entry = { 'path' => full_path }
    v_entry['transcript'] = entry['transcript_file'] if entry['transcript_file']
    v_entry['duration'] = entry['duration'].to_s if entry['duration']
    # Check for cleaned transcript by convention
    src_base = File.basename(filename, File.extname(filename))
    cleaned_candidates = Dir.glob(File.join(transcripts_dir, "*#{src_base}*cleaned*"))
    v_entry['cleaned_transcript'] = File.basename(cleaned_candidates.first) if cleaned_candidates.any?
    v_entry['audio_features'] = entry['audio_features'] if entry['audio_features']
    v_entry['speech_analysis'] = entry['speech_analysis'] if entry['speech_analysis']
    pool_videos << v_entry
  end

  if pool_videos.any?
    library['videos'] = pool_videos
    File.write(library_yaml_path, library.to_yaml)
    videos = library['videos']
    $stderr.puts "  Registered #{pool_videos.size} source(s) in library.yaml from pool index"
  end

  # Mine mode continues into shared pipeline below (Phase 1.4 → 2 → D.2.5 → 3 → 4)
  $stderr.puts "\n  Mine mode ingestion complete — continuing to shared pipeline..."
end

# --- Auto-register top-level videos from --pool-dir (Branch A/B/C) ---
# Mine mode has its own index.yaml registry and exited above. For non-mine
# flows, if the user passed --pool-dir and library.yaml has no videos yet,
# enumerate top-level video files (non-recursive) and register them.
# Subfolders (e.g. 'b roll/', 'assets/') are ignored by design.
if (videos.nil? || videos.empty?) && pool_dir_arg && mode != 'mine'
  pool_scan_dir = File.expand_path(pool_dir_arg)
  if File.directory?(pool_scan_dir)
    video_exts = %w[.mp4 .mov .mkv].freeze
    found = Dir.glob(File.join(pool_scan_dir, '*'))
                .select { |f| File.file?(f) && video_exts.include?(File.extname(f).downcase) }
                .sort_by { |f| File.basename(f) }

    if found.any?
      library['videos'] = found.map { |path| { 'path' => path } }
      File.write(library_yaml_path, library.to_yaml)
      videos = library['videos']
      $stderr.puts "Registered #{found.size} video(s) from --pool-dir:"
      found.each { |f| $stderr.puts "  - #{File.basename(f)}" }
    end
  end
end

abort "No videos in library.yaml\n" \
      "RUN SESSION INTEGRITY: If running inside Claude Code, do not attempt to patch this defect. End the session. Open a dev session to investigate and fix." unless videos && videos.any?

$stderr.puts "Thelma Pipeline — #{library_name}"
$stderr.puts "Videos: #{videos.size} source file(s)"

# --- Load profile ---

profile = profile_name ? load_profile_by_name(profile_name) : load_profile(library_name)
$stderr.puts "Profile: #{profile['name']} (merged with defaults)"

# Language + tone profile warning for non-English content
std_lang = language_override || (library['language'] == 'english' ? 'en' : (library['language'] || 'en'))
if std_lang != 'en' && profile['name'] && !%w[_default].include?(profile['name'])
  $stderr.puts "  WARNING: Language '#{std_lang}' with tone profile '#{profile['name']}' — " \
               "tone profiles are English-tuned and may not apply optimally."
end

# --- Branch detection ---

branch = branch_override

unless branch
  # Auto-detect: Branch A if script_parsed.yaml exists in transcripts_dir
  # (canonical location — parse_script.rb writes it there and
  # arrange_to_script.rb reads it from there). Fall back to library['script_parsed']
  # for legacy library.yaml entries.
  script_parsed_at_transcripts = File.join(transcripts_dir, 'script_parsed.yaml')
  if library['script_parsed'] || File.exist?(script_parsed_at_transcripts)
    branch = 'A'
  else
    branch = 'B'
  end
end

$stderr.puts "Branch: #{branch}#{analyze_only ? ' (analyze-only)' : ''}"

# ============================================================
# PHASE 1: INGEST (per-video)
# ============================================================

phase '1 — Ingest'

# Fail-fast: refuse to proceed if any source has a transcript but no transcript_domain.
# This prevents stale-cache domain mismatches (video-time transcripts treated as WAV time).
videos.each do |v|
  next unless v['transcript'] && !v['transcript'].to_s.empty?
  next if v['transcript_domain']
  source = File.basename(v['path'].to_s)
  abort "PIPELINE ABORT: Source '#{source}' has a transcript but no transcript_domain in library.yaml.\n" \
        "  Run: ruby scripts/normalize_transcript_domain.rb --library #{library_name}\n" \
        "  This ensures all transcripts have a verified time domain before processing."
end

# Track per-video outputs for downstream consumers
per_video_outputs = []

videos.each_with_index do |video, vi|
  video_path = video['path']
  unless File.exist?(video_path.to_s)
    $stderr.puts "  WARNING: Video not found, skipping: #{video_path}"
    next
  end

  basename = File.basename(video_path, File.extname(video_path))
  $stderr.puts "\n  --- Video #{vi + 1}/#{videos.size}: #{basename} ---"

  # Determine the audio source: production audio or video audio
  has_sync = video.key?('sync_audio') && video['sync_audio']
  if has_sync
    production_audio = video['sync_audio']['path']
    treated_basename = File.basename(production_audio, File.extname(production_audio))
  else
    production_audio = nil
    treated_basename = basename
  end

  treated_wav = File.join(transcripts_dir, "#{treated_basename}_treated.wav")

  # 1a. Audio cleanup
  if file_cached?(treated_wav)
    skip 'audio_cleanup', 'treated WAV exists'
  else
    step 'audio_cleanup'
    input = production_audio || video_path
    run_script('audio_cleanup.rb', input, transcripts_dir)
  end

  # 1b. WhisperX transcription
  transcript_name = video['transcript']
  transcript_path = transcript_name ? File.join(transcripts_dir, transcript_name) : nil

  if transcript_path && file_cached?(transcript_path)
    skip 'whisperx', 'transcript exists'
  else
    step 'whisperx transcription'
    whisperx_bin = File.expand_path('~/.thelma/whisperx')
    whisperx_bin = 'whisperx' unless File.exist?(whisperx_bin)
    lang_code = language_override || (library['language'] == 'english' ? 'en' : (library['language'] || 'en'))
    whisper_model = 'turbo'

    whisperx_cmd = "#{Shellwords.shellescape(whisperx_bin)} #{Shellwords.shellescape(treated_wav)} --model #{whisper_model} --language #{lang_code} " \
                   "--output_format json --output_dir #{Shellwords.shellescape(transcripts_dir)} --compute_type int8"
    whisperx_cmd += " --diarize" if diarize
    run_command(whisperx_cmd)

    # Find the generated transcript
    expected = File.join(transcripts_dir, "#{treated_basename}_treated.json")
    if File.exist?(expected)
      transcript_path = expected
      transcript_name = File.basename(expected)
      $stderr.puts "  Transcript: #{transcript_name}"
    else
      abort "PIPELINE ABORT: WhisperX did not produce expected output: #{expected}\n" \
            "RUN SESSION INTEGRITY: If running inside Claude Code, do not attempt to patch this defect. End the session. Open a dev session to investigate and fix."
    end
  end

  # 1c. Audio sync offset (dual-system only)
  if has_sync
    offset = video.dig('sync_audio', 'offset')
    if offset
      skip 'audio_sync_offset', "cached (#{offset}s)"
    else
      step 'audio_sync_offset'
      run_script('audio_sync_offset.rb', video_path, production_audio, library_yaml_path)
    end
  end

  # 1d. Speech analysis (VAD)
  speech_analysis_name = video['speech_analysis']
  speech_analysis_path = speech_analysis_name ? File.join(transcripts_dir, speech_analysis_name) : nil

  if speech_analysis_path && file_cached?(speech_analysis_path)
    skip 'audio_analysis (VAD)', 'speech analysis exists'
  else
    step 'audio_analysis (VAD)'
    audio_input = has_sync ? production_audio : video_path
    run_script('audio_analysis.rb', audio_input, library_yaml_path)
    # Reload library.yaml to pick up cached speech_analysis filename
    library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
    videos = library['videos']
    video = videos[vi]
    speech_analysis_name = video['speech_analysis']
    speech_analysis_path = speech_analysis_name ? File.join(transcripts_dir, speech_analysis_name) : nil
  end

  # Persist transcript filename back to library.yaml
  # (audio_analysis.rb already persists speech_analysis, but whisperx doesn't)
  lib_snap = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
  v_entry = lib_snap['videos'][vi]
  if transcript_name && !v_entry['transcript']
    v_entry['transcript'] = transcript_name
    v_entry['transcript_domain'] = 'wav'  # orchestrator always transcribes from treated WAV
    File.write(library_yaml_path, lib_snap.to_yaml)
  end

  per_video_outputs << {
    video_path: video_path,
    treated_wav: treated_wav,
    transcript_path: transcript_path,
    speech_analysis_path: speech_analysis_path,
    has_sync: has_sync,
    production_audio: production_audio
  }
end

# Reload library.yaml after all per-video processing (scripts may have updated it)
library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
videos = library['videos']

# For downstream phases that need a single reference, use first video
first_video = videos.first
first_output = per_video_outputs.first
video_path = first_video['path']
transcript_path = first_output&.dig(:transcript_path)
speech_analysis_path = first_output&.dig(:speech_analysis_path)
treated_wav = first_output&.dig(:treated_wav)
has_sync = first_output&.dig(:has_sync) || false

$stderr.puts "\nPhase 1 complete: #{per_video_outputs.size}/#{videos.size} videos processed"

# ============================================================
# BRANCH A: LEAN SCRIPT-DRIVEN FLOW
# ============================================================
# After Phase 1 ingest, Branch A runs its own short pipeline:
#   parse_script.rb  -> script_parsed.yaml  (LLM, hash-cached)
#   audio_prosody.rb -> prosody.yaml        (algorithmic, mtime-cached)
#   per beat (driven by --filter / --short):
#     arrange_to_script.rb  -> arrangement_<beat_id>.yaml
#     export_arrangement_xml.rb -> <library>_<beat_id>.xml
#
# Branch A does NOT call: detect_content_type, classification,
# semantic_dedup, audio_emotion, detect_scenes, extract_visual_frames,
# semantic_ingest, arrange.rb, export_packaging_brief.

if branch == 'A'
  phase 'A — Script Parse'
  script_parsed_path = File.join(transcripts_dir, 'script_parsed.yaml')

  project_dir = File.dirname(video_path)
  script_files = Dir.glob(File.join(project_dir, '*.{txt,md,pdf,docx}'))
                    .reject { |f| f.include?('output/') || f.include?('_treated') || f.include?('_cleaned') }
  abort "Branch A but no script file found in #{project_dir}. Add a .txt/.md/.pdf/.docx script or pass --branch B." if script_files.empty?

  # parse_script.rb does its own source_hash check and exits fast on cache hit
  step 'parse_script (hash-checked)'
  ps_args = [script_files.first, transcripts_dir]
  ps_args += ['--llm-mode', llm_mode] if llm_mode
  run_script('parse_script.rb', *ps_args)
  abort "parse_script did not produce #{script_parsed_path}" unless File.exist?(script_parsed_path)

  phase 'A — Prosody'
  prosody_path = File.join(library_dir, 'prosody.yaml')
  sa_mtimes = videos.map { |v|
    sa_name = v['speech_analysis']
    sa_path = sa_name ? File.join(transcripts_dir, sa_name) : nil
    sa_path && File.exist?(sa_path) ? File.mtime(sa_path) : nil
  }.compact
  prosody_current = file_cached?(prosody_path) && sa_mtimes.any? && File.mtime(prosody_path) >= sa_mtimes.max
  if prosody_current
    skip 'audio_prosody', 'prosody.yaml newer than speech analysis'
  else
    step 'audio_prosody'
    run_script('audio_prosody.rb', '--library', library_name)
  end

  phase 'A — Beat Selection'
  script_parsed = YAML.safe_load(File.read(script_parsed_path), permitted_classes: [Date])
  all_beats = script_parsed['beats'] || []

  # Whole-script run: loop over every top-level script tree node (parent == nil).
  # Each is a bb_3-sized arrange call, then the adapter combines them into one
  # multi-chapter YAML for a single export. This avoids the 16K max_tokens cliff
  # of a single whole-transcript call and degrades gracefully on per-beat failure.
  is_whole_script_mode = filter_expr.nil?
  beat_ids = if filter_expr
    filter_key, filter_value = parse_filter_expr(filter_expr)
    matched = select_beats_for_filter(all_beats, filter_key, filter_value)
    abort "No beats matched filter '#{filter_expr}'" if matched.empty?
    matched.map { |b| b['id'] }
  else
    top_level = all_beats.select { |b| b['parent'].nil? }
    abort "Whole-script run: script_parsed.yaml has no top-level beats (parent==nil)" if top_level.empty?
    top_level.map { |b| b['id'] }
  end
  mode_label = is_whole_script_mode ? '(whole-script — top-level nodes)' : "(#{filter_expr})"
  $stderr.puts "Filter: #{mode_label} -> #{beat_ids.size} beat(s): #{beat_ids.join(', ')}"

  # ── Phase A.1: Arrange per beat (uniform for whole-script and filter modes)
  phase 'A — Arrange (per beat)'
  arrange_failed = []
  arrange_succeeded_paths = []  # in beat_ids order, only the successful ones

  beat_ids.each_with_index do |beat_id, i|
    $stderr.puts "\n--- [#{i + 1}/#{beat_ids.size}] Arrange: #{beat_id} ---"
    arrangement_path = File.join(library_dir, "arrangement_#{beat_id}.yaml")

    if file_cached?(arrangement_path) && !force
      skip "arrange_to_script (#{beat_id})", "arrangement_#{beat_id}.yaml exists"
      arrange_succeeded_paths << arrangement_path
      next
    end

    step "arrange_to_script (#{beat_id})"
    ats_flags = ['--library', library_name, '--short', beat_id]
    ats_flags += ['--profile', profile_name] if profile_name
    ats_flags += ['--llm-mode', llm_mode] if llm_mode
    ats_flags << '--no-review' if no_review
    _, ok, code = try_run_script('arrange_to_script.rb', *ats_flags)
    if ok && File.exist?(arrangement_path)
      arrange_succeeded_paths << arrangement_path
    else
      $stderr.puts "  FAILED: arrange_to_script for '#{beat_id}' (exit #{code})"
      arrange_failed << beat_id
    end
  end

  # ── Phase A.2: Adapt + Export
  # Whole-script: one combined chapters yaml -> one XML.
  # Per-beat: per-arrangement chapters yaml -> per-arrangement XML (existing).
  phase 'A — Adapt + Export'
  export_failed = []
  exported_xml_names = []

  if is_whole_script_mode
    if arrange_succeeded_paths.empty?
      $stderr.puts "  All beats failed arrangement — nothing to export."
    else
      chapters_path = File.join(library_dir, "#{library_name}_chapters.yaml")
      xml_name      = library_name
      xml_path      = File.join(File.dirname(video_path), 'output', "#{xml_name}.xml")

      # Adapter cache: chapters newer than every input arrangement?
      sources_max_mtime = arrange_succeeded_paths.map { |p| File.mtime(p) }.max
      adapter_current   = file_cached?(chapters_path) && File.mtime(chapters_path) >= sources_max_mtime
      if adapter_current && !force
        skip 'arrangement_adapter (whole-script combine)', 'chapters yaml newer than all arrangements'
      else
        step "arrangement_adapter (combine #{arrange_succeeded_paths.size} arrangements)"
        begin
          ArrangementAdapter.convert_files!(arrange_succeeded_paths, script_parsed_path, chapters_path)
        rescue => e
          $stderr.puts "  FAILED: arrangement_adapter combine: #{e.message}"
          export_failed << '(combined)'
        end
      end

      if !export_failed.include?('(combined)')
        if file_cached?(xml_path) && !force
          skip "export_arrangement_xml (#{xml_name})", "#{xml_name}.xml exists"
          exported_xml_names << xml_name
        else
          step "export_arrangement_xml (#{xml_name})"
          exp_flags = ['--library', library_name,
                       '--arrangement', chapters_path,
                       '--output-name', xml_name]
          exp_flags += ['--profile', profile_name] if profile_name
          _, ok, code = try_run_script('export_arrangement_xml.rb', *exp_flags)
          if ok
            exported_xml_names << xml_name
          else
            $stderr.puts "  FAILED: export_arrangement_xml for '#{xml_name}' (exit #{code})"
            export_failed << xml_name
          end
        end
      end
    end
  else
    # Per-beat mode: one chapters + one XML per arrangement.
    arrange_succeeded_paths.each do |arrangement_path|
      beat_id       = File.basename(arrangement_path, '.yaml').sub(/^arrangement_/, '')
      chapters_path = File.join(library_dir, "#{beat_id}_chapters.yaml")
      xml_name      = "#{library_name}_#{beat_id}"
      xml_path      = File.join(File.dirname(video_path), 'output', "#{xml_name}.xml")

      adapter_current = file_cached?(chapters_path) && File.mtime(chapters_path) >= File.mtime(arrangement_path)
      if adapter_current && !force
        skip "arrangement_adapter (#{beat_id})", 'chapters yaml newer than arrangement'
      else
        step "arrangement_adapter (#{beat_id})"
        begin
          ArrangementAdapter.convert_file!(arrangement_path, script_parsed_path, chapters_path)
        rescue => e
          $stderr.puts "  FAILED: arrangement_adapter for '#{beat_id}': #{e.message}"
          export_failed << beat_id
          next
        end
      end

      if file_cached?(xml_path) && !force
        skip "export_arrangement_xml (#{beat_id})", "#{xml_name}.xml exists"
        exported_xml_names << xml_name
        next
      end

      step "export_arrangement_xml (#{beat_id})"
      exp_flags = ['--library', library_name,
                   '--arrangement', chapters_path,
                   '--output-name', xml_name]
      exp_flags += ['--profile', profile_name] if profile_name
      _, ok, code = try_run_script('export_arrangement_xml.rb', *exp_flags)
      if ok
        exported_xml_names << xml_name
      else
        $stderr.puts "  FAILED: export_arrangement_xml for '#{beat_id}' (exit #{code})"
        export_failed << beat_id
      end
    end
  end

  $stderr.puts "\n#{'=' * 60}"
  $stderr.puts 'BRANCH A LEAN PIPELINE COMPLETE'
  $stderr.puts "  Arranged: #{arrange_succeeded_paths.size}/#{beat_ids.size}"
  $stderr.puts "  Exported: #{exported_xml_names.size} XML(s): #{exported_xml_names.join(', ')}" unless exported_xml_names.empty?
  if arrange_failed.any?
    $stderr.puts "  Arrange failed: #{arrange_failed.size} (#{arrange_failed.join(', ')})"
  end
  if export_failed.any?
    $stderr.puts "  Export failed: #{export_failed.size} (#{export_failed.join(', ')})"
  end
  $stderr.puts '=' * 60
  exit((arrange_failed.any? || export_failed.any?) ? 1 : 0)
end

# ============================================================
# PHASE 0: CONTENT TYPE DETECTION
# ============================================================

phase '0 — Content Type Detection'

existing_ct = library['content_type']
if existing_ct && existing_ct['detected']
  skip 'detect_content_type', "#{existing_ct['detected']} (#{existing_ct['source']})"
else
  step 'detect_content_type'
  profile_flag = profile_name ? ['--profile', profile_name] : []
  run_script('detect_content_type.rb', *profile_flag, library_yaml_path)
  # Reload library to pick up content_type
  library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
end

# ============================================================
# PHASE 1.25: PROSODY (Branch B/C)
# ============================================================

phase '1.25 — Prosody'
prosody_path = File.join(library_dir, 'prosody.yaml')
sa_mtimes = videos.map { |v|
  sa_name = v['speech_analysis']
  sa_path = sa_name ? File.join(transcripts_dir, sa_name) : nil
  sa_path && File.exist?(sa_path) ? File.mtime(sa_path) : nil
}.compact
prosody_current = file_cached?(prosody_path) && sa_mtimes.any? && File.mtime(prosody_path) >= sa_mtimes.max
if prosody_current
  skip 'audio_prosody', 'prosody.yaml newer than speech analysis'
else
  step 'audio_prosody'
  run_script('audio_prosody.rb', '--library', library_name)
end

# ============================================================
# PHASE 1.35: SEMANTIC SEGMENTATION (per-source, LLM)
# ============================================================

phase '1.35 — Semantic Segmentation'

videos.each_with_index do |v, vi|
  source_filename = File.basename(v['path'])
  source_basename = File.basename(v['path'], File.extname(v['path']))
  seg_output = File.join(transcripts_dir, "#{source_basename}_semantic_segments.yaml")

  if file_cached?(seg_output) && !force_cascade
    skip "semantic_segment (#{source_filename})", 'semantic segments exist'
  else
    step "semantic_segment (#{source_filename})"
    cmd_args = ['--library', library_name, '--source', source_filename]
    cmd_args += ['--profile', profile_name] if profile_name
    cmd_args += ['--llm-mode', llm_mode] if llm_mode
    run_script('semantic_segment.rb', *cmd_args)
  end
end

# ============================================================
# PHASE 1.4: EXTRACT SEGMENTS (deterministic, no LLM)
# ============================================================

phase '1.4 — Extract Segments'

classified_path = File.join(library_dir, 'segments_classified.yaml')

step 'extract_segments'
run_script('extract_segments.rb', '--library', library_name)

# ============================================================
# PHASE 1.5c: AUDIO EMOTION (per-video)
# ============================================================

phase '1.5c — Audio Emotion'

# Multi-video strategy: audio_emotion.rb matches segments by time proximity.
# When multiple sources exist, we must split segments_classified.yaml per-source
# to avoid cross-source time collisions, run audio_emotion against each source's
# slice, then merge results back.

all_seg_data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])
all_segments = all_seg_data['segments'] || []
multi_source = videos.size > 1

videos.each_with_index do |v, vi|
  v_basename = File.basename(v['path'], File.extname(v['path']))
  source_filename = File.basename(v['path'])

  if v['audio_features']
    skip "audio_emotion (#{v_basename})", 'cached in library.yaml'
    next
  end

  pvo = per_video_outputs[vi]
  tw = pvo&.dig(:treated_wav)
  unless tw && file_cached?(tw)
    skip "audio_emotion (#{v_basename})", 'no treated WAV available'
    next
  end

  step "audio_emotion (#{v_basename})"

  if multi_source
    # Split: write temp YAML with only this source's segments
    source_segs = all_segments.select { |s| s['source'] == source_filename }
    tmp_yaml = File.join(library_dir, ".tmp_audio_emotion_#{v_basename}.yaml")
    tmp_data = all_seg_data.merge('segments' => source_segs)
    File.write(tmp_yaml, YAML.dump(tmp_data))

    run_script('audio_emotion.rb', tw, tmp_yaml, library_yaml_path)

    # Merge: read enriched segments from tmp, update main data
    enriched = YAML.safe_load(File.read(tmp_yaml), permitted_classes: [Date])
    enriched_by_id = {}
    (enriched['segments'] || []).each { |s| enriched_by_id[s['id']] = s }
    all_segments.each do |s|
      next unless enriched_by_id[s['id']]
      es = enriched_by_id[s['id']]
      %w[audio_profile audio_energy audio_energy_variance audio_pitch_mean
         audio_pitch_range audio_pitch_trend audio_speaking_rate
         audio_spectral_centroid acoustic_pattern].each do |field|
        s[field] = es[field] if es[field]
      end
    end
    File.delete(tmp_yaml) if File.exist?(tmp_yaml)
  else
    run_script('audio_emotion.rb', tw, classified_path, library_yaml_path)
  end

  # Reload library.yaml after audio_emotion caches its output
  library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
  videos = library['videos']
end

# Write merged results back for multi-source case
if multi_source
  all_seg_data['segments'] = all_segments
  File.write(classified_path, YAML.dump(all_seg_data))
end

# Merge per-segment prosody summaries (if prosody.yaml exists)
prosody_merge_path = File.join(library_dir, 'prosody.yaml')
if file_cached?(prosody_merge_path) && file_cached?(classified_path)
  step 'merge_prosody_segments'
  run_script('merge_prosody_segments.rb', classified_path, prosody_merge_path)
else
  skip 'merge_prosody_segments', 'prosody.yaml or segments_classified.yaml missing'
end

# ============================================================
# PHASE 1.5d: SCENE DETECTION + VISUAL ANALYSIS
# ============================================================

phase '1.5d — Scene Detection + Visual Analysis'

scene_changes_path = File.join(library_dir, 'scene_changes.yaml')
if file_cached?(scene_changes_path)
  skip 'scene_detection', 'scene_changes.yaml exists'
else
  step 'scene_detection'
  run_script('detect_scenes.rb', '--library', library_name, '--output', scene_changes_path)
end

# Per-shot visual frame extraction (produces visual_analysis.yaml + sampled frames)
first_video_basename = File.basename(video_path || '', File.extname(video_path || ''))
va_path = File.join(transcripts_dir, "#{first_video_basename}_visual_analysis.yaml")
if !force_revisualize && file_cached?(va_path)
  skip 'extract_visual_frames', 'visual_analysis.yaml exists'
else
  if video_path && File.exist?(video_path)
    step 'extract_visual_frames'
    va_flags = ['--library', library_name, '--video', video_path]
    va_flags << '--force' if force_revisualize
    run_script('extract_visual_frames.rb', *va_flags)
  else
    skip 'extract_visual_frames', 'video file not accessible'
  end
end

visual_name = first_video['visual_transcript']
if visual_name && visual_name.to_s.strip != ''
  skip 'visual_analysis', 'visual_transcript exists'
else
  step 'visual_analysis'
  $stderr.puts "  NOTE: Visual analysis requires Claude vision. Run analyze-video skill separately."
  if file_cached?(va_path)
    $stderr.puts "  Per-shot frames ready: #{va_path}"
  end
  $stderr.puts "  Continuing without visual transcript."
end

# Branch C is deprecated — caught earlier in CLI validation.
# (Branch C scripts remain in tree but are removed from active routing.)

# ============================================================
# PHASE 2: DISCOVERY PASS (LLM — replaces classify + semantic_ingest)
# ============================================================

phase '2 — Discovery Pass'

discovery_pass_path = File.join(library_dir, 'discovery_pass.yaml')

step 'discovery_pass'
flags = ['--library', library_name]
flags += ['--profile', profile_name] if profile_name
flags += ['--llm-mode', llm_mode] if llm_mode
flags += ['--duration', duration_target] if duration_target
flags << '--no-review' if no_review
run_script('discovery_pass.rb', *flags, forward_stdin: true)

# Verify selected_thesis exists (review gate sets it)
dp_data = YAML.safe_load(File.read(discovery_pass_path), permitted_classes: [Date])
unless dp_data['selected_thesis']
  abort "PIPELINE ABORT: No thesis selected in discovery_pass.yaml — review gate did not complete"
end

# ============================================================
# PHASE D.2.5: REGISTER POOL SOURCES (Branch D only)
# ============================================================

if mode == 'mine'
  phase 'D.2.5 — Register Pool Sources'
  step 'register_pool_sources'
  run_script('register_pool_sources.rb', '--library', library_name)
  # Reload library.yaml after source registration
  library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
  videos = library['videos']
end

# ============================================================
# PHASE 3: ARRANGEMENT (thesis-driven)
# ============================================================

phase '3 — Arrangement'

arrangement_path = File.join(library_dir, 'arrangement.yaml')
if file_cached?(arrangement_path)
  skip 'arrange', 'arrangement.yaml exists'
else
  step 'arrange'
  flags = ['--library', library_name]
  flags += ['--profile', profile_name] if profile_name
  flags += ['--llm-mode', llm_mode] if llm_mode
  flags << '--no-review' if no_review
  run_script('arrange.rb', *flags)
end

# ============================================================
# PHASE 4: EXPORT & BUILD
# ============================================================

phase '4 — Export & Build'

step 'export_arrangement_xml'
flags = ['--library', library_name]
flags += ['--profile', profile_name] if profile_name
xml_path = run_script('export_arrangement_xml.rb', *flags)

# ============================================================
# PHASE 5: PACKAGING BRIEF
# ============================================================

phase '5 — Packaging Brief'

if profile.fetch('generate_packaging_brief', true)
  step "export_packaging_brief"
  flags = ['--library', library_name, '--output', xml_path]
  flags += ['--profile', profile_name] if profile_name
  flags += ['--llm-mode', llm_mode] if llm_mode
  flags << '--no-review' if no_review
  run_script('export_packaging_brief.rb', *flags)
end

$stderr.puts "\n#{'=' * 60}"
$stderr.puts "PIPELINE COMPLETE"
$stderr.puts "  XML: #{xml_path}"
$stderr.puts '=' * 60

puts xml_path
exit 0

# Legacy phases (1.6-4 storyline flow, Branch C, old classify()) removed in Session 3.
# See docs/SESSION_3_SPEC.md §9 for deprecation details.
