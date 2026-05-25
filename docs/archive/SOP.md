# Thelma — Standard Operating Procedure

> Written April 2026, after completing the v3.0 pipeline rework. This is the manual you'll need when you come back in 3 months and can't remember how any of this works.

## Table of Contents

1. [What Thelma Does](#what-thelma-does)
2. [What Thelma Does NOT Do](#what-thelma-does-not-do)
3. [Setup (One-Time)](#setup-one-time)
4. [Creator Profiles](#creator-profiles)
5. [Project Setup](#project-setup)
6. [Running a Build](#running-a-build)
7. [Review Gates](#review-gates)
8. [Importing to Premiere](#importing-to-premiere)
9. [Premiere Workflow After Import](#premiere-workflow-after-import)
10. [Troubleshooting](#troubleshooting)
11. [Clearing State / Forcing Regeneration](#clearing-state--forcing-regeneration)
12. [Known Quirks (Not Bugs)](#known-quirks-not-bugs)
13. [Known Limitations](#known-limitations)
14. [Stop Condition](#stop-condition)

---

## What Thelma Does

Thelma is a semantic-first video editing tool for talking-head and essay content. It takes raw footage and an optional script/outline, analyzes the spoken content at a transcript level, classifies emotional states, builds a directorial understanding of the material, then produces a Premiere-ready XML with role-coded markers, chapter markers, stumble cleanup, alternate-take stacking on V2, and a packaging brief (thumbnail + title direction). The output is a structurally complete rough cut that a human editor polishes — not a final export.

## What Thelma Does NOT Do

- **Travel footage, vlogs without a spoken argument, music videos, non-speech content.** Thelma's entire pipeline assumes coherent spoken content that can be transcribed, classified, and arranged by semantic meaning.
- **Multi-speaker interviews.** Untested. The classification framework assumes a single speaker's argument structure. Panel discussions, debates, or interview formats will produce unpredictable results.
- **Final color, graphics, music, or export.** Thelma produces the editorial structure. Everything after that — color grading, title cards, lower thirds, music beds, sound design, final export — is manual editor work.
- **Short-form vertical content generation.** The pipeline is optimized for longform horizontal content. Shorts/reels are a planned future extension, not current functionality.

## Setup (One-Time)

### Dependencies

| Dependency | Version | Install |
|------------|---------|---------|
| Ruby | 3.3.6 | `mise install ruby@3.3.6` or rbenv/asdf |
| Python | 3.12.x | `mise install python@3.12.8` or pyenv |
| FFmpeg | latest | `brew install ffmpeg` |
| WhisperX | latest | `pip install whisperx` (or venv at `~/.buttercut/venv/`) |
| Bundler | latest | `gem install bundler` |

After installing dependencies:

```bash
cd ~/path/to/thelma
bundle install
```

Run the verification script to confirm everything:

```bash
ruby .claude/skills/setup/verify_install.rb
```

### API Key

Set the Anthropic API key in your shell profile (`~/.zshrc` or `~/.bashrc`):

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
```

### SSH Key (Per Session)

If you're pushing to GitHub, run once per terminal session:

```bash
ssh-add ~/.ssh/id_ed25519
```

### Settings

On first library creation, Thelma copies `templates/settings_template.yaml` to `libraries/settings.yaml`. Confirm your defaults:

```yaml
editor: premiere    # premiere | fcpx | resolve
whisper_model: turbo  # small | medium | turbo
```

## Creator Profiles

Profiles live at `profiles/creators/<name>.yaml`. They control LLM behavior — what emotional states to favor, what to preserve, what to cut, and the tone of voice.

### When to Create a Profile

- **New creator with distinct style**: Create a profile. The LLM produces noticeably better results when it understands the creator's voice.
- **One-off project, no strong style**: Use `_default`. The default profile works fine for generic content.
- **Testing**: Use `_default`. Don't create profiles for test libraries.

### Profile Structure

Here's Ivan's profile as a concrete example (`profiles/creators/ivan.yaml`):

```yaml
name: ivan
description: "Ivan's brand strategy and content operations content"
content_type: talking_head_business

# Which emotional states this creator's content gravitates toward
primary_state_preferences:
  - competence
  - vindication
  - curiosity

# Structural templates that work well for this creator
template_categories:
  - argumentative
  - explainer
template_affinities:
  - hidden_truth_reveal
  - problem_solution
  - three_item_framework

notes: "Solo recording, no dual-system audio typically. Content tends toward analytical/framework-heavy."

# Tone profile — controls LLM voice and editorial judgment
tone_profile:
  guide_doc: docs/tone/ivan.md    # optional detailed tone guide

  humor_register:                 # what kinds of humor to preserve
    - absurdist
    - dry
    - crude_ok

  profanity_limit: one_per_script_after_60s   # never | one_per_script_after_60s | unrestricted

  tangent_tolerance: moderate     # low | moderate | high — how much off-topic to keep

  formality: conversational       # formal | conversational | casual

  preserve_strongly:              # editorial signals to keep in the cut
    - specific_concrete_examples_grounding_claims
    - flat_delivery_on_uncomfortable_truths
    - analogies_from_outside_domain
    - signature_phrasings
    - comedic_beats_with_payoff
    - parallel_rhetorical_structures

  cut_preferentially:             # editorial signals to trim
    - hedging_qualifiers
    - premature_jargon
    - melodrama_and_grandiosity
    - academic_citations_as_lead
    - self_censored_tangents_without_payoff
    - over_transmission
    - self_deprecation_as_shtick
    - empty_filler_phrases
```

### Tone Guide (Optional)

For creators with a strong, distinctive voice, write a markdown tone guide at `docs/tone/<name>.md`. This gives the LLM a richer understanding of the creator's style than YAML fields alone can express.

**When to write one:** The creator has recognizable sentence patterns, vocabulary habits, or delivery quirks that a generic profile would miss. Ivan's guide (`docs/tone/ivan.md`) includes calibrated reference lines, vocabulary rules, and known failure modes.

**When to skip:** The creator's style is standard or you don't have enough sample content to characterize it. The YAML fields are sufficient for most creators.

### Default Profile

`profiles/_default.yaml` provides base defaults that all profiles inherit from. Key settings:

- LLM routing: classification → Sonnet, semantic_ingest/arrangement/coherence → Opus
- Target durations: shorts 30-60s, longform 480-900s
- Auto content type detection
- Packaging brief generation enabled

## Project Setup

### Folder Convention

```
~/Desktop/RAW/<ProjectName>/
  ├── video1.mp4              # A-roll footage at root
  ├── video2.mov              # multiple files OK
  ├── script.pdf              # optional — editing directions, auto-detected
  ├── outline.md              # optional — alternative to script
  ├── B Roll/                 # optional — B-roll footage
  │   ├── broll1.mp4
  │   └── broll2.mov
  └── output/                 # created automatically by Thelma
      ├── <name>_arrangement_<timestamp>.xml
      └── <name>_arrangement_<timestamp>_packaging_brief.md
```

- A-roll goes at the root of the project folder
- B-roll goes in a `B Roll/` subdirectory (if it exists)
- Scripts/outlines are auto-detected at the project root
- The `output/` directory is created automatically on first export

### Library Initialization

Libraries are created through Claude Code conversation (the `setup` workflow in CLAUDE.md). The library YAML and transcript directories are created at `libraries/<name>/`. You don't need to create these manually.

## Running a Build

### The Single Command

```bash
ruby scripts/orchestrate.rb --library <name> --profile <name> --llm-mode claude_code
```

### Flags

| Flag | Required | Description |
|------|----------|-------------|
| `--library <name>` | Yes | Library name (matches directory under `libraries/`) |
| `--profile <name>` | No | Creator profile name (matches `profiles/creators/<name>.yaml`). Auto-detected from library name if omitted. Falls back to `_default`. |
| `--llm-mode claude_code` | No | Enables pending file workflow instead of direct API calls. Use this when running from Claude Code. |
| `--no-review` | No | Skip interactive review gates (auto-approve). Use for batch/automated runs. |
| `--branch <A\|B\|C>` | No | Override branch detection. A = script-locked, B = state-architected (default for most content), C = analyze-only. |
| `--analyze-only` | No | Shortcut for `--branch C`. Runs analysis phases only, generates a report, skips editing phases. |

### What Happens at Each Phase

| Phase | What It Does | LLM? | Output |
|-------|-------------|------|--------|
| **1 — Ingest** | Audio cleanup (ffmpeg), transcription (WhisperX), speech analysis (VAD), transcript cleanup | No | `transcripts/*.json`, `*_cleaned.json`, `*_speech_analysis.json` |
| **0 — Content Type** | Detects content format from transcript signals | No | `content_type` in `library.yaml` |
| **1.5 — Classification** | Classifies each transcript segment with emotional states, distillation, durability, confidence | Yes (Sonnet) | `segments_classified.yaml` |
| **1.5c — Audio Emotion** | Analyzes audio delivery (energy, pitch, speaking rate) per segment | No | Merges into `segments_classified.yaml` |
| **1.5d — Scene Detection** | Detects scene changes, extracts representative frames | No | `scene_changes.yaml`, `visual_frames.yaml` |
| **2 — Semantic Ingest** | Builds directorial understanding: clip groups, usability, narrative structure | Yes (Opus) | `semantic_ingest.yaml` |
| **3 — Arrangement** | Creates the proposed cut: chapter structure, clip ordering, V1/V2 assignment | Yes (Opus) | `arrangement.yaml` |
| **4 — Export & Build** | Converts arrangement to Premiere XML with tiered markers | No | `output/<name>_arrangement_<timestamp>.xml` |
| **5 — Packaging Brief** | Generates thumbnail and title direction based on emotional architecture | Yes (Sonnet) | `output/<name>_arrangement_<timestamp>_packaging_brief.md` |

### Pending LLM Handoff (Claude Code Mode)

When running with `--llm-mode claude_code`, LLM calls don't hit the API directly. Instead:

1. The script writes a **pending file** to `libraries/<name>/pending_llm_calls/<call_name>.yaml` containing the full prompt
2. The script exits with **code 2** (pipeline paused)
3. You (or Claude Code) read the prompt, formulate a response, and write it to `libraries/<name>/pending_llm_calls/<call_name>_response.yaml`
4. Re-run the same `orchestrate.rb` command — completed phases skip (cached), the script picks up the response and continues

**Response file format:**

```yaml
---
response: |
  <LLM response text here>
```

**Pending calls per run:** Classification (1), semantic ingest (1), arrangement (1), packaging brief (2 — thumbnail + title). Total: 5 LLM calls per full pipeline run. Each re-run after filling responses continues from where it left off.

## Review Gates

Two interactive checkpoints pause the pipeline for human review. Both use the same `(y/r/n)` interface.

### Gate 1: Semantic Ingest (Phase 2)

**What you see:**

```
REVIEW GATE — Does this match your intent?

## Core Understanding
<2-3 paragraph description of what the video is about>

## Central Tension
<1-2 sentence thesis/question the video explores>

5 clip groups | 13 clips | 10 fine, 3 marginal, 0 unusable | 1 clusters

(y) Continue  (r) Show full output  (n) Abort
```

**What to check:**
- Does the core understanding match what the video is actually about?
- Is the central tension correct? (This drives the entire arrangement.)
- Are the usability counts reasonable? Too many "unusable" clips suggests a transcription or classification problem.

### Gate 2: Arrangement (Phase 3)

**What you see:**

```
PROPOSED CUT: <library_name>

Target: longform (8:44 estimated)
Branch: B

Summary:
<2-3 sentence description of the proposed cut>

Key decisions:
  - Dropped group_003 (false start, content repeated in group_005)
  - Used alternate take at t=21.30 for punchier delivery

B-roll: 0 matched, 4 suggestions for missing
Chapters: 5 | Clips: 74 (V1: 74, V2: 0)

(y) Continue  (r) Show full output  (n) Abort
```

**What to check:**
- Does the chapter count feel right for the content length?
- Are the key decisions sensible? (Dropped clips should have good reasons.)
- Is the estimated duration in the right ballpark?

### Options

- **`y`** — Approve and continue to export
- **`r`** — Show the full YAML output for detailed inspection, then approve/reject
- **`n`** — Abort. Delete the output file and re-run to regenerate with different LLM responses.

**Tip:** Pass `--no-review` to skip these gates entirely. Useful when you trust the pipeline and want unattended runs.

## Importing to Premiere

### File Location

```
~/Desktop/RAW/<ProjectName>/output/<name>_arrangement_<timestamp>.xml
```

### Import Steps

1. Open Premiere Pro
2. File > Import
3. Select the `.xml` file
4. Premiere creates a new sequence from the XML

### What the Timeline Looks Like

**Video Tracks:**
- **V1** — Primary narrative spine. All clips in intended order.
- **V2** — Alternate takes (when available). Stacked above V1 at the same timecode for easy comparison.

**Audio Tracks:**
- **A1/A2** — Audio linked to V1/V2 video clips

**Markers (Tiered System):**

| Tier | Purpose | Colors in Premiere |
|------|---------|-------------------|
| **Tier 0** | Narrative role per clip | Green (hook), Orange (setup), Blue (continuation), Purple (payoff) |
| **Tier 1** | Structural landmarks | Green (HOOK), Blue (CLOSE), Orange (SECTION — chapter boundaries), Purple (PIVOT), Cyan (REVEAL) |
| **Tier 2** | Editor alerts | Light blue (state transitions, durability shifts), Yellow-green (signpost/cut candidates, long segments, low confidence) |
| **Tier 3** | Reference overlay | Grey — per-segment emotional state, distillation, durability class, audio profile |

**Tier 0 markers** are the most immediately useful — they color-code every clip by its role in the narrative. Green clips are hooks, purple clips are payoffs, blue clips are the body.

**Tier 1 SECTION markers** are range markers with chapter labels (e.g., "SECTION: Why Westaway"). They correspond to the arrangement chapters.

**Tier 2 and Tier 3** are for deep editorial work. Tier 2 flags transition points and potential cut candidates. Tier 3 gives you the full emotional classification of each segment.

## Premiere Workflow After Import

The XML produces a structurally complete starting point. The manual polish pass:

1. **Review V2 clips** — where alternate takes exist above V1, compare and delete whichever is weaker. Most V2 clips can be deleted; they're there for choice, not inclusion.
2. **Trim remaining stumbles** — Thelma catches most stumbles but some inline partial-phrase repeats and doubled words leak through. The Tier 2 markers flag suspicious spots. Trust your ears.
3. **Drop B-roll** — Put B-roll on V3+. The packaging brief's `broll_suggestions` section gives semantic direction (e.g., "fortune_100_logos" at chapter 4). Match to available assets.
4. **Add music** — Music goes on A3+. Use the chapter structure for music cue placement.
5. **Graphics and titles** — Lower thirds, title cards, chapter cards. The chapter labels from the arrangement give you the text.
6. **Color and export** — Standard post-production. Thelma has no opinions here.

## Troubleshooting

### "File Import Failure" in Premiere

Usually malformed XML. Validate with:

```bash
xmllint --noout ~/Desktop/RAW/<ProjectName>/output/<name>_arrangement_*.xml
```

If xmllint reports errors, the XML generation had a problem. Delete the XML and re-run Phase 4.

### Pending LLM Not Clearing

Check:
1. The pending file exists at `libraries/<name>/pending_llm_calls/<call_name>.yaml`
2. The response file is at the exact path printed in the pending message: `<call_name>_response.yaml`
3. The response file has the correct format: `response: |` as a YAML key with the text indented below
4. The response text is not empty

### Profile Load Errors

Verify the file exists at `profiles/creators/<name>.yaml`. Profile names are case-sensitive and match the filename without extension.

### FFmpeg Codec Warnings (apac stream)

```
Could not find codec parameters for stream 2 (Audio: apac...)
```

Harmless. This is a metadata stream in some camera formats. FFmpeg processes the actual audio and video correctly. Ignore.

### Stale Semantic Ingest Producing Wrong Decisions

If the arrangement seems off (wrong clip ordering, bad chapter structure), the problem is usually in `semantic_ingest.yaml`. Delete it to regenerate:

```bash
rm libraries/<name>/semantic_ingest.yaml
```

Then re-run orchestrate.rb. Phases 1-1.5d will skip (cached), and semantic ingest will regenerate fresh.

### Pipeline Not Resuming After Pending

The pipeline should resume automatically when you re-run `orchestrate.rb` after filling response files. If it doesn't:

1. Check that the response file is at the exact `response_path` printed in the pending YAML
2. Verify the response file parses as valid YAML (`ruby -ryaml -e "YAML.safe_load(File.read('path'))"`)
3. Check that `exit 2` propagated correctly — the orchestrate.rb output should show "PIPELINE PAUSED" not "PIPELINE ABORT"

## Clearing State / Forcing Regeneration

Each phase checks for cached output before running. Delete specific files to force re-run:

| To Re-Run | Delete |
|-----------|--------|
| Classification | `libraries/<name>/segments_classified.yaml` |
| Semantic dedup | `libraries/<name>/segments_deduped.yaml` |
| Audio emotion | Remove `audio_features` key from `library.yaml` |
| Semantic ingest | `libraries/<name>/semantic_ingest.yaml` |
| Arrangement | `libraries/<name>/arrangement.yaml` |
| XML export | No deletion needed — always regenerates with new timestamp |
| Packaging brief | Delete the `*_packaging_brief.md` in `output/` (or re-run with new XML) |
| All pending LLM state | `rm -rf libraries/<name>/pending_llm_calls/` |
| Everything (full reset) | `rm -rf libraries/<name>/` — nukes the library, starts from scratch |

**Note:** Output XML regenerates on every run regardless of cache. Each run produces a new timestamped file (`<name>_arrangement_<YYYYMMDD-HHMMSS>.xml`), so old files are never overwritten.

## Known Quirks (Not Bugs)

**Duplicate XML files on re-runs.** Each pipeline run through Phase 4 produces a new timestamped XML file. If you ran the pipeline 5 times to fill pending responses, you'll have 5 XML files in `output/`. Only the latest matters. Delete the others if they bother you.

**Doubled stderr output in Claude Code mode.** When orchestrate.rb runs child scripts via `Open3.capture3`, both the child's stderr and the parent's phase logging appear. This makes the output look duplicated. It's cosmetic — the pipeline is only running once.

**Target duration warnings on short source footage.** The default target range is 480-900 seconds (longform). If your source footage is 83 seconds, the pipeline will warn "estimated duration outside target range." This is informational, not an error. The pipeline produces the best cut possible from available material regardless of target.

**Phase 1.5 Classification still runs.** It looks redundant with semantic ingest, but it isn't. Classification feeds 37 of 42 Premiere markers (Tier 0/1/2/3), the packaging brief's emotional architecture analysis, and the arrangement's enrichment data. Removing it would collapse the marker system.

**transcript_cleanup runs on every invocation.** It's fast (no LLM) and deterministic, so it always re-runs rather than caching. Not a problem.

## Known Limitations

### Stumble Detection Gaps

Thelma catches most speech stumbles through transcript cleanup and restart trimming, but some patterns leak through:

- **Inline partial-phrase repeats** — "We need to, we need to focus on..." where the restart happens mid-sentence without a clean break point
- **Cross-clip abandonment** — Speaker trails off at the end of one clip and restarts the thought in the next. Thelma treats each clip independently.
- **Doubled words inside takes** — "The the problem is..." where WhisperX transcribes both instances
- **Short fragment clips** — Sub-2-second clips that survive transcript cleanup but feel choppy in the edit

### Speech-to-Text Errors

Thelma can't fix what WhisperX gets wrong:

- **Name mispronunciations** — Proper nouns, brand names, and unusual terms may be transcribed incorrectly, leading to wrong distillations
- **Speaker diarization** — WhisperX sometimes splits one speaker into two, or merges overlapping speech. This confuses the classification.
- **Timestamp drift** — Occasionally WhisperX timestamps drift by 100-300ms from actual speech boundaries. The frame-snapping logic compensates but can't fix large drifts.

### Manual Polish Still Required

Even a perfect Thelma run produces a rough cut, not a final edit. You will always need to:

- Fine-tune clip boundaries (2-3 frame adjustments)
- Drop in B-roll where suggested
- Add music, sound design, and ambient audio
- Create title cards, lower thirds, and graphics
- Color grade
- Final review and export

## Stop Condition

The v3.0 pipeline rework is complete. One real project (ivantest1) has shipped through the full pipeline, and a second (kyle) was tested end-to-end as validation.

**Do not re-open Thelma for nice-to-haves.** The tool works standalone. Future work should only happen if real usage surfaces blocking problems — not because something could theoretically be improved.
