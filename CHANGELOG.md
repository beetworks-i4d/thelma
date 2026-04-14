# Changelog

All notable changes to ButterCut will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-04-15 — v1.1-foundation

Phase 1 of the editorial pipeline rebuild: validation, scoring, dedup, test coverage, and reusability.

### Added
- **Classification output validator** (`scripts/validate_classification.rb`) — structural, taxonomy, and data validation for `segments_classified.yaml` with exit codes 1/2/3 by severity
- **Two-layer coherence scoring** (`scripts/score_coherence.rb`) — algorithmic pre-filter (state continuity, template fit, coherence heuristics) + LLM narrative judgment pass with combined scoring and quality floor
- **Semantic dedup** (`scripts/semantic_dedup.rb`) — Phase 1.5b post-classification pass that compares consecutive segments by distillation overlap to detect retakes while preserving rhetorical repetition
- **Test coverage for critical scripts** — 24 new tests for `build_structure_cut.rb` (14) and `transcript_cleanup.rb` (10), plus specs for all new scripts
- SKILL.md orchestration documentation for Phases 1.5b, 1.6, 1.7, 1.8

### Changed
- **`branch_a_batch.rb` now accepts `--library` flag** — removed hardcoded paths to `dylan-shorts-batch-1`; all paths derived from `library.yaml`. New `--shorts` range flag replaces hardcoded 1..30.
- Pipeline flow updated: Phase 1.5 classification → Phase 1.5b semantic dedup → Phase 1.6 storyline discovery (reads `segments_deduped.yaml`)

### Fixed
- Close search window in `branch_a_batch.rb` — all 30 shorts now match correctly
- Distillation word limits tightened to 5-word maximum during classification
- Sync audio pulled from `library.yaml` when no fast mode YAML exists

## [0.4.0] - 2026-02-24

### Changed
- **~2x faster roughcut generation** - Removed scratchpad workflow and increased transcript chunk size from 1000 to 5000 lines (~3.5min vs ~6-7min)
- **Persistent editor preference** - Editor choice (fcpx/premiere/resolve) saved to library.yaml, no longer prompted each time
- Replaced shell-out code generation in export script with direct ButterCut require under bundle exec
- Simplified transcript combining: replaced Ruby script with shell pipeline for NDJSON output
- Temporary files now use project `tmp/` directory instead of system `/tmp`

### Added
- Claude Code project settings for auto-allowing common workflow operations (skills, ffprobe, ffmpeg, whisperx)
- Worktree creation skill for working with libraries across git worktrees

### Fixed
- Timestamp variable not persisting across shell calls during export

## [0.3.0] - 2025-12-01

### Changed
- **BREAKING**: Simplified library.yaml transcript fields
  - `transcript_path` → `transcript` (filename only, not full path)
  - `visual_transcript_path` → `visual_transcript` (filename only, not full path)
  - Transcripts are always stored in `libraries/[library-name]/transcripts/`
  - Reduces library.yaml size by ~45% for large libraries
- **Hundredths-of-second timestamp precision** in roughcuts
  - Timestamps now use `HH:MM:SS.ss` format instead of `HH:MM:SS`
  - Preserves timing within ~10ms of WhisperX transcript data
  - Prevents clipping words at edit points

### Removed
- `file_size_mb` field from library.yaml (not used for editorial decisions)

### Migration
```bash
# Back up your libraries first (creates ZIP in /backups/)
ruby .claude/skills/backup-library/backup_libraries.rb

# Migrate library.yaml files to new field names
ruby scripts/001_migrate_0.2_to_0.3.rb --all
```

## [0.2.0] - 2025-11-25

### Added
- **backup-library skill**: Creates compressed ZIP backups of libraries (transcripts, roughcuts, YAML - not video files)
- **update-buttercut skill**: Automatically downloads and installs the latest version while preserving libraries
- **Flexible setup options**: Simple mise-based install for beginners, advanced checklist for developers
- `.ruby-version` and `.python-version` files for broad version manager support (rbenv, pyenv, asdf, etc.)
- Install location check to warn about problematic directories
- Manual installation documentation at `docs/installation.md`

### Changed
- Restructured setup skill with separate `simple-setup.md` and `advanced-setup.md` guides
- Moved roughcut generation to subtask for streamlined workflow
- Improved Homebrew installation messaging (needs interactive terminal for password prompts)
- Added libyaml dependency to prevent psych extension build failures
- Added note about Ruby compilation time (5-10 minutes via mise)

## [0.1.1] - 2025-01-21

### Added
- DaVinci Resolve support via FCP7 XML (xmeml version 5) format
- Release skill for automated version management and publishing workflow
- Centralized version management via `ButterCut::VERSION` constant

### Changed
- Improved library management with better documentation and workflow guidelines
- Enhanced CLAUDE.md with clearer library setup and parallel transcription patterns

### Fixed
- Gemspec now references version from `lib/buttercut/version.rb` for single source of truth

## [0.1.0] - 2025-01-15

### Added
- Initial release of ButterCut gem
- FCPX XML generation (FCPXML 1.8 format)
- FCP7/Premiere XML generation (xmeml version 5)
- Automatic video metadata extraction via FFmpeg
- Support for embedded SMPTE timecode
- Claude Code skills:
  - `transcribe-audio`: WhisperX-based audio transcription
  - `analyze-video`: Frame extraction and visual analysis
  - `roughcut`: AI-powered rough cut and sequence creation
- Library-based project management system
- Comprehensive test suite with 65+ specs
