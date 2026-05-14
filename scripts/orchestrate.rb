#!/usr/bin/env ruby
# Thelma Pipeline Orchestrator
# Deterministic pipeline runner. Replaces SKILL.md as pipeline brain.
# Checks cache at each step, skips completed phases, aborts loud on failure.
#
# Usage:
#   ruby scripts/orchestrate.rb --library <name> [--profile <name>] [--branch A|B|C] [--analyze-only]
#
# --analyze-only is shorthand for --branch C.
# Branch C runs Phases 1-1.8, generates report, exits without arrangement or XML.

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
  else
    abort "Unknown argument: #{args.first}\n" \
          "Usage: ruby scripts/orchestrate.rb --library <name> [--profile <name>] [--branch A|B|C] [--analyze-only] [--no-review] [--llm-mode api|claude_code] [--mode mine] [--force-reindex] [--force-rediscover] [--discover-only] [--candidate <id>] [--force-cascade] [--force-revisualize] [--pool-dir <path>] [--language <code>] [--filter <expr>] [--short <id>] [--force]"
  end
end

abort "Usage: ruby scripts/orchestrate.rb --library <name> [--profile <name>] [--branch A|B|C] [--analyze-only] [--no-review] [--llm-mode api|claude_code] [--mode mine] [--force-reindex] [--force-rediscover] [--discover-only] [--candidate <id>] [--force-cascade] [--force-revisualize] [--pool-dir <path>] [--language <code>] [--filter <expr>] [--short <id>] [--force]" unless library_name

# --short is shorthand for --filter id=<id>. --filter wins if both are set.
filter_expr = "id=#{short_id_arg}" if short_id_arg && filter_expr.nil?

LLMClient.mode = llm_mode.to_sym if llm_mode

branch_override = 'C' if analyze_only

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

def run_script(script, *args)
  cmd = ['ruby', File.join(SCRIPTS_DIR, script)] + args.map(&:to_s)
  $stderr.puts "  $ #{cmd.join(' ')}"
  stdout, stderr, status = Open3.capture3(*cmd)
  $stderr.puts stderr unless stderr.strip.empty?
  if status.exitstatus == 2
    $stderr.puts "PIPELINE PAUSED: #{script} awaiting LLM input"
    exit 2
  end
  unless status.success?
    abort "\nPIPELINE ABORT: #{script} failed (exit #{status.exitstatus})\n#{stderr}"
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
        if ENV['HF_TOKEN'] && !ENV['HF_TOKEN'].strip.empty?
          whisperx_cmd += " --diarize"
        else
          $stderr.puts "  NOTE: HF_TOKEN not set — skipping diarization. Set HF_TOKEN for speaker labels."
        end
        run_command(whisperx_cmd)
        abort "PIPELINE ABORT: WhisperX did not produce: #{expected_transcript}" unless File.exist?(expected_transcript)
      end
      attrs[:transcript_file] = File.basename(expected_transcript) if File.exist?(expected_transcript)

      # Extract speaker info from diarized transcript
      if File.exist?(expected_transcript)
        t_data = JSON.parse(File.read(expected_transcript)) rescue {}
        speakers = (t_data['segments'] || []).map { |s| s['speaker'] }.compact.uniq.sort
        attrs[:diarization_enabled] = ENV['HF_TOKEN'] && !ENV['HF_TOKEN'].strip.empty? ? true : false
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

  # Arc discovery — discover_arcs.rb handles its own cache check internally
  phase 'MINE — Arc Discovery'
  discover_flags = ['--library', library_name]
  discover_flags += ['--profile', profile_name] if profile_name
  discover_flags += ['--llm-mode', llm_mode]    if llm_mode
  discover_flags << '--force-rediscover'         if force_rediscover
  arc_candidates_path = run_script('discover_arcs.rb', *discover_flags)
  # run_script propagates exit 2 (Claude Code pending) automatically

  # ── Discover-only exit ────────────────────────────────────────────────────
  if discover_only
    $stderr.puts "\n#{'=' * 60}"
    $stderr.puts "ARC DISCOVERY COMPLETE (--discover-only)"
    $stderr.puts "  Index:      #{PoolIndex.index_path(library_dir)}"
    $stderr.puts "  Candidates: #{arc_candidates_path}"
    $stderr.puts '=' * 60
    puts arc_candidates_path
    exit 0
  end

  arc_data   = YAML.safe_load(File.read(arc_candidates_path), permitted_classes: [Date])
  mine_candidates = arc_data['candidates'] || []
  abort "No arc candidates found — re-run arc discovery" if mine_candidates.empty?

  selected_candidate_id = candidate_id

  # ── Interactive candidate selection ───────────────────────────────────────
  unless selected_candidate_id
    phase 'MINE — Candidate Selection'
    system('ruby', File.join(SCRIPTS_DIR, 'present_candidates.rb'), '--library', library_name)
    abort "Failed to display candidates" unless $?.success?
    print "\nSelect [1-#{mine_candidates.size}] or (q)uit: "
    $stdout.flush
    input = $stdin.gets&.strip
    if input.nil? || input.downcase == 'q'
      $stderr.puts "No candidate selected — pipeline paused."
      exit 0
    end
    idx = input.to_i - 1
    abort "Invalid selection: #{input}" if idx < 0 || idx >= mine_candidates.size
    selected_candidate_id = mine_candidates[idx]['id']
  end

  $stderr.puts "  Candidate: #{selected_candidate_id}"

  # ── Convert candidate → arrangement.yaml ──────────────────────────────────
  phase 'MINE — Candidate Conversion'
  convert_flags = ['--library', library_name, '--candidate', selected_candidate_id]
  convert_flags += ['--profile', profile_name] if profile_name
  convert_flags << '--force' if force_cascade
  run_script('convert_candidate.rb', *convert_flags)

  # ── Export XML ────────────────────────────────────────────────────────────
  phase 'MINE — Export XML'
  export_flags = ['--library', library_name]
  export_flags += ['--profile', profile_name] if profile_name
  mine_xml_path = run_script('export_arrangement_xml.rb', *export_flags)

  $stderr.puts "\n#{'=' * 60}"
  $stderr.puts "MINE PIPELINE COMPLETE"
  $stderr.puts "  Candidate: #{selected_candidate_id}"
  $stderr.puts "  XML:       #{mine_xml_path}"
  pickup_md = File.join(library_dir, 'pickup_recording_suggestions.md')
  $stderr.puts "  Pickups:   #{pickup_md}" if File.exist?(pickup_md)
  $stderr.puts '=' * 60
  puts mine_xml_path
  exit 0
end

abort "No videos in library.yaml" unless videos && videos.any?

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
  # Auto-detect: Branch A if script_parsed exists, else Branch B
  script_parsed_path = File.join(library_dir, 'script_parsed.yaml')
  if library['script_parsed'] || File.exist?(script_parsed_path)
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
    if ENV['HF_TOKEN'] && !ENV['HF_TOKEN'].strip.empty?
      whisperx_cmd += " --diarize"
    else
      $stderr.puts "  NOTE: HF_TOKEN not set — skipping diarization. Set HF_TOKEN for speaker labels."
    end
    run_command(whisperx_cmd)

    # Find the generated transcript
    expected = File.join(transcripts_dir, "#{treated_basename}_treated.json")
    if File.exist?(expected)
      transcript_path = expected
      transcript_name = File.basename(expected)
      $stderr.puts "  Transcript: #{transcript_name}"
    else
      abort "PIPELINE ABORT: WhisperX did not produce expected output: #{expected}"
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

  # 1e. Transcript cleanup
  cleaned_name = video['cleaned_transcript']
  cleaned_path = cleaned_name ? File.join(transcripts_dir, cleaned_name) : nil

  if cleaned_path && file_cached?(cleaned_path)
    skip 'transcript_cleanup', 'cleaned transcript exists'
  else
    step 'transcript_cleanup'
    sa_flag = speech_analysis_path && file_cached?(speech_analysis_path) ? ['--speech-analysis', speech_analysis_path, '--protect-rhetorical'] : []
    run_script('transcript_cleanup.rb', transcript_path, *sa_flag)
  end

  per_video_outputs << {
    video_path: video_path,
    treated_wav: treated_wav,
    transcript_path: transcript_path,
    speech_analysis_path: speech_analysis_path,
    cleaned_path: cleaned_path,
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
cleaned_path = first_output&.dig(:cleaned_path)
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

  beat_ids = if filter_expr
    filter_key, filter_value = parse_filter_expr(filter_expr)
    matched = select_beats_for_filter(all_beats, filter_key, filter_value)
    abort "No beats matched filter '#{filter_expr}'" if matched.empty?
    matched.map { |b| b['id'] }
  else
    ['all']  # arrange_to_script handles 'all' as the whole-tree case
  end
  $stderr.puts "Filter: #{filter_expr || '(none — whole tree)'} -> #{beat_ids.size} beat(s): #{beat_ids.join(', ')}"

  phase 'A — Arrange + Export'
  failed_beats = []
  succeeded_beats = []

  beat_ids.each_with_index do |beat_id, i|
    $stderr.puts "\n--- [#{i + 1}/#{beat_ids.size}] Beat: #{beat_id} ---"

    arrangement_path = File.join(library_dir, "arrangement_#{beat_id}.yaml")
    xml_name = "#{library_name}_#{beat_id}"
    xml_path = File.join(File.dirname(video_path), 'output', "#{xml_name}.xml")

    # ── Arrange
    if file_cached?(arrangement_path) && !force
      skip "arrange_to_script (#{beat_id})", "arrangement_#{beat_id}.yaml exists"
    else
      step "arrange_to_script (#{beat_id})"
      ats_flags = ['--library', library_name, '--short', beat_id]
      ats_flags += ['--profile', profile_name] if profile_name
      ats_flags += ['--llm-mode', llm_mode] if llm_mode
      ats_flags << '--no-review' if no_review
      _, ok, code = try_run_script('arrange_to_script.rb', *ats_flags)
      unless ok
        $stderr.puts "  FAILED: arrange_to_script for '#{beat_id}' (exit #{code})"
        failed_beats << beat_id
        next
      end
    end

    # ── Export
    if file_cached?(xml_path) && !force
      skip "export_arrangement_xml (#{beat_id})", "#{xml_name}.xml exists"
      succeeded_beats << beat_id
      next
    end

    step "export_arrangement_xml (#{beat_id})"
    exp_flags = ['--library', library_name,
                 '--arrangement', arrangement_path,
                 '--output-name', xml_name]
    exp_flags += ['--profile', profile_name] if profile_name
    _, ok, code = try_run_script('export_arrangement_xml.rb', *exp_flags)
    unless ok
      $stderr.puts "  FAILED: export_arrangement_xml for '#{beat_id}' (exit #{code})"
      failed_beats << beat_id
      next
    end
    succeeded_beats << beat_id
  end

  $stderr.puts "\n#{'=' * 60}"
  $stderr.puts "BRANCH A LEAN PIPELINE COMPLETE"
  $stderr.puts "  Succeeded: #{succeeded_beats.size}/#{beat_ids.size} (#{succeeded_beats.join(', ')})"
  if failed_beats.any?
    $stderr.puts "  Failed:    #{failed_beats.size} (#{failed_beats.join(', ')})"
    $stderr.puts '=' * 60
    exit 1
  end
  $stderr.puts '=' * 60
  exit 0
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
# PHASE 1.5: CLASSIFICATION
# ============================================================

phase '1.5 — Classification'

classified_path = File.join(library_dir, 'segments_classified.yaml')

if file_cached?(classified_path)
  # Verify hash matches current transcript
  existing = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])
  current_transcript = cleaned_path && file_cached?(cleaned_path) ? cleaned_path : transcript_path
  current_hash = Digest::MD5.hexdigest(File.read(current_transcript)) if current_transcript
  cached_hash = existing['transcript_hash']

  if cached_hash && current_hash && cached_hash == current_hash
    skip 'classification', 'segments_classified.yaml matches transcript hash'
  else
    step 'classification (hash mismatch — re-running)'
    classify(current_transcript, classified_path, profile)
  end
else
  step 'classification (LLM call)'
  current_transcript = cleaned_path && file_cached?(cleaned_path) ? cleaned_path : transcript_path
  classify(current_transcript, classified_path, profile)
end

# Validate classification
step 'validate_classification'
run_script('validate_classification.rb', classified_path)

# Semantic dedup (Branch B only)
if branch == 'B'
  deduped_path = File.join(library_dir, 'segments_deduped.yaml')
  if file_cached?(deduped_path)
    skip 'semantic_dedup', 'segments_deduped.yaml exists'
  else
    step 'semantic_dedup'
    run_script('semantic_dedup.rb', classified_path)
  end
  # Use deduped for downstream if available
  segments_path = file_cached?(deduped_path) ? deduped_path : classified_path
else
  segments_path = classified_path
end

# ============================================================
# PHASE 1.5c: AUDIO EMOTION (per-video)
# ============================================================

phase '1.5c — Audio Emotion'

videos.each_with_index do |v, vi|
  v_basename = File.basename(v['path'], File.extname(v['path']))
  if v['audio_features']
    skip "audio_emotion (#{v_basename})", 'cached in library.yaml'
  else
    pvo = per_video_outputs[vi]
    tw = pvo&.dig(:treated_wav)
    if tw && file_cached?(tw)
      step "audio_emotion (#{v_basename})"
      run_script('audio_emotion.rb', tw, classified_path, library_yaml_path)
      # Reload library.yaml after audio_emotion caches its output
      library = YAML.safe_load(File.read(library_yaml_path), permitted_classes: [Date])
      videos = library['videos']
    else
      skip "audio_emotion (#{v_basename})", 'no treated WAV available'
    end
  end
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

# ============================================================
# BRANCH C: GENERATE REPORT AND EXIT
# ============================================================

if branch == 'C'
  # Continue through storyline scoring before generating report

  phase '1.6 — Storyline Discovery'
  storylines_path = File.join(library_dir, 'storylines.yaml')
  if file_cached?(storylines_path)
    skip 'discover_storylines', 'storylines.yaml exists'
  else
    step 'discover_storylines'
    profile_flag = profile_name ? ['--profile', profile_name] : []
    run_script('discover_storylines.rb', segments_path, '--library', library_yaml_path, *profile_flag)
  end

  phase '1.7 — Template Matching'
  matched_path = File.join(library_dir, 'storylines_matched.yaml')
  storylines_file = file_cached?(storylines_path) ? storylines_path : File.join(library_dir, 'storylines.yaml')
  step 'match_templates'
  profile_flag = profile_name ? ['--profile', profile_name] : []
  run_script('match_templates.rb', storylines_file, classified_path, *profile_flag)

  phase '1.7.5 — Adaptive Structure Detection'
  matched_data_c = YAML.safe_load(File.read(File.join(library_dir, 'storylines_matched.yaml')), permitted_classes: [Date])
  matched_storylines_c = matched_data_c['storylines'] || []
  best_fit_c = matched_storylines_c.map { |s| s.dig('template_match', 'fit_score').to_i }.max || 0
  has_longform_c = matched_storylines_c.any? { |s| s['profile'] == 'best_single_longform' }

  if best_fit_c < 70 || !has_longform_c
    step 'detect_structure (prompts only — Branch C)'
    $stderr.puts "  Trigger: best_fit=#{best_fit_c}% (threshold: 70%), longform=#{has_longform_c}"
    structure_path_c = File.join(library_dir, 'structure_detected.yaml')
    unless file_cached?(structure_path_c)
      run_script('detect_structure.rb', segments_path, '--best-fit-score', best_fit_c.to_s)
    end
    $stderr.puts "  Prompts generated. LLM synthesis deferred (Branch C is analyze-only)."
  else
    skip 'detect_structure', "best_fit=#{best_fit_c}% >= 70% and longform exists"
  end

  phase '1.8 — Coherence Scoring'
  matched_file = File.join(library_dir, 'storylines_matched.yaml')
  step 'score_coherence (algorithmic only)'
  profile_flag = profile_name ? ['--profile', profile_name] : []
  run_script('score_coherence.rb', '--no-llm', *profile_flag, matched_file, classified_path)

  phase 'C — Generate Report'
  step 'generate_report'
  profile_flag = profile_name ? ['--profile', profile_name] : []
  report_path = run_script('generate_report.rb', library_dir, *profile_flag)

  $stderr.puts "\n#{'=' * 60}"
  $stderr.puts "PIPELINE COMPLETE (Branch C — analyze-only)"
  $stderr.puts "Report: #{report_path}"
  $stderr.puts '=' * 60
  puts report_path
  exit 0
end

# ============================================================
# PHASE 2: SEMANTIC INGEST
# ============================================================

phase '2 — Semantic Ingest'

semantic_ingest_path = File.join(library_dir, 'semantic_ingest.yaml')
if file_cached?(semantic_ingest_path)
  skip 'semantic_ingest', 'semantic_ingest.yaml exists'
else
  step 'semantic_ingest'
  flags = ['--library', library_name]
  flags += ['--profile', profile_name] if profile_name
  flags += ['--llm-mode', llm_mode] if llm_mode
  flags << '--no-review' if no_review
  run_script('semantic_ingest.rb', *flags)
end

# ============================================================
# PHASE 3: ARRANGEMENT
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

# ============================================================
# LEGACY PHASES (1.6-4): Storyline-based arrangement flow
# Kept for reference. Unreachable in default pipeline.
# Use --branch C for analyze-only, or invoke scripts directly.
# ============================================================

# ============================================================
# PHASE 1.6: STORYLINE DISCOVERY
# ============================================================

phase '1.6 — Storyline Discovery'

storylines_path = File.join(library_dir, 'storylines.yaml')
if file_cached?(storylines_path)
  skip 'discover_storylines', 'storylines.yaml exists'
else
  step 'discover_storylines'
  profile_flag = profile_name ? ['--profile', profile_name] : []
  run_script('discover_storylines.rb', segments_path, '--library', library_yaml_path, *profile_flag)
end

# ============================================================
# PHASE 1.7: TEMPLATE MATCHING
# ============================================================

phase '1.7 — Template Matching'

step 'match_templates'
profile_flag = profile_name ? ['--profile', profile_name] : []
run_script('match_templates.rb', storylines_path, classified_path, *profile_flag)

# ============================================================
# PHASE 1.7.5: ADAPTIVE STRUCTURE DETECTION (conditional)
# ============================================================

phase '1.7.5 — Adaptive Structure Detection'

matched_data = YAML.safe_load(File.read(File.join(library_dir, 'storylines_matched.yaml')), permitted_classes: [Date])
matched_storylines = matched_data['storylines'] || []

best_fit = matched_storylines.map { |s| s.dig('template_match', 'fit_score').to_i }.max || 0
has_longform = matched_storylines.any? { |s| s['profile'] == 'best_single_longform' }

if best_fit < 70 || !has_longform
  step 'detect_structure'
  $stderr.puts "  Trigger: best_fit=#{best_fit}% (threshold: 70%), longform=#{has_longform}"

  structure_path = File.join(library_dir, 'structure_detected.yaml')
  unless file_cached?(structure_path)
    run_script('detect_structure.rb', segments_path, '--best-fit-score', best_fit.to_s)
  end

  # Agent fills viability + synthesis via LLM, then saves template
  detected = YAML.safe_load(File.read(structure_path), permitted_classes: [Date])

  if detected['viability'].nil?
    # Run viability check
    pending_dir = File.join(library_dir, 'pending_llm_calls')
    begin
      viability_response = LLMClient.call(detected['viability_prompt'], call_type: 'structure_detection', profile: profile, max_tokens: 200,
                                          pending_dir: pending_dir, call_name: 'structure_viability')
    rescue LLMClient::Pending => e
      $stderr.puts e.message
      exit 2
    end
    viability_line = viability_response.strip.lines.first&.strip || ''
    detected['viability'] = viability_line.split(' — ').first&.strip
    detected['viability_reason'] = viability_response.strip.lines[1]&.strip
    File.write(structure_path, detected.to_yaml)
  end

  if %w[YES PARTIAL].include?(detected['viability']) && detected['synthesized_template'].nil?
    # Run synthesis
    pending_dir = File.join(library_dir, 'pending_llm_calls')
    begin
      synthesis_response = LLMClient.call(detected['synthesis_prompt'], call_type: 'structure_detection', profile: profile, max_tokens: 1000,
                                          pending_dir: pending_dir, call_name: 'structure_synthesis')
    rescue LLMClient::Pending => e
      $stderr.puts e.message
      exit 2
    end
    # Parse YAML from response
    yaml_match = synthesis_response.match(/```yaml\n(.*?)```/m)
    if yaml_match
      detected['synthesized_template'] = YAML.safe_load(yaml_match[1])
      File.write(structure_path, detected.to_yaml)

      # Save template and re-match
      run_script('detect_structure.rb', segments_path, '--save-template', structure_path)
      step 're-match templates with synthesized template'
      run_script('match_templates.rb', storylines_path, classified_path, *profile_flag)
    end
  end
else
  skip 'detect_structure', "best_fit=#{best_fit}% >= 70% and longform exists"
end

# ============================================================
# PHASE 1.8: COHERENCE SCORING
# ============================================================

phase '1.8 — Coherence Scoring'

matched_path = File.join(library_dir, 'storylines_matched.yaml')
step 'score_coherence'
profile_flag = profile_name ? ['--profile', profile_name] : []
run_script('score_coherence.rb', *profile_flag, matched_path, classified_path)

# ============================================================
# PHASE 1.9: SANITY CHECK
# ============================================================

phase '1.9 — Sanity Check'

scored_path = File.join(library_dir, 'storylines_scored.yaml')
step 'sanity_check'
profile_flag = profile_name ? ['--profile', profile_name] : []
run_script('sanity_check.rb', *profile_flag, scored_path, segments_path)

# ============================================================
# PHASE 2: USER SELECTION (Interactive)
# ============================================================

phase '2 — Storyline Selection'

scored_data = YAML.safe_load(File.read(scored_path), permitted_classes: [Date])
storylines = scored_data['storylines'] || []
passing = storylines.select { |s| s['passed_floor'] }

if passing.empty?
  $stderr.puts "  No candidates passed quality floor (combined >= 60)."
  $stderr.puts "  Showing all candidates:"
  passing = storylines.sort_by { |s| -(s['combined_score'] || 0) }
end

$stderr.puts "\n  Available storyline candidates:"
passing.each_with_index do |s, i|
  tm = s['template_match'] || {}
  $stderr.puts "    #{i + 1}. #{s['id']} — score #{s['combined_score']}"
  $stderr.puts "       Template: #{tm['template']} (#{tm['completeness']}% complete)"
  $stderr.puts "       Duration: ~#{(s['duration_estimate'].to_f / 60).round(1)} min"
end

$stderr.puts "\n  Select candidates (comma-separated numbers, or 'all'):"
$stderr.print "  > "
selection = $stdin.gets&.strip

selected = if selection == 'all' || selection.nil? || selection.empty?
  passing
else
  indices = selection.split(',').map { |s| s.strip.to_i - 1 }
  indices.map { |i| passing[i] }.compact
end

if selected.empty?
  abort "PIPELINE ABORT: No candidates selected."
end

$stderr.puts "  Selected: #{selected.map { |s| s['id'] }.join(', ')}"

# ============================================================
# PHASE 3: ARRANGEMENT + BUILD
# ============================================================

phase '3 — Arrangement & Build'

project_dir = File.dirname(video_path)
output_dir = File.join(project_dir, 'output')
FileUtils.mkdir_p(output_dir)

editor = library['editor'] || 'fcp7'
editor = 'fcp7' if editor == 'premiere'

selected.each do |storyline|
  step "arranging #{storyline['id']}"

  # Reconstruct segment list from classification
  classified_data = YAML.safe_load(File.read(classified_path), permitted_classes: [Date])
  all_segments = classified_data['segments'] || []
  seg_by_t = {}
  all_segments.each { |s| seg_by_t[s['t'].to_f] = s }

  hook_t = storyline['hook_segment'].to_f
  close_t = storyline['close_segment']&.to_f

  hook_seg = seg_by_t[hook_t]
  close_seg = close_t ? seg_by_t[close_t] : nil

  body_segs = if close_t
    all_segments.select { |s| s['t'].to_f > hook_t && s['t'].to_f < close_t }
  else
    all_segments.select { |s| s['t'].to_f > hook_t }
  end.sort_by { |s| s['t'].to_f }

  # Build clips in chronological order
  clips = []
  ordered = []
  ordered << hook_seg if hook_seg
  ordered += body_segs
  ordered << close_seg if close_seg

  # Filter: cut signposts, low-confidence tertiary-only segments
  ordered = ordered.select do |seg|
    next true if seg == hook_seg || seg == close_seg # always keep hook/close
    next true if (seg['distillation'] || '').downcase.match?(/next video|free training|check out|link in|subscribe|comment below|sign up|download|click|follow me/) # CTA preservation
    next false if seg['signpost'] # cut signposts
    next false if seg['confidence'] == 'low' && seg['roles'] == ['tertiary']
    true
  end

  # Determine time domain
  time_key_start = has_sync ? 'audio_start' : 'video_start'
  time_key_end = has_sync ? 'audio_end' : 'video_end'

  ordered.each do |seg|
    clips << { time_key_start => seg['t'].to_f, time_key_end => seg['e'].to_f }
  end

  # Determine output format
  output_format = storyline['id'].include?('short') ? 'vertical_short' : 'match_source'

  # Build structure cut YAML
  yaml_name = "#{library_name}_#{storyline['id']}"
  yaml_path = File.join(output_dir, "#{yaml_name}.yaml")

  structure_cut = {
    'video_path' => video_path,
    'output_dir' => output_dir,
    'editor' => editor,
    'name' => yaml_name,
    'output_format' => output_format,
    'clips' => clips,
    'markers' => [],
    'classification' => classified_path
  }

  # Add sync audio if dual-system
  if has_sync
    structure_cut['sync_audio'] = {
      'path' => video.dig('sync_audio', 'path'),
      'offset' => video.dig('sync_audio', 'offset')
    }
  end

  # Add speech analysis if available
  if speech_analysis_path && file_cached?(speech_analysis_path)
    structure_cut['speech_analysis'] = speech_analysis_path
  end

  # Add edit patterns if available
  edit_patterns_path = File.join(library_dir, 'edit_patterns.yaml')
  if file_cached?(edit_patterns_path)
    structure_cut['edit_patterns'] = edit_patterns_path
  end

  File.write(yaml_path, structure_cut.to_yaml)
  $stderr.puts "  YAML: #{yaml_path}"

  # Build XML
  step "build_structure_cut #{yaml_name}"
  profile_flag = profile_name ? ['--profile', profile_name] : []
  run_script('build_structure_cut.rb', yaml_path, *profile_flag)
end

# ============================================================
# PHASE 4: PRESENT
# ============================================================

phase '4 — Output'

xml_files = Dir.glob(File.join(output_dir, '*.xml')).sort_by { |f| File.mtime(f) }.last(selected.size)

$stderr.puts "\n  Built #{selected.size} structure cut(s):"
xml_files.each do |xml|
  $stderr.puts "    #{xml}"
end

# Export packaging briefs
if profile.fetch('generate_packaging_brief', true)
  xml_files.each do |xml_path|
    step "export_packaging_brief #{File.basename(xml_path)}"
    profile_flag = profile_name ? ['--profile', profile_name] : []
    run_script('export_packaging_brief.rb',
      '--library-dir', library_dir,
      '--output', xml_path,
      *profile_flag)
  end
end

$stderr.puts "\n  Import into #{library['editor'] || 'Premiere'} via File > Import"

$stderr.puts "\n#{'=' * 60}"
$stderr.puts "PIPELINE COMPLETE (Branch #{branch})"
$stderr.puts '=' * 60

puts xml_files.join("\n")

# --- Classification helper ---
BEGIN {
  def classify(transcript_path, output_path, profile)
    abort "PIPELINE ABORT: No transcript found for classification" unless transcript_path && File.exist?(transcript_path)

    transcript_data = JSON.parse(File.read(transcript_path))
    segments = transcript_data['segments'] || []
    abort "PIPELINE ABORT: No segments in transcript" if segments.empty?

    transcript_hash = Digest::MD5.hexdigest(File.read(transcript_path))

    states_list = %w[vindication outrage awe competence fear schadenfreude amusement
                     catharsis nostalgia belonging escape calm aspiration sensual curiosity]

    # Chunk segments to avoid hitting output token limits.
    # ~100 segments per chunk keeps output well under 16k tokens.
    chunk_size = 100
    chunks = segments.each_slice(chunk_size).to_a
    all_classified_segments = []

    $stderr.puts "  Classification: #{segments.size} segments in #{chunks.size} chunk(s)"

    chunks.each_with_index do |chunk, ci|
      chunk_lines = chunk.map { |s|
        "[#{s['start']&.round(2)}-#{s['end']&.round(2)}] #{s['text']&.strip}"
      }.join("\n")

      chunk_label = chunks.size > 1 ? " (chunk #{ci + 1}/#{chunks.size})" : ""

      prompt = <<~PROMPT
        You are classifying video transcript segments using the Content Psychopharmacology framework.

        For each segment below, produce a JSON object with a "segments" array. Each entry has:
        - "t": start time (seconds, number)
        - "e": end time (seconds, number)
        - "states": array of 1-3 strings from: #{states_list.join(', ')}
        - "distillation": 5-word max summary of WHAT the segment says (the idea, not delivery)
        - "signal": short description of the visible/verbal element triggering the state
        - "dur": "spike" (momentary), "mood" (emotional tone), or "identity" (lasting impact)
        - "roles": array from ["primary", "secondary", "tertiary"] — content importance
        - "notes": 10-word max editorial note
        - "rationale": 5-15 word explanation of why these states
        - "confidence": "high", "medium", or "low"
        - "signpost": true if meta-commentary announcing content without delivering it, false otherwise

        Rules:
        - Skip segments under 3 seconds or obvious filler (um, uh, false starts)
        - Primary state is FIRST in the states array
        - distillation must be 5 words or fewer
        - Keep numbers literal in distillation

        Transcript segments#{chunk_label}:
        #{chunk_lines}

        Respond with ONLY valid JSON. No markdown fences. Start directly with {"segments": [
      PROMPT

      pending_dir = File.join(File.dirname(output_path), 'pending_llm_calls')
      call_name = chunks.size > 1 ? "classification_chunk_#{ci + 1}" : 'classification'
      begin
        response = LLMClient.call(prompt, call_type: 'classification', profile: profile,
                                  pending_dir: pending_dir, call_name: call_name,
                                  max_tokens: 16_384)
      rescue LLMClient::Pending => e
        $stderr.puts e.message
        exit 2
      end

      # Extract JSON from response (strip markdown fences if present)
      json_text = response.gsub(/\A```(?:json)?\s*/, '').gsub(/```\s*\z/, '').strip

      begin
        chunk_classified = JSON.parse(json_text)
      rescue JSON::ParserError => e
        abort "PIPELINE ABORT: Classification LLM returned invalid JSON#{chunk_label}\n#{e.message}\n\nResponse:\n#{json_text[0..500]}"
      end

      chunk_segments = chunk_classified['segments'] || []
      $stderr.puts "  Chunk #{ci + 1}: #{chunk_segments.size} segments classified"
      all_classified_segments.concat(chunk_segments)
    end

    classified = {
      'transcript_hash' => transcript_hash,
      'recording' => File.basename(transcript_path),
      'classified_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
      'segments' => all_classified_segments
    }

    File.write(output_path, classified.to_yaml)
    $stderr.puts "  Classification saved: #{output_path} (#{all_classified_segments.size} segments)"
  end
}
