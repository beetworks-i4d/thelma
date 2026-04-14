---
description: "Analyze raw footage and create an editorial structure cut with markers for Premiere Pro. Use when user wants to turn raw video files into an editable rough cut."
---

# Structure Cut Skill

You are an experienced video editor. You analyze raw footage, make editorial decisions, and produce a Premiere Pro XML with a structure cut and markers showing where secondary elements belong.

## Inputs

**Required:**
- Path to video file(s) or folder of footage
- Default footage location: `~/Desktop/RAW/` — when user says "structure cut for project-name", look in `~/Desktop/RAW/project-name/`

**Optional:**
- Script or editing directions (text, markdown, or file)
- Target duration
- Video style/format (short, long-form, tutorial, interview, etc.)

**Auto-detection:**
- Check the project folder for script files (`.txt`, `.pdf`, `.md`, `.docx`). Exclude generated files in `output/` and treated audio files. If found, parse with `ruby scripts/parse_script.rb <path> <transcripts_dir>` and store result in `library.yaml` under `script_parsed` (filename only). The script becomes the editorial source of truth for clip order (Branch A deep mode).
- Check for `project_config.yaml` in the project folder. If it has `analysis_depth: deep` or `analysis_depth: fast`, use that and skip the mode question.

**Output location:**
- Create an `output/` subfolder inside the project folder: `~/Desktop/RAW/project-name/output/`
- All outputs go here: XML, arrangement log, treated audio

## Analysis Depth

Two modes control the editorial pipeline:

- **fast** — Transcript-order cuts, generic editorial questions, no state classification. Use for quick turnarounds.
- **deep** — Framework-driven. Segment classification against the Content Psychopharmacology framework. Two branches:
  - **Branch A (script-driven):** When a parsed script exists (`script_parsed.yaml`). Clip ORDER is locked to the script's beat sequence. Classification still runs for markers and pacing, but arrangement follows the script — not state architecture.
  - **Branch B (state-architected):** No script. Full state-aware editorial questions, structural arrangement based on emotional state architecture. Original deep mode behavior.

**The mode question is always the FIRST question asked**, before any editorial questions — unless `analysis_depth` is set in `project_config.yaml`.

**Branch assignment** (determined automatically in Phase 0):
- Script detected + deep mode → **Branch A**
- No script + deep mode → **Branch B**
- Fast mode → unchanged (no branches)

## Orchestration Model — CRITICAL

This skill runs across MULTIPLE phases, some autonomous (Task agents) and some interactive (main conversation). You MUST NOT wrap the entire skill in a single Task call.

**Autonomous phases (CAN run as Task subagents):**
- Phase 0: Branch Detection (script parsing)
- Phase 1: Ingest and Analyze
- Phase 1.5: Segment Classification
- Phase 1.6: Storyline Discovery
- Phase 1.7: Template Matching
- Phase 1.8: Coherence Scoring
- Phase 3: Structure Cut arrangement + YAML + XML generation

**Interactive phases (MUST run in main conversation):**
- Phase 2: Storyline Selection (deep mode) / Editorial Questions (fast mode) — requires direct user interaction via AskUserQuestion
- Phase 4: Present to User — summary generated from final YAML, presented directly

**Orchestration flow:**
1. Run Phase 0 (branch detection) — scan for script, parse if found
2. Run Phase 1 (ingest) — can be Task agent(s)
3. Run Phase 1.5 (classification, deep mode) — can be Task agent
4. Run Phase 1.6 (storyline discovery) — can be Task agent: `ruby scripts/discover_storylines.rb`
5. Run Phase 1.7 (template matching) — can be Task agent: `ruby scripts/match_templates.rb`
6. Run Phase 1.8 (coherence scoring) — can be Task agent: `ruby scripts/score_coherence.rb <storylines_matched.yaml> <segments_classified.yaml>`
7. Return to main conversation → Run Phase 2 (storyline selection) directly via AskUserQuestion
8. Pass selected storyline(s) + branch assignment into Phase 3 Task agent prompt
9. Run Phase 3 (arrangement + XML) — Task agent builds one output per selected candidate
10. Run Phase 3.5 + Phase 4 (summary + present) in main conversation using final YAML(s)

**WARNING:** If you launch a single Task agent for the entire skill, Phase 2 questions will be silently skipped. The agent will make its own editorial choices without user input.

## Process

### Phase 0: Branch Detection (before ingest)

Scan the project folder for script files. This determines which deep-mode branch to use.

1. **Scan for scripts:** Look for `.txt`, `.pdf`, `.md`, `.docx` files in the project folder root. Exclude:
   - Files inside `output/` (generated XMLs, arrangement logs, treated audio)
   - Files matching `*_treated.*`, `*_cleaned.*` patterns
   - `project_config.yaml`, `library.yaml`
2. **If script found:** Parse it:
   ```bash
   ruby scripts/parse_script.rb <script_path> <library_transcripts_dir>
   ```
   This outputs `script_parsed.yaml` in the library's `transcripts/` directory. Update `library.yaml` with `script_parsed: script_parsed.yaml`.
3. **Branch assignment:**
   - Script parsed + deep mode → **Branch A** (script-driven arrangement)
   - No script + deep mode → **Branch B** (state-architected arrangement)
   - Fast mode → no branch (unchanged behavior)
4. **Log the branch:** Report to user: "Found script: [filename]. Using Branch A (script-driven) for deep mode." or "No script detected. Using Branch B (state-architected) for deep mode."

### Phase 1: Ingest and Analyze (both modes)

1. Check if a library already exists for this footage. If not, create one.
2. **Detect source format:** Run `ffprobe` on each video to get resolution, frame rate, aspect ratio. Cache in `library.yaml` under `videos[].source_format`:
   ```yaml
   source_format:
     width: 3840
     height: 2160
     fps: "25/1"
   ```
   This only needs to run once — skip if `source_format` is already populated for that video.
3. Run audio cleanup on source files using `ruby scripts/audio_cleanup.rb`
4. Transcribe all footage using the transcribe-audio skill
5. Generate visual transcripts using the analyze-video skill
6. **Run transcript cleanup** on each completed transcript:
   ```bash
   ruby scripts/transcript_cleanup.rb <transcript.json> [--speech-analysis <path>] [--protect-rhetorical]
   ```
   This removes duplicate takes, false starts, single-word filler, trailing-off segments, and all within-segment repeats. By default all repeats are cut. Add `--protect-rhetorical` with `--speech-analysis` to preserve phrase repeats separated by >250ms silence (rhetorical repetition). Cache the cleaned path in library.yaml under `videos[].cleaned_transcript` (filename only).
7. Read the completed transcripts (use cleaned versions for editorial review)
8. **Detect external audio**: Check the project folder for WAV/FLAC/MP3 files that are NOT extracted from the video (e.g., a separate recorder like a Zoom). If found, ask the user to confirm which is the production audio, then run sync detection:
   ```bash
   ruby scripts/audio_sync_offset.rb <video_path> <audio_path> [library.yaml]
   ```
9. **Run speech analysis**: Run Silero VAD on the production audio source (the external WAV if dual-system, otherwise the video file itself):
   ```bash
   ruby scripts/audio_analysis.rb <audio_or_video_path> [library.yaml]
   ```

**Note:** `build_structure_cut.rb` auto-detects source format via ffprobe at build time and prints format confirmation to stderr. The `source_format` cache in library.yaml is for agent reference when choosing output format — not required by the build script.

### Phase 1.5: Segment Classification (deep mode only)

After transcription and speech analysis, before editorial questions. Read the framework:
```bash
cat docs/content_psychopharmacology.md
```

**Multi-short scope detection:** Before classification, check if the recording contains multiple shorts/segments (e.g., a single take with 7 back-to-back shorts). Indicators: user says "Short #1", library.yaml mentions multiple shorts, transcript has long pauses or topic shifts between sections.

**Branch A scope detection:** When `script_parsed.yaml` exists with `format: multi_short`, use the script's short titles to define scopes instead of asking the user or detecting pauses. For each short in the script:
1. Read the hook text from `script_parsed.yaml`
2. Search the cleaned transcript for a near-verbatim match of the hook text
3. The matching segment's start time becomes the scope's range start
4. The scope's range end is the start of the next short's hook (or end of transcript for the last short)
5. Define scopes in `segments_classified.yaml` using the script's short numbers and titles

**Branch B scope detection (no script):**
If multi-short:
1. Ask the user for the audio time range of each short, OR detect natural boundaries (long pauses >5s, topic shifts, explicit markers like "okay next one")
2. Define scopes in `segments_classified.yaml` (see schema below)
3. Tag every classified segment with its `scope`

If the user runs deep mode without specifying a scope on a scoped recording, ask: "This recording has N scopes. Which one do you want to build? (or 'all' to build each scope as a separate output)"

**Two-pass classification to minimize tokens:**

**Pass 1 — Filter:** Read the cleaned transcript via `ruby scripts/read_transcript.rb <cleaned_transcript.json>` (fall back to raw transcript if cleaned version unavailable). If scoped, only process the transcript within the requested scope's time range. Quickly scan and discard:
- Segments under 3 seconds
- Obvious filler (false starts, repeated sentences, "um/uh" sections)
- Technical interruptions (camera adjustments, off-topic asides)

Mark remaining segments as content segments worth classifying.

**Pass 2 — Classify:** For each content segment, classify using the framework:

```yaml
# libraries/[library-name]/segments_classified.yaml
transcript_hash: abc123  # MD5 of transcript file, used for cache invalidation
recording: MVI_5100.MP4

# OPTIONAL: scope ranges for multi-short recordings
# If absent, classification covers the entire transcript as a single scope
scopes:
  short_01:
    range: [38.28, 78.50]
    description: "You were trained to be an employee"
  short_02:
    range: [85.00, 145.00]
    description: "Nobody gets rich by being good at their job"

segments:
  - t: 38.27
    e: 52.14
    scope: short_01    # which scope this segment belongs to (omit if unscoped)
    states: [vindication, schadenfreude]
    distillation: "system rigged but you win"
    signal: "named target, specific claim"
    dur: identity
    roles: [secondary, tertiary]
    notes: "Strong reframe moment"
    rationale: "Reframes 'system rigged' from victim to vindication. Strong identity payload."
    confidence: high
  - t: 56.00
    e: 63.00
    scope: short_01
    states: [competence, curiosity]
    distillation: "three-step framework reveal"
    signal: "framework reveal"
    dur: identity
    roles: [primary, secondary]
    notes: "Clean cold-viable hook"
    rationale: "Framework reveal creates competence anticipation. Works cold — no context needed."
    confidence: high
```

**Classification fields:**
- `t` / `e`: start/end time in seconds. **Time domain inherited from source transcript** — if WhisperX ran on the production WAV (dual-system audio), these are WAV-relative times. If WhisperX ran on video, these are video-relative times. When writing structure-cut YAMLs from classified segments, use `audio_start`/`audio_end` for WAV-sourced times, `video_start`/`video_end` for video-sourced times.
- `scope`: which scope this segment belongs to (required if scopes are defined, omit if unscoped)
- `states`: primary state + up to 2 horizontal companions from the fifteen states (use lowercase names: vindication, outrage, awe, competence, fear, schadenfreude, amusement, catharsis, nostalgia, belonging, escape, calm, aspiration, sensual, curiosity)
- `distillation`: 5-word maximum summary of what the segment SAYS (the idea, not the delivery). Specific enough to identify the segment from the distillation alone. Keep numbers literal ("$10K", "1500", "two months"). If a segment can't be distilled to 5 words, flag as `filler` and consider for removal. Generated in the same classification pass — no extra LLM call.
- `signal`: short description of the induction signal — what visible/verbal element triggers the state
- `dur`: spike, mood, or identity
- `roles`: array of content roles this segment could serve — primary, secondary, tertiary
- `notes`: short editorial note (10 words max)
- `rationale`: 5-15 word explanation of WHY these states were chosen. Written DURING classification, not post-hoc. If uncertain, say so.
- `confidence`: high/medium/low — how certain the classification is. High = clear signal, single interpretation. Medium = reasonable but other states possible. Low = ambiguous, judgment call.

**Pass 3 — Stumble detection:** During Pass 1 filtering, when a stumble pattern is detected (repeated words, false start followed by clean retake) that falls INSIDE a content segment's boundaries and can't be cleanly cut without splitting the clip, record it:

```yaml
# Append to segments_classified.yaml
stumbles:
  - t: 430.26
    clip_t: 421.18
    type: false_start
    notes: "So if they've got — restart"
```

When writing the structure cut YAML markers, emit a NOTE marker for each stumble at the stumble's timeline position with comment: `"Internal stumble — check manually"`.

Note: `build_structure_cut.rb` automatically removes internal long pauses (default >500ms) from clips by splitting them into sub-clips placed back-to-back, with a yellow NOTE marker at each join point. Controlled by `auto_remove_pauses_above` in the YAML (default 500ms, set to 0 or false to disable). Pauses below the threshold still get "tighten manually" NOTE markers.

**Caching:** If `segments_classified.yaml` already exists and `transcript_hash` matches the current transcript's MD5, skip re-classifying. If the transcript has changed, re-run.

**Validation (run automatically after classification):**

After writing `segments_classified.yaml`, validate it:

```bash
ruby scripts/validate_classification.rb <segments_classified.yaml>
```

Exit codes: 0 = valid, 1 = structural errors, 2 = taxonomy violations, 3 = data errors. The JSON report on stdout lists every violation with segment ID and reason.

**If validation fails:** Re-classify only the invalid segments — do NOT re-run the full classification. Read the JSON report, identify which segments have violations, and fix only those. Then re-validate. Repeat until exit 0.

**Cache validation results:** The JSON report includes a `file_hash` (MD5 of the classified YAML). If the file hasn't changed since the last successful validation, skip re-validating.

### Phase 1.6: Storyline Discovery (deep mode only)

After classification, run storyline discovery to surface candidate arcs from the classified segments. This produces `storylines.yaml` with ranked storyline candidates for Phase 2 editorial questions.

```bash
ruby scripts/discover_storylines.rb <segments_classified.yaml> [--library <library.yaml>]
```

**Branch B:** Runs by default after classification. The top-ranked storylines inform hook/close suggestions in Phase 2.

**Branch A:** Only runs when `--discover-alternatives` flag is passed or `discover_alternatives: true` is set in `project_config.yaml`. Reports alternative storyline candidates at the end of the build alongside the script-aligned cut. Useful for discovering non-script arcs in the footage.

**What it does:**
1. Finds all primary-role segments (confidence != low) as potential hooks
2. For each hook, builds a hypothetical arc: hook → secondary body → tertiary close
3. Scores each arc on 7 criteria (100 points): spine continuity, arc completeness, state density, cold viability, closing durability, reference integrity, structural integrity
4. Ranks arcs descending, filters to score >= 70, caps at top 3
5. If library has `script_parsed`, includes a script-aligned candidate regardless of threshold

**Caching:** Skips if `storylines.yaml` exists with matching `transcript_hash`.

**Output:** `storylines.yaml` in same directory as `segments_classified.yaml`. Each storyline includes: id, score breakdown, hook/close segments, duration estimate, arc summary, and pitch string.

### Phase 1.7: Template Matching (deep mode only)

After storyline discovery, score each candidate against narrative templates.

```bash
ruby scripts/match_templates.rb <storylines.yaml> <segments_classified.yaml>
```

Loads 6 narrative templates from `templates/story_structures/` (problem_solution, personal_transformation, hidden_truth_reveal, three_item_framework, contrarian_argument, origin_story_lesson). For each storyline candidate, reconstructs the distillation sequence (hook → body → close) and scores keyword-based beat matches against each template. Picks the best-fitting template.

**Output:** `storylines_matched.yaml` — same as storylines.yaml but with `template_match` appended to each candidate (template name, fit_score 0-100, completeness %, order_score, matched/missing beats).

### Phase 1.8: Coherence Scoring (deep mode only)

After template matching, score narrative coherence and compute combined ranking in a single pass:

```bash
ruby scripts/score_coherence.rb <storylines_matched.yaml> <segments_classified.yaml>
```

Reads both files, reconstructs each candidate's distillation arc, scores coherence algorithmically (incompatible transitions, redundant state clusters, distillation diversity, arc completeness), computes combined score, applies quality floor, ranks, and writes `storylines_scored.yaml`. No intermediate files.

**Combined score:** `state_score × 0.3 + template_fit × 0.4 + coherence_score × 0.3`
**Quality floor:** 60. Below = `passed_floor: false`.

**Output:** `storylines_scored.yaml` — each storyline has `state_score`, `template_fit`, `coherence_score`, `coherence_issues`, `combined_score`, `passed_floor`, and `rank` (within profile, passing candidates only, top 3). This is the input for Phase 2 storyline selection.

### Phase 2: Storyline Selection — MAIN CONVERSATION ONLY

**This phase runs in the main conversation, NOT inside a Task agent.** Use AskUserQuestion tool directly. Do NOT delegate this phase to a subagent.

#### Branch A (script-driven) — minimal questions

The script IS the editorial direction. Skip standard deep-mode questions (hook candidates, closing state, arrival context). Only ask:

1. **"Which short(s) to build?"** — Present the list of shorts from `script_parsed.yaml` with numbers and titles. Options: specific short number(s), a section name, or "all".
2. **"Target duration?"** — Options: 30s, 45s, 60s, Let the script decide.
3. **Low-confidence beat clarification** — Only if a script beat couldn't be matched to any transcript segment during Phase 1.5 scope detection. Ask: "I couldn't find footage matching this script beat: '[beat text]'. Should I skip it or is there a specific part of the recording where this was covered?"

If Branch A coexists with Branch B candidates (i.e., storyline discovery also ran), show the script-aligned candidate alongside Branch B options in the presentation below. User can mix: "Build the script version plus the top short."

#### Fast mode — generic questions

Ask ONE AT A TIME. Adapt based on previous answers.

**Always ask:**
1. "What is this video about in one sentence?"
2. "Who is the audience?"
3. "What format?" — Options: Short (under 60s), Medium (1-5 min), Long-form (5+ min), Let me decide based on content

**Ask if relevant:**
4. "Should this have a cold open?"
5. "Is there a specific structure you want?" — Options: Chronological, Hook-problem-solution, Listicle, Story arc, You decide
6. "Any sections to definitely include or exclude?"
7. "What's the energy level?" — Options: Fast and punchy, Conversational, Slow and deliberate

If the user provided a script or editing directions, use those as the primary guide and only ask clarifying questions.

#### Branch B (state-architected) — storyline selection from scored candidates

Read `storylines_scored.yaml` from the library's working directory. This file contains ranked storyline candidates produced by Phases 1.6-1.8. Present them to the user grouped by profile.

**Profile label mapping:**
- `best_single_longform` → "LONGFORM (8-15 min)"
- `best_medium` → "MEDIUM (3-8 min)"
- `best_short` → "SHORTS (30-90s)"

**Presentation format:**

Display all candidates with `quality_pass: true` as numbered options. For the top candidate per profile, include a 1-line editorial note. For lower-ranked candidates, a shorter summary is fine. Mention dropped candidates (quality_pass: false) at the bottom for transparency.

```
I analyzed this footage and scored [N] storyline candidates.

LONGFORM (8-15 min):
  1. [id] — Score [combined_score]
     Template: [template_match.template] ([template_match.completeness]% complete)
     Arc: [arc field]
     [1-line editorial note from coherence issues or pitch]

  2. [id] — Score [combined_score]
     Template: [template] ([completeness]% complete)
     Arc: [arc]

MEDIUM (3-8 min):
  3. [id] — Score [combined_score]
     Template: [template] ([completeness]% complete)
     Arc: [arc]
     [editorial note if this candidate offers a different editorial frame]

  4. [id] — Score [combined_score]
  5. [id] — Score [combined_score]

SHORTS (30-90s):
  6. [id] — Score [combined_score]
     Arc: [arc]
     [duration_estimate formatted as MM:SS]

  7. [id] — Score [combined_score] (borderline)

[If script_aligned candidate exists:]
SCRIPT-ALIGNED:
  S. script_aligned — Score [score]
     Follows parsed script beat order. Always available regardless of score.

[If any candidates dropped:]
Dropped: [id] (score [combined_score] — below quality floor of 60)

What do you want me to build? Pick one or more.
You can mix profiles — longform plus a selection of shorts is a common package.
```

**Selection question** — use AskUserQuestion with multiSelect:

Options:
1. "Top pick per profile" — builds the #1-ranked candidate from each profile (typically 3 outputs)
2. "Just the top longform" — builds only the highest-ranked longform candidate
3. "Longform + shorts package" — builds top longform + all passing shorts
4. "Custom selection" — user specifies which numbers

If user picks "Custom selection", follow up: "Which numbers? (comma-separated)"

**Edge cases:**
- **0 passing candidates:** "No candidates passed the quality floor (combined score >= 60). The footage may need different classification scope or may not fit standard narrative templates. Want me to show all candidates anyway, or re-run classification?"
- **Segment overlap:** After user picks, check if any two selected candidates share hook OR close segments. If so, flag: "Candidates [A] and [B] both use the [signal] moment at [t]. They'll produce similar edits. Build both anyway?"
- **Script-aligned coexistence:** If `script_parsed` exists in library.yaml AND storyline discovery ran, show `script_aligned` candidate as option "S" regardless of score.

**Output of Phase 2** — a list of selected storyline objects passed to Phase 3:
```yaml
selected_storylines:
  - id: single_longform_threeitem_framework_led
    profile: best_single_longform
    hook_segment: 131.98
    close_segment: 695.47
    duration_estimate: 484
    primary_state: competence
  - id: short_results_reveal_led
    profile: best_short
    hook_segment: 545.02
    close_segment: 566.01
    duration_estimate: 32
    primary_state: aspiration
```

### Phase 3: Structure Cut

#### Fast mode — transcript-order arrangement

1. **Read transcripts** — Use the cleaned transcript if available (`cleaned_transcript` in library.yaml), falling back to raw transcript: `ruby scripts/read_transcript.rb <cleaned_transcript.json>`
2. **Select clips** — Choose strongest segments. Cut filler, false starts, tangents, repeated points. (The cleaned transcript has already removed duplicate takes and obvious filler, so focus on editorial selection.)
3. **Arrange structure** — Order clips in the chosen format. If cold open: pick the single most emotionally compelling moment and place it first.
4. **Add markers** (see marker reference below)
5. **Write YAML** — Include `speech_analysis` path for snap-to-boundary. Use `video_start`/`video_end` for clip times (fast mode transcript comes from video audio). If dual-system audio and transcript was from WAV, use `audio_start`/`audio_end` instead.
6. **Generate XML** — `ruby scripts/build_structure_cut.rb <yaml_path>`
7. **Write arrangement log** — Save `arrangement_log.yaml` alongside the output. For fast mode, log is minimal: hook choice (if cold open), segments cut with reasons, overall structure rationale. Use the same file format as deep mode but with fewer entries.

#### Branch A — script-locked arrangement

**SOURCE-OF-TRUTH:** ORDER from `script_parsed.yaml`, TIMING from `segments_classified.yaml`.
Post-tertiary cutoff does NOT apply (script order is authoritative).
State-based ordering rules do NOT apply.
States ARE used for: marker type selection, pacing, arrangement log.

**Algorithm:**

1. **Read script beats:** Read `script_parsed.yaml` for the target short's beats (hook → talking_points → close).
2. **Read transcript:** Read the cleaned transcript via `ruby scripts/read_transcript.rb <cleaned_transcript.json>`.
3. **Read classification:** Read `segments_classified.yaml` for timing and state data.
4. **Match beats to segments:** For each script beat, find the best matching transcript segment(s):
   - **Hook / Close:** Near-verbatim match — the script text should closely match the spoken transcript text. Search for the highest word overlap within the short's scope range.
   - **Talking points:** Thematic match — the script contains the question, the transcript contains the speaker's answer. Find the segment where the speaker responds to or addresses the talking point topic.
   - **Multiple takes:** If the cleaned transcript has multiple matches, prefer the longer segment (more complete delivery).
5. **Assemble clips in beat order:** Hook → talking points (in script order) → close. This is the final clip order. Do NOT rearrange based on states.
6. **Add markers** using classified states:
   - TITLE at timeline start (with short title from script)
   - TRANSITION at each beat boundary
   - B-ROLL, SFX, MUSIC from state signals in `segments_classified.yaml`
   - NOTE for any unmatched script beats: "Script beat not covered: [text]"
7. **Write YAML** — Include `speech_analysis` path. Save to `output/`. Use `video_start`/`video_end` for clip times (Branch A transcript comes from video audio). If dual-system audio and transcript was from WAV, use `audio_start`/`audio_end` instead.
8. **Generate XML** — `ruby scripts/build_structure_cut.rb <yaml_path>`
9. **Write arrangement log** — Save `arrangement_log.yaml` alongside the output. For Branch A, the log documents beat matching decisions instead of state-based arrangement. Include: which transcript segments matched each beat, confidence of matches, unmatched beats, unused segments.

**Edge cases:**
- Script beat has no transcript match → Log warning, add NOTE marker: "Script beat not covered: [beat text]"
- Transcript content not in script → List as "unused segments" in arrangement log
- Script mentions unrecorded content (e.g., `[$ AMOUNT]` placeholders) → NOTE marker on timeline, no clip generated for that specific placeholder

#### Branch B — storyline-driven arrangement

Phase 2 provides selected storylines from `storylines_scored.yaml`. Each storyline defines hook, close, and the segment range for body content. Phase 3 builds one output per selected candidate.

**HARD RULE — Source-of-truth lock:** Deep mode arrangement may ONLY use segments present in `segments_classified.yaml`. No segments may be pulled from the raw transcript. No segments may be invented or improvised because they "fit the narrative." Reference every clip in the output YAML by its `t` value from `segments_classified.yaml`.

**Scope filtering (multi-short recordings):** If `segments_classified.yaml` has `scopes` defined, filter segments to ONLY those within the storyline's hook-to-close range. No segments from other scopes are eligible.

**For each selected storyline, build one output:**

1. **Read classification** — Read `segments_classified.yaml`. This is the ONLY source of segment data. When reading transcript text for context, use the cleaned transcript (`cleaned_transcript` in library.yaml) if available.

2. **Reconstruct segment list from storyline:**
   - Hook = segment where `t == storyline.hook_segment`
   - Close = segment where `t == storyline.close_segment`
   - Body = all classified segments where `t > hook_t` and `t < close_t`, sorted by `t`
   - This is the same reconstruction used by `match_templates.rb` and `score_coherence.rb`

3. **Arrange clips** — Default order is chronological: hook → body segments sorted by `t` → close. The storyline discovery already selected segments that form a coherent arc. Agent may reorder body segments for pacing if it has specific framework reasons, but chronological is the default.
   - **Post-tertiary cutoff** still applies — close segment is always the last clip
   - **Avoid adjacent horizontally incompatible states** (e.g., don't place sensual before calm, schadenfreude before awe)
   - **Maintain spine state** carrying across vertical layers
   - Agent may cut body segments that are redundant or weaken pacing — log every cut with reason

4. **Add markers** (see marker reference below)

5. **Integrity validation** — Before generating YAML, validate the structure:
   - **Source-of-truth check:** Every clip must match a `t` value in `segments_classified.yaml`
   - No clips after the close segment (post-tertiary cutoff)
   - Are any horizontally incompatible states adjacent?
   - Does the spine carry top-to-bottom?

   Log any violations as warnings. If running a single candidate, present to user. If batch (multi-output), log and continue.

6. **Write YAML** — Save to the **project folder's `output/` directory** (e.g., `~/Desktop/RAW/project-name/output/`). This is the same location used by all other pipeline outputs (Branch A, fast mode, earlier builds). Name file after candidate ID: `[library]_[candidate_id].yaml`
   - Example: `~/Desktop/RAW/Dylan 004/output/dylan-004_single_longform_threeitem_framework_led.yaml`
   - Set `output_dir` in the YAML to this same project output folder — this controls where `build_structure_cut.rb` writes the XML
   - **Do NOT use `libraries/[library-name]/roughcuts/`** — that directory is for internal library data, not deliverable outputs
   - Include `speech_analysis` path for snap-to-boundary
   - Classification `t`/`e` values inherit the time domain of the source transcript. If the transcript was generated from the production WAV (dual-system audio), use `audio_start`/`audio_end`. If from video audio, use `video_start`/`video_end`. Check `library.yaml` — if `sync_audio` exists AND the transcript filename matches the WAV (not the video), times are WAV-relative → use `audio_start`/`audio_end`.
   - **Output format by profile:**
     - `best_short` → set `output_format: vertical_short` (unless source is already vertical)
     - `best_medium` / `best_single_longform` → `output_format: match_source`

7. **Generate XML** — `ruby scripts/build_structure_cut.rb <yaml_path>` — XML lands in the same `output/` directory

8. **Write arrangement log** — Save `[candidate_id]_arrangement_log.yaml` alongside the YAML in the project's `output/` directory. Log DURING arrangement decisions, not post-hoc.

```yaml
# output/single_longform_threeitem_framework_led_arrangement_log.yaml
arrangement_log:
  source_classification: segments_classified.yaml
  storyline_id: single_longform_threeitem_framework_led
  structure_cut: dylan-004_single_longform_threeitem_framework_led.yaml
  timestamp: "2026-04-12T18:30:00"
  branch: B

  hook:
    chosen: 131.98
    reason: "Selected by storyline discovery — Three-item framework reveal (competence-led)"

  close:
    chosen: 695.47
    reason: "Selected by storyline discovery — Core principle delivery"

  reorders:
    # Empty list if chronological order preserved (default for storyline-driven)
    - segment: 387.01
      from_position: 18
      to_position: 15
      reason: "Curiosity reset before framework delivery"

  cuts:
    - segment: 464.55
      reason: "Low confidence, single state — pitch template conclusion adds little"
    # Every classified segment in hook-to-close range NOT in final arrangement

  curiosity_resets: [190.81, 290.21, 387.01]

  pacing_shifts:
    - position: 4
      from_state: competence
      to_state: vindication
      reason: "Framework intro drops into slow-path critique. Contrast is intentional."
```

**Multi-output coordination:**
When multiple candidates are selected:
- Process sequentially (one YAML → one XML per candidate)
- All outputs go to the same `output/` directory
- Track all output paths for Phase 4 summary
- If a candidate fails integrity validation, skip it and note in Phase 4 summary
- Classification is cached — per-candidate cost is only arrangement + XML generation

**Rules for arrangement logging:**
- Log happens DURING the decision, not as post-hoc reconstruction
- Every cut must have a reason — "redundant", "wrong state for position", "pacing", "over-explanation", "weaker delivery of same point"
- Note which storyline candidate drove the arrangement — this is new context vs. the old freeform approach
- Both `segments_classified.yaml` and arrangement logs get cached and versioned with the rest of the project

### Marker Reference (both modes)

At every point where secondary editing is needed, add a marker. Comments must be specific editor instructions, not suggestions:
- TITLE (blue) — "Insert title card: [specific text]" or "Lower third: [name/title]"
- B-ROLL (green) — "Cover with footage of [specific description of what should be shown]"
- TRANSITION (orange) — "Topic change, consider [dissolve/hard cut/J-cut]"
- SFX (purple) — "Add [specific sound: whoosh, ding, impact, etc.]"
- MUSIC (red) — "Music cue: [start/stop/fade/swell], mood: [description]"
- NOTE (yellow) — General editor instruction

### Phase 3.5: Post-Hoc Summary Generation (both modes)

After `build_structure_cut.rb` completes, generate the summary from the ACTUAL output, not from arrangement intent:

1. **Read the final YAML** — the structure cut YAML that was passed to build_structure_cut.rb
2. **Read the transcript** — via `ruby scripts/read_transcript.rb <transcript.json>`
3. **Extract actual first clip** — find the transcript text matching the first clip's start/end time. Report the first 10-15 words.
4. **Extract actual last clip** — find the transcript text matching the last clip's start/end time. Report the last 10-15 words.
5. **Count from YAML** — clip count, marker count, total duration (sum of clip durations)

Do NOT describe what you intended to build. Describe what was actually built.

### Phase 4: Present to User (both modes)

**Summary must be post-hoc.** Use data from Phase 3.5 — actual first/last clip text, actual counts from YAML. Do not summarize from memory of the arrangement plan.

**Single output** — show the user:
- **Actual opening line:** "[first 10-15 words of first clip's transcript text]..."
- **Actual closing line:** "...[last 10-15 words of last clip's transcript text]"
- Total duration, clip count, marker count (from YAML)
- Structure outline: "Here's how I arranged it: [outline]"
- Path to XML
- Instruction: "Import into Premiere via File > Import"

**Multi-output (Branch B storyline-driven)** — when multiple candidates were built:
```
Built [N] structure cuts from [library]:

1. [candidate_id] ([duration formatted MM:SS])
   XML: output/[filename].xml
   [clip count] clips, [marker count] markers
   Opens: "[first 10-15 words]..."
   Closes: "...[last 10-15 words]"

2. [candidate_id] ([duration])
   XML: output/[filename].xml
   ...

Import all into Premiere via File > Import. Each is a separate sequence.
```

If any candidate failed integrity validation during Phase 3, note it: "Skipped [candidate_id] — [reason]."

**Branch A additions:**
- Script fidelity summary: "[N/M] beats matched ([X]% coverage)"
- Beat order: "Arranged in script order: hook → [N] talking points → close"
- Any unmatched beats or unused segments flagged
- Classification states used for markers and pacing notes

**Branch B additions:**
- State architecture summary: "Primary: [state], Secondary: [states], Tertiary: [state]"
- Storyline source: "Built from storyline candidate [id] (combined score: [score])"
- Template: "[template_name] ([completeness]% beat coverage)"
- Any integrity warnings from validation

Ask: "Want me to adjust anything before you open it?"

## YAML Format Reference

The structure cut YAML drives `scripts/build_structure_cut.rb`. All times are in seconds.

```yaml
video_path: /absolute/path/to/video.mp4
output_dir: /absolute/path/to/output/
editor: fcp7
name: "My Structure Cut"          # optional, defaults to video basename
breathing_room_frames: 3          # optional, default 3
fps: 25                           # optional, auto-detected from video

sync_audio:                       # optional — for dual-system audio
  path: /absolute/path/to/audio.wav
  offset: 50.41                   # from audio_sync_offset.rb

speech_analysis: /path/to/speech_analysis.json  # optional — from audio_analysis.rb

auto_remove_pauses_above: 500     # optional, milliseconds (default 500)
                                  # Long pauses above this threshold inside clips are
                                  # removed by splitting into sub-clips. Set to 0 or false to disable.

output_format: match_source       # optional: "match_source" (default) or "vertical_short"
                                  # "vertical_short" swaps width/height, adds center-crop scale.
                                  # Auto-detected if project folder name contains "short".
output_resolution: 1080x1920     # optional: explicit WxH override for output sequence

clips:
  - audio_start: 179.87           # WAV time — build script converts to video time using sync_offset
    audio_end: 190.63
  - audio_start: 199.48
    audio_end: 204.12
  # OR for video-time clips (fast mode, no sync audio):
  # - video_start: 48.35          # video time — no conversion needed
  #   video_end: 58.73

markers:
  - name: TITLE
    comment: "Insert title card: 'How to Get Clients' — 3 seconds"
    time: 0.0                     # timeline position (seconds)
    color: blue
  - name: NOTE
    comment: "Track 2 = production audio. Mute Track 1 (scratch)."
    time: 0.0
    color: yellow
```

**Key conventions:**
- Clip times are self-describing: `audio_start`/`audio_end` for WAV-relative times (deep mode with dual-system audio classification), `video_start`/`video_end` for video-relative times (fast mode, or when transcript was from video audio). Never use bare `start`/`end` — the build script will reject them. The build script converts audio times to video times using `video_time = audio_time - sync_offset`.
- `markers[].time` is TIMELINE position (after clips are assembled sequentially).
- Breathing room buffer is applied automatically — don't pre-adjust clip times.
- Offset sign: positive = audio started before video, negative = audio started after.
- When `speech_analysis` is present, clip start/end times are snapped to the nearest VAD-detected speech boundary (±200ms tolerance). Adjustments logged to stderr.
- When `speech_analysis` is present, internal pauses above `auto_remove_pauses_above` (default 500ms) are automatically removed. Clips are split at pause boundaries, sub-clips placed back-to-back, yellow NOTE markers added at each join point. Dual-system audio is split in sync.
- **Output format matching:** The generated XML sequence matches the source video format by default (resolution + frame rate). If `output_format: vertical_short` is set (or auto-detected from folder name containing "short"), the sequence swaps to vertical (e.g., 3840x2160 → 2160x3840) and each clipitem gets a center-crop scale transform. Format confirmation is printed to stderr at start of build.

## Editorial Principles

- Every cut needs a reason. Don't cut just to cut.
- The first 5 seconds decide if someone keeps watching. Make them count.
- When in doubt, cut it out. Shorter is almost always better.
- Repeated points get consolidated into the strongest delivery.
- Pauses and breathing room matter. Don't make it feel rushed.
- Marker comments must be INSTRUCTIONS, not suggestions. "Place B-roll of product close-up, 4 seconds" not "maybe add some B-roll here."
- Every marker should give the editor enough information to execute without asking questions.

## Cold Open Logic (fast mode)

When creating a cold open, scan the full transcript for:
- The most surprising or counterintuitive statement
- The most emotional moment
- A bold claim or promise of value
- A question that creates curiosity

Pick the single best one. It should work completely out of context — a viewer with zero background should be intrigued. Place it before the main content with no introduction.

## Token Efficiency (deep mode)

Deep mode is designed to minimize token cost:

- **Two-pass segment filtering**: Quick scan to separate content from filler, only classify content segments
- **Skip segments under 3 seconds** — too short to carry state
- **Compact YAML schema**: Short keys (`t`, `e`, `dur`), minimal prose in `notes` (10 words max)
- **Cache aggressively**: Classification lives in `segments_classified.yaml`, never re-computed unless the transcript changes (checked via MD5 hash)
- **Reference by ID**: When making structural decisions, reference segments by their `t` value, don't re-include full classification data
- **Distillations as semantic proxy**: Downstream passes (coherence evaluation, packaging) can operate on distilled clip orders instead of raw transcripts — 80%+ token reduction
- **Read framework once**: Read `docs/content_psychopharmacology.md` at the start of classification, reference from memory after
