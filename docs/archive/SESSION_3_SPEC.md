# Session 3 Spec — Discovery Pass + Arrange Rework

**Status:** Code-ready. Locked 2026-05-22.
**Supersedes:** Session 2 draft (discovery_pass spec, incomplete).
**Validation target:** Andreessen 2-video footage produces a thesis-driven Branch B cut end-to-end; Branch D consolidates onto discovery_pass.

---

## 1. Scope

**Session 3 ships, as one coordinated cutover on `dev`:**

- New deterministic script: `extract_segments.rb` (Phase 1.4)
- New LLM script: `discovery_pass.rb` (Phase 2, replaces classify + semantic_ingest)
- New slim utility script: `register_pool_sources.rb` (Phase D.2.5, replaces `convert_candidate.rb`'s source-registration job)
- Full rework of `arrange.rb` (thesis-driven, throughline-aware, clip_group-aware; also absorbs `convert_candidate.rb`'s arrangement-building job)
- `orchestrate.rb` updates: phase routing, **classify() function excised from orchestrate.rb**, Branch C kill, Branch D consolidation
- Branch C scripts marked deprecated; Branch D legacy scripts (`discover_arcs.rb`, `present_candidates.rb`, `convert_candidate.rb`) and `semantic_ingest.rb` marked deprecated. All kept in tree, removed from active routing.
- Schema migration: `segments_classified.yaml`, `arrangement.yaml`, new `discovery_pass.yaml`
- Visual analysis contract reserved as nil/empty fields (P2 plugs in later without re-spec)

**Session 3 does NOT ship:**

- Editorial critique phase 2.5 (P3 — separate session)
- Unused-segments backstop XML (P3 — separate session)
- P2 visual analysis implementation (its own session per VISION.md)
- Archetype template integration (P6 — separate session)
- Adapter layer for legacy classify+semantic_ingest output (explicitly rejected; cutover is clean)

**Cutover semantics:** No half-state. Either the whole new pipeline runs Branch B and Branch D end-to-end, or Session 3 is not done.

---

## 2. Architectural Decisions (Locked, Do Not Relitigate)

These were resolved across the design conversation that produced this spec. They are inputs, not topics.

**D1. Discovery scope = understanding + thesis(es).** Discovery_pass produces segments awareness, clip_groups (relational), throughlines (loop-aware), and ranked thesis candidates with logline + duration + shape_and_risk. Arrange selects against the chosen thesis. Critique-2.5 (future) audits as backstop.

**D2. LLM footprint principle: LLM only where determinism fails.** Every step that can be done by a dumb script is done by a dumb script. extract_segments is deterministic. Acoustic + prosody enrichment is deterministic. discovery_pass is the only LLM call in this pipeline segment.

**D3. Per-segment fields after extract+enrich:** `id, t, e, text, source` + 8 acoustic + `acoustic_pattern` + 4 prosody aggregates + reserved `visual: {...nil}` block. No `roles`, no `confidence`, no `states`, no `narrative_role`, no `distillation`. Editorial intelligence lives in top-level relational structures, not per-segment labels.

**D4. Three top-level relational outputs in discovery_pass.yaml:** `theses`, `clip_groups` (five types), `throughlines` (open/middle/close with distance).

**D5. clip_group types (five):** `alternate_takes`, `setup_payoff`, `tangent`, `bridge`, `run-on`. Throughlines are first-class, NOT a clip_group type.

**D6. Throughlines are first-class.** Schema: `{id, theme, open: seg_id, middle: [seg_id...], close: seg_id, distance_guidance, notes}`. Middle is positional/ordered, not typed. Nested sub-throughlines are by reference (own entry), not nested structure. Replaces old `open_loops` entirely.

**D7. Thesis schema = four fields.** `id`, `logline` (2–3 sentences, claim + arc), `duration` (one line: runtime + fit-vs-target if target set), `shape_and_risk` (one line: emotional arc + failure mode). No `key_beats`, no `confidence_score`.

**D8. Thesis count + duration handling.** Cap 5, no floor. No `--duration` flag → rank by strength, agnostic of runtime. `--duration mm:ss` flag → only surface theses within ±30s of target; if none qualify, emit empty list + note saying why.

**D9. Editorial bias for thesis emission AND arrange:** tight, retention-conscious, err shorter; but not thesis-purist — texture, asides, examples stay if they meaningfully advance OR meaningfully enrich AND are engaging on their own merits. Bar is "earns its seconds," not "serves the thesis exclusively." Baked into discovery_pass prompt as the editorial frame.

**D10. Review gate default-on.** Reused existing `--no-review` flag opts out. Review presents N theses (≤5), user picks one, arrange proceeds against chosen thesis.

**D11. Branch C dead.** Scripts marked deprecated, removed from orchestrate routing. P5 will rebuild from scratch as finished-video template extraction. `extract_template.rb` deprecated alongside.

**D12. Branch D consolidates onto discovery_pass.** `discover_arcs.rb` is replaced by discovery_pass running against pool-scoped segments file. Thesis selection for Branch D uses discovery_pass's review gate (same script as Branch B); `present_candidates.rb` is therefore redundant and deprecated. `convert_candidate.rb`'s arrangement-building logic is absorbed by arrange.rb; its only surviving job — registering pool source paths in library.yaml — is extracted into a new slim utility `register_pool_sources.rb` (Phase D.2.5). Source registration uses the chosen thesis's referenced clip_groups + throughlines to identify which pool sources to register, BEFORE arrange.rb runs.

**D13. Visual analysis contract reserved.** Per-segment `visual: {...}` block all-nil for now. Discovery_pass output reserves top-level `visual_context: {mode, summary, visual_groups: []}` all-nil for now. Discovery_pass and arrange prompts written with branch points for future modes (minimal/standard/full) but operate text+acoustic-only for Session 3.

---

## 3. Pipeline Phases (Branch B)

```
Phase 1     — Ingest (existing: audio_cleanup, WhisperX, audio_sync_offset, audio_analysis, transcript_cleanup)
Phase 1.4   — extract_segments.rb              [NEW, deterministic, no LLM]
Phase 1.5c  — audio_emotion.rb                 [existing, validated 2026-05-22]
Phase 1.5d  — merge_prosody_segments.rb        [existing, validated 2026-05-22]
Phase 1.5e  — visual analysis                  [P2; nil placeholders for now]
Phase 2     — discovery_pass.rb                [NEW, LLM, replaces classify + semantic_ingest]
Phase 2.5   — review gate                      [in discovery_pass.rb, default-on; --no-review skips]
Phase 3     — arrange.rb                       [REWORKED, thesis-driven]
Phase 4     — export_arrangement_xml.rb        [existing, mostly unchanged]
Phase 5     — export_packaging_brief.rb        [existing, updated to drop confidence weight]
```

## 3a. Pipeline Phases (Branch D)

```
Phase D.0   — Pool indexing (existing: pool_index.rb, detect_scenes, extract_visual_frames, match_hq_audio)
Phase 1.4   — extract_segments.rb              [NEW, runs pool-wide, single segments_classified.yaml]
Phase 1.5c  — audio_emotion.rb                 [existing]
Phase 1.5d  — merge_prosody_segments.rb        [existing]
Phase 1.5e  — visual analysis                  [P2 placeholder]
Phase 2     — discovery_pass.rb                [SAME script as Branch B; review gate handles thesis selection]
Phase D.2.5 — register_pool_sources.rb         [NEW, slim utility; registers pool source paths in library.yaml]
Phase 3     — arrange.rb                       [REWORKED, same script as Branch B, against chosen thesis]
Phase 4     — export_arrangement_xml.rb        [existing]
```

**Distinguishing Branch D from Branch B at runtime:** input scope (pool segments file vs single library) + a slim source-registration step (`register_pool_sources.rb`) between discovery_pass and arrange. Thesis selection itself uses the SAME review gate inside discovery_pass — no separate Branch D selection UX. `present_candidates.rb` is killed; `convert_candidate.rb` is killed (its arrangement-building moves to arrange, its source-registration moves to register_pool_sources).

---

## 4. NEW Script: `extract_segments.rb`

### Purpose
Deterministic, no-LLM script. Reads `cleaned_transcript.json` (one per source video in library.yaml), writes the minimal container `segments_classified.yaml` that audio_emotion and merge_prosody_segments enrich.

### CLI

```
ruby scripts/extract_segments.rb --library <name>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |

Positional args: none.

### Inputs

- `library.yaml` — to enumerate source videos and their `cleaned_transcript` paths
- Per-source `cleaned_transcript.json` files — WhisperX output post-cleanup

### Output

`segments_classified.yaml` in library directory. Shape:

```yaml
version: 1
segments:
  - id: seg_001
    t: 2.31              # start (seconds, video-time of source)
    e: 5.84              # end
    text: "..."          # transcript text
    source: "DJI_001.mov"   # source video filename
    # Acoustic fields populated by Phase 1.5c (audio_emotion):
    audio_profile: nil
    audio_energy: nil
    audio_energy_variance: nil
    audio_pitch_mean: nil
    audio_pitch_range: nil
    audio_pitch_trend: nil
    audio_speaking_rate: nil
    audio_spectral_centroid: nil
    acoustic_pattern: nil
    # Prosody aggregates populated by Phase 1.5d (merge_prosody_segments):
    stumble_count: nil
    mid_word_break_count: nil
    mean_trailing_pause_ms: nil
    max_within_segment_pause_ms: nil
    # Visual block reserved for P2:
    visual:
      shot_type: nil
      on_screen_elements: []
      camera_movement: nil
      is_broll: nil
      visual_style_tag: nil
```

### Behavior

- Iterates source videos in `library.yaml.videos` in their listed order.
- For each source, reads `cleaned_transcript.json`. One YAML segment entry per WhisperX segment. Preserves WhisperX's segment boundaries — no re-segmentation in this script (granularity question deferred to future P2 work).
- Assigns deterministic IDs `seg_001`, `seg_002`, ... in chronological order across ALL sources concatenated in the order they appear in library.yaml. `seg_NNN` is therefore stable across runs as long as the source list and segment boundaries don't change.
- `t` and `e` are source-video-relative times (NOT pool-timeline times). Downstream conversion to timeline/WAV time is handled where it's already handled today.
- `source` is the filename only (e.g., `"DJI_001.mov"`), matching the existing convention.
- Acoustic / prosody / visual fields written as `nil` (acoustic) or `[]` (lists) — enrichment scripts overwrite.

### Caching

- Hash input: SHA256 of (library.yaml.videos list + each cleaned_transcript.json content).
- If `segments_classified.yaml` exists with matching `input_fingerprint`, skip. Else regenerate and INVALIDATE downstream caches (discovery_pass.yaml, arrangement.yaml).
- Write `input_fingerprint` at top of file.

### Failure modes

- Missing cleaned_transcript.json for any source in library.yaml → abort loud with message naming the missing file.
- Empty cleaned_transcript.json → abort loud. Do not write empty segments file.
- Library has zero sources → abort loud.

### Called by
`orchestrate.rb` (Phase 1.4, all branches).

---

## 5. NEW Script: `discovery_pass.rb`

### Purpose
Single LLM call. Reads enriched `segments_classified.yaml`. Emits `discovery_pass.yaml` containing:
- Ranked thesis candidates (≤5)
- `clip_groups` (relational segment groupings)
- `throughlines` (loops with open/middle/close)
- Reserved `visual_context` block (P2)

Replaces the prior `classify()` + `semantic_ingest.rb` two-pass with one consolidated call. No per-segment classification — all editorial intelligence is relational.

### CLI

```
ruby scripts/discovery_pass.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--profile` | string | auto-detected | Creator profile name |
| `--no-review` | boolean | `false` | Skip interactive review gate |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |
| `--duration` | string (mm:ss) | `nil` | Target runtime; filters theses to within ±30s |

Positional args: none.

### Inputs

- `segments_classified.yaml` (post-enrichment): segments with acoustic + prosody features
- `library.yaml`: source enumeration, profile reference
- Profile YAML (loaded via `LoadProfile`): tone context, llm_routing for `call_type: 'discovery_pass'`

### Output

`discovery_pass.yaml` in library directory. Shape:

```yaml
version: 1
input_fingerprint: <sha256 of segments_classified.yaml content + profile name + duration target>
generated_at: <ISO timestamp>
model: <model id used>

theses:
  - id: thesis_001
    logline: |
      [2–3 sentences: condensed claim + arc-in-motion. Not a summary; a claim with story shape.]
    duration: "7:20"                              # OR "7:20, within 8:00 target" if --duration set
    shape_and_risk: |
      [One line: emotional arc + failure mode of this cut.]
  - id: thesis_002
    ...

clip_groups:
  - id: cg_001
    type: alternate_takes                         # alternate_takes | setup_payoff | tangent | bridge | run-on
    segments: [seg_004, seg_007, seg_011]
    theme: "Master-prompt framing — three attempts, third lands cleanest"
    selection_guidance:
      recommended: seg_011
      reason: "Clean delivery, no false start, lands the metaphor"
    trim_notes: "seg_011 has 0.8s dead air at end"
  - id: cg_002
    type: tangent
    segments: [seg_034]
    theme: "Aside about his daughter — warm, humanizes mid-section"
    selection_guidance: null                       # not always present
    trim_notes: null

throughlines:
  - id: tl_001
    theme: "Who benefits from the prompt-engineering boom?"
    open: seg_023
    middle: [seg_031, seg_044, seg_051]
    close: seg_058
    distance_guidance: "≥2 min between open and close; middles spread across the gap"
    notes: "Middle seg_044 is itself a mini-loop — see tl_003"
  - id: tl_002
    ...

visual_context:
  mode: null            # P2: minimal | standard | full
  summary: null         # P2: one-paragraph what's-here
  visual_groups: []     # P2: cross-segment visual relationships
```

### Prompt frame (high-level, build during implementation)

**System (cached, tone context):**
- Loaded from profile via existing `LoadProfile.build_compact_tone_context`.
- Plus the editorial frame from D9:
  > "Aim for the tightest, most engaging cut the material supports. Err shorter when possible. Texture, asides, and examples earn their place when they meaningfully advance OR meaningfully enrich the video AND are engaging on their own merits. Bar is 'earns its seconds,' not 'serves the thesis exclusively.'"

**User prompt structure:**
1. Library metadata (source count, total raw duration, profile name)
2. Full enriched segments table (id, t, e, text, source, acoustic_pattern, prosody aggregates, key acoustic features inline)
3. Duration target if set (`--duration` flag value, with ±30s window stated)
4. Task description:
   - Identify up to 5 thesis candidates ordered by strength. Cap at 5; floor is 1; if material only supports one, return one.
   - For each thesis, emit logline (2–3 sentences, claim + arc), estimated duration with fit annotation, shape_and_risk one-liner.
   - If `--duration` set, ONLY return theses whose estimated runtime is within ±30s of target. If none qualify, return empty theses list and a one-line `theses_filtered_note` explaining why.
   - Identify clip_groups across the five types. Express only relationships the material actually exhibits; don't invent.
   - Identify throughlines (loops with open/middle/close + distance). Nested sub-loops by reference.
   - `visual_context.mode = null` for this session; do not reason about visual yet.
5. Output strictly as YAML matching the schema above.

**Model:** Opus (per profile.llm_routing.discovery_pass; falls back to project default).

### Review gate behavior

If `--no-review` not passed:
- After LLM call returns and YAML parses cleanly, print to terminal:
  - All N theses with id + logline + duration + shape_and_risk
  - Count of clip_groups by type
  - Count of throughlines
- Prompt user: "Pick thesis (id or number), or 'r' to regenerate, or 'q' to abort."
  - User picks → write chosen thesis id into discovery_pass.yaml's top level as `selected_thesis: thesis_NNN`. Continue to arrange.
  - User picks `r` → re-run LLM call (count regenerations; cap at 3 to prevent loops).
  - User picks `q` → exit cleanly, leave discovery_pass.yaml in place for inspection.

If `--no-review` passed:
- Auto-select `theses[0]` (top-ranked). Write `selected_thesis: thesis_001`.

### Caching

- Hash input: SHA256 of (segments_classified.yaml content + profile name + duration target value).
- If `discovery_pass.yaml` exists with matching `input_fingerprint`, skip the LLM call.
- `selected_thesis` is NOT part of cache key — if file exists with valid fingerprint but no selected_thesis, re-run review gate only (not the LLM call).
- Cache invalidation propagates downstream: regenerating discovery_pass.yaml invalidates arrangement.yaml.

### Failure modes

- LLM returns malformed YAML → existing recovery (strip code fences, attempt colon-in-string fixes from semantic_ingest.rb). If still malformed after recovery, abort loud with stdout + path to saved raw response.
- LLM returns empty theses with no `theses_filtered_note` (duration-flag case only) → abort loud as schema violation.
- segments_classified.yaml missing or has unenriched segments (any acoustic field still nil after Phase 1.5c expected to run) → abort loud with clear message.
- Regeneration cap (3) hit during review gate → abort loud, suggest user revisit footage or adjust target.

### Called by
`orchestrate.rb` (Phase 2, both Branch B and Branch D).

---

## 6. NEW Script: `register_pool_sources.rb` (Branch D only)

### Purpose
Slim utility, no LLM. Replaces `convert_candidate.rb`. Reads the chosen thesis from discovery_pass.yaml, identifies which pool sources are referenced by the segments declared in that thesis's clip_groups and throughlines, and registers those source paths in library.yaml so arrange.rb and export can find the actual video files.

### CLI

```
ruby scripts/register_pool_sources.rb --library <name>
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |

Positional args: none.

### Inputs

- `discovery_pass.yaml` — must contain `selected_thesis`
- `segments_classified.yaml` — source the IDs in clip_groups + throughlines resolve back to
- `library.yaml` — to update
- Pool index (`<pool>/index.yaml` via `pool_index.rb`) — to look up actual file paths from source filenames

### Behavior

1. Read `selected_thesis` from discovery_pass.yaml. Abort loud if missing.
2. Collect all segment IDs referenced by clip_groups (any type) and throughlines in discovery_pass.yaml. This is the "candidate material" for the chosen thesis — superset of what arrange will actually pick. Over-registration is intentional and safe.
3. For each segment ID, look up its `source` filename in segments_classified.yaml.
4. For each unique source filename, look up the actual file path in pool_index.
5. Write entries into `library.yaml['videos']` — one per source — with full path, cleaned_transcript path, and any other fields the existing convention requires (model existing convert_candidate.rb behavior here).
6. Idempotent: if a source is already registered with the same path, leave it.
7. Abort loud if any referenced source is missing from pool_index.

### Caching

No caching needed. Script is cheap, runs once between discovery_pass and arrange.

### Failure modes

- `selected_thesis` missing in discovery_pass.yaml → abort loud.
- Source filename in segments_classified.yaml not found in pool_index → abort loud, name the missing source.
- Pool index missing → abort loud (Branch D requires pool indexing to have run).

### Called by
`orchestrate.rb` (Phase D.2.5, Branch D only).

---

## 7. REWORKED Script: `arrange.rb`

### What changes

- **Inputs:** Now reads `discovery_pass.yaml` (chosen thesis + clip_groups + throughlines) in addition to `segments_classified.yaml`. No longer reads classify output or semantic_ingest output (those scripts are gone).
- **Editorial frame:** Now thesis-constrained. Selection happens against the chosen thesis. The "what to make" decision has already been made upstream (discovery_pass + review gate).
- **Decisions arrange owns:**
  - Which segments to include in the cut (selection against thesis)
  - Order (sequencing against thesis arc + throughlines)
  - Take selection from `alternate_takes` clip_groups (may override `selection_guidance.recommended` when thesis demands)
  - Trim points within segments (informed by acoustic signals already on segment + clip_group `trim_notes`)
  - Tangent inclusion calls (against the editorial bias from D9)
  - Honoring throughline distance_guidance (loops can't collapse, opens can't be stranded)
  - Honoring setup_payoff adjacency
- **Decisions arrange does NOT own:**
  - Which thesis to pursue (discovery_pass + review gate)
  - Whether a relationship between segments exists (discovery_pass declared it)
  - Visual coherence (P2; arrange will read visual_groups when mode is `full`, ignored for Session 3)

### CLI

```
ruby scripts/arrange.rb --library <name> [options]
```

| Flag | Type | Default | Description |
|------|------|---------|-------------|
| `--library` | string | **required** | Library name |
| `--profile` | string | auto-detected | Creator profile name |
| `--no-review` | boolean | `false` | Skip interactive review gate (on arrangement output) |
| `--llm-mode` | `api\|claude_code` | `[unknown]` | Override LLM mode |

**Removed flags:** `--format longform|shorts` (no longer in the pipeline; format goes through profile or future `--duration`/`--platform` flags from P2 roadmap, not Session 3).

### Inputs

- `discovery_pass.yaml` — required, must contain `selected_thesis`
- `segments_classified.yaml` (enriched)
- `library.yaml`
- Profile YAML

### Prompt frame (high-level)

**System (cached):** tone context + the same editorial bias frame from D9 (verbatim) + arrange-specific framing:

> "You have been given a chosen thesis. Your job is to select and order segments from the material that serve this thesis as the tightest, most engaging cut possible. You must honor declared relationships: alternate_takes pick one; setup_payoff segments travel together; throughline open/close pairs must both appear with the specified distance between them; bridge and run-on groupings preserve their internal coherence; tangents are evaluated against the editorial bias. You may override clip_group `selection_guidance.recommended` when the thesis specifically demands a different take, and you must state why in `arrangement_reasoning`."

**User prompt:**
1. Chosen thesis (full logline, duration, shape_and_risk)
2. Clip_groups (full)
3. Throughlines (full)
4. Enriched segments table (compact form: id, source, duration, key acoustic signals, text)
5. Task: produce arrangement.yaml selecting and ordering segments

### Output

`arrangement.yaml` shape:

```yaml
version: 2
input_fingerprint: <sha256 of discovery_pass.yaml + segments_classified.yaml>
generated_at: <ISO timestamp>
selected_thesis: thesis_001                   # carried forward from discovery_pass
model: <model id>

arrangement_reasoning: |
  [LLM-emitted: how this cut serves the chosen thesis, key trade-offs made,
  why alternate-take overrides happened if any, how throughlines were honored.]

chapters:
  - id: chapter_001
    title: "Opening — master-prompt framing"
    segments:
      - seg_id: seg_011
        source: "DJI_001.mov"
        clip_in: 2.31              # video-time, source-relative
        clip_out: 5.40
        clip_group_ref: cg_001     # which clip_group this came from, for unused-segments XML later
        notes: "Chose seg_011 over recommended; thesis calls for clean delivery here"
      - seg_id: seg_013
        ...
  - id: chapter_002
    ...

throughline_honoring:
  - throughline_id: tl_001
    open_chapter: chapter_001
    middle_chapters: [chapter_003, chapter_005]
    close_chapter: chapter_007
    distance_seconds: 187           # actual distance between open and close in the cut
    notes: "Within distance_guidance"

unused_segment_audit:                # for unused-segments backstop XML (future P3 work)
  cut_by_thesis: [seg_005, seg_009, seg_022]
  alternate_take_not_chosen: [seg_004, seg_007]
  cut_for_pacing: [seg_017]
  bridge_dropped: [seg_028]
```

The `unused_segment_audit` block costs nothing extra to emit (LLM already knows what it didn't pick and why) and provides P3's unused-segments XML the binning information it needs.

### Caching

- Hash input: SHA256 of (discovery_pass.yaml content + segments_classified.yaml content + profile name).
- If arrangement.yaml exists with matching `input_fingerprint`, skip the LLM call.
- Cache invalidation: regenerating arrangement.yaml invalidates exported XML.

### Failure modes

- discovery_pass.yaml missing or has no `selected_thesis` → abort loud, instruct user to run Phase 2 first.
- Arrangement references a `seg_id` not present in segments_classified.yaml → abort loud (LLM hallucination).
- Throughline distance_guidance violated → warn but don't abort; record in `arrangement_reasoning`.
- Setup_payoff broken (one segment of a pair in cut, other not) → warn loud; record in `arrangement_reasoning`.

### Called by
`orchestrate.rb` (Phase 3, both Branch B and Branch D).

---

## 8. orchestrate.rb Changes

### Branch routing

- **Default Branch B path:** Phase 1 → Phase 1.4 → Phase 1.5c → Phase 1.5d → Phase 2 → Phase 3 → Phase 4 → Phase 5
- **Branch A path:** UNCHANGED for Session 3. Branch A's lean refactor is its own VISION.md item; do not touch Branch A routing in this session beyond the classify() excision below (which Branch A does not call).
- **Branch D path:** Phase D.0 (pool indexing) → Phase 1.4 → Phase 1.5c → Phase 1.5d → Phase 2 → Phase D.2.5 (register_pool_sources) → Phase 3 → Phase 4

### Inline code changes

- Delete the `classify()` function definition in orchestrate.rb (~line 1482) and its call sites (~lines 949 and 954). Replace its job with `discovery_pass.rb` call at Phase 2. There is no script file to deprecate; this is a code excision.

### Flag changes

- **Remove from active routing:** `--analyze-only`, `--branch C`. These flags should error with a clear message: "Branch C deprecated as of v4.1; will be redesigned in P5."
- **Add:** `--duration mm:ss` (passes through to discovery_pass.rb).
- **Keep:** `--mode mine`, `--candidate`, `--force-cascade`, `--force-reindex`, `--force-rediscover`, `--no-review`, `--llm-mode`, `--profile`, `--library`, `--pool-dir`, `--language`, `--force-revisualize`.

### Legacy Branch D script retirement

`discover_arcs.rb`, `present_candidates.rb`, and `convert_candidate.rb` are removed from orchestrate routing. Branch D's pipeline runs `discovery_pass.rb` (with built-in review gate) → `register_pool_sources.rb` → `arrange.rb`. All three legacy scripts stay in tree marked deprecated for one release cycle, then deleted.

### Phase progression: aborts hard between phases

- Phase 1.4 must succeed before 1.5c runs.
- 1.5c + 1.5d both must succeed before Phase 2 runs.
- Phase 2 must succeed AND have `selected_thesis` set before Phase D.2.5 (Branch D) or Phase 3 (Branch B) runs.
- Phase D.2.5 must succeed before Phase 3 (Branch D only).
- Phase 3 must succeed before Phase 4 runs.

This is existing orchestrate.rb behavior; just confirming it's preserved across the new phase set.

---

## 9. Branch C + Branch D Legacy Deprecation Checklist

### Code excision (not file deprecation)

**`classify()` function in `scripts/orchestrate.rb`** — this is an inline function (defined ~line 1482, called ~lines 949 and 954), not a standalone script. Delete the function definition and its call sites from orchestrate.rb as part of the Phase 2 routing rework. There is no script file to mark deprecated.

### Files to mark with header comment `# DEPRECATED — see VISION.md P5. Will be replaced by finished-video template extraction.`:

Branch C scripts (per D11):
- `scripts/discover_storylines.rb`
- `scripts/match_templates.rb`
- `scripts/score_coherence.rb`
- `scripts/generate_report.rb`
- `scripts/detect_structure.rb`
- `scripts/sanity_check.rb`
- `scripts/extract_template.rb`

### Files to mark with header comment `# DEPRECATED — replaced by discovery_pass.rb / arrange.rb / register_pool_sources.rb in Session 3 (v4.1).`:

Branch D legacy + semantic_ingest (per D12):
- `scripts/discover_arcs.rb` — replaced by discovery_pass.rb
- `scripts/present_candidates.rb` — replaced by discovery_pass review gate
- `scripts/convert_candidate.rb` — arrangement-building absorbed by arrange.rb; source-registration extracted into register_pool_sources.rb
- `scripts/semantic_ingest.rb` — replaced by discovery_pass.rb

### CLI.md updates:
- Move all deprecated scripts above under a "## Deprecated" heading at the bottom of the file.
- Add a one-line note at the top of CLI.md: "Branch C, classify(), and the legacy Branch D candidate-selection scripts are deprecated as of v4.1; see VISION.md."

### STATE.md regeneration after Session 3 ships:
- Branch C status: "Shipped" → "Deprecated, awaiting P5 redesign."
- Mode D status: "Shipped" → "Reworked v4.1 — runs on discovery_pass.rb + register_pool_sources.rb + arrange.rb."

---

## 10. Schemas (Consolidated)

### segments_classified.yaml (post extract_segments + enrichments)

```yaml
version: 1
input_fingerprint: <sha256>
segments:
  - id: seg_NNN
    t: <float>
    e: <float>
    text: <string>
    source: <filename>
    audio_profile: <descriptor string>
    audio_energy: <value>
    audio_energy_variance: <value>
    audio_pitch_mean: <value>
    audio_pitch_range: <value>
    audio_pitch_trend: <value>
    audio_speaking_rate: <value>
    audio_spectral_centroid: <value>
    acoustic_pattern: <descriptor string>
    stumble_count: <int>
    mid_word_break_count: <int>
    mean_trailing_pause_ms: <int>
    max_within_segment_pause_ms: <int>
    visual:
      shot_type: null
      on_screen_elements: []
      camera_movement: null
      is_broll: null
      visual_style_tag: null
```

### discovery_pass.yaml

See Section 5 output spec.

### arrangement.yaml v2

See Section 6 output spec.

---

## 11. Validation Criteria

Session 3 is "shipped" when ALL of the following are true:

1. `extract_segments.rb` runs on the Andreessen 2-video library and produces a complete segments_classified.yaml with all source segments, deterministic IDs in chronological order, and source fields populated.

2. Phase 1.5c (audio_emotion) and 1.5d (merge_prosody_segments) run unchanged against the new segments_classified.yaml shape and populate all 8 acoustic features + acoustic_pattern + 4 prosody aggregates per segment. (Validates extract_segments didn't break enrichment scripts.)

3. `discovery_pass.rb` runs against the enriched segments file and produces a discovery_pass.yaml with:
   - At least 1 thesis, no more than 5
   - At least 1 clip_group of any type
   - Each thesis has logline, duration, shape_and_risk
   - YAML parses cleanly
   - Review gate fires and accepts user selection; --no-review skips and auto-selects thesis_001

4. `arrange.rb` runs against discovery_pass.yaml + segments_classified.yaml and produces arrangement.yaml v2 with:
   - selected_thesis carried forward
   - Chapters with ordered segments
   - throughline_honoring block populated if discovery emitted throughlines
   - unused_segment_audit block populated
   - No segment ID hallucinations (all referenced IDs exist in segments_classified.yaml)

5. `export_arrangement_xml.rb` runs against the new arrangement.yaml v2 and produces a Premiere XML that opens cleanly in Premiere.

6. Full Branch B pipeline runs end-to-end on Andreessen footage via `orchestrate.rb --library andreessen --branch B` with no manual intervention and produces a final XML.

7. Branch D consolidation works: existing pool footage (e.g., dbtest pool) runs through orchestrate with `--mode mine`, discovery_pass produces thesis candidates, review gate accepts selection, register_pool_sources.rb registers the referenced pool sources in library.yaml, arrange.rb produces arrangement.yaml v2, export produces XML. No invocation of `discover_arcs.rb`, `present_candidates.rb`, or `convert_candidate.rb` in the Branch D path.

8. Branch C flags (`--analyze-only`, `--branch C`) error out with deprecation message; legacy scripts marked deprecated but stay in tree.

9. Cache invalidation works: regenerating segments_classified.yaml invalidates discovery_pass.yaml and arrangement.yaml; regenerating discovery_pass.yaml invalidates arrangement.yaml.

10. STATE.md and CLI.md regenerated to reflect the new pipeline state.

---

## 12. Explicitly Deferred to Later Sessions

- **Editorial critique phase 2.5** (P3) — audits arrangement against thesis before export
- **Unused-segments backstop XML** (P3) — uses arrangement.yaml's `unused_segment_audit` block as binning input
- **P2 visual analysis** — populates `visual:` block on segments + `visual_context` block on discovery_pass output
- **Branch A lean refactor** (separate VISION.md item) — keeps existing branch_a_batch path for now
- **P5 Branch C redesign** — finished-video template extraction, rebuilt from scratch
- **P6 archetype amalgamation** — multi-source template synthesis from Branch C outputs
- **Flag surface redesign** (P2 roadmap: `--duration`, `--aspect`, `--platform` orthogonal flags) — Session 3 adds `--duration` only as proof-of-concept; full redesign deferred
- **VAD silence cutting** — deferred per existing roadmap
- **Bass** — parallel development, not Session 3 scope

---

## 13. Implementation Sequence (Recommended Order Within Session 3)

1. **extract_segments.rb** first. Smallest, deterministic, validates segments_classified.yaml shape change end-to-end through enrichment scripts BEFORE any LLM work.
2. **Validate 1.5c + 1.5d** against new segments file. If broken here, the whole pipeline blocks; fix before LLM work begins.
3. **discovery_pass.rb prompt + LLM call** — write prompt, write output parser, write review gate. Validate YAML output structure before integrating with arrange.
4. **arrange.rb rework** — gut classify+semantic_ingest reads, wire in discovery_pass.yaml reads, rebuild prompt against the new editorial frame.
5. **register_pool_sources.rb** — slim utility. Reads discovery_pass.yaml + segments_classified.yaml, writes pool source paths into library.yaml. Branch D only.
6. **orchestrate.rb routing updates** — phase rewiring, classify() excision, Branch C kill, Branch D consolidation (drop discover_arcs/present_candidates/convert_candidate from routing).
7. **Deprecation file headers + CLI.md update** — Branch C scripts plus Branch D legacy scripts.
8. **End-to-end validation** on Andreessen footage (Branch B) and pool footage (Branch D).
9. **STATE.md + CLI.md regeneration.**

---

## 14. Open Questions / Risk Areas (For Implementation Awareness, Not Re-Litigation)

- **Discovery_pass token cost.** Full enriched segments table + relational reasoning is a sizeable prompt. Existing `semantic_ingest` already runs on similar input; discovery_pass adds clip_group + throughline + thesis reasoning but kills per-segment labeling. Net expected: roughly similar input size, larger output. Watch token usage on first runs.
- **Throughline distance_guidance violations.** First runs will reveal whether the LLM honors distance instructions or whether prompt needs tightening.
- **Review gate UX.** Three theses with three-line summaries each is ~30 lines of terminal output. Probably fine. Watch user feedback.
- **`--duration` filter strictness.** ±30s window may filter out everything on some footage. The "empty theses + note" path needs to actually fire cleanly, not just produce a confusing empty file.
- **Branch D's pool-scoped segments file.** Pool can be much larger than a single library. Discovery_pass prompt with all pool segments may hit context limits. May need pre-filtering at extract_segments time for Branch D (e.g., only segments from sources flagged "ingested" in pool_index). Flag this if it bites during validation.

These are implementation-time concerns to be aware of, not architectural decisions requiring further design.

---

**End of Session 3 spec.**
