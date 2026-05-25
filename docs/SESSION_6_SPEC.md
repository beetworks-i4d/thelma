# Session 6 Specification: candidate_builder.rb

**Locked:** 2026-05-25
**Status:** SPEC ONLY — not implemented
**Prereqs:** Session 5 complete (atom architecture, semantic_segment, extract_segments, discovery_pass, arrange v3, export)

---

## Goal

Build `candidate_builder.rb` — the editorial enrichment layer that bridges Session 5's content-pure atoms to the full editorial intelligence pipeline from main branch (v3.1).

**Input:** `segments_classified.yaml` (atoms with t, e, text, source, acoustic/prosody fields)
**Output:** `editorial_candidates.yaml` (atoms enriched with trim_choices, exclusion_choices, states, distillation, durability, roles, confidence)

This restores the editorial metadata that main branch's `classify()` provided, adapted for the atom architecture, and adds the mechanical substrate (trim/exclusion options) that main never had.

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
│    Compute trim_choices             │
│    Compute exclusion_choices        │
│    Evaluate boundary safety         │
│    Assign cand_ids, trim_ids,       │
│    exclusion_ids                    │
│                                     │
│  Phase B — LLM Editorial Labeling   │
│    Classify states (15-state)       │
│    Assign distillation (5-word)     │
│    Assign durability tier           │
│    Assign roles                     │
│    Assign confidence                │
│    Suggest narrative roles          │
│    Evaluate content_preserved       │
│    Assign candidate_priority        │
│                                     │
│  Phase C — Validation               │
│    Structural checks                │
│    Taxonomy checks                  │
│    Data integrity checks            │
│    Referential integrity            │
│                                     │
└─────────────────────────────────────┘
         │
         ▼
editorial_candidates.yaml
         │
         ├──▶ discovery_pass.rb (reads candidates for thesis proposals)
         ├──▶ arrange.rb (selects candidates by ID for v4 arrangement)
         └──▶ export_arrangement_xml.rb (resolves IDs to mechanical data)
```

---

## Pipeline Integration

### New phase: 1.45

`candidate_builder.rb` runs as Phase 1.45 in orchestrate.rb:

```
Phase 1.4  — extract_segments      → segments_classified.yaml (atoms, nil enrichment fields)
Phase 1.5c — audio_emotion         → segments_classified.yaml (acoustic fields filled)
           — merge_prosody         → segments_classified.yaml (prosody fields filled)
Phase 1.45 — candidate_builder     → editorial_candidates.yaml    ← NEW
Phase 1.5d — scene detection       → scene_changes.yaml
Phase 2    — discovery_pass        → discovery_pass.yaml (now reads editorial_candidates)
Phase 3    — arrange               → arrangement.yaml v4 (candidate-based)
Phase 4    — export                → XML (resolves cand_ids)
```

**Note on ordering:** Phase 1.45 runs AFTER 1.5c/merge_prosody because it needs acoustic/prosody data populated in segments_classified.yaml. The numbering reflects logical dependency, not strict numeric ordering.

### Downstream changes required

1. **discovery_pass.rb** — Update prompt to read editorial_candidates.yaml instead of (or in addition to) segments_classified.yaml. The enriched candidates provide states, distillation, and roles that improve thesis quality.

2. **arrange.rb** — New v4 prompt. LLM selects candidates by cand_id, trim_choices by trim_id, exclusion_choices by exclusion_id. No timestamps in output.

3. **export_arrangement_xml.rb** — Add v4 detection. Resolve cand_id → trim_choice → t/e/source. Resolve exclusion_choices → mid-cut ranges. Existing v3 path remains for backward compatibility.

4. **orchestrate.rb** — Add Phase 1.45 call. Update cache invalidation: editorial_candidates.yaml stale → delete discovery_pass.yaml + arrangement.yaml.

---

## Phase A — Deterministic Substrate

Phase A operates on pure mechanical data. No LLM calls. Fully deterministic given the same input.

### Inputs

- `segments_classified.yaml` — atom list with t, e, text, source, word-level timing (from semantic_segment), acoustic fields (from audio_emotion), prosody fields (from merge_prosody)

### Operations per segment

1. **Assign cand_id** — sequential `cand_001`, `cand_002`, etc.

2. **Compute trim_choices:**
   - `full` — t and e unchanged. Always included. Always `mechanical_boundary_safe: true`.
   - `tight` — trimmed to first word onset + BREATHING_MARGIN (80ms before) and last word offset + BREATHING_MARGIN (80ms after). Boundary-safe if BREATHING_MARGIN doesn't cross segment boundary.
   - `leading_trim` — if VAD detects silence or non-speech at segment start, trim to first speech onset. Requires word-level timing from semantic_segment.
   - `trailing_trim` — if VAD detects trailing silence, trim to last word offset + margin.
   - `word_boundary` — for segments with false starts detected acoustically (stumble_count > 0), compute a trim that starts after the false start. Requires word timing.

3. **Compute exclusion_choices:**
   - `none` — no exclusions. Always included. Always boundary-safe.
   - `stutter` — if stumble_count > 0 and word-level timing identifies the stutter location, create an exclusion range covering the stutter.
   - `filler` — if transcript contains um/uh/like with word-level timing, create exclusion ranges.
   - `pause` — if max_within_segment_pause_ms > threshold (e.g., 500ms), create exclusion range covering the pause.

4. **Evaluate mechanical_boundary_safe** for each trim and exclusion:
   - Safe if boundary aligns with word onset/offset (within 20ms tolerance)
   - Safe if boundary aligns with VAD pause edge
   - Unsafe if boundary falls mid-word or mid-phoneme

5. **Compute preserved_text** for each trim_choice — deterministically extract the text that survives the trim using word-level timing alignment.

6. **Propagate cluster membership** from discovery_pass.yaml clip_groups (if discovery_pass has already run; otherwise leave null — discovery_pass runs after candidate_builder and will enrich later).

### Output

A complete `editorial_candidates.yaml` with all Phase A fields populated and all Phase B fields set to null.

---

## Phase B — LLM Editorial Labeling

Phase B makes exactly ONE LLM call that labels all candidates. It receives the complete Phase A substrate as context.

### Prompt Design

**System message:** Tone context from profile (cached).

**User message structure:**
```
## Candidates

[Table: cand_id | seg_id | source | t-e | text | audio_profile | energy | speaking_rate | stumble_count | trim_count | exclusion_count]

## Task

For each candidate, provide:
1. states (1-3 from 15-state taxonomy, primary first)
2. distillation (5-word max summary of WHAT it says)
3. dur (spike | mood | identity)
4. roles (array: primary, secondary, tertiary)
5. confidence (high | medium | low)
6. suggested_narrative_roles (optional: hook, setup, continuation, payoff, transition, claim, evidence, definition, aside, close)
7. rationale (5-15 words)
8. signpost (true if meta-commentary without content delivery)
9. For each trim_choice that is NOT type=full: content_preserved (true/false — does the trim retain core meaning?)
10. candidate_priority (only for candidates in alternate_takes clusters: 1=best, 2=backup, etc.)

## Content Psychopharmacology Reference

[Condensed taxonomy: state name, definition, durability class — 15 entries]

## Output Format

[Exact YAML schema]
```

### LLM Restrictions

The LLM output must contain ONLY:
- `cand_id` (echoed back for alignment — must match input exactly)
- Editorial label fields (states, distillation, dur, roles, confidence, etc.)
- `content_preserved` evaluations keyed by trim_id

The LLM output must NOT contain:
- Timestamps
- New IDs (no new cand_ids, trim_ids, exclusion_ids)
- Source paths
- Any field not in the Phase B schema

### Pending File Pattern

Phase B uses the same pending-file pattern as discovery_pass and arrange:
1. Write `pending_llm_calls/editorial_labeling.yaml` with prompt + input_fingerprint
2. If `--llm-mode claude_code`: exit 2 (paused). External agent reads pending, writes response, pipeline resumes.
3. If `--llm-mode api`: call LLM directly via llm_client.rb, parse response.

### Merge Strategy

Phase B output is merged INTO the Phase A candidates:
- For each candidate in LLM response, match by cand_id
- Populate: states, distillation, dur, roles, confidence, suggested_narrative_roles, rationale, signpost, candidate_priority
- For each trim_choice, populate content_preserved from LLM evaluation
- Reject any cand_id in LLM output that doesn't exist in Phase A substrate
- Reject any extra fields not in the Phase B schema

---

## Phase C — Validation

Phase C runs validate_candidates.rb (or an integrated validation block) against the merged output.

### Checks

**Structural (exit 1):**
- Every candidate has at least one trim_choice with type=full
- Every candidate has at least one exclusion_choice with type=none
- All trim_choice boundaries within [candidate.t, candidate.e]
- All exclusion ranges within [candidate.t, candidate.e]
- No overlapping exclusion ranges within one exclusion_choice
- All IDs unique (cand_ids globally, trim_ids within candidate, exclusion_ids within candidate)
- seg_id references valid segment in segments_classified.yaml

**Taxonomy (exit 2):**
- states: non-empty, max 3, all in 15-state enum
- distillation: max 5 words
- dur: in {spike, mood, identity}
- roles: non-empty, all in {primary, secondary, tertiary}
- confidence: in {high, medium, low}
- suggested_narrative_roles: all in allowed enum
- No extra fields in LLM output

**Data (exit 3):**
- trim_choice.t < trim_choice.e for all trims
- trim_choice.t >= candidate.t
- trim_choice.e <= candidate.e
- exclusion range [start, end] where start < end
- content_preserved evaluated for all non-full trim_choices
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
- Full acoustic and prosody fields populated

### Step 2: Phase A implementation

Write Phase A of `candidate_builder.rb`:
- Read segments_classified.yaml
- Generate cand_ids
- Compute trim_choices (start with full + tight only; add leading/trailing/word_boundary)
- Compute exclusion_choices (start with none only; add stutter/filler/pause)
- Evaluate mechanical_boundary_safe
- Write editorial_candidates.yaml with null Phase B fields

**Test:** Run Phase A on fixture. Verify:
- Output is valid YAML
- Every candidate has trim_choice type=full and exclusion_choice type=none
- All IDs are unique
- trim boundaries are within segment boundaries
- Fixture with stumble has appropriate trim/exclusion choices generated

### Step 3: Fixture — golden editorial_candidates.yaml (Phase A output)

Capture Phase A output as `spec/fixtures/session6/editorial_candidates_phase_a.yaml`. This becomes the input fixture for Phase B testing.

### Step 4: Phase B prompt construction

Write Phase B prompt builder. Test with fixture input:
- Verify prompt is valid
- Verify all candidates appear in prompt table
- Verify taxonomy reference is included
- Verify output schema instructions are clear

### Step 5: Phase B response fixture

Manually create `spec/fixtures/session6/editorial_labeling_response.yaml` — a valid Phase B LLM response for the fixture candidates. This is the "golden response" for merge testing.

### Step 6: Phase B merge implementation

Write Phase B merge logic:
- Parse LLM response
- Match by cand_id
- Populate editorial fields
- Reject unknown cand_ids
- Reject extra fields

**Test:** Merge golden response into Phase A fixture. Verify all fields populated correctly.

### Step 7: Phase C validation

Write validation:
- Structural checks
- Taxonomy checks
- Data checks

**Test:** Run on merged fixture — should pass. Mutate fixture to trigger each exit code — verify detection.

### Step 8: Integration — orchestrate.rb wiring

Add Phase 1.45 to orchestrate.rb:
- Call candidate_builder.rb after merge_prosody
- Add cache fingerprint check
- Add cascade invalidation (delete discovery_pass.yaml, arrangement.yaml on stale)

### Step 9: End-to-end — full pipeline run

Run orchestrate.rb on dylan-shorts-batch-1 through all phases. Verify:
- Phase 1.45 produces editorial_candidates.yaml
- Discovery_pass reads enriched candidates (if prompt is updated)
- Pipeline completes without errors

---

## Acceptance Criteria

Session 6 is complete when:

1. `candidate_builder.rb` exists and passes all fixture tests
2. `editorial_candidates.yaml` is produced with valid Phase A + B + C output
3. `validate_candidates.rb` (or integrated validation) catches all error classes
4. orchestrate.rb Phase 1.45 is wired with cache/cascade logic
5. Full pipeline run on dylan-shorts-batch-1 completes through Phase 5
6. No regressions: existing v3 arrangement path still works (backward compat)

Session 6 is NOT complete until:

7. arrange.rb v4 prompt accepts candidate IDs (not seg_ids)
8. export_arrangement_xml.rb v4 path resolves cand_id → trim → t/e/source
9. Full pipeline run produces valid XML using v4 arrangement

---

## Deferred Work (Not Session 6)

These are explicitly out of scope for Session 6:

### Template Matching Integration
Wire `match_templates.rb` to score thesis segment sequences against story structure templates. Requires distillations from candidate enrichment. Injecting best-fit template into arrangement prompt.

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

---

## Implementation Cautions

### Do not collapse Phase A into Phase B
It is tempting to "let the LLM do it all" — classify, trim, exclude, label in one call. This violates the core invariant. Phase A MUST be deterministic. The LLM MUST receive a pre-built substrate with pre-generated IDs. If Phase A is collapsed into Phase B, validators cannot distinguish mechanical errors from editorial errors, and cache invalidation breaks.

### Do not add features beyond the schema
The editorial_candidate.schema.yaml v1.2 is locked. Do not add fields like `emotional_arc`, `pacing_score`, `b_roll_suggestions`, or `chapter_affinity`. If a new field is needed, it requires a schema version bump and a new lock session.

### Do not invent new ID namespaces
Only three ID namespaces exist in candidates: `cand_NNN`, `trim_NNN_<type>`, `excl_NNN_<type>`. Do not add `label_NNN`, `role_NNN`, `group_NNN`, or any other new ID space.

### Do not make Phase C advisory
Phase C is a hard gate. If validation fails, the pipeline aborts. Do not downgrade errors to warnings to "get past" validation during development. Fix the root cause.

### Do not read discovery_pass.yaml in Phase A
Phase A must not depend on discovery_pass.yaml. Cluster membership is optional context that can be populated AFTER discovery_pass runs. candidate_builder must be runnable before discovery_pass exists.

### Do not skip the fixture step
The fixture is the contract. If you write Phase A without a fixture, you're writing code without a spec. If you write Phase B without a golden response fixture, you're testing against LLM non-determinism. Fixtures first, always.

### Respect the pending-file pattern
Phase B in `claude_code` mode writes a pending file and exits 2. It does NOT make inline LLM calls. The external agent (thelmaedit.rb or Claude Code) reads the pending file, generates the response, and writes the response file. Then the pipeline resumes. This pattern is load-bearing — it decouples LLM execution from pipeline orchestration.
