# Session 5 Spec — Semantic Segmentation + Clip-Boundary Clamp

**Status:** Design-only. Locked 2026-05-24.
**Prerequisite:** Session 3 (v4.1) pipeline.
**Core principle:** Atoms are inviolate. A segment produced by semantic_segment.rb is the atomic unit of selection for the entire downstream pipeline. No downstream script sub-trims, snaps, or adjusts atom boundaries. Arrange selects atoms by ID. Export renders atoms with a fixed BREATHING_MARGIN.
**Validation target:** dylan-shorts-batch-1 produces a segmented pipeline run where single-word fragments are gone, boundary leakage is eliminated, and transcript_cleanup.rb is no longer called.

---

## 1. Scope

**Session 5 ships, as one coordinated cutover on `dev`:**

- New LLM script: `semantic_segment.rb` (Phase 1.35, per-source)
- Modified deterministic script: `extract_segments.rb` (Phase 1.4, now reads semantic segmentation output instead of raw Whisper segments)
- Modified arrangement script: `arrange.rb` (prompt simplified — selects atoms by ID, no clip_in/clip_out reasoning)
- Modified export script: `export_arrangement_xml.rb` (looks up seg_id → t,e from segments_classified.yaml; no clip_in/clip_out passthrough)
- Simplified export script: `build_structure_cut.rb` (snap_to_boundary, END_BUFFER, overlap-clamp, trim_restart_inpoint all deleted; clip boundaries = segment t/e + BREATHING_MARGIN)
- `orchestrate.rb` updates: new Phase 1.35 routing, transcript_cleanup.rb removal from Phase 1
- `transcript_cleanup.rb` deprecated (header marked, removed from routing)
- `arrangement.yaml` schema v3: segments carry seg_id only, no clip_in/clip_out

**Session 5 does NOT ship:**

- Prosody as segmentation input (v2 — only if v1 misses prosody-only-detectable defects)
- ASR engine swap (Deepgram etc.) — only if v1 segmentation still produces unacceptable cuts due to transcription quality
- Editorial critique phase 2.5 (separate session)
- Branch C redesign (P5)
- Visual analysis P2 (separate workstream)

**Cutover semantics:** Same as Session 3 — no half-state. Either semantic_segment.rb is the sole source of segment boundaries flowing into segments_classified.yaml, or Session 5 is not done.

---

## 2. Locked Decisions (Do Not Relitigate)

These were resolved in the design conversation that produced this spec. They are inputs, not topics.

**D5.1** — Whisper's segment-level boundaries are dropped entirely from the pipeline. Word-level timestamps + Silero VAD pause data are the only inputs to segmentation.

**D5.2** — Segmentation is per-source-video. Cross-source deduplication is discovery_pass's job, not segmentation's.

**D5.3** — Binary classification: each segment is either usable or not-usable. No granular taxonomy (restart / aside / mumble / etc.). Editorial decision rule: "would an editor consider this for the cut?"

**D5.4** — Not-usable segments are excluded from `segments_classified.yaml` entirely. They are written to a separate `discarded_segments.yaml` for debug/audit only. Downstream pipeline (audio_emotion, discovery_pass, arrange) only sees usable segments.

**D5.5** — Model: Opus for v1. Re-evaluate downgrade after measuring quality.

**D5.6** — Prosody is NOT input to v1 segmentation. Text + word timing + VAD pauses only. Prosody added in v2 only if v1 misses prosody-only-detectable defects in real footage.

**D5.7** — `transcript_cleanup.rb` is deprecated. Its job (removing fillers, stutters, false starts) is absorbed into semantic segmentation.

**D5.8** — Schema simplification: `segments_classified.yaml` keeps existing schema. Semantic segmentation writes the same shape, just with usable segments only. No `usable: bool` field needed because not-usable segments never enter the file.

**D5.9** — Clip-boundary clamping in `build_structure_cut.rb` is folded into this session. Under the atoms-are-inviolate principle, the "clamp" degenerates to a trivial operation: rendered_start = segment.t - BREATHING_MARGIN, rendered_end = segment.e + BREATHING_MARGIN. All existing snap/buffer/overlap-clamp machinery is deleted.

**D5.10 (NEW)** — Atoms are inviolate. The segment's `t` and `e` ARE the speech boundaries by construction (first word start, last word end). No downstream script modifies them. Arrange selects atoms by ID. Export derives source windows from segment t/e. build_structure_cut.rb applies a fixed BREATHING_MARGIN and nothing else.

---

## 3. Pipeline Phase Structure

### Before (Session 3)

```
Phase 1     — Ingest (per-video loop):
  1a. audio_cleanup
  1b. WhisperX transcription
  1c. audio_sync_offset
  1d. audio_analysis (VAD / Silero)
  1e. transcript_cleanup           ← REMOVED
  1f. persist to library.yaml

Phase 1.4   — extract_segments.rb  ← MODIFIED: reads semantic_segment output
Phase 1.5c  — audio_emotion.rb
Phase 1.5d  — merge_prosody_segments.rb
Phase 2     — discovery_pass.rb
Phase 3     — arrange.rb           ← MODIFIED: no clip_in/clip_out
Phase 4     — export               ← MODIFIED: seg_id lookup, simplified build
```

### After (Session 5)

```
Phase 1     — Ingest (per-video loop):
  1a. audio_cleanup
  1b. WhisperX transcription
  1c. audio_sync_offset
  1d. audio_analysis (VAD / Silero)
  1f. persist to library.yaml

Phase 1.35  — semantic_segment.rb              ← NEW (LLM, per-source)
Phase 1.4   — extract_segments.rb              ← MODIFIED (reads semantic output)
Phase 1.5c  — audio_emotion.rb                 (unchanged)
Phase 1.5d  — merge_prosody_segments.rb        (unchanged)
Phase 2     — discovery_pass.rb                (unchanged)
Phase 3     — arrange.rb                       ← MODIFIED (atom selection only)
Phase 4     — export_arrangement_xml.rb        ← MODIFIED (seg_id → t,e lookup)
              build_structure_cut.rb            ← SIMPLIFIED (massive code deletion)
```

### What semantic_segment.rb consumes

| Input | Source | Purpose |
|-------|--------|---------|
| Raw transcript JSON (word-level) | WhisperX (Phase 1b) | Every word with `start`, `end`, `word` |
| `*_speech_analysis.json` (long_pauses) | Silero VAD (Phase 1d) | Regions of silence between speech |
| `library.yaml` | Ingest | Source enumeration, profile reference, language |
| Profile YAML | `load_profile.rb` | Tone context for "usable" calibration |

### What semantic_segment.rb produces

- `transcripts/{source_basename}_semantic_segments.yaml` — per-source file containing usable segments with word-level data
- `transcripts/{source_basename}_discarded_segments.yaml` — per-source file containing not-usable segments (debug/audit only)

### What becomes obsolete

| Item | Disposition |
|------|-------------|
| `transcript_cleanup.rb` | Deprecated. Header marked. Removed from orchestrate.rb Phase 1e routing. |
| `cleaned_transcript` field in library.yaml | No longer written for new pipeline runs. Not removed from schema. |
| `snap_to_boundary()` in build_structure_cut.rb | Deleted. |
| `END_BUFFER` constant | Deleted. |
| `SNAP_TOLERANCE` constant | Deleted. |
| Overlap-clamp logic (~lines 675-731) | Deleted. |
| `trim_restart_inpoint()` function | Deleted. Semantic segmentation handles restart collapse. |
| Speech analysis loading in build_structure_cut.rb | Deleted. No longer needed for boundary snapping. |
| Transcript word loading in build_structure_cut.rb | Deleted. No longer needed for restart trimming. |
| `clip_in`/`clip_out` fields in arrangement.yaml | Removed. Atoms carry seg_id only; t/e derived at export. |

---

## 4. New Script: `semantic_segment.rb`

### Purpose

LLM-powered semantic segmentation. Reads a source video's raw word-level transcript and VAD pause data. Produces an array of coherent editorial segments (usable material) and a separate array of discarded material.

Replaces the prior two-step approach (transcript_cleanup.rb for stutter/filler removal + extract_segments.rb for mechanical Whisper-segment-to-YAML conversion) with a single LLM pass that understands editorial intent.

### CLI

```
ruby scripts/semantic_segment.rb --library <name> --source <filename>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--source` | string | **required** | Source video filename (e.g., `Dylan_Shorts_1.MP4`) |
| `--profile` | string | auto-detected | Creator profile name |
| `--llm-mode` | `api\|claude_code` | per profile | Override LLM mode |
| `--force` | boolean | `false` | Force regeneration (ignore cache) |

### Per-source iteration

Orchestrate.rb calls `semantic_segment.rb` once per source video in a loop (not in parallel — sequential to avoid race conditions on library.yaml and to respect API rate limits). The script processes exactly one source per invocation. Orchestrate handles the loop.

### Inputs (resolved internally)

1. **Raw transcript:** `transcripts/{treated_basename}_treated.json` — the WhisperX output. Located via library.yaml `transcript` field. Contains:
   - `segments[]` — Whisper-level segments (ignored for boundary decisions)
   - `segments[].words[]` — `{ word, start, end, score }` — word-level timestamps (PRIMARY INPUT)

2. **VAD long_pauses:** From `transcripts/{speech_analysis_name}` (located via library.yaml `speech_analysis` field). Contains:
   - `long_pauses[]` — `{ start, end, duration }` — silence regions

3. **Profile:** Loaded via `load_profile.rb`. Provides tone context for calibrating "usable" judgment.

4. **Library metadata:** `library.yaml` — source enumeration, language, content description.

### Output files

**Primary:** `transcripts/{source_basename}_semantic_segments.yaml`

```yaml
version: 1
input_fingerprint: <sha256>
generated_at: <ISO timestamp>
model: <model id>
source: "Dylan_Shorts_1.MP4"
language: english

segments:
  - start: 38.275
    end: 48.661
    text: "And that's when it hit me. Everything I was taught before age 20 was designed to make me a good employee, not a good builder, a good employee."
    word_count: 27
    words:
      - word: "And"
        start: 38.275
        end: 38.415
      - word: "that's"
        start: 38.575
        end: 38.795
      # ... all words in this segment with their timestamps
  - start: 49.634
    end: 58.270
    text: "So I started asking myself a very dangerous question..."
    word_count: 9
    words:
      - word: "So"
        start: 49.634
        end: 49.834
      # ...
```

**Audit:** `transcripts/{source_basename}_discarded_segments.yaml`

```yaml
version: 1
input_fingerprint: <sha256>  # same as primary
generated_at: <ISO timestamp>
source: "Dylan_Shorts_1.MP4"

discarded:
  - start: 28.066
    end: 37.566
    text: "Hold. OK, um, let me start again. And that's when it... no wait."
    reason: "false start — speaker restarts the thought at 38.275"
    word_count: 13
    words:
      - word: "Hold."
        start: 28.066
        end: 28.350
      # ...
```

### LLM call structure

**One call per source video.** The call receives the complete word-level transcript for that source plus VAD pause data.

**System prompt (cached across calls):**

```
You are an editorial segmentation engine for video post-production.

Your job: read a word-level transcript with precise timestamps and identify
coherent editorial units — continuous stretches of speech an editor would
consider as a candidate clip for the final cut.

{tone_context from profile — e.g., "This creator produces talking-head
entrepreneurship content. Conversational, direct, occasionally uses
repetition for emphasis."}

Editorial rules:
- A segment is "usable" if an editor would consider it for the cut. The bar
  is editorial viability, not perfection — a slightly rough delivery that
  contains a good point IS usable.
- A segment is "not-usable" if it's a restart, false start, aside to crew,
  mumble, reading notes to self, equipment check, or garbled speech that
  carries no editorial value.
- When the speaker restarts a thought, collapse to the final clean take.
  The earlier attempts go to discarded. If NO clean take exists (all attempts
  are partial), discard all of them.
- False starts: if a few words begin a thought that is immediately abandoned
  and restarted more completely, the false start goes to discarded and the
  complete version is one segment.
- Filler words (um, uh, like, you know, so) WITHIN an otherwise usable
  segment are KEPT in the segment — they are the speaker's natural speech
  pattern. Do not strip fillers. Segmentation decides boundaries, not word
  content.
- Single-word utterances that are not part of a sentence (e.g., "Cool.",
  "Hold.", stray "And.") go to discarded unless they serve a clear editorial
  function (e.g., a deliberate one-word close: "Period.").
- Segment boundaries must align exactly to word timestamps. segment.start =
  first_word.start, segment.end = last_word.end. Every word in the source
  must appear in exactly one segment (usable) or one discarded entry. No
  words may be dropped or invented.
- Use VAD long_pauses as hints for natural segment boundaries. A pause ≥1s
  between words is a strong signal for a segment break. But a pause alone
  does not determine usability — a 2-second pause followed by a clean
  thought is a segment boundary, not a discard.
- Preserve the speaker's rhetorical repetition. "No no no, listen" is
  intentional emphasis, not a stutter. When in doubt about whether repetition
  is rhetorical vs. disfluent, keep it (err toward usable).

Output format: YAML with two top-level keys:
- segments: array of usable segments, each with start, end, text, words[]
- discarded: array of not-usable segments, same shape plus a "reason" field

Every word from the input must appear in exactly one entry (segment or
discarded). This is a hard constraint — the output is invalid if any word
is missing or duplicated.
```

**User prompt structure:**

```
Source: {source_filename}
Duration: {mm:ss}
Language: {language}
Total words: {word_count}

## VAD Long Pauses (silence ≥1s)

{pause_start} - {pause_end} ({duration}s)
{pause_start} - {pause_end} ({duration}s)
...

## Word-Level Transcript

{word_index}: {word} [{start} - {end}]
{word_index}: {word} [{start} - {end}]
...

Segment the above transcript into usable and discarded groups.
Output YAML with `segments` and `discarded` arrays per the system prompt spec.
```

**Word-level format rationale:** Each word is presented as a single line with index, text, and timestamps. This is the most token-efficient representation (~8 tokens per word vs ~15 for JSON). The index provides the LLM an easy way to reference word positions.

### Caching

**Fingerprint computation:**

```ruby
parts = [
  Digest::SHA256.hexdigest(File.read(raw_transcript_path)),  # word content
  Digest::SHA256.hexdigest(File.read(speech_analysis_path)),  # VAD pauses
  profile_name.to_s,
  source_filename
]
input_fingerprint = Digest::SHA256.hexdigest(parts.join(':'))
```

**Cache check:** If `{source_basename}_semantic_segments.yaml` exists and its `input_fingerprint` matches, skip. Otherwise regenerate.

**Shadow-cache fingerprint gate:** Following the pattern from commit 029b901, pass `input_fingerprint` to `LLMClient.call`. If a `*_response.yaml` file exists in `pending_llm_calls/` but its fingerprint doesn't match, the response is discarded and the LLM is re-called.

**Invalidation cascade:** When semantic_segment.rb output changes for ANY source, `segments_classified.yaml` is stale (extract_segments.rb will detect this via its own fingerprint). This cascades through existing chain: segments_classified → discovery_pass → arrangement.

### Failure modes

| Failure | Behavior |
|---------|----------|
| Raw transcript missing for source | Abort loud: `"PIPELINE ABORT: No transcript for source {filename}"` |
| Speech analysis missing for source | Warn, proceed without VAD pauses (degrade gracefully — segmentation still works on word timing alone) |
| LLM returns malformed YAML | Standard recovery: strip code fences, attempt colon-in-string fixes. If still malformed after recovery, abort loud with path to raw response. |
| LLM drops words (output word count != input word count) | Abort loud: `"SEGMENTATION ABORT: Word count mismatch — input {N}, output {M}. {N-M} words lost/added."` Save raw response for debug. |
| LLM marks >80% of source as not-usable | Warn loud but DO NOT abort: `"WARNING: {pct}% of source {filename} marked not-usable ({discarded_count}/{total} words). Review discarded_segments.yaml."` Write output normally. |
| Source has <10 words | Skip segmentation, write single segment containing all words. Log: `"Source {filename} has {N} words — passing through as single segment."` |

---

## 5. Modified Script: `extract_segments.rb`

### What changes

Currently, extract_segments.rb reads `cleaned_transcript.json` and creates one YAML segment per Whisper segment. After Session 5:

1. **Primary input changes** from `cleaned_transcript.json` to `{source_basename}_semantic_segments.yaml` (semantic_segment.rb output).
2. **Segment boundaries** come from the LLM's semantic segmentation, not from Whisper's mechanical segment breaks.
3. **Fingerprint input** changes to include semantic_segment output files instead of cleaned_transcript files.
4. **Word-level data** is NOT carried into segments_classified.yaml (same as today — segments_classified stores `id, t, e, text, source` plus enrichment placeholders). The word-level data lives in the semantic_segments.yaml file and is available to downstream consumers that need it (e.g., export for boundary rendering).

### Inputs (after Session 5)

- `library.yaml` — to enumerate source videos
- Per-source `{source_basename}_semantic_segments.yaml` — semantic segmentation output (usable segments only)

### Output

Same shape as today: `segments_classified.yaml` with segment entries `{id, t, e, text, source, audio_*, prosody_*, visual}`. The only difference is that the segments reflect LLM-determined editorial units rather than Whisper's arbitrary chunking.

### Fingerprint

```ruby
fingerprint_parts = [video_list_yaml]
videos.each do |v|
  source_basename = File.basename(v['path'], File.extname(v['path']))
  seg_path = File.join(transcripts_dir, "#{source_basename}_semantic_segments.yaml")
  fingerprint_parts << Digest::SHA256.hexdigest(File.read(seg_path))
end
input_fingerprint = Digest::SHA256.hexdigest(fingerprint_parts.join(':'))
```

### Failure modes

- Missing `_semantic_segments.yaml` for any source → abort loud: `"PIPELINE ABORT: Semantic segments not found for source {filename}. Run Phase 1.35 first."`
- Empty segments array in semantic output → abort loud.

---

## 6. Arrangement Schema Change — v3

### The atom principle applied

Under D5.10, arrange.rb's job is to select atoms by ID and order them into chapters. It does NOT reason about timing within atoms. The arrangement schema reflects this:

### arrangement.yaml v3 (Session 5)

```yaml
version: 3
input_fingerprint: <sha256>
generated_at: <ISO timestamp>
selected_thesis: thesis_001
model: <model id>

arrangement_reasoning: |
  [How this cut serves the chosen thesis, key trade-offs made,
  why alternate-take overrides happened if any, how throughlines were honored.]

chapters:
  - id: chapter_001
    title: "Opening — master-prompt framing"
    segments:
      - seg_id: seg_011
        # NO clip_in, NO clip_out — derived from segments_classified.yaml at export
        clip_group_ref: cg_001     # optional — which clip_group this came from
        notes: "Chose seg_011 over recommended; thesis calls for clean delivery here"
      - seg_id: seg_013
        notes: null

throughline_honoring:
  - throughline_id: tl_001
    open_chapter: chapter_001
    middle_chapters: [chapter_003, chapter_005]
    close_chapter: chapter_007
    distance_seconds: 187
    notes: "Within distance_guidance"

unused_segment_audit:
  cut_by_thesis: [seg_005, seg_009, seg_022]
  alternate_take_not_chosen: [seg_004, seg_007]
  cut_for_pacing: [seg_017]
  bridge_dropped: [seg_028]
```

### What changed from v2

- `clip_in` and `clip_out` removed from segment entries. The atom's `t` and `e` in segments_classified.yaml ARE the source window. No per-clip timing overrides.
- `source` removed from segment entries. Derivable from seg_id → segments_classified.yaml lookup. (Reduces LLM output size and eliminates a class of hallucination — wrong source for a seg_id.)
- Version bumped to 3.

### Migration

export_arrangement_xml.rb detects schema version:
- v1 (Branch A/D legacy): `chapter['clips']` with `t_in`/`t_out` — existing path
- v2 (Session 3): `chapter['segments']` with `clip_in`/`clip_out` — existing path
- v3 (Session 5): `chapter['segments']` with `seg_id` only — new lookup path

---

## 7. Modified Script: `arrange.rb` — Prompt Simplification

### What changes

arrange.rb's prompt loses all timing math. Its job becomes: **select atoms by seg_id, order them into chapters, write chapter titles + editorial reasoning.** No clip_in/clip_out reasoning.

### Prompt changes

The output schema section in the prompt (currently lines ~205-232 of arrange.rb) changes to:

```
## Output Schema

Respond with ONLY valid YAML. No markdown code fences.

arrangement_reasoning: |
  [How this cut serves the chosen thesis, key trade-offs,
  why alternate-take overrides happened, how throughlines were honored.]

chapters:
  - id: chapter_001
    title: "Chapter title"
    segments:
      - seg_id: seg_NNN
        clip_group_ref: cg_NNN       # if from a clip_group
        notes: "editorial note"       # optional
  - id: chapter_002
    ...

throughline_honoring:
  - throughline_id: tl_NNN
    open_chapter: chapter_NNN
    middle_chapters: [chapter_NNN, ...]
    close_chapter: chapter_NNN
    notes: "within/outside distance_guidance"

unused_segment_audit:
  cut_by_thesis: [seg_NNN, ...]
  alternate_take_not_chosen: [seg_NNN, ...]
  cut_for_pacing: [seg_NNN, ...]
  bridge_dropped: [seg_NNN, ...]
```

**Removed from prompt:**
- "Use clip_in/clip_out from segment t/e values"
- Any reference to timing, source-relative video time, or trim reasoning
- `source` field in segment entries (derivable from seg_id)
- `distance_seconds` in throughline_honoring (the LLM doesn't know rendered durations without clip_in/clip_out; export can compute this from segment t/e + chapter ordering)

**Segments table in prompt:**
The compact segments block (currently lines ~125-134 of arrange.rb) keeps seg_id, source, duration, acoustic signals, and text. The timing (`t`-`e`) stays in the table for context (the LLM needs to understand relative positioning and duration), but the prompt makes clear that the LLM selects atoms by ID, not by time range.

---

## 8. Modified Script: `export_arrangement_xml.rb` — seg_id Lookup

### What changes

Currently, export_arrangement_xml.rb reads `clip_in`/`clip_out` from arrangement.yaml and passes them as `video_start`/`video_end` to build_structure_cut.rb's YAML config. Under v3:

1. Load `segments_classified.yaml` at startup.
2. Build a `seg_id → { t, e, source }` lookup table.
3. For each segment in arrangement chapters, look up `t` and `e` from segments_classified.yaml.
4. `source` is also derived from the lookup (not from arrangement.yaml).
5. Pass `video_start = t`, `video_end = e` to build_structure_cut.rb.

### New code (pseudocode)

```ruby
# Load segments_classified for seg_id → timing lookup
segments_classified = YAML.safe_load(File.read(segments_path), permitted_classes: [Date])
seg_lookup = {}
(segments_classified['segments'] || []).each do |s|
  seg_lookup[s['id']] = { 't' => s['t'], 'e' => s['e'], 'source' => s['source'] }
end

# In the chapter iteration, for v3 segments:
raw_clips = (chapter['segments'] || []).map do |seg|
  atom = seg_lookup[seg['seg_id']]
  abort "Unknown seg_id '#{seg['seg_id']}' — not in segments_classified.yaml" unless atom
  {
    'source' => atom['source'],
    't_in'   => atom['t'],
    't_out'  => atom['e'],
    'track'  => 'V1',
    'seg_id' => seg['seg_id']
  }
end
```

### What gets removed

- `transcript_map` loading (lines 94-102) — no longer needed for restart trimming
- `speech_analysis_map` passthrough to build_structure_cut config (lines 338-346) — no longer needed for snap_to_boundary
- `transcript` passthrough to build_structure_cut config (lines 348-356) — no longer needed

These removals apply to the v3 path only. v1/v2 legacy paths are preserved for backward compatibility.

---

## 9. Simplified Script: `build_structure_cut.rb` — Atom Rendering

### The simplification

Under D5.10, build_structure_cut.rb's job for rendering atoms is trivial:

```
rendered_start = clip.video_start - BREATHING_MARGIN
rendered_end   = clip.video_end   + BREATHING_MARGIN
```

Where `BREATHING_MARGIN = 0.080` (80ms). That's it.

The atom's `video_start` and `video_end` (which are segment `t` and `e` from segments_classified.yaml) ARE the speech boundaries — the first word's start and the last word's end, as determined by semantic_segment.rb. No further adjustment.

### What gets deleted

| Code block | Lines (approx) | Reason |
|------------|----------------|--------|
| `snap_to_boundary()` function | 419-449 | Atoms have precise boundaries; no snapping needed |
| `END_BUFFER` constant | 423 | Replaced by BREATHING_MARGIN |
| `SNAP_TOLERANCE` constant | 422 | No snapping |
| Speech analysis loading | 223-249 | No snap_to_boundary, no pause-based splitting |
| Transcript word loading | 251-275 | No restart trimming |
| `trim_restart_inpoint()` function | 452-567 | Semantic segmentation handles restarts |
| Snap-to-boundary call sites | 654-673 | Deleted with the function |
| Overlap-clamp logic | 675-731 | With fixed BREATHING_MARGIN and atom-sized clips, source overlap is structurally prevented — semantic segments don't overlap |
| Overlap-clamp state variables | 581-594 | Goes with the logic |
| Overlap-clamp summary output | 1758-1774 | Goes with the logic |
| `find_split_points()` function | 391-417 | No max_segment_duration splitting |
| Auto-split oversized segments | 958-1092 | No max_segment_duration splitting |

**Estimated net deletion: 300-400 LOC.**

### What stays

- Source format detection (ffprobe, dimensions, fps)
- Output format determination (vertical_short, match_source)
- BREATHING_MARGIN application (replaces breathing_room_frames — now a fixed 80ms, not frame-count-based)
- Clipitem XML emission (the core of the file)
- Sync audio handling (dual-system WAV track)
- Markers (Tier 0 narrative role, arrangement markers, chapter markers)
- Per-clip time domain detection (audio_start/video_start routing)
- Classification loading for tiered markers
- Template match / edit patterns loading

### BREATHING_MARGIN value

**80ms (0.080s).**

Rationale:
- At 25fps, one frame = 40ms. 80ms = 2 frames of padding per side.
- At 30fps, 80ms = 2.4 frames.
- At 24fps, 80ms = 1.9 frames.
- This captures the natural onset/release of consonants without reaching into adjacent segments.
- The old system compounded breathing_room_frames (3 frames = 120ms) with END_BUFFER (200ms) and SNAP_TOLERANCE (300ms), resulting in up to 620ms of boundary extension. 80ms is dramatically tighter and structurally safe because atoms don't overlap.

### Time domain handling

The BREATHING_MARGIN is applied in video time, same as the current buffer. Time domain conversion (WAV → video via sync_offset) still happens before the margin is applied. The per-clip sync audio lookup in export_arrangement_xml.rb handles this conversion.

---

## 10. Orchestrate.rb Routing Changes

### New Phase 1.35

Inserted between Phase 1 (per-video ingest loop) and Phase 1.4 (extract_segments):

```ruby
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
```

### Phase 1e removal

Remove the transcript_cleanup.rb call from the per-video ingest loop (currently at orchestrate.rb lines ~651-665). The `cleaned_transcript` field is no longer written to library.yaml by orchestrate for new pipeline runs.

### Phase 1.4 modification

extract_segments.rb now reads `_semantic_segments.yaml` instead of `cleaned_transcript.json`. The orchestrate routing for Phase 1.4 is unchanged (it just calls `extract_segments.rb --library <name>`), but the script's internal behavior changes per Section 5.

### New library.yaml field

Add per-video `semantic_segments` field:

```yaml
videos:
  - path: /path/to/video.MP4
    transcript: video_transcript.json
    semantic_segments: video_semantic_segments.yaml     # NEW
    speech_analysis: video_speech_analysis.json
```

Written by orchestrate.rb after semantic_segment.rb completes for each source. The `cleaned_transcript` field is not populated for new runs.

### Cache invalidation chain

```
semantic_segment.rb output changes (any source)
  → segments_classified.yaml fingerprint mismatch (extract_segments detects)
    → discovery_pass.yaml invalidated (extract_segments cascade-deletes)
      → arrangement.yaml invalidated (extract_segments cascade-deletes)
        → exported XML stale (export detects)
```

Existing cascade from Session 3, with semantic_segment as the new upstream node.

---

## 11. Prompt Design for Segmentation

### Goals

The prompt must achieve:
1. **Coherent grouping** — Words form editorial units, not mechanical chunks
2. **Restart collapsing** — Multiple takes → keep final clean take, discard earlier attempts
3. **False start absorption** — Partial starts attach to or split from following content
4. **Junk removal** — Mumbles, asides to crew, equipment checks → discarded
5. **Word-level precision** — Every segment boundary aligns to exact word timestamps
6. **Exhaustive coverage** — Every word from input appears in exactly one output entry

### System prompt

See Section 4 (LLM call structure) for full system prompt text. Key calibration points:

- **"Usable" threshold** is editorial viability, not perfection.
- **Filler words within segments are kept.** Segmentation decides boundaries, not word content.
- **Rhetorical repetition is preserved.**
- **Single-word fragments** go to discarded unless they serve a clear editorial function.

### Tone context

The profile's tone context (loaded via `LoadProfile.build_compact_tone_context`) is injected into the system prompt. This gives the LLM awareness of the creator's speaking style and content type — a meaningful calibration signal for distinguishing rhetorical repetition from disfluency, or conversational asides from junk. Include it in v1.

---

## 12. Schemas (Consolidated)

### `{source_basename}_semantic_segments.yaml` (NEW)

```yaml
version: 1
input_fingerprint: <sha256>
generated_at: <ISO timestamp>
model: <model id used>
source: "Dylan_Shorts_1.MP4"
language: english

segments:
  - start: <float>        # = first word's start timestamp
    end: <float>          # = last word's end timestamp
    text: <string>        # concatenated words
    word_count: <int>
    words:
      - word: <string>
        start: <float>
        end: <float>
```

Constraints:
- `start` = `words[0].start`, `end` = `words[-1].end`
- Chronological, non-overlapping
- Every word from input appears in exactly one segment or one discarded entry

### `{source_basename}_discarded_segments.yaml` (NEW)

```yaml
version: 1
input_fingerprint: <sha256>
generated_at: <ISO timestamp>
source: "Dylan_Shorts_1.MP4"

discarded:
  - start: <float>
    end: <float>
    text: <string>
    reason: <string>      # e.g., "false start", "restart take 1 of 3", "aside to crew"
    word_count: <int>
    words:
      - word: <string>
        start: <float>
        end: <float>
```

### `segments_classified.yaml` (UNCHANGED schema)

No schema change. Segments now originate from semantic_segment.rb output.

### `arrangement.yaml` v3 (CHANGED — see Section 6)

Segments carry `seg_id` only, no `clip_in`/`clip_out`/`source`.

---

## 13. Cost Model

### Per-source token estimate

For a word-level transcript, each word in the compact format (`{index}: {word} [{start} - {end}]`) costs approximately **8 tokens**.

| Source | Duration | Words | Input tokens (est.) | Output tokens (est.) |
|--------|----------|-------|--------------------|--------------------|
| Dylan Shorts 1 | 32:16 | 4,212 | ~34,000 | ~17,000 |
| MVI_5116 | 05:04 | 606 | ~5,000 | ~3,000 |
| MVI_5118 | 46:04 | 5,598 | ~45,000 | ~22,000 |
| MVI_5119 | 26:53 | 3,557 | ~29,000 | ~14,000 |
| MVI_5120 | 24:20 | 3,660 | ~30,000 | ~15,000 |
| **TOTAL** | **~135 min** | **17,633** | **~143,000** | **~71,000** |

**Input breakdown per call:** ~1,500 tokens for system prompt + ~500 tokens for VAD pauses + word data.

**Output:** Must include all words with timestamps for both segments and discarded arrays. Estimate output at ~50% of word-data input tokens.

**Cost estimate (Opus, API mode):**
- Input: 143K tokens x $15/M = **$2.15**
- Output: 71K tokens x $75/M = **$5.33**
- **Total for dylan-shorts-batch-1: ~$7.50**

On subscription billing (Claude Code), this is included. On API billing, $7.50 per library for a one-time segmentation pass is acceptable but worth tracking — a 20-library batch would be ~$150.

### Chunking strategy for long sources (60+ min)

**Open question — deferred to v2.** A 60-minute source at ~140 words/minute = ~8,400 words = ~67,000 input tokens. Within Opus's 200K context window. Dylan-shorts-batch-1's longest source is 46 minutes (5,598 words). Implement chunking only when a real source exceeds 10,000 words.

---

## 14. Validation Criteria

Session 5 is "shipped" when ALL of the following are true:

### 14.1 Pipeline completeness

- `semantic_segment.rb` runs on all 5 dylan-shorts-batch-1 sources and produces `_semantic_segments.yaml` + `_discarded_segments.yaml` for each.
- `extract_segments.rb` reads semantic segment output (not cleaned_transcript) and produces `segments_classified.yaml`.
- Full pipeline runs end-to-end: Phase 1 → 1.35 → 1.4 → 1.5c → 1.5d → 2 → 3 → 4.

### 14.2 Fragment elimination

The 5 single-word fragment segments currently in `segments_classified.yaml` are gone:
- `Cool.` (t=1228.01) — either absorbed into adjacent segment or in discarded
- `Hold.` (t=4.73) — in discarded (setup/equipment check)
- `care.` (t=106.38) — either absorbed or in discarded
- `And.` (t=194.33) — in discarded (false start fragment)
- Any other single-word orphans from similar patterns

Verify: `grep "text: " segments_classified.yaml | awk 'NF <= 3'` returns nothing that looks like an orphaned fragment.

### 14.3 Boundary leakage eliminated

The "Way." class of audible defect is absent from exported cuts. Verify by:
- Playing the exported XML in Premiere and listening to clip transitions
- Confirming build_structure_cut.rb stderr shows no snap/overlap-clamp messages (those code paths are deleted)
- 80ms BREATHING_MARGIN produces clean transitions with no audible speech from adjacent atoms

### 14.4 transcript_cleanup.rb removed from pipeline

- `orchestrate.rb` no longer calls `transcript_cleanup.rb` in Phase 1
- `transcript_cleanup.rb` has deprecated header comment
- Pipeline runs without creating `_cleaned.json` files for new sources

### 14.5 Atom integrity through pipeline

- arrange.rb output contains only seg_id references (no clip_in/clip_out)
- export_arrangement_xml.rb successfully resolves all seg_ids to t/e values from segments_classified.yaml
- build_structure_cut.rb receives video_start/video_end that exactly match segment t/e (no intermediate adjustment)

### 14.6 Qualitative cut improvement

For dylan-shorts-batch-1, compare a structure cut before and after Session 5:
- Opener has antecedent (no orphaned fragments at the start)
- No fragment hooks (single words that don't connect to meaning)
- Less leakage at boundaries (atom rendering working)
- Segment boundaries feel editorial rather than mechanical

### 14.7 Cache integrity

- Regenerating `_semantic_segments.yaml` for one source invalidates `segments_classified.yaml`, which cascades through discovery_pass → arrangement
- Running the pipeline twice with no input changes produces cache hits at every phase

### 14.8 Per-source validation (implementation gate)

During prompt iteration (implementation step b-c), ALL 5 dylan-shorts-batch-1 sources must individually pass spot-check before proceeding to extract_segments rewrite. Per-source quality is independent — one source segmenting well does not predict another.

---

## 15. Explicit Deferrals to Later Sessions

| Item | Deferred to | Rationale |
|------|-------------|-----------|
| Prosody as segmentation input | Session 5 v2 | Only add if v1 misses prosody-only-detectable defects |
| ASR engine swap (Deepgram etc.) | Separate evaluation | Only if transcription quality is the bottleneck after Session 5 |
| Critique phase 2.5 | Separate session | Arrangement-level editorial coherence, not segmentation |
| Branch C redesign | P5 | Finished-video template extraction |
| Visual analysis P2 | Separate workstream | Shot classification, B-roll correlation |
| Chunking for 60+ minute sources | Session 5 v2 | No current sources exceed threshold |
| Sonnet fallback for cost optimization | Post v1 quality measurement | Need quality baseline from Opus first |

---

## 16. What Gets Deprecated

### File: `scripts/transcript_cleanup.rb`

Add header:
```ruby
# DEPRECATED — Session 5 (v4.2). Job absorbed by semantic_segment.rb.
# Kept in tree for one release cycle, then deleted.
```

Remove from orchestrate.rb Phase 1e routing. File stays in tree.

### Code deleted from `build_structure_cut.rb`

Not deprecated — outright deleted:
- `snap_to_boundary()` and its constants (`SNAP_TOLERANCE`, `END_BUFFER`)
- `trim_restart_inpoint()` and its constants (`RESTART_FILLER`, `RESTART_GAP_THRESHOLD`)
- `find_split_points()` and `SENTENCE_BOUNDARY_THRESHOLD`
- Speech analysis loading block
- Transcript word loading block
- Overlap-clamp state machine and summary
- Auto-split oversized segments block

### Code deleted from `export_arrangement_xml.rb` (v3 path)

- `transcript_map` loading and passthrough
- `speech_analysis_map` passthrough to build_structure_cut config

### Fields removed from `arrangement.yaml`

- `clip_in`, `clip_out`, `source` in segment entries (v3 schema)

### `cleaned_transcript` field in library.yaml

Not removed from schema. Not populated for new pipeline runs. Existing values are dead data.

---

## 17. Implementation Order

| Step | Script | Type | Dependency |
|------|--------|------|------------|
| a | `semantic_segment.rb` — new script, stubbed LLM call | Create | None |
| b | Test prompt on Dylan Shorts 1 (32 min) | Iterate | a |
| c | Validate ALL 5 sources individually — spot-check segmentation quality, word coverage, restart collapsing, fragment elimination | Gate | b |
| d | `extract_segments.rb` — modify to consume semantic_segment output | Modify | c (all 5 sources pass) |
| e | `orchestrate.rb` — Phase 1.35 routing, Phase 1e removal | Modify | d |
| f | `transcript_cleanup.rb` — deprecation header | Modify | e |
| g | `arrange.rb` — prompt simplification (remove clip_in/clip_out, atoms by ID only) | Modify | d |
| h | `export_arrangement_xml.rb` — v3 schema detection, seg_id → t,e lookup | Modify | g |
| i | `build_structure_cut.rb` — delete snap/buffer/clamp/restart code, add BREATHING_MARGIN | Modify | h |
| j | End-to-end validation on dylan-shorts-batch-1 | Test | d, e, f, g, h, i |
| k | STATE.md, CLI.md regeneration | Docs | j |

**Critical path:** Steps a → b → c are the prompt iteration loop. Step c is a hard gate: all 5 sources must individually pass before continuing. This is where most design risk lives.

**Code deletion opportunity:** Steps g, h, i together are net-negative LOC. The atom principle makes the downstream pipeline dramatically simpler.

---

## 18. Open Questions (Surfaced, Not Resolved)

### 18.1 Very long sources (60+ min)

Single LLM call or chunked? Deferred. No current sources exceed the 10,000-word threshold. Strategy defined in Section 13 for when needed.

### 18.2 Over-aggressive discard

What if the LLM marks >80% of source as not-usable? Warn but don't abort. If it fires on real footage, investigate the prompt.

### 18.3 Interaction between atom rendering and existing pause removal

The current `auto_remove_pauses_above` feature (optional, profile-configured) splits clips at internal pauses. Under atoms-are-inviolate, this feature is in tension: you can't split an atom. Two options:
- **Option A:** Disable pause removal for atom-sourced clips. Pauses within an atom are part of the atom. If a pause is long enough to be objectionable, the semantic segmenter should have split the atom there.
- **Option B:** Treat pause removal as a post-atom rendering concern — it operates on the rendered timeline, not on atom boundaries. But this reintroduces the complexity we're deleting.

**Recommendation:** Option A. Disable auto_remove_pauses_above for v3-path clips. If internal pauses are a problem, iterate the segmentation prompt to produce finer atoms at pause points. This is cleaner than re-adding timeline surgery downstream.

### 18.4 Branch A compatibility

Branch A (script-driven) uses `branch_a_batch.rb` which produces its own arrangement format. Session 5 changes don't touch Branch A's path — it continues to use the v1 arrangement schema and the existing build_structure_cut.rb code paths. The v1/v2 legacy paths in export_arrangement_xml.rb and build_structure_cut.rb are preserved. Only the v3 path gets the simplified atom rendering.

---

**End of Session 5 spec.**
