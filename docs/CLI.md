# Thelma CLI Reference

Auto-generated from source. Every flag listed below exists in code.

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
| `--branch` | `A\|B\|C` | auto-detected (`A` if `script_parsed` exists, else `B`) | Pipeline branch override |
| `--analyze-only` | boolean | `false` | Shorthand for `--branch C` |
| `--no-review` | boolean | `false` | Skip interactive review gates |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |
| `--mode` | `mine` | `nil` | Activates pool-based mining pipeline |
| `--force-reindex` | boolean | `false` | Force re-scan of all pool sources (mine mode) |
| `--force-rediscover` | boolean | `false` | Bypass arc discovery cache (mine mode) |
| `--discover-only` | boolean | `false` | Stop after arc discovery, skip candidate selection (mine mode) |
| `--candidate` | string | `nil` | Pre-select candidate ID, skip interactive selection (mine mode) |
| `--force-cascade` | boolean | `false` | Force regeneration of downstream outputs (mine mode) |
| `--force-revisualize` | boolean | `false` | Regenerate visual analysis even if cached |
| `--pool-dir` | string | `nil` | Pool folder path for auto-creating new library |
| `--language` | string | from `library.yaml` | Language code override (e.g. `en`, `es`) |

**Positional args:** none.

**Downstream calls (standard pipeline, Branch A/B):**

| Phase | Script called | Flags forwarded |
|-------|--------------|-----------------|
| 1 — Ingest | `audio_cleanup.rb` | positional: `<input> <output_dir>` |
| 1 — Ingest | WhisperX (external) | `--model turbo --language <code>` |
| 1 — Ingest | `audio_sync_offset.rb` | positional: `<video> <audio> <library.yaml>` |
| 1 — Ingest | `audio_analysis.rb` | positional: `<input> <library.yaml>` |
| 1 — Ingest | `transcript_cleanup.rb` | positional: `<transcript.json>`, `--speech-analysis`, `--protect-rhetorical` |
| 1 — Ingest | `parse_script.rb` | positional: `<script_file> <output_dir>` (Branch A only) |
| 0 — Content Type | `detect_content_type.rb` | positional: `<library.yaml>`, `--profile` |
| 1.5 — Classification | `validate_classification.rb` | positional: `<segments_classified.yaml>` |
| 1.5 — Classification | `semantic_dedup.rb` | positional: `<segments_classified.yaml>` (Branch B only) |
| 1.5c — Audio Emotion | `audio_emotion.rb` | positional: `<wav> <classified.yaml> <library.yaml>` |
| 1.5d — Scene Detection | `detect_scenes.rb` | `--library`, `--output` |
| 1.5d — Visual Analysis | `extract_visual_frames.rb` | `--library`, `--video`, `--force` |
| 2 — Semantic Ingest | `semantic_ingest.rb` | `--library`, `--profile`, `--llm-mode`, `--no-review` |
| 3 — Arrangement | `arrange.rb` | `--library`, `--profile`, `--llm-mode`, `--no-review` |
| 4 — Export | `export_arrangement_xml.rb` | `--library`, `--profile` |
| 5 — Packaging Brief | `export_packaging_brief.rb` | `--library`, `--output`, `--profile`, `--llm-mode`, `--no-review` |

**Downstream calls (Branch C — analyze-only):**

| Phase | Script called | Flags forwarded |
|-------|--------------|-----------------|
| 1.6 | `discover_storylines.rb` | positional: `<segments>`, `--library`, `--profile` |
| 1.7 | `match_templates.rb` | positional: `<storylines> <classified>`, `--profile` |
| 1.7.5 | `detect_structure.rb` | positional: `<segments>`, `--best-fit-score` |
| 1.8 | `score_coherence.rb` | `--no-llm`, `--profile`, positional: `<matched> <classified>` |
| C | `generate_report.rb` | positional: `<library_dir>`, `--profile` |

**Downstream calls (mine mode):**

| Phase | Script called | Flags forwarded |
|-------|--------------|-----------------|
| Pool Indexing | `audio_cleanup.rb` | positional: `<input> <transcripts_dir>` |
| Pool Indexing | WhisperX (external) | `--model turbo --language <code>` |
| Pool Indexing | `detect_scenes.rb` | positional: `<video>`, `--output` |
| Pool Indexing | `extract_visual_frames.rb` | `--library`, `--video`, `--scene-file`, `--force` |
| HQ Audio | `match_hq_audio.rb` | `--library` |
| Arc Discovery | `discover_arcs.rb` | `--library`, `--profile`, `--llm-mode`, `--force-rediscover` |
| Candidate Selection | `present_candidates.rb` | `--library` |
| Candidate Conversion | `convert_candidate.rb` | `--library`, `--candidate`, `--profile`, `--force` |
| Export | `export_arrangement_xml.rb` | `--library`, `--profile` |

**Legacy phases (1.6–4):** Unreachable in default pipeline. Kept in source for reference. Includes interactive storyline selection, `sanity_check.rb`, and per-storyline `build_structure_cut.rb` calls.

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

### `scripts/transcript_cleanup.rb`

Cleans a WhisperX transcript JSON by removing duplicate takes, false starts, single-word filler segments, trailing-off patterns, and within-segment stutters.

```
ruby scripts/transcript_cleanup.rb <transcript.json> [--speech-analysis <path>] [--protect-rhetorical]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<transcript.json>` | string | **required** — path to WhisperX transcript JSON |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--speech-analysis` | string | `nil` | Path to Silero speech analysis JSON |
| `--protect-rhetorical` | boolean | `false` | When set with `--speech-analysis`, phrase repeats separated by >250ms silence are treated as rhetorical repetition and kept |

**Called by:** `orchestrate.rb` (Phase 1).

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

### `scripts/validate_classification.rb`

Phase 1.1 — Classification output validator. Validates segments_classified.yaml structure and taxonomy.

```
ruby scripts/validate_classification.rb <segments_classified.yaml>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<segments_classified.yaml>` | string | **required** — path to classified segments YAML |

**Flags:** none.

**Exit codes:** 0=valid, 1=structural error, 2=taxonomy error, 3=data error.

**Called by:** `orchestrate.rb` (Phase 1.5).

---

## Semantic Phase

### `scripts/semantic_ingest.rb`

Phase 1.5 — Semantic ingest pass. Replaces per-segment classification with a unified directorial understanding. One LLM call reads full transcript + audio emotion + visual analysis.

```
ruby scripts/semantic_ingest.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--profile` | string | auto-detected | Creator profile name |
| `--no-review` | boolean | `false` | Skip interactive review gate |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |

**Positional args:** none.

**Called by:** `orchestrate.rb` (Phase 2).

---

### `scripts/semantic_dedup.rb`

Phase 1.5b — Semantic deduplication. Removes near-duplicate segments from classification.

```
ruby scripts/semantic_dedup.rb <segments_classified.yaml>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<segments_classified.yaml>` | string | **required** — path to classified segments YAML |

**Flags:** none.

**Called by:** `orchestrate.rb` (Branch B, Phase 1.5).

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

### `scripts/discover_storylines.rb`

Phase 1.6 — Storyline discovery. Identifies narrative storylines from classified segments.

```
ruby scripts/discover_storylines.rb <segments_classified.yaml> [options]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<segments_classified.yaml>` | string | **required** — path to classified segments YAML |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | `nil` | Path to library.yaml (optional enrichment) |
| `--profile` | string | `nil` | Creator profile name |

**Called by:** `orchestrate.rb` (Branch C, legacy phases).

---

### `scripts/match_templates.rb`

Phase 1.7 — Template matching for storyline candidates. Matches discovered storylines against story structure templates.

```
ruby scripts/match_templates.rb <storylines.yaml> <segments_classified.yaml> [options]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<storylines.yaml>` | string | **required** — path to storylines YAML |
| `<segments_classified.yaml>` | string | **required** — path to classified segments YAML |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--profile` | string | `nil` | Creator profile name |
| `--extra-template` | string | `nil` | Path to additional template YAML to include in matching |

**Called by:** `orchestrate.rb` (Branch C, legacy phases).

---

### `scripts/detect_structure.rb`

Phase 1.9.4 — Adaptive structure detection. Detects narrative structure when no existing template scores above threshold. Two-pass design: viability check then ad-hoc template synthesis.

```
ruby scripts/detect_structure.rb <segments_classified.yaml> [options]
ruby scripts/detect_structure.rb --save-template <structure_detected.yaml> [--category <name>]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<segments_classified.yaml>` | string | **required** (normal mode) — path to classified segments YAML |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--best-fit-score` | integer | `nil` | Best existing template fit score (context for reporting) |
| `--save-template` | string | `nil` | Path to completed `structure_detected.yaml` — saves synthesized template to `templates/story_structures/` |
| `--category` | string | `nil` | Subdirectory category for saved template |

**Called by:** `orchestrate.rb` (Phase 1.7.5, Branch C).

---

### `scripts/score_coherence.rb`

Phase 1.8 — Coherence scoring and combined ranking. Scores storyline candidates for coherence and assigns combined rank.

```
ruby scripts/score_coherence.rb <storylines_matched.yaml> <segments_classified.yaml> [options]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<storylines_matched.yaml>` | string | **required** — path to matched storylines YAML |
| `<segments_classified.yaml>` | string | **required** — path to classified segments YAML |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--no-llm` | boolean | `false` | Algorithmic-only mode (skip LLM coherence check) |
| `--profile` | string | auto-detected from directory | Creator profile name |

**Called by:** `orchestrate.rb` (Phase 1.8, Branch C).

---

### `scripts/sanity_check.rb`

Phase 2.5 — Pre-build sanity check. Runs after coherence scoring, before XML generation. Generates review data: shape descriptor, cold-open/close assessment, distilled segments.

```
ruby scripts/sanity_check.rb <storylines_scored.yaml> <segments_file.yaml> [candidate_ids...]
ruby scripts/sanity_check.rb --skip-sanity-check
ruby scripts/sanity_check.rb --all <storylines_scored.yaml> <segments_file.yaml>
ruby scripts/sanity_check.rb --batch <storylines_scored.yaml> <segments_file.yaml>
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<storylines_scored.yaml>` | string | **required** — path to scored storylines YAML |
| `<segments_file.yaml>` | string | **required** — path to segments YAML |
| `[candidate_ids...]` | string(s) | optional — space-separated candidate IDs to review |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--skip-sanity-check` | boolean | `false` | Skip sanity check entirely (exit 0) |
| `--all` | boolean | `false` | Review all candidates, not just ranked ones |
| `--batch` | boolean | `false` | Batch triage mode: classifies candidates into tiers (strong/acceptable/borderline) |
| `--profile` | string | `_default` | Creator profile name (for threshold defaults) |
| `--strong-threshold` | integer | `80` (or from profile) | Score threshold for "strong" tier |
| `--acceptable-threshold` | integer | `65` (or from profile) | Score threshold for "acceptable" tier |

**Called by:** `orchestrate.rb` (legacy Phase 1.9).

---

## Arrange Phase

### `scripts/arrange.rb`

Phase 2 — Arrangement. Converts semantic understanding into a proposed cut. One LLM call that produces arrangement.yaml with chapter ordering, clip selection, take decisions, B-roll matching, and editorial reasoning.

```
ruby scripts/arrange.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--profile` | string | auto-detected | Creator profile name |
| `--format` | `longform\|shorts` | `longform` | Target format |
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

### `scripts/discover_arcs.rb`

Discovers narrative arc candidates in a pool library. Reads pool index + all transcripts, calls LLM (Opus) to find up to 5 self-contained video arcs.

```
ruby scripts/discover_arcs.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--topic` | string | `nil` | Semantic topic filter (e.g. `"brand strategy"`) |
| `--template` | string | `nil` | Story structure template name to match against |
| `--format` | `longform\|shorts` | `longform` | Target duration class |
| `--profile` | string | auto-detected | Creator profile name |
| `--force-rediscover` | boolean | `false` | Bypass cache and re-run LLM |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |

**Positional args:** none.

**Called by:** `orchestrate.rb` (mine mode).

---

### `scripts/present_candidates.rb`

Displays arc candidate summary from arc_candidates.yaml. Called by orchestrate.rb before interactive selection, or run standalone.

```
ruby scripts/present_candidates.rb --library <name>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |

**Positional args:** none.

**Called by:** `orchestrate.rb` (mine mode).

---

### `scripts/convert_candidate.rb`

Converts an arc candidate from arc_candidates.yaml into arrangement.yaml. Updates library.yaml `videos` with pool sources required for export. Generates pickup_recording_suggestions.md if missing_bridge_clips are present.

```
ruby scripts/convert_candidate.rb --library <name> --candidate <id> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--candidate` | string | **required** | Candidate ID from arc_candidates.yaml |
| `--profile` | string | `nil` | Creator profile name |
| `--force` | boolean | `false` | Regenerate arrangement even if one exists for this candidate |

**Positional args:** none.

**Called by:** `orchestrate.rb` (mine mode).

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

### `scripts/generate_report.rb`

Phase C — Generates analysis report for a library. Produces a comprehensive YAML report with storyline analysis, template matches, and recommendations.

```
ruby scripts/generate_report.rb <library_path> [options]
```

| Positional | Type | Description |
|-----------|------|-------------|
| `<library_path>` | string | **required** — library directory path or library.yaml file |

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--profile` | string | `nil` | Creator profile name |
| `--output-dir` | string | `reports/` | Output directory for report YAML |

**Called by:** `orchestrate.rb` (Branch C).

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
