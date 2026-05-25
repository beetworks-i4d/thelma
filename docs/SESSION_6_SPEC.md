# Session 6 Specification: candidate_builder.rb

**Locked:** 2026-05-25
**Status:** SPEC ONLY — not implemented
**Prereqs:** Session 5 complete (atom architecture, semantic_segment, extract_segments, discovery_pass, arrange v3, export)

> **LLMs judge meaning. Scripts handle mechanics.**

---

## Goal

Build `candidate_builder.rb` — the editorial enrichment layer that bridges Session 5's content-pure atoms to the full editorial intelligence pipeline from main branch (v3.1).

**Input:** `segments_classified.yaml` (atoms with t, e, text, source, acoustic/prosody fields)
**Output:** `editorial_candidates.yaml` conforming to `editorial_candidate.schema.yaml` v1.2

This restores the editorial metadata that main branch's `classify()` provided, adapted for the atom architecture, and adds the mechanical substrate (trim/exclusion options) that main never had.

### Phase Definitions

- **Phase A** = Deterministic substrate generation. No LLM calls. Produces all mechanical data: candidate spans, IDs, trim_choices, exclusion_choices, boundary safety, prosody aggregation, cluster labels.
- **Phase B** = Semantic labeling only. One LLM call. Produces all editorial judgments: states, durability, confidence, candidate_priority, usability, summary, distillation, suggested_narrative_roles, content_preserved evaluations.
- **Phase C** = Deterministic validation. No LLM calls. Validates merged Phase A + B output against editorial_candidate.schema.yaml v1.2. Hard gate — pipeline aborts on failure.

---

## Architecture

```
segments_classified.yaml (from extract_segments.rb + audio_emotion + merge_prosody)
         │
         ▼
┌─────────────────────────────────────┐
│ candidate_builder.rb                │
│                                     │
│  Phase A — Deterministic Substrate  │
│    Generate candidate spans         │
│    Assign id (cand_NNN)             │
│    Compute segment_ids, t, e, text  │
│    Compute trim_choices (trim_NNN)  │
│    Compute exclusion_choices(ex_NNN)│
│    Evaluate mechanical_boundary_safe│
│    Detect lexical clusters          │
│    Aggregate prosody                │
│                                     │
│  Phase B — Semantic Labeling (LLM)  │
│    Classify states (15-state)       │
│    Assign distillation (5-word)     │
│    Assign summary, usability        │
│    Assign durability tier           │
│    Assign candidate_priority        │
│    Assign confidence                │
│    Suggest narrative roles          │
│    Evaluate content_preserved       │
│                                     │
│  Phase C — Deterministic Validation │
│    Structural checks                │
│    Taxonomy checks                  │
│    Data integrity checks            │
│    Referential integrity            │
│    Reject invented IDs/timestamps   │
│                                     │
└─────────────────────────────────────┘
         │
         ▼
editorial_candidates.yaml
         │
         ├──▶ discovery_pass.rb (reads candidates for thesis proposals)
         ├──▶ arrange.rb (selects candidates by candidate_id for v4 arrangement)
         └──▶ export_arrangement_xml.rb (resolves IDs to mechanical data)
```

---

## Pipeline Integration

### New phase: 1.6

`candidate_builder.rb` runs as Phase 1.6 in orchestrate.rb:

```
Phase 1.4  — extract_segments      → segments_classified.yaml (atoms, nil enrichment fields)
Phase 1.5c — audio_emotion         → segments_classified.yaml (acoustic fields filled)
           — merge_prosody         → segments_classified.yaml (prosody fields filled)
Phase 1.6  — candidate_builder     → editorial_candidates.yaml    ← NEW
Phase 1.5d — scene detection       → scene_changes.yaml
Phase 2    — discovery_pass        → discovery_pass.yaml (now reads editorial_candidates)
Phase 3    — arrange               → arrangement.yaml v4 (candidate-based)
Phase 4    — export                → XML (resolves candidate_ids)
```

### Downstream changes required

1. **discovery_pass.rb** — Update prompt to read editorial_candidates.yaml instead of (or in addition to) segments_classified.yaml. The enriched candidates provide states, distillation, and candidate_priority that improve thesis quality.

2. **orchestrate.rb** — Add Phase 1.6 call. Update cache invalidation: editorial_candidates.yaml stale → delete discovery_pass.yaml + arrangement.yaml.

---

## Phase A — Deterministic Substrate

Phase A operates on pure mechanical data. No LLM calls. Fully deterministic given the same input.

**Deterministic guarantee:** Given identical inputs (same segments_classified.yaml content), Phase A must produce byte-identical outputs. No randomness, no timestamp-based IDs, no non-deterministic ordering.

### Inputs

- `segments_classified.yaml` — atom list with t, e, text, source, word-level timing (from semantic_segment), acoustic fields (from audio_emotion), prosody fields (from merge_prosody)

### Operations

1. **Generate candidate spans** — group contiguous same-source segments into candidate spans. A candidate may wrap one or more atoms. All segments in a candidate must share the same source.

2. **Assign candidate id** — sequential `cand_001`, `cand_002`, etc. Compute `segment_ids` (array of seg_NNN references), `t` (earliest segment start), `e` (latest segment end), `text` (concatenated segment texts).

3. **Compute trim_choices** (each assigned id `trim_NNN`, with `in`/`out`/`label`/`mechanical_boundary_safe`):
   - `full_clean` — in and out match candidate t/e. Always included. Always `mechanical_boundary_safe: true`.
   - `tighter_start` — trimmed to first word onset + BREATHING_MARGIN (80ms). Boundary-safe if margin doesn't cross segment boundary.
   - `tighter_end` — trimmed to last word offset + BREATHING_MARGIN (80ms).
   - `both_tighter` — both start and end tightened.
   - `minimal_trim` — for segments with false starts detected acoustically (stumble_count > 0), compute a trim that starts after the false start. Requires word timing.

4. **Compute exclusion_choices** (each assigned id `ex_NNN`, with `start`/`end`/`type`/`reason`/`recommended`):
   - Type `defect`: stumbles, false starts, abandonment detected from acoustic analysis
   - Type `pacing`: long pauses, trailing off, dead air, low-energy pauses detected from VAD/prosody

5. **Evaluate mechanical_boundary_safe** for each trim and exclusion:
   - Safe if boundary aligns with word onset/offset (within 20ms tolerance)
   - Safe if boundary aligns with VAD pause edge
   - Unsafe if boundary falls mid-word or mid-phoneme

6. **Detect lexical clusters** — deterministic text-similarity clustering using segment text. Assign `cluster` field (snake_case label or null). No embeddings required — lexical overlap is sufficient for initial clustering.

7. **Aggregate prosody** — compute `prosody` object (audio_profile, energy, stumble_count, max_pause_ms, pitch_trend) from source segment acoustic data.

### Output

A complete `editorial_candidates.yaml` with all Phase A fields populated and all Phase B fields set to null.

---

## Phase B — Semantic Labeling (LLM)

Phase B makes exactly ONE LLM call that labels all candidates. It receives the complete Phase A substrate as context.

**Phase B may NOT:**
- Invent any IDs (no new cand_NNN, trim_NNN, ex_NNN, seg_NNN)
- Invent any timestamps or time values
- Modify Phase A substrate structure (no adding/removing trim_choices or exclusion_choices)
- Generate trim or exclusion ranges
- Add fields not defined in the Phase B section of editorial_candidate.schema.yaml v1.2

### Prompt Design

**System message:** Tone context from profile (cached).

**User message structure:**
```
## Candidates

[Table: id | segment_ids | source | t-e | text | audio_profile | energy | stumble_count | trim_count | exclusion_count]

## Task

For each candidate, provide:
1. states (1-3 from 15-state taxonomy, primary first)
2. distillation (5-word max summary of WHAT it says)
3. durability (spike | mood | identity)
4. candidate_priority (primary | secondary | tertiary)
5. confidence (high | medium | low)
6. summary (25-word max of what candidate says/does)
7. usability (fine | marginal | unusable)
8. suggested_narrative_roles (ranked, max 3: hook, setup, continuation, payoff, transition, claim, evidence, definition, aside — with confidence per role)
9. For each trim_choice: content_preserved (true/false — does the trim retain core meaning?)
10. edit_notes (optional debug notes)

## Content Psychopharmacology Reference

[Condensed taxonomy: state name, definition, durability class — 15 entries]

## Output Format

[Exact YAML schema]
```

### LLM Restrictions

The LLM output must contain ONLY:
- `id` (echoed back for alignment — must match input exactly)
- Editorial label fields (states, distillation, durability, candidate_priority, confidence, summary, usability, suggested_narrative_roles, edit_notes)
- `content_preserved` evaluations keyed by trim choice id

The LLM output must NOT contain:
- Timestamps or time values of any kind
- New IDs (no invented cand_NNN, trim_NNN, ex_NNN)
- Source paths
- Trim or exclusion ranges
- Any field not in the Phase B schema

### Pending File Pattern

Phase B uses the same pending-file pattern as discovery_pass and arrange:
1. Write `pending_llm_calls/editorial_labeling.yaml` with prompt + input_fingerprint
2. If `--llm-mode claude_code`: exit 2 (paused). External agent reads pending, writes response, pipeline resumes.
3. If `--llm-mode api`: call LLM directly via llm_client.rb, parse response.

### Merge Strategy

Phase B output is merged INTO the Phase A candidates:
- For each candidate in LLM response, match by `id`
- Populate: states, distillation, durability, candidate_priority, confidence, summary, usability, suggested_narrative_roles, edit_notes
- For each trim_choice, populate content_preserved from LLM evaluation
- Reject any `id` in LLM output that doesn't exist in Phase A substrate
- Reject any extra fields not in the Phase B schema

---

## Phase C — Deterministic Validation

Phase C runs validate_candidates.rb (or an integrated validation block) against the merged output. No LLM calls. Hard gate — pipeline aborts on failure.

### Checks

**Structural (exit 1):**
- Every candidate `id` matches `cand_NNN` format
- Every candidate has `segment_ids` (non-empty array of valid `seg_NNN` references)
- All segments in a candidate share the same source
- Every candidate has at least one trim_choice with label `full_clean`
- All trim_choice `in` >= candidate.t, all trim_choice `out` <= candidate.e
- All trim_choice `in` < `out`
- All exclusion_choice `start`/`end` within [candidate.t, candidate.e]
- No overlapping exclusion ranges within a candidate
- All IDs unique (candidate ids globally, trim choice ids within candidate, exclusion choice ids within candidate)
- No invented IDs or timestamps in LLM output

**Taxonomy (exit 2):**
- states: non-empty, max 3, all in 15-state enum
- states: no incompatible pairs
- distillation: max 5 words
- durability: in {spike, mood, identity}
- candidate_priority: in {primary, secondary, tertiary}
- confidence: in {high, medium, low}
- usability: in {fine, marginal, unusable}
- suggested_narrative_roles: all in allowed enum, no duplicates
- No extra fields in LLM output

**Data (exit 3):**
- candidate.t < candidate.e
- exclusion range start < end
- content_preserved evaluated for every trim_choice after Phase B
- At least one trim_choice has content_preserved=true per candidate

---

## Fixture-First Development Order

Implementation proceeds in this order. Each step produces a testable artifact before the next begins.

### Step 1: Fixture — golden segments_classified.yaml

Create `spec/fixtures/session6/segments_classified.yaml` — a minimal but representative subset of the dylan-shorts-batch-1 segments. Include:
- At least 10 segments from 2+ sources
- At least one segment with stumble_count > 0
- At least one segment with high max_within_segment_pause_ms
- At least one segment pair that would form an alternate_takes cluster
- At least two contiguous same-source segments suitable for multi-atom candidate grouping
- Full acoustic and prosody fields populated

### Step 2: Phase A implementation

Write Phase A of `candidate_builder.rb`:
- Read segments_classified.yaml
- Generate candidate spans (group contiguous same-source segments)
- Assign candidate ids (`cand_NNN`), compute segment_ids, t, e, text
- Compute trim_choices (`trim_NNN` with in/out/label/mechanical_boundary_safe)
- Compute exclusion_choices (`ex_NNN` with start/end/type/reason/recommended)
- Detect lexical clusters (deterministic text similarity)
- Aggregate prosody
- Write editorial_candidates.yaml with null Phase B fields

**Test:** Run Phase A on fixture. Verify:
- Output is valid YAML
- Every candidate has trim_choice with label `full_clean`
- All IDs are unique and match format (cand_NNN, trim_NNN, ex_NNN)
- Trim boundaries are within candidate boundaries
- Fixture with stumble has appropriate exclusion_choices generated
- Multi-atom candidates have correct segment_ids, t, e, text
- Run Phase A twice on same input — output is byte-identical

### Step 3: Fixture — golden editorial_candidates.yaml (Phase A output)

Capture Phase A output as `spec/fixtures/session6/editorial_candidates_phase_a.yaml`. This becomes the input fixture for Phase B testing.

**STOP CHECKPOINT:** Do not proceed to Phase B until Phase A fixture passes all Step 2 tests and the golden Phase A output fixture is committed.

### Step 4: Phase B prompt construction

Write Phase B prompt builder. Test with fixture input:
- Verify prompt is valid
- Verify all candidates appear in prompt table with canonical field names (id, segment_ids, etc.)
- Verify taxonomy reference is included
- Verify output schema instructions are clear
- Verify prompt does not ask LLM for timestamps, IDs, or mechanical data

### Step 5: Phase B response fixture

Manually create `spec/fixtures/session6/editorial_labeling_response.yaml` — a valid Phase B LLM response for the fixture candidates. This is the "golden response" for merge testing. Must include:
- All Phase B fields: states, distillation, durability, candidate_priority, confidence, summary, usability, suggested_narrative_roles, content_preserved per trim
- No timestamps, no invented IDs, no mechanical data

### Step 6: Phase B merge implementation

Write Phase B merge logic:
- Parse LLM response
- Match by `id`
- Populate editorial fields (states, distillation, durability, candidate_priority, confidence, summary, usability, suggested_narrative_roles, edit_notes)
- Populate content_preserved per trim_choice
- Reject unknown ids in LLM output
- Reject extra fields not in Phase B schema

**Test:** Merge golden response into Phase A fixture. Verify all fields populated correctly.

**STOP CHECKPOINT:** Do not proceed to Phase C until Phase B merge passes all Step 6 tests and the merged output fixture is committed.

### Step 7: Phase C validation

Write validation:
- Structural checks (exit 1)
- Taxonomy checks (exit 2)
- Data checks (exit 3)

**Test:** Run on merged fixture — should pass. Mutate fixture to trigger each exit code — verify detection. Specifically test:
- Invented ID rejection
- Timestamp in LLM output rejection
- Incompatible state pair detection

### Step 8: Integration — orchestrate.rb wiring

Add Phase 1.6 to orchestrate.rb:
- Call candidate_builder.rb after merge_prosody
- Add cache fingerprint check
- Add cascade invalidation (delete discovery_pass.yaml, arrangement.yaml on stale)

---

## Acceptance Criteria

Session 6 is complete when:

1. `candidate_builder.rb` exists and passes all fixture tests
2. `editorial_candidates.yaml` is produced with valid Phase A + B + C output conforming to editorial_candidate.schema.yaml v1.2
3. `validate_candidates.rb` (or integrated validation) catches all error classes (exit 1, 2, 3)
4. orchestrate.rb Phase 1.6 is wired with cache/cascade logic
5. No invented IDs appear in any LLM output — validator rejects them
6. No timestamps appear in any LLM output — validator rejects them
7. Phase A produces byte-identical output on identical inputs (deterministic repeatability)
8. editorial_candidates.yaml passes Phase C validation on fixture data

---

## Deferred Work (Not Session 6)

These are explicitly out of scope for Session 6:

### arrange.rb v4 Rewrite
Rewriting arrange.rb to use candidate_id/trim_choice_id/exclusion_choice_ids and produce arrangement.schema.yaml v4 output. Deferred to a dedicated session after candidate_builder is validated.

### export_arrangement_xml.rb v4 Path
Adding v4 resolution (candidate_id → trim → in/out/source). Deferred until arrange.rb v4 exists.

### Real Footage Validation
Full pipeline run on dylan-shorts-batch-1 through all phases with real LLM calls. Deferred until fixture-based validation is complete.

### Template Matching Integration
Wire `match_templates.rb` to score thesis segment sequences against story structure templates. Requires distillations from candidate enrichment.

### Coherence Pre-Filter
Port `score_coherence.rb` Layer 1 algorithmic deductions as post-arrangement validation. Check incompatible adjacent states, state redundancy, missing close. Advisory, non-blocking.

### Dual Discovery Mode
`--discovery-mode algorithmic|llm` flag to offer `discover_storylines.rb → match_templates → score_coherence` as alternative to `discovery_pass.rb`.

### Production Design Feedback Loop
Wire `parse_finished_edit.rb → extract_edit_patterns.rb → edit_patterns.yaml` into the orchestrator for learning from finished edits.

### Branch C Restoration
Re-enable `--analyze-only` for non-destructive footage assessment.

### Visual Context
Populate `discovery_pass.yaml`'s `visual_context` block from visual analysis data.

### Advanced Clustering Heuristics
Embedding-based or semantic clustering beyond lexical overlap. Deferred — lexical clustering is sufficient for Session 6.

### Advanced Exclusion Heuristics
Complex exclusion patterns (compound defects, overlapping issues). Deferred — basic defect/pacing exclusions are sufficient for Session 6.

---

## Implementation Cautions

### Do not collapse Phase A into Phase B
It is tempting to "let the LLM do it all" — classify, trim, exclude, label in one call. This violates the core invariant: LLMs judge meaning, scripts handle mechanics. Phase A MUST be deterministic. The LLM MUST receive a pre-built substrate with pre-generated IDs. If Phase A is collapsed into Phase B, validators cannot distinguish mechanical errors from editorial errors, and cache invalidation breaks.

### Do not add features beyond the schema
The editorial_candidate.schema.yaml v1.2 is locked. Do not add fields like `emotional_arc`, `pacing_score`, `b_roll_suggestions`, or `chapter_affinity`. If a new field is needed, it requires a schema version bump and a new lock session.

### Do not invent new ID namespaces
Only three ID namespaces exist in candidates: `cand_NNN`, `trim_NNN`, `ex_NNN`. Do not add `label_NNN`, `role_NNN`, `group_NNN`, or any other new ID space.

### Do not make Phase C advisory
Phase C is a hard gate. If validation fails, the pipeline aborts. Do not downgrade errors to warnings to "get past" validation during development. Fix the root cause.

### Do not read discovery_pass.yaml in Phase A
Phase A must not depend on discovery_pass.yaml. Cluster detection uses deterministic lexical similarity, not discovery_pass clip_groups. candidate_builder must be runnable before discovery_pass exists.

### Do not skip the fixture step
The fixture is the contract. If you write Phase A without a fixture, you're writing code without a spec. If you write Phase B without a golden response fixture, you're testing against LLM non-determinism. Fixtures first, always.

### Respect the pending-file pattern
Phase B in `claude_code` mode writes a pending file and exits 2. It does NOT make inline LLM calls. The external agent (thelmaedit.rb or Claude Code) reads the pending file, generates the response, and writes the response file. Then the pipeline resumes. This pattern is load-bearing — it decouples LLM execution from pipeline orchestration.
