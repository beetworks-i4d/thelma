# Thelma — Repo State

Generated 2026-05-22 from filesystem. Facts, not assumptions.

> **Session 3 (v4.1)**: Pipeline restructured. `classify()` excised from orchestrate.rb. New scripts: `extract_segments.rb`, `discovery_pass.rb`, `register_pool_sources.rb`. Branch C deprecated. Branch D consolidated (discover_arcs/present_candidates/convert_candidate retired). `arrange.rb` fully reworked (thesis-driven). See `docs/SESSION_3_SPEC.md`.

---

## Gem Version

`lib/buttercut/version.rb`: **0.5.0**

---

## Uncommitted State

```
On branch dev
nothing to commit, working tree clean
```

---

## Current Branches

### Active

| Branch | Last commit | Ahead of main | Purpose |
|--------|------------|---------------|---------|
| `dev` | 2026-05-13 | 41 commits | v4 development. Mode D mining, speaker diarization, semantic ingest pipeline, visual analysis. 19 commits unpushed to origin/dev. |
| `main` | 2026-04-22 | — | Stable release. Tagged `v3.1-multisource`. |
| `origin/dev` | 2026-04-29 | — | Remote dev, 19 commits behind local dev. |
| `origin/main` | 2026-04-22 | — | Remote main, in sync with local main. |

#### dev — last 5 commits

```
ac2e1a6 add: docs/CLI.md — comprehensive CLI reference for all scripts
4a2c08c fix: convert arrangement WAV-time to video-time before export
f46fdd5 fix: pass sync_audio from library.yaml through to build_structure_cut
cab8033 auto-save: session start
f3799b4 fix: bump HTTP read_timeout from 300s to 600s
```

#### main — last 5 commits

```
34e04d1 fix: detect_scenes.rb iterates all videos in library (multi-source)
02b9f0f fix: per-source transcript lookup for restart trimming (multi-source)
68c48e6 test: update specs for Sonnet model ID change to claude-sonnet-4-6
3771e48 fix: add 10ms tolerance to clip clamp to avoid false warnings on rounding noise
02c1d48 add: source file durations in arrangement prompt to prevent boundary overshoots
```

### Stale (all on origin, no local tracking, 5-6 months old)

| Branch | Last commit | Head commit |
|--------|------------|-------------|
| `origin/claude/github-issue-3-*` | 2025-11-21 | `9193f8e` Add automated backup-library skill |
| `origin/claude/compress-transcriptions-*` | 2025-11-27 | `6915665` Add compressed transcript format with 75% token reduction |
| `origin/claude/improve-frame-detection-*` | 2025-11-27 | `7804723` Add frame detection benchmark scripts and performance analysis |
| `origin/improve-roughcut-generation` | 2025-12-01 | `1570e85` Add hundredths-of-second timestamp precision to roughcuts |
| `origin/simplify-library-yaml-fields` | 2025-12-01 | `550fe3d` Simplify library.yaml transcript fields |
| `origin/settings-and-skill-updates` | 2025-12-04 | `c16a636` Use project tmp/ for frame extraction instead of system /tmp |
| `origin/roughcut-performance` | 2025-12-07 | `5a89b18` Optimize roughcut generation by removing scratchpad workflow |
| `origin/claude/update-readme-video-*` | 2025-12-09 | `25829f3` Update README demo video |
| `origin/improve-transcribe-audio-skill` | 2025-12-17 | `75ce2bc` Add LLM refinement step to transcribe-audio skill |
| `origin/simplify-roughcuts` | 2025-12-19 | `05b88aa` More aggressively tell claude to load timeline skill |

All 10 stale branches predate v1.0. Their changes were either merged or superseded by the v1–v3 rewrite.

---

## Shipped Tags

| Tag | Date | Head commit |
|-----|------|-------------|
| `v0.1.1` | 2025-11-21 | `7d2ed34` Bump version to 0.1.1 |
| `v0.2.0` | 2025-11-25 | `3b0e8d0` Bump version to 0.2.0 |
| `v0.3.0` | 2025-12-01 | `25caff3` Simplify library.yaml transcript fields |
| `v0.4.0` | 2026-02-24 | `1c06030` Bump version to 0.4.0 |
| `v0.9-snapshot` | 2026-04-10 | `27212b6` WIP: structure-cut deep mode, Tier 0 fixes |
| `v1.0-stable` | 2026-04-11 | `6fe9439` merge: dev into main — v1.0-stable |
| `v0.5.0` | 2026-04-15 | `7c5de67` Merge branch 'dev' |
| `v1.1-foundation` | 2026-04-15 | `7c5de67` Merge branch 'dev' |
| `v1.2-reasoning` | 2026-04-17 | `1ae1359` merge: Phase 1.9 reasoning surfacing layer |
| `v2.0-thelma` | 2026-04-18 | `e723444` merge: rename to Thelma + profile system |
| `v2.1-orchestrator` | 2026-04-19 | `7472a09` merge: orchestrator + scene detection + creator profiles |
| `v2.2-markers` | 2026-04-19 | `12db453` merge: content type routing + marker system overhaul |
| `v2.4-memory` | 2026-04-19 | `25af5cb` merge: packaging handoff + production design memory |
| `v2.4-complete` | 2026-04-19 | `b12ebad` merge: packaging + production memory + visual frame extraction |
| `v3.0-pipeline` | 2026-04-21 | `c8f0aac` merge: pipeline rework — semantic ingest, arrangement, full orchestration |
| `v3.1-multisource` | 2026-04-22 | `34e04d1` fix: detect_scenes.rb iterates all videos in library (multi-source) |

Notes:
- `v0.5.0` and `v1.1-foundation` point to the same commit (`7c5de67`). Tag naming shifted from semver to milestone names at v1.0.
- `v2.4-memory` and `v2.4-complete` share the `v2.4` prefix — memory was tagged first, then complete added the visual frame extraction on top.
- `v0.9-snapshot` is a WIP snapshot, not a release.
- Tags are not chronologically sorted by version — `v0.5.0` was tagged after `v1.0-stable`.

---

## Active Modes

Per README.md, CLAUDE.md, and `docs/v4_design.md`:

| Mode | Name | Implementation Status | Evidence |
|------|------|-----------------------|----------|
| **A** | Script-driven (Branch A) | Shipped | `scripts/branch_a_batch.rb`, `scripts/parse_script.rb`. orchestrate.rb auto-detects Branch A when `script_parsed` exists in library.yaml. |
| **B** | Organic/unscripted (Branch B) | **Reworked (Session 3)** | Default branch. Pipeline: ingest → extract_segments (deterministic) → audio_emotion → prosody → discovery_pass (LLM, thesis-driven) → arrange (LLM, thesis-driven) → export. `classify()` excised, `semantic_ingest.rb` and `semantic_dedup.rb` deprecated. |
| **C** | Analyze-only (Branch C) | **Deprecated (v4.1)** | `--analyze-only` and `--branch C` now error with deprecation message. Scripts remain in tree for P5 redesign. |
| **D** | Mining/pool-based (Mode D) | **Reworked (Session 3)** | `--mode mine` in orchestrate.rb. Pool indexing → shared pipeline (extract_segments → discovery_pass → register_pool_sources → arrange → export). Legacy scripts `discover_arcs.rb`, `present_candidates.rb`, `convert_candidate.rb` deprecated; replaced by `discovery_pass.rb`, `register_pool_sources.rb`, `arrange.rb`. |

### v4_design.md planned phases vs actual state

| Phase | Planned | Status |
|-------|---------|--------|
| Phase 1: Mode D Mining | 4-5 sessions | **Done.** Full pipeline working. Pool indexing, mixed media, arc discovery, candidate selection, arrangement export, HQ audio matching. |
| Phase 2: Advanced Visual Analysis | 3-4 sessions | **Partially done.** `extract_visual_frames.rb` implements per-shot frame sampling (3 frames/shot), `detect_scenes.rb` for scene boundaries. Shot classification fields exist in schema but are `nil` (populated by Claude Vision in Session 2). Pacing analysis, B-roll correlation, motion detection: schema defined, values not yet computed. |
| Phase 3: Mode C Template Extraction + Edit Review | 4-5 sessions | **Partially done.** `extract_template.rb` exists for template extraction from classified segments. `parse_finished_edit.rb` + `extract_edit_patterns.rb` exist for edit review memory. Retention CSV ingestion: not implemented. Full `--mode extract_template` and `--mode review` orchestration: not implemented. |
| Phase 4: Production Output Enhancement | 1-2 sessions | **Partially done.** `export_packaging_brief.rb` generates thumbnail/title direction, hook analysis, peak map, structural notes. Detailed per-chapter editing brief with graphics/music callouts: not implemented. |

### Modes NOT in README but referenced in v4_design.md

- `--mode extract_template`: Not implemented in orchestrate.rb.
- `--mode review` (Edit Review): Not implemented in orchestrate.rb.

---

## Test Coverage

**Test runner:** `bundle exec rspec` — currently failing to run due to bundler version mismatch (system Ruby 2.6.10 vs Gemfile.lock bundler 2.5.23). No version manager (rbenv/rvm/chruby) installed.

**Spec files:** 42 unique (45 listed, 3 duplicates from glob expansion: `backup_spec.rb`, `buttercut_spec.rb`, `spec_helper.rb`).

**Test examples:** ~938 `it` blocks across all spec files (grep count, not rspec).

| Directory | Files | Coverage area |
|-----------|-------|---------------|
| `spec/` (root) | 3 | buttercut_spec, backup_spec, video_metadata_spec |
| `spec/buttercut/` | 3 | fcp7_spec, fcp7_markers_spec, fcp7_multitrack_spec, fcpx_spec |
| `spec/scripts/` | 33 | One spec per script: orchestrate, arrange, semantic_ingest, discover_arcs, build_structure_cut, branch_a_batch, convert_candidate, export_packaging_brief, etc. |

**Scripts without dedicated specs:** `audio_cleanup.rb`, `audio_sync_offset.rb`, `read_transcript.rb`, `parse_script.rb`, `rebuild_clips_from_cleaned.rb`, `001_migrate_0.2_to_0.3.rb`.

---

## Known Bugs (from `fix:` commits on dev)

56 fix commits total on dev. Patterns grouped by category:

### Time domain / clip boundary issues (recurring)

- `4a2c08c` fix: convert arrangement WAV-time to video-time before export
- `f46fdd5` fix: pass sync_audio from library.yaml through to build_structure_cut
- `b01b94d` fix: buffer-aware frame-domain clamp for clip boundary overshoot
- `188284d` fix: audio-only clips advance video track offset in fcp7.rb
- `35eab95` fix: clamp clip video_end to source file duration in export_arrangement_xml.rb
- `199b271` fix: clamp timeline duration when source_out clamped, prevents silence in striped region
- `3771e48` fix: add 10ms tolerance to clip clamp to avoid false warnings on rounding noise
- `9dce58e` fix: use sequence timebase for audio-only WAV files in xmeml

**Pattern:** Clips from LLM responses or arrangement YAML frequently exceed source file duration. Multiple layers of clamping have been added (export_arrangement_xml, convert_candidate, build_structure_cut, fcp7). Audio-only and dual-system (sync audio) paths need special handling.

### Multi-source handling

- `34e04d1` fix: detect_scenes.rb iterates all videos in library (multi-source)
- `02b9f0f` fix: per-source transcript lookup for restart trimming (multi-source)
- `d639aba` fix: orchestrate.rb Phase 1 processes all videos, not just first
- `37aa1a1` fix: multi-source support in build_structure_cut.rb
- `cda6660` fix: multi-source video path resolution in export_arrangement_xml.rb
- `7480234` fix: per-source speech analysis for multi-source projects

**Pattern:** Pipeline was originally built for single-video libraries. Multi-source (multiple videos per library) required fixes across most scripts.

### LLM integration

- `f3799b4` fix: bump HTTP read_timeout from 300s to 600s
- `f4f1501` fix: increase API timeout to 300s for large Opus prompts
- `2ffa4b2` fix: bump semantic_ingest max_tokens from 8192 to 32768
- `5cfd4f3` fix: switch classification output from YAML to JSON
- `8040509` fix: chunk classification to handle long transcripts
- `bc5a46e` fix: allow YAML aliases in semantic_ingest.rb
- `4f360e4` fix: allow YAML aliases in scene_changes.yaml parsing
- `c99aaff` fix: compute estimated_duration from clip_sequence in discover_arcs.rb
- `fe0d1a0` fix: correct API cost calculation — model-aware pricing, non-negative input cost
- `3690eb1` fix: update Sonnet model ID from claude-sonnet-4-20250514 to claude-sonnet-4-6

**Pattern:** LLM outputs frequently exceed expected size (requiring higher max_tokens), timeout on large prompts, and produce YAML that uses aliases or features that `YAML.safe_load` rejects. Classification switched from YAML to JSON output to avoid parsing failures.

### Transcript cleanup

- `faf6002` fix: transcript_cleanup.rb graceful exit for empty transcripts
- `f360de9` fix: restart trimming false positives — protect parallel structure and mid-clip content

---

## Active Project Directories

`~/Desktop/RAW/` contents:

| Directory | Last modified |
|-----------|---------------|
| `Dylan005` | 2026-05-12 |
| `EveryAIBusinessIdea` | 2026-05-08 |
| `Dylan Shorts Batch 1` | 2026-04-13 |
| `Dylan 004` | 2026-04-13 |
| `Dylan 002` | 2026-04-13 |

---

## Last 20 Commits (dev)

```
ac2e1a6 add: docs/CLI.md — comprehensive CLI reference for all scripts
4a2c08c fix: convert arrangement WAV-time to video-time before export
f46fdd5 fix: pass sync_audio from library.yaml through to build_structure_cut
cab8033 auto-save: session start
f3799b4 fix: bump HTTP read_timeout from 300s to 600s
2ffa4b2 fix: bump semantic_ingest max_tokens from 8192 to 32768
bc5a46e fix: allow YAML aliases in semantic_ingest.rb
4f360e4 fix: allow YAML aliases in scene_changes.yaml parsing
5cfd4f3 fix: switch classification output from YAML to JSON
8040509 fix: chunk classification to handle long transcripts
f439606 move: every-ai-business-idea library to pool-dir .thelma pattern
52dc494 auto-save: session start
1dcfd9c test: Phase 1.5 speaker diarization tests
09e28b5 docs: add speaker diarization setup guide to README
181f18e add: speaker field preservation in arrangement clips
9a6c61f add: speaker labels in transcript reading and arc discovery prompts
214fa4d add: speaker tracking fields in pool index schema
d1d7937 add: --language flag, WhisperX diarization, speaker extraction in orchestrate.rb
64471a1 checkpoint: before Phase 1.5 speaker diarization
a01beee fix: add standalone Visual Analysis phase for already-ingested sources
```
