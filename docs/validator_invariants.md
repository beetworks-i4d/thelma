# Validator Invariants

**Locked:** 2026-05-25
**Scope:** All Thelma pipeline validators and the separation-of-concerns principle they enforce.

---

## Core Principle

> **LLMs judge meaning. Scripts handle mechanics.**

This is the foundational separation of concerns in Thelma. Every validator enforces this boundary. Every schema assumes it. Every new script must respect it.

---

## What LLMs May Do

LLMs may:
- **Classify** — assign emotional states, durability tiers, candidate_priority, confidence
- **Summarize** — produce distillations, summaries, editorial notes
- **Rank** — order theses, prioritize candidates, score coherence
- **Reason** — explain editorial decisions, assess narrative arcs
- **Choose among pre-generated IDs** — select candidate_id, trim_choice_id, exclusion_choice_ids
- **Evaluate semantic preservation** — judge whether a trim retains meaning
- **Assign narrative_role** — determine each selection's function within a specific arrangement

LLMs produce *judgments about content*. Their output is always qualified by confidence and always validated downstream.

---

## What LLMs May NOT Do

LLMs may NOT invent:
- **Timestamps** — no `t`, `e`, `in`, `out`, `start`, `end`, `clip_in`, `clip_out`, or any time values
- **`seg_NNN`** — segment identifiers are assigned by `extract_segments.rb`
- **`cand_NNN`** — candidate identifiers are assigned by `candidate_builder.rb` Phase A
- **`trim_NNN`** — trim choice identifiers are assigned by `candidate_builder.rb` Phase A
- **`ex_NNN`** — exclusion choice identifiers are assigned by `candidate_builder.rb` Phase A
- **`thesis_NNN`** — thesis identifiers are assigned by `discovery_pass.rb`
- **Source paths** — video/audio file paths come from `library.yaml`
- **XML structure** — element hierarchy, attributes, DTD compliance
- **Timeline math** — frame calculations, sample rates, cursor positions, BREATHING_MARGIN

LLMs produce *no mechanical data*. If a timestamp or invented ID appears in LLM output, the validator must reject it.

---

## Boundary Invariants

These invariants define the hard boundary between LLM responsibility and script responsibility at each pipeline stage.

### 1. Segment Atoms (semantic_segment.rb → extract_segments.rb)

| Responsibility | Owner |
|---------------|-------|
| Decide segment boundaries (where utterances begin/end) | LLM (semantic_segment.rb) |
| Validate word coverage (no words lost or duplicated) | Script (semantic_segment.rb D5.15 validation) |
| Assign global seg_ids | Script (extract_segments.rb) |
| Merge multi-source segments into unified file | Script (extract_segments.rb) |
| Cascade-invalidate downstream on stale input | Script (extract_segments.rb) |

**Invariant:** Once a segment atom exists, its `t` and `e` are immutable. No downstream process may modify segment timing.

### 2. Editorial Candidates (candidate_builder.rb)

**Phase A — Deterministic Substrate:**

| Responsibility | Owner |
|---------------|-------|
| Group contiguous same-source segments into candidate spans | Script (Phase A) |
| Assign candidate id (`cand_NNN`), compute t, e, text from segment_ids | Script (Phase A) |
| Compute trim_choices from word boundaries and VAD | Script (Phase A) |
| Assign trim choice ids (`trim_NNN`) | Script (Phase A) |
| Compute exclusion_choices from acoustic analysis | Script (Phase A) |
| Assign exclusion choice ids (`ex_NNN`) | Script (Phase A) |
| Evaluate mechanical_boundary_safe per trim and exclusion | Script (Phase A) |
| Aggregate prosody from source segments | Script (Phase A) |
| Assign deterministic cluster label (or null) | Script (Phase A) |

**Phase B — Semantic Labeling (LLM):**

| Responsibility | Owner |
|---------------|-------|
| Classify states (15-state taxonomy, 1-3 per candidate) | LLM (Phase B) |
| Assign distillation (5-word semantic fingerprint) | LLM (Phase B) |
| Assign durability tier (spike, mood, identity) | LLM (Phase B) |
| Assign candidate_priority (primary, secondary, tertiary) | LLM (Phase B) |
| Assign confidence (high, medium, low) | LLM (Phase B) |
| Assign summary and usability | LLM (Phase B) |
| Suggest narrative_roles (advisory — final role belongs in arrangement) | LLM (Phase B) |
| Evaluate content_preserved per trim_choice | LLM (Phase B) |

**Phase C — Validation:**

| Responsibility | Owner |
|---------------|-------|
| Validate all fields against editorial_candidate.schema.yaml | Script (Phase C) |
| Reject invented IDs or timestamps in LLM output | Script (Phase C) |
| Reject broken segment_ids references | Script (Phase C) |
| Enforce taxonomy enum constraints | Script (Phase C) |

**Invariant:** Phase A completes entirely before Phase B begins. The LLM never sees partially-generated mechanical data. It receives a complete, validated substrate.

**Invariant:** Phase B may not add, remove, or modify any Phase A fields. It may only populate fields designated as "Phase B" in the schema.

**Invariant:** Given identical deterministic inputs, Phase A must produce byte-identical outputs. No randomness, no timestamps in IDs, no non-deterministic ordering.

### 3. Arrangement (arrange.rb)

| Responsibility | Owner |
|---------------|-------|
| Select candidates for the edit (by candidate_id) | LLM |
| Choose trim options (by trim_choice_id) | LLM |
| Choose exclusion options (by exclusion_choice_ids) | LLM |
| Assign narrative_role per segment selection | LLM |
| Order chapters and segments | LLM |
| Write editorial reasoning and notes | LLM |
| Validate all ID references resolve | Script (validator) |
| Validate no duplicates, cluster rules | Script (validator) |
| Validate selected trim has mechanical_boundary_safe=true | Script (validator) |
| Validate selected trim has content_preserved=true | Script (validator) |

**Invariant:** The arrangement contains zero timestamps. If any float that looks like a time value appears in arrangement output, the validator must reject it.

**Invariant:** Every arrangement selection must reference ONLY existing candidate_id, trim_choice_id, and exclusion_choice_ids from editorial_candidates.yaml. The arrangement invents no IDs — it only selects from pre-generated options.

**Invariant:** Selected trim_choices require BOTH `mechanical_boundary_safe: true` AND `content_preserved: true`. This is a hard validation error (exit code 1), not advisory.

### 4. Export (export_arrangement_xml.rb → build_structure_cut.rb)

| Responsibility | Owner |
|---------------|-------|
| Resolve candidate_id → candidate → t, e, source, segment_ids | Script |
| Resolve trim_choice_id → trim choice → in (clip_in), out (clip_out) | Script |
| Resolve exclusion_choice_ids → exclusion choices → start/end (mid-cut ranges) | Script |
| Apply BREATHING_MARGIN (80ms per side) | Script |
| Resolve source → video path, sync audio, offset | Script |
| Generate XML (xmeml or FCPXML) | Script |
| Generate markers from chapter titles, narrative_role, and notes | Script |
| All timeline math (frames, samples, durations) | Script |

**Invariant:** Export reads the arrangement as a pure editorial decision document. It makes zero editorial decisions itself — it only resolves IDs to mechanical data and builds XML.

---

## Cross-Boundary Invariants

These invariants span multiple pipeline stages.

### Fingerprint Cascade

Every pipeline stage that produces output includes an `input_fingerprint` (SHA256) of its inputs. When a stage's inputs change:

1. The stage detects fingerprint mismatch on next run
2. The stage regenerates its output
3. The stage **actively deletes** all downstream outputs that depended on it

**Cascade chain:**
```
segments_classified.yaml
  → editorial_candidates.yaml
    → discovery_pass.yaml
      → arrangement.yaml
        → XML output
```

**Invariant:** Stale downstream files must not survive upstream regeneration. `extract_segments.rb` deletes `discovery_pass.yaml` and `arrangement.yaml` when segments change. `candidate_builder.rb` deletes `arrangement.yaml` when candidates change.

### ID Referential Integrity

Every ID reference must resolve:
- `segment_ids[]` in a candidate → each must exist in `segments_classified.yaml`
- `candidate_id` in an arrangement → must match a candidate `id` in `editorial_candidates.yaml`
- `trim_choice_id` in an arrangement → must match a trim choice `id` within the referenced candidate's `trim_choices`
- `exclusion_choice_ids[]` in an arrangement → each must match an exclusion choice `id` within the referenced candidate's `exclusion_choices`
- `selected_thesis` in an arrangement → must exist in `discovery_pass.yaml` (when non-null)
- `source` in a candidate → must exist in `library.yaml` videos

**Invariant:** Broken references are structural errors (exit code 1). Never warn-and-continue on a broken reference.

### Immutability Chain

```
Word timing (from WhisperX)    — immutable after transcription
Segment boundaries (t, e)      — immutable after semantic_segment
Candidate mechanical substrate — immutable after Phase A
Candidate editorial labels     — immutable after Phase B + validation
Arrangement selections         — immutable after arrange + validation
```

**Invariant:** No downstream stage modifies upstream data. Export does not fix timing. Arrangement does not adjust candidates. Candidates do not alter segments.

---

## Branch-Specific Invariants

### Branch A (Script-Driven)

- Script beats drive arrangement — not theses or storylines
- `parse_script.rb` produces `script_parsed.yaml`
- `arrange_to_script.rb` matches segments to beats
- `arrangement_adapter.rb` normalizes to chapters schema
- **`selected_thesis` must be null** — Branch A has no thesis
- **`branch` must be `A`** in arrangement.yaml
- Branch A exits before Phase 0 — no content type detection needed
- Branch A and Branch B never execute in the same run

### Branch B (Organic Discovery)

- No script assumed — LLM discovers theses from enriched segments
- `discovery_pass.rb` produces theses, clip_groups, throughlines
- `arrange.rb` produces candidate-based arrangement (v4)
- **`selected_thesis` must be non-null** — references a thesis from discovery_pass.yaml
- **`branch` must be `B`** in arrangement.yaml
- Full enrichment pipeline runs: prosody → semantic_segment → extract → audio_emotion → merge_prosody

### Branch D (Mine Mode)

- Pool-based incremental ingestion
- Sources discovered via `pool_index.rb`, not pre-specified in library.yaml
- `register_pool_sources.rb` bridges pool into library.yaml — **must complete before ingest**
- After ingestion, falls through to Branch B shared pipeline
- **`selected_thesis` must be non-null** — same as Branch B
- **`branch` must be `D`** in arrangement.yaml

---

## Loud-Failure Principle

Validators fail loudly and specifically. No silent degradation.

### Exit Code Protocol

| Code | Meaning | Action |
|------|---------|--------|
| 0 | All valid | Continue pipeline |
| 1 | Structural error | Abort. Missing fields, wrong types, broken references, invalid version, entity not found. |
| 2 | Taxonomy violation | Abort. Invalid enum values, out-of-range values, extra fields in LLM output. |
| 3 | Data error | Abort. Time violations, range overlaps, range boundary violations. |

### Validator Behavior Rules

1. **Never warn-and-continue on structural errors.** If a required field is missing, abort.
2. **Never silently fix data.** If a timestamp is wrong, don't correct it — reject it.
3. **Never assume defaults for missing data.** If `durability` is missing, don't default to `spike` — fail.
4. **Report ALL errors, not just the first.** Collect all validation failures and report them together.
5. **Include context in error messages.** "seg_014: states contains invalid value 'excitement'" not "taxonomy error."

### No Silent Skips

Validators must never silently skip a check, silently drop a record, or silently substitute a default. Every validation path either passes explicitly or fails with a specific error message. If a validator encounters an unexpected condition it has no rule for, it must abort with exit code 1 and report the condition — not silently proceed.

### Advisory Warnings (non-blocking)

Some checks produce warnings that don't block the pipeline:
- Duration estimate outside ±30s of thesis target (Branch B/D only)
- Missing `throughline_honoring` entry for a known throughline
- Missing entries in `unused_candidate_audit`
- Exclusion choice with `recommended: false` selected in arrangement

Warnings are printed to stderr with `[WARN]` prefix. They never cause non-zero exit codes.

---

## Cache Invalidation Rules

### What Triggers Regeneration

| File | Invalidated When |
|------|-----------------|
| `*_semantic_segments.yaml` | Source transcript changes, VAD analysis changes, prompt version changes |
| `segments_classified.yaml` | Any semantic_segments file changes, video list changes |
| `editorial_candidates.yaml` | segments_classified.yaml changes, profile changes |
| `discovery_pass.yaml` | segments_classified.yaml changes, profile changes, duration target changes |
| `arrangement.yaml` | editorial_candidates.yaml changes, discovery_pass.yaml changes (selected thesis) |
| XML output | arrangement.yaml changes, library.yaml source mappings change |

### Fingerprint Composition

Each fingerprint includes ALL inputs that affect the output:
- File content (SHA256 of the file)
- Profile name (different profile = different editorial decisions)
- Duration target (if applicable)
- Prompt version (for LLM-based stages)

### Cascade Deletion

When a stage regenerates, it MUST delete:
- Its own previous output
- All downstream cached outputs
- All downstream pending_llm_calls response files

This is not optional. Stale cache is worse than no cache.

---

## LLM Output Restrictions

### Structural Restrictions

LLM output must be valid YAML (parseable by `YAML.safe_load`).

LLM output must contain ONLY fields defined in the relevant schema. Extra fields are validation errors, not ignored silently.

LLM output must not contain Ruby objects, executable code, or YAML tags beyond basic types (string, integer, float, boolean, null, array, hash).

### Content Restrictions

LLM-generated text fields (distillation, notes, reasoning) must not contain:
- File paths or directory references
- Timestamps formatted as HH:MM:SS or MM:SS
- Frame numbers or sample counts
- XML fragments or markup
- References to Thelma internals (script names, class names, method names)

These restrictions exist because LLM-generated mechanical data cannot be validated for correctness — only human-meaningful semantic content can be evaluated by the LLM reliably.
