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
- Check the project folder for `script.txt` or `script.pdf`. If found, use as editing directions and skip most editorial questions. Only ask clarifying questions.
- Check for `project_config.yaml` in the project folder. If it has `analysis_depth: deep` or `analysis_depth: fast`, use that and skip the mode question.

**Output location:**
- Create an `output/` subfolder inside the project folder: `~/Desktop/RAW/project-name/output/`
- All outputs go here: XML, edit brief, treated audio

## Analysis Depth

Two modes control the editorial pipeline:

- **fast** — Transcript-order cuts, generic editorial questions, no state classification. Use for quick turnarounds.
- **deep** — Framework-driven. Segment classification against the Content Psychopharmacology framework, state-aware editorial questions grounded in actual footage, structural arrangement based on emotional state architecture. Use for high-quality client work.

**The mode question is always the FIRST question asked**, before any editorial questions — unless `analysis_depth` is set in `project_config.yaml`.

## Orchestration Model — CRITICAL

This skill runs across MULTIPLE phases, some autonomous (Task agents) and some interactive (main conversation). You MUST NOT wrap the entire skill in a single Task call.

**Autonomous phases (CAN run as Task subagents):**
- Phase 1: Ingest and Analyze
- Phase 1.5: Segment Classification
- Phase 3: Structure Cut arrangement + YAML + XML generation

**Interactive phases (MUST run in main conversation):**
- Phase 2: Editorial Questions — requires direct user interaction via AskUserQuestion
- Phase 4: Present to User — summary generated from final YAML, presented directly

**Orchestration flow:**
1. Run Phase 1 (ingest) — can be Task agent(s)
2. Run Phase 1.5 (classification, deep mode) — can be Task agent
3. Return to main conversation → Run Phase 2 (editorial questions) directly
4. Pass user answers into Phase 3 Task agent prompt
5. Run Phase 3 (arrangement + XML) — Task agent with user answers as input
6. Run Phase 3.5 + Phase 4 (summary + present) in main conversation using final YAML

**WARNING:** If you launch a single Task agent for the entire skill, Phase 2 questions will be silently skipped. The agent will make its own editorial choices without user input.

## Process

### Phase 1: Ingest and Analyze (both modes)

1. Check if a library already exists for this footage. If not, create one.
2. Run audio cleanup on source files using `ruby scripts/audio_cleanup.rb`
3. Transcribe all footage using the transcribe-audio skill
4. Generate visual transcripts using the analyze-video skill
5. Read the completed transcripts
6. **Detect external audio**: Check the project folder for WAV/FLAC/MP3 files that are NOT extracted from the video (e.g., a separate recorder like a Zoom). If found, ask the user to confirm which is the production audio, then run sync detection:
   ```bash
   ruby scripts/audio_sync_offset.rb <video_path> <audio_path> [library.yaml]
   ```
7. **Run speech analysis**: Run Silero VAD on the production audio source (the external WAV if dual-system, otherwise the video file itself):
   ```bash
   ruby scripts/audio_analysis.rb <audio_or_video_path> [library.yaml]
   ```

### Phase 1.5: Segment Classification (deep mode only)

After transcription and speech analysis, before editorial questions. Read the framework:
```bash
cat docs/content_psychopharmacology.md
```

**Multi-short scope detection:** Before classification, check if the recording contains multiple shorts/segments (e.g., a single take with 7 back-to-back shorts). Indicators: user says "Short #1", library.yaml mentions multiple shorts, transcript has long pauses or topic shifts between sections.

If multi-short:
1. Ask the user for the audio time range of each short, OR detect natural boundaries (long pauses >5s, topic shifts, explicit markers like "okay next one")
2. Define scopes in `segments_classified.yaml` (see schema below)
3. Tag every classified segment with its `scope`

If the user runs deep mode without specifying a scope on a scoped recording, ask: "This recording has N scopes. Which one do you want to build? (or 'all' to build each scope as a separate output)"

**Two-pass classification to minimize tokens:**

**Pass 1 — Filter:** Read the transcript via `ruby scripts/read_transcript.rb`. If scoped, only process the transcript within the requested scope's time range. Quickly scan and discard:
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
    signal: "named target, specific claim"
    dur: identity
    roles: [secondary, tertiary]
    notes: "Strong reframe moment"
  - t: 56.00
    e: 63.00
    scope: short_01
    states: [competence, curiosity]
    signal: "framework reveal"
    dur: identity
    roles: [primary, secondary]
    notes: "Clean cold-viable hook"
```

**Classification fields:**
- `t` / `e`: start/end time in seconds
- `scope`: which scope this segment belongs to (required if scopes are defined, omit if unscoped)
- `states`: primary state + up to 2 horizontal companions from the fifteen states (use lowercase names: vindication, outrage, awe, competence, fear, schadenfreude, amusement, catharsis, nostalgia, belonging, escape, calm, aspiration, sensual, curiosity)
- `signal`: short description of the induction signal — what visible/verbal element triggers the state
- `dur`: spike, mood, or identity
- `roles`: array of content roles this segment could serve — primary, secondary, tertiary
- `notes`: short editorial note (10 words max)

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

### Phase 2: Editorial Questions — MAIN CONVERSATION ONLY

**This phase runs in the main conversation, NOT inside a Task agent.** Use AskUserQuestion tool directly. The classified segments from Phase 1.5 inform the questions asked here. Do NOT delegate this phase to a subagent.

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

#### Deep mode — framework-aware questions

Read the classified segments. Each question proposes specific options from the actual footage with reasoning. No generic questions.

**Question 1 — Primary state and hook candidates:**

Identify the 2-3 strongest hook candidates from the classified segments. Present them with framework reasoning:

> "I found these strong hook candidates in the footage:
>
> 1. **Vindication-led** — [segment at MM:SS]: '[quote]'. Opens on [induction signal]. High compressibility, works cold. Best for audience growth.
> 2. **Competence-led** — [segment at MM:SS]: '[quote]'. Opens on [framework reveal]. Best for retention from niche feed. Slower but higher-quality viewers.
> 3. **Curiosity-led** — [segment at MM:SS]: '[quote]'. Opens on [open loop]. Identity-durable but slow to induce. Best for loyal audience.
>
> Which direction?"

Select candidates based on: axis scores matching likely arrival context, induction speed, signal compressibility.

**Question 2 — Closing state and residue:**

> "Your strongest Identity-durable moments are at [timestamps]. These create the best closing for audience building. Want to use [best one] as the close, or keep a different ending?"

Identify segments classified with `dur: identity` and `roles` containing `tertiary`.

**Question 3 — Arrival context:**

> "Where will this video live primarily?"
> - Algorithmic feed (needs cold-viable primary)
> - Niche feed (can tolerate more context)
> - Subscribed audience (can use slower states)

This determines which primary states are viable per the framework's arrival context rules.

**Question 4 — Only if relevant:**

> "The footage has natural Curiosity moments at [timestamps]. Want me to use them as retention resets in the middle section?"

Ask this if multiple curiosity-classified segments exist that could serve as transition glue.

### Phase 3: Structure Cut

#### Fast mode — transcript-order arrangement

1. **Read transcripts** — `ruby scripts/read_transcript.rb <transcript.json>`
2. **Select clips** — Choose strongest segments. Cut filler, false starts, tangents, repeated points.
3. **Arrange structure** — Order clips in the chosen format. If cold open: pick the single most emotionally compelling moment and place it first.
4. **Add markers** (see marker reference below)
5. **Write YAML** — Include `speech_analysis` path for snap-to-boundary.
6. **Generate XML** — `ruby scripts/build_structure_cut.rb <yaml_path>`
7. **Generate edit brief** (see edit brief section below)

#### Deep mode — state-architected arrangement

**HARD RULE — Source-of-truth lock:** Deep mode arrangement may ONLY use segments present in `segments_classified.yaml`. No segments may be pulled from the raw transcript. No segments may be invented or improvised because they "fit the narrative." If the available classified segments are insufficient to build the requested arc, arrangement must fail loudly and request re-classification with expanded scope. Reference every clip in the output YAML by its `t` value from `segments_classified.yaml`.

**Scope filtering (multi-short recordings):** If `segments_classified.yaml` has `scopes` defined and the user requested a specific scope (e.g., "Short #1"), filter segments to ONLY those with the matching `scope` field before arrangement. No segments from other scopes are eligible.

1. **Read classification** — Read `segments_classified.yaml`. If scoped, filter to the requested scope. This is the ONLY source of segment data for arrangement.

2. **Select clips** — Choose segments from the filtered classification. Reference segments by their `t` value. Keep segments that serve the chosen state architecture.

3. **Arrange by state architecture** — Clips follow structural logic, NOT recording chronology:
   - **Primary spine state** goes first (hook position) — must match the chosen arrival context's axis requirements
   - **Tertiary Identity-durable state** goes last (residue position) — the moment the viewer carries away
   - **Secondary states** fill the middle with pacing variation
   - **Curiosity moments** serve as transition glue between sections (retention resets)
   - **Avoid adjacent horizontally incompatible states** (e.g., don't place sensual before calm, schadenfreude before awe)
   - **Maintain spine state** carrying across vertical layers
   - **HARD RULE — Post-tertiary cutoff:** Once the tertiary Identity-durable residue segment is placed, the timeline ENDS. No clips may appear after it. Any remaining unplaced segments are discarded, regardless of quality or state. The tertiary segment is always the final clip.

4. **Add markers** (see marker reference below)

5. **Integrity validation** — Before generating YAML, validate the structure:
   - **Source-of-truth check:** For every clip in the proposed arrangement, verify the start audio time matches a `t` value in `segments_classified.yaml` (within the active scope if scoped). If any clip references an audio time not in the classification, the arrangement is INVALID — do not generate YAML. Fix by removing the unclassified clip or requesting re-classification.
   - Does the primary match the chosen arrival context? (Check axis scores)
   - Are any horizontally incompatible states adjacent?
   - Does the spine carry top-to-bottom?
   - What's the failure pivot if the primary promise misses?
   - Is any clip placed after the tertiary residue position? (If yes: validation ERROR — must be resolved before XML generation. Move or remove the offending clips.)

   Log any violations as warnings. Present to the user for approval:
   > "Structure check: [N issues found / structure is clean]. [Details of any issues]. Approve or adjust?"

6. **Write YAML** — Include `speech_analysis` path. Save to `output/`.
   - The classification `t`/`e` values are in **video time** (because WhisperX transcribes the video's audio track). Use them directly as clip `start`/`end` in the YAML. Do NOT set `time_domain: audio` unless the transcript was generated from a separate WAV file (rare case — almost never needed).
   - **Markers are unaffected** — marker `time` values are timeline positions (seconds from timeline start), not source times.

7. **Generate XML** — `ruby scripts/build_structure_cut.rb <yaml_path>`

8. **Generate edit brief** — Include the State Architecture section (see below).

### Marker Reference (both modes)

At every point where secondary editing is needed, add a marker. Comments must be specific editor instructions, not suggestions:
- TITLE (blue) — "Insert title card: [specific text]" or "Lower third: [name/title]"
- B-ROLL (green) — "Cover with footage of [specific description of what should be shown]"
- TRANSITION (orange) — "Topic change, consider [dissolve/hard cut/J-cut]"
- SFX (purple) — "Add [specific sound: whoosh, ding, impact, etc.]"
- MUSIC (red) — "Music cue: [start/stop/fade/swell], mood: [description]"
- NOTE (yellow) — General editor instruction

### Edit Brief (both modes)

Create a markdown file alongside the XML in `output/` containing:
- One-sentence summary of the video
- Structure outline with timecodes
- Checklist of all markers (what the editor needs to do)
- List of assets needed (B-roll descriptions, music mood, title text)
- Delivery specs

#### Deep mode addition — State Architecture section

Add a "State Architecture" section to the edit brief:

```markdown
## State Architecture

**Primary spine:** [state] + [horizontal companions]
- Induction signal: [what triggers it]
- Arrival context: [cold/niche/subscribed]

**Secondary states:** [states used in body]
**Tertiary residue:** [identity-durable state used for close]

**Vertical stack:** [Primary] → [Secondary] → [Tertiary]
**Spine integrity:** [clean / issues noted]

**Failure pivot:** If the [primary state] promise misses, viewer pivots to [specific negative state]. Risk level: [recoverable/moderate/catastrophic].

**Integrity notes:**
- [Any horizontal incompatibilities flagged]
- [Any arrival context mismatches]
- [Any spine discontinuities]
```

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

Show the user:
- **Actual opening line:** "[first 10-15 words of first clip's transcript text]..."
- **Actual closing line:** "...[last 10-15 words of last clip's transcript text]"
- Total duration, clip count, marker count (from YAML)
- Structure outline: "Here's how I arranged it: [outline]"
- Path to XML and edit brief
- Instruction: "Import into Premiere via File > Import"

**Deep mode additions:**
- State architecture summary: "Primary: [state], Secondary: [states], Tertiary: [state]"
- Hook reasoning: "I led with [segment] because [framework reason]"
- Close reasoning: "I closed with [segment] for [durability] residue"
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

time_domain: video                # optional: "audio" or "video" (default: "video")
                                  # "video" = times are video-relative (normal — WhisperX on video)
                                  # "audio" = times are WAV-relative (only if transcript from WAV)

clips:
  - start: 121.73                 # video source time (seconds)
    end: 127.11
  - start: 130.80
    end: 146.91

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
- `clips[].start/end` are video source times by default. Only set `time_domain: audio` if the transcript was generated from the production WAV (rare). When `audio`, the script converts using `video_time = audio_time - sync_offset`.
- `markers[].time` is TIMELINE position (after clips are assembled sequentially).
- Breathing room buffer is applied automatically — don't pre-adjust clip times.
- Offset sign: positive = audio started before video, negative = audio started after.
- When `speech_analysis` is present, clip start/end times are snapped to the nearest VAD-detected speech boundary (±200ms tolerance). Adjustments logged to stderr.
- When `speech_analysis` is present, internal pauses above `auto_remove_pauses_above` (default 500ms) are automatically removed. Clips are split at pause boundaries, sub-clips placed back-to-back, yellow NOTE markers added at each join point. Dual-system audio is split in sync.

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
- **Read framework once**: Read `docs/content_psychopharmacology.md` at the start of classification, reference from memory after
