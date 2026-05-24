# Thelma CLI Reference

Auto-generated from source. Every flag listed below exists in code.

> **v4.1 (Session 3):** Branch C, `classify()`, and the legacy Branch D candidate-selection scripts (`discover_arcs`, `present_candidates`, `convert_candidate`) are deprecated. See VISION.md.

---

## Orchestrator

### `scripts/orchestrate.rb`

Deterministic pipeline runner. Replaces SKILL.md as pipeline brain. Checks cache at each step, skips completed phases, aborts loud on failure.

```
ruby scripts/orchestrate.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--profile` | string | auto-detected | Creator profile name |
| `--branch` | `A\|B` | auto-detected (`A` if `script_parsed` exists, else `B`) | Pipeline branch override. Branch C deprecated in v4.1 |
| `--no-review` | boolean | `false` | Skip interactive review gates |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |
| `--mode` | `mine` | `nil` | Activates pool-based mining pipeline |
| `--force-reindex` | boolean | `false` | Force re-scan of all pool sources (mine mode) |
| `--force-rediscover` | boolean | `false` | Bypass arc discovery cache (mine mode) |
| `--discover-only` | boolean | `false` | Stop after pool indexing (mine mode) |
| `--duration` | string | `nil` | Target runtime for discovery pass (e.g. `7:30`). Filters theses to ±30s of target |
| `--force-cascade` | boolean | `false` | Force regeneration of downstream outputs (mine mode) |
| `--force-revisualize` | boolean | `false` | Regenerate visual analysis even if cached |
| `--pool-dir` | string | `nil` | Pool folder path. Auto-creates library if missing. For Branch A/B/C, also auto-registers top-level `.mp4`/`.mov`/`.mkv` files into `library.yaml['videos']` when empty (subfolders ignored). For mine mode, triggers pool indexing via `index.yaml`. |
| `--language` | string | from `library.yaml` | Language code override (e.g. `en`, `es`) |
| `--diarize` | boolean | `false` | Enable speaker diarization in WhisperX. Requires `HF_TOKEN` env var |

**Positional args:** none.

**Downstream calls (Branch B pipeline):**

| Phase | Script called | Flags forwarded |
|-------|--------------|-----------------|
| 1 — Ingest | `audio_cleanup.rb` | positional: `<input> <output_dir>` |
| 1 — Ingest | WhisperX (external) | `--model turbo --language <code>` (`--diarize` if `--diarize` set) |
| 1 — Ingest | `audio_sync_offset.rb` | positional: `<video> <audio> <library.yaml>` |
| 1 — Ingest | `audio_analysis.rb` | positional: `<input> <library.yaml>` |
| 0 — Content Type | `detect_content_type.rb` | positional: `<library.yaml>`, `--profile` |
| 1.25 — Prosody | `audio_prosody.rb` | `--library` |
| 1.35 — Semantic Segmentation | `semantic_segment.rb` | `--library`, `--source`, `--profile`, `--llm-mode`, `--force` |
| 1.4 — Extract Segments | `extract_segments.rb` | `--library` |
| 1.5c — Audio Emotion | `audio_emotion.rb` | positional: `<wav> <classified.yaml> <library.yaml>` |
| 1.5d — Scene Detection | `detect_scenes.rb` | `--library`, `--output` |
| 1.5d — Visual Analysis | `extract_visual_frames.rb` | `--library`, `--video`, `--force` |
| 2 — Discovery Pass | `discovery_pass.rb` | `--library`, `--profile`, `--llm-mode`, `--duration`, `--no-review` |
| 3 — Arrangement | `arrange.rb` | `--library`, `--profile`, `--llm-mode`, `--no-review` |
| 4 — Export | `export_arrangement_xml.rb` | `--library`, `--profile` |
| 5 — Packaging Brief | `export_packaging_brief.rb` | `--library`, `--output`, `--profile`, `--llm-mode`, `--no-review` |

**Downstream calls (mine mode / Branch D):**

| Phase | Script called | Flags forwarded |
|-------|--------------|-----------------|
| D.0 — Pool Indexing | `audio_cleanup.rb` | positional: `<input> <transcripts_dir>` |
| D.0 — Pool Indexing | WhisperX (external) | `--model turbo --language <code>` (`--diarize` if `--diarize` set) |
| D.0 — Pool Indexing | `detect_scenes.rb` | positional: `<video>`, `--output` |
| D.0 — Pool Indexing | `extract_visual_frames.rb` | `--library`, `--video`, `--scene-file`, `--force` |
| D.0 — HQ Audio | `match_hq_audio.rb` | `--library` |
| 1.4 — Extract Segments | `extract_segments.rb` | `--library` |
| 1.5c — Audio Emotion | `audio_emotion.rb` | positional: `<wav> <classified.yaml> <library.yaml>` |
| 2 — Discovery Pass | `discovery_pass.rb` | `--library`, `--profile`, `--llm-mode`, `--duration`, `--no-review` |
| D.2.5 — Pool Sources | `register_pool_sources.rb` | `--library` |
| 3 — Arrangement | `arrange.rb` | `--library`, `--profile`, `--llm-mode`, `--no-review` |
| 4 — Export | `export_arrangement_xml.rb` | `--library`, `--profile` |

**Branch A:** Unchanged in Session 3 — has its own lean pipeline (parse_script → prosody → arrange_to_script per beat → export).

**Branch C:** Deprecated as of v4.1. `--analyze-only` and `--branch C` error with deprecation message.

---

## Ingest Phase

### `scripts/audio_cleanup.rb`

Extracts audio from video, applies noise reduction (highpass 80Hz) and loudness normalization (two-pass), outputs treated WAV for transcription.

```
ruby scripts/audio_cleanup.rb <input_video> <output_dir>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<input_video>` | string | **required** — path to input video or audio file |
| `<output_dir>` | string | **required** — directory to write `<basename>_treated.wav` |

**Flags:** none.

**Called by:** `orchestrate.rb` (Phase 1, mine mode).

---

### `scripts/audio_analysis.rb`

Runs Silero VAD speech analysis on an audio or video file. Caches results in library.yaml if provided.

```
ruby scripts/audio_analysis.rb <audio_or_video_path> [library.yaml]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<audio_or_video_path>` | string | **required** — path to input file |
| `[library.yaml]` | string | optional — path to library.yaml for caching |

**Flags:** none.

**Called by:** `orchestrate.rb` (Phase 1).

---

### `scripts/audio_sync_offset.rb`

Finds sync offset between a video's scratch audio and an external audio file using FFT cross-correlation.

```
ruby scripts/audio_sync_offset.rb <video_path> <audio_path> [library.yaml]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<video_path>` | string | **required** — path to video file |
| `<audio_path>` | string | **required** — path to external audio file (WAV/FLAC/MP3) |
| `[library.yaml]` | string | optional — path to library.yaml for caching |

**Flags:** none.

**Called by:** `orchestrate.rb` (Phase 1), `match_hq_audio.rb`.

---

### `scripts/transcript_cleanup.rb` *(deprecated)*

**Deprecated as of Session 5.** Replaced by `semantic_segment.rb` (Phase 1.35). No longer called by `orchestrate.rb`. File remains in tree for reference.

---

### `scripts/parse_script.rb`

Parses a script file (.txt, .md, .pdf, .docx) into structured YAML with beats (hook, talking_point, close) for each short.

```
ruby scripts/parse_script.rb <script_file> [output_dir]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<script_file>` | string | **required** — path to script file |
| `[output_dir]` | string | same directory as input | directory to write `script_parsed.yaml` |

**Flags:** none.

**Called by:** `orchestrate.rb` (Branch A only).

---

### `scripts/read_transcript.rb`

Reads a WhisperX JSON transcript and prints formatted segments to stdout.

```
ruby scripts/read_transcript.rb <transcript.json>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<transcript.json>` | string | **required** — path to WhisperX transcript JSON |

**Flags:** none.

**Called by:** standalone utility.

---

## Extract & Enrich Phase

### `scripts/extract_segments.rb`

Phase 1.4 — Deterministic segment extraction. Reads cleaned_transcript.json per source video, writes combined segments_classified.yaml with nil placeholders for enrichment by audio_emotion.rb and merge_prosody_segments.rb.

```
ruby scripts/extract_segments.rb --library <name>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |

**Positional args:** none.

**Output:** `libraries/<name>/segments_classified.yaml`

**Cache:** SHA256 fingerprint of all cleaned transcripts. Stale → invalidates downstream `discovery_pass.yaml` and `arrangement.yaml`.

**Called by:** `orchestrate.rb` (Phase 1.4).

---

## Classify Phase

### `scripts/detect_content_type.rb`

Phase 0 — Content type detection. Analyzes transcript, audio, visual, and metadata signals to automatically detect content type and route downstream defaults.

```
ruby scripts/detect_content_type.rb <library.yaml> [--profile <name>]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<library.yaml>` | string | **required** — path to library.yaml file |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--profile` | string | auto-detected | Creator profile name (overrides detection if `content_type` is set in profile) |

**Called by:** `orchestrate.rb` (Phase 0).

---

---

## Discovery Phase

### `scripts/discovery_pass.rb`

Phase 2 — Discovery pass. Single LLM call. Reads enriched segments_classified.yaml, emits discovery_pass.yaml with ranked thesis candidates, clip_groups, throughlines, and reserved visual_context. Includes interactive review gate for thesis selection.

```
ruby scripts/discovery_pass.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--profile` | string | auto-detected | Creator profile name |
| `--no-review` | boolean | `false` | Auto-select top thesis, skip interactive review |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |
| `--duration` | string | `nil` | Target runtime (e.g. `7:30`). Filters theses to ±30s of target |

**Positional args:** none.

**Output:** `libraries/<name>/discovery_pass.yaml`

**Review gate:** Presents up to 5 theses. User picks by number/id, or 'r' to regenerate (max 3 regenerations), or 'q' to abort.

**Called by:** `orchestrate.rb` (Phase 2, both Branch B and Branch D).

---

### `scripts/register_pool_sources.rb`

Phase D.2.5 — Register pool sources (Branch D only). Reads chosen thesis from discovery_pass.yaml, identifies which pool sources are referenced by clip_groups and throughlines, resolves paths from pool index, and registers in library.yaml.

```
ruby scripts/register_pool_sources.rb --library <name>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |

**Positional args:** none.

**Called by:** `orchestrate.rb` (Phase D.2.5, Branch D only).

---

### `scripts/audio_emotion.rb`

Phase 1.5c — Extracts vocal emotion features from a WAV file using librosa (via Python). Merges audio_profile and acoustic features into segments_classified.yaml.

```
ruby scripts/audio_emotion.rb <wav_path> <segments_classified.yaml> [library.yaml]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<wav_path>` | string | **required** — path to treated WAV file |
| `<segments_classified.yaml>` | string | **required** — path to classified segments YAML |
| `[library.yaml]` | string | optional — path to library.yaml for caching |

**Flags:** none.

**Called by:** `orchestrate.rb` (Phase 1.5c).

---

### `scripts/detect_scenes.rb`

Phase 1.5d — Detect visual scene changes in a video using FFmpeg scene detection. Zero token cost — runs locally.

```
ruby scripts/detect_scenes.rb <video_path> [--threshold 0.3] [--output scene_changes.yaml]
ruby scripts/detect_scenes.rb --library <name>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<video_path>` | string | required (single-video mode) — path to video file |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--threshold` | float | `0.3` | FFmpeg scene detection threshold |
| `--output` | string | `scene_changes.yaml` in video dir or library dir | Output file path |
| `--library` | string | `nil` | Library name (library mode — iterates all videos) |

**Called by:** `orchestrate.rb` (Phase 1.5d, mine mode).

---

### `scripts/extract_visual_frames.rb`

Per-shot frame sampling for visual analysis. Reads scene data to build shot boundaries, extracts 3 representative frames per shot (opening, midpoint, closing).

```
ruby scripts/extract_visual_frames.rb --library <name> --video <video_path> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--video` | string | **required** | Path to video file |
| `--scene-file` | string | `nil` | Path to per-source scene YAML (mine mode). Without this, reads library-level scene_changes.yaml |
| `--force` | boolean | `false` | Regenerate even if cached visual_analysis.yaml exists |

**Called by:** `orchestrate.rb` (Phase 1.5d, mine mode).

---

---

## Arrange Phase

### `scripts/arrange.rb`

Phase 3 — Thesis-driven arrangement. Reads discovery_pass.yaml (chosen thesis + clip_groups + throughlines) and enriched segments_classified.yaml. Produces arrangement.yaml v2 with chapters, throughline_honoring, and unused_segment_audit.

```
ruby scripts/arrange.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--profile` | string | auto-detected | Creator profile name |
| `--no-review` | boolean | `false` | Skip interactive review gate |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |

**Positional args:** none.

**Called by:** `orchestrate.rb` (Phase 3).

---

### `scripts/mine_content.rb`

Content mining mode — inventories raw footage from classified segments.

```
ruby scripts/mine_content.rb <segments_classified.yaml>
ruby scripts/mine_content.rb --library <name>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<segments_classified.yaml>` | string | alternative to `--library` — path to classified segments YAML |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | `nil` | Library name (alternative to positional arg) |

**Called by:** standalone (not part of standard pipeline).

---

---

### `scripts/match_hq_audio.rb`

Detects HQ audio / video transcript pairs in a pool library. Compares transcripts pairwise for word overlap, then runs waveform alignment for exact sync offset.

```
ruby scripts/match_hq_audio.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--overlap-threshold` | float | `0.80` | Jaccard word overlap threshold for pair detection |

**Positional args:** none.

**Calls:** `scripts/audio_sync_offset.rb`.

**Called by:** `orchestrate.rb` (mine mode).

---

## Export Phase

### `scripts/export_arrangement_xml.rb`

Exports an arrangement.yaml to a Premiere Pro XML via build_structure_cut.rb. Maps arrangement clips to structure cut YAML with V1 sequential and V2+ positioned at chapter start offsets.

```
ruby scripts/export_arrangement_xml.rb --library <name> [--profile <name>]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--profile` | string | `nil` | Creator profile name |

**Positional args:** none.

**Calls:** `scripts/build_structure_cut.rb`.

**Called by:** `orchestrate.rb` (Phase 4, mine mode).

---

### `scripts/build_structure_cut.rb`

Builds a structure cut XML from a YAML definition file. Core XML generation engine used by all export paths.

```
ruby scripts/build_structure_cut.rb <yaml_path> [--profile <name>]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<yaml_path>` | string | **required** — path to structure cut YAML definition |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--profile` | string | `nil` | Creator profile name [undocumented — extracted from code] |

**Called by:** `export_arrangement_xml.rb`, `branch_a_batch.rb`, `generate_short_bodies.rb`.

---

### `scripts/export_packaging_brief.rb`

Generates a packaging handoff document alongside the XML. Reads classification, scoring, and audio data to produce thumbnail/title direction, hook analysis, peak map, and structural notes.

```
ruby scripts/export_packaging_brief.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** (unless `--library-dir`) | Library name |
| `--library-dir` | string | `nil` | **(deprecated)** Direct library directory path. Use `--library <name>` instead |
| `--output` | string | auto-detected (latest arrangement XML in output dir) | Path to the exported XML file |
| `--profile` | string | auto-detected | Creator profile name |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |
| `--no-review` | boolean | `false` | Accepted for CLI consistency, no-op in this script |

**Positional args:** none.

**Called by:** `orchestrate.rb` (Phase 5, legacy phases).

---

---

## Batch & Special Workflows

### `scripts/branch_a_batch.rb`

Batch Branch A (script-driven) processing. Sequential forward-only hook discovery across ordered video transcripts. Produces one XML per short.

```
ruby scripts/branch_a_batch.rb --library <library-name> [--shorts 1..5]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--shorts` | string (range) | all shorts in script | Range of shorts to process, e.g. `1..5` |

**Positional args:** none.

**Calls:** `scripts/build_structure_cut.rb`.

**Called by:** standalone (not part of standard pipeline).

---

### `scripts/generate_short_bodies.rb`

Generates body-only XMLs for 30 shorts from batch recordings.

```
ruby scripts/generate_short_bodies.rb --library <library-name>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |

**Positional args:** none.

**Calls:** `scripts/build_structure_cut.rb`.

**Called by:** standalone (interactive — prompts for approval).

---

### `scripts/rebuild_clips_from_cleaned.rb`

Rebuilds a structure cut YAML by splitting clips to exclude segments that were removed by transcript_cleanup.rb.

```
ruby scripts/rebuild_clips_from_cleaned.rb <structure.yaml> <raw_transcript.json> <cleaned_transcript.json>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<structure.yaml>` | string | **required** — path to existing structure cut YAML |
| `<raw_transcript.json>` | string | **required** — path to raw WhisperX transcript |
| `<cleaned_transcript.json>` | string | **required** — path to cleaned transcript |

**Flags:** none.

**Called by:** standalone utility.

---

## Profile & Template Tools

### `scripts/extract_creator_profile.rb`

Extracts cross-video creator profile from accumulated reports.

```
ruby scripts/extract_creator_profile.rb --name <name> [report1.yaml report2.yaml ...]
ruby scripts/extract_creator_profile.rb --creator <name>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<report.yaml ...>` | string(s) | glob-aware report paths (minimum 2 required unless `--creator` auto-discovers) |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--name` / `--creator` | string | **required** | Creator name (also used for auto-discovery of reports) |
| `--output-dir` | string | `profiles/creators/` | Output directory for profile YAML |

**Called by:** standalone (not part of standard pipeline).

---

### `scripts/extract_template.rb`

Phase 2.1 — Template extraction pipeline. Extracts story structure template from multiple classified segment files.

```
ruby scripts/extract_template.rb <seg1.yaml> <seg2.yaml> <seg3.yaml> [...] [options]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<seg.yaml ...>` | string(s) | **minimum 3 required** — paths to classified segment YAML files |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--label` | string | `nil` | Human-readable label for the template |
| `--update` | string | `nil` | Path to existing template to merge into |
| `--category` | string | `nil` | Subdirectory category for template storage |

**Called by:** standalone (not part of standard pipeline).

---

### `scripts/extract_edit_patterns.rb`

Aggregates overlay patterns from parsed finished edits.

```
ruby scripts/extract_edit_patterns.rb --library <name>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |

**Called by:** standalone (run after `parse_finished_edit.rb`).

---

### `scripts/parse_finished_edit.rb`

Parses a finished Premiere XML export. Extracts overlay placements and correlates with classified segments to build production design memory.

```
ruby scripts/parse_finished_edit.rb --library <name> --finished <exported_xml_path>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--finished` | string | **required** | Path to exported Premiere XML |

**Called by:** standalone (not part of standard pipeline).

---

## Migration & Utilities

### `scripts/migrate_library.rb`

Migrates a library from `~/thelma/libraries/<name>/` to `<pool_dir>/.thelma/` and registers in libraries_registry.yaml.

```
ruby scripts/migrate_library.rb --library <name> [--dry-run]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--dry-run` | boolean | `false` | Show what would happen without making changes |

**Called by:** standalone utility.

---

### `scripts/001_migrate_0.2_to_0.3.rb`

Migration script: converts full transcript paths to filenames in library.yaml (v0.2 → v0.3 format).

```
ruby scripts/001_migrate_0.2_to_0.3.rb [library_name]
ruby scripts/001_migrate_0.2_to_0.3.rb --all
```

| Positional | Type | Description |
|-----------|------|-------------|
| `[library_name]` | string | optional — specific library to migrate |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--all` | boolean | `false` | Migrate all libraries |

**Called by:** standalone migration.

---

## Helper Modules (not CLI scripts)

These are `require`-d by other scripts and have no CLI interface.

### `scripts/pool_index.rb`

Module `PoolIndex`. Manages `libraries/<pool>/index.yaml`: source files, SHA256 fingerprints, processing state. Methods: `.load`, `.save`, `.scan_pool`, `.add_source`, `.mark_ingested`, `.set_hq_pair`, `.compute_sha256`, `.detect_media_type`, `.probe_duration`.

### `scripts/library_resolver.rb`

Module `LibraryResolver`. Central library directory resolution. Priority: `ENV['THELMA_LIBRARY_DIR']` → registry (`libraries_registry.yaml`) → legacy fallback (`~/thelma/libraries/<name>/`). Methods: `.resolve`, `.register`.

### `scripts/llm_client.rb`

Module `LLMClient`. LLM interaction abstraction. Supports `api` mode (Anthropic API direct) and `claude_code` mode (pending file workflow). Handles prompt caching, model routing, and pending/resume flow.

### `scripts/load_profile.rb`

Module providing `load_profile`, `load_profile_by_name`, `load_tone_guide`, `build_tone_context`, `build_compact_tone_context`, `effective_content_type`. Loads creator profiles from `profiles/` with `_default.yaml` merge.

---

## lib/buttercut/ (Ruby Gem — no CLI)

Library code for XML generation. No CLI interface — used programmatically by `build_structure_cut.rb`.

| File | Purpose |
|------|---------|
| `lib/buttercut.rb` | Factory class. `ButterCut.generate(editor:, clips:, ...)` dispatches to editor-specific generator |
| `lib/buttercut/editor_base.rb` | Shared validation, metadata extraction (FFprobe), timeline math, clip merging |
| `lib/buttercut/fcp7.rb` | FCP7/Premiere/DaVinci Resolve implementation (xmeml version 5) |
| `lib/buttercut/fcpx.rb` | Final Cut Pro X implementation (FCPXML 1.8) |
| `lib/buttercut/version.rb` | Gem version constant |

---

## Deprecated (v4.1)

Scripts below are kept in tree but removed from active orchestrate.rb routing.

### Branch C scripts (will be redesigned in P5)

- `scripts/discover_storylines.rb` — Phase 1.6 storyline discovery
- `scripts/match_templates.rb` — Phase 1.7 template matching
- `scripts/detect_structure.rb` — Phase 1.7.5 adaptive structure detection
- `scripts/score_coherence.rb` — Phase 1.8 coherence scoring
- `scripts/sanity_check.rb` — Phase 1.9 pre-build sanity check
- `scripts/generate_report.rb` — Branch C report generation
- `scripts/extract_template.rb` — template extraction from classified segments

### Branch D legacy scripts (replaced in Session 3)

- `scripts/discover_arcs.rb` — replaced by `discovery_pass.rb`
- `scripts/present_candidates.rb` — replaced by discovery_pass review gate
- `scripts/convert_candidate.rb` — arrangement-building absorbed by `arrange.rb`; source-registration extracted into `register_pool_sources.rb`
- `scripts/semantic_ingest.rb` — replaced by `discovery_pass.rb`
- `scripts/validate_classification.rb` — no longer needed (extract_segments.rb is deterministic)
- `scripts/semantic_dedup.rb` — no longer needed (discovery_pass handles dedup internally)
