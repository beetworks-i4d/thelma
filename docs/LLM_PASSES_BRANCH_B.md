# LLM Passes — Branch B End-to-End Pipeline

**Locked:** 2026-05-28
**Scope:** All LLM passes in the Branch B (organic discovery) editing pipeline, from atoms through final arrangement.

---

## Global Invariant

> LLMs may select, classify, relate, review, and propose constrained patches.
> LLMs may not invent IDs, timestamps, candidates, trims, exclusions, source paths, or XML.

Every LLM pass operates on pre-generated mechanical substrate. Every LLM output is validated before downstream consumption. No LLM output reaches the timeline without passing through a deterministic validator.

---

## Pipeline Overview

```
atoms (segments_classified.yaml)
  → deterministic candidate substrate         [script: candidate_builder Phase A]
  → LLM Pass 1: candidate labeling            [pending-file workflow]
  → validated editorial_candidates.yaml       [script: candidate_builder Phase C]
  → LLM Pass 2: relationship mapping          [pending-file workflow]
  → candidate_relationships.yaml              [script: relationship_validator]
  → LLM Pass 3: thesis / angle selection      [pending-file workflow]
  → selected_thesis.yaml                      [script: thesis_validator]
  → LLM Pass 4: arrangement generation        [pending-file workflow]
  → arrangement.yaml                          [script: arrangement_validator]
  → LLM Pass 5: arrangement coherence review  [pending-file workflow]
  → arrangement_review.yaml                   [script: review_validator]
  → LLM Pass 6: constrained revision          [pending-file workflow]
  → final_arrangement.yaml                    [script: arrangement_validator]
  → XML export                                [script: export_arrangement_xml.rb]
```

Packaging, editor handoff, markers, and delivery are downstream of XML export and are explicitly excluded from this pipeline definition.

---

## Pending-File Workflow (All Passes)

Every LLM pass follows the same exchange protocol:

1. Script writes `<pass>_pending.json` — the request, containing instructions, constraints, output format, and input data.
2. Claude Code CLI (`claude -p`) or user fills the response.
3. Script reads `<pass>_response.json`, validates strictly, writes the output artifact.
4. On validation failure: abort with specific errors. No fallback to stale data.

No pass calls the Anthropic API directly. All LLM interaction uses the Claude Code subscription via CLI or manual fill.

---

## Pass 1: Candidate Labeling

**Purpose:** Classify each candidate by rhetorical function, emotional state, editorial value, and trim content preservation. Operates on candidates in isolation — no cross-candidate reasoning.

**Input files:**
- `candidate_substrate.yaml` (Phase A output)
- `semantic_labels_pending.json` (generated request)

**Output file:**
- `editorial_candidates.yaml` (substrate + validated labels, via Phase B merge + Phase C validation)

**Allowed outputs:**
- `summary` (string, max 25 words)
- `distillation` (string, max 5 words)
- `usability` (fine | marginal | unusable)
- `candidate_priority` (primary | secondary | tertiary)
- `suggested_narrative_roles` (1-2 entries from role enum with confidence)
- `states` (1-3 from 15-state taxonomy, primary first)
- `durability` (spike | mood | identity)
- `confidence` (high | medium | low)
- `content_preserved_trims` (trim_id: true | false for each trim)
- `edit_notes` (free text)

**Forbidden outputs:**
- Timestamps, segment IDs, candidate IDs, trim IDs, exclusion IDs
- New candidates or trims not in the substrate
- Cross-candidate references or sequencing decisions
- Any field not listed above

**Validator responsibilities (Phase C):**
- All enum values within schema bounds
- Incompatible state pairs rejected (vindication+outrage, amusement+fear, calm+outrage, escape+belonging)
- No invented fields beyond the allowed set
- Every trim referenced in `content_preserved_trims` must exist in the substrate
- `content_preserved` set on every trim after merge
- Candidates with no arrangement-safe trim (mechanical_boundary_safe AND content_preserved both true) must be usability=unusable

**Failure behavior:**
- Validation errors: abort with per-candidate error list, exit code 2. Do not write editorial_candidates.yaml.
- Structural errors (missing fields, wrong types): exit code 1.

---

## Pass 2: Relationship Mapping

**Purpose:** Identify semantic relationships between candidates. Which candidates reinforce, contradict, extend, or provide evidence for each other. Enables arrangement to build coherent narrative arcs from isolated labels.

**Input files:**
- `editorial_candidates.yaml` (validated Pass 1 output)

**Output file:**
- `candidate_relationships.yaml`

**Allowed outputs per relationship:**
- `from_candidate_id` (existing cand_NNN)
- `to_candidate_id` (existing cand_NNN)
- `relationship_type` (reinforces | contradicts | extends | evidence_for | sets_up | pays_off | restates)
- `strength` (strong | moderate | weak)
- `notes` (free text, brief)

**Forbidden outputs:**
- Candidate IDs not present in editorial_candidates.yaml
- Timestamps, trim references, exclusion references
- New candidates or modifications to existing candidate fields
- Arrangement decisions (ordering, chapter assignment, selection)

**Validator responsibilities:**
- Every `from_candidate_id` and `to_candidate_id` must resolve to editorial_candidates.yaml
- No self-relationships (from == to)
- No duplicate relationships (same from+to+type)
- `relationship_type` and `strength` within enum bounds
- No invented fields

**Failure behavior:**
- Validation errors: abort, exit code 2. Do not write candidate_relationships.yaml.
- Unknown candidate reference: exit code 1.

---

## Pass 3: Thesis / Angle Selection

**Purpose:** Given the labeled candidates and their relationships, propose and select an editorial thesis — the angle, argument, or narrative thread that will organize the arrangement. The thesis constrains which candidates are relevant and how they should be ordered.

**Input files:**
- `editorial_candidates.yaml`
- `candidate_relationships.yaml`

**Output file:**
- `selected_thesis.yaml`

**Allowed outputs:**
- `thesis_id` (thesis_NNN, assigned by the generating script — not invented by LLM in the response)
- `thesis_statement` (string, max 50 words)
- `target_duration_s` (integer, estimated total edit duration)
- `primary_candidates` (array of existing cand_NNN IDs central to the thesis)
- `supporting_candidates` (array of existing cand_NNN IDs that reinforce the thesis)
- `excluded_candidates` (array of existing cand_NNN IDs that conflict with or dilute the thesis)
- `throughlines` (array of narrative thread descriptions, max 3)
- `reasoning` (free text)

**Forbidden outputs:**
- Candidate IDs not present in editorial_candidates.yaml
- Timestamps, trim choices, exclusion choices
- Arrangement structure (chapters, segment ordering)
- New candidates or modifications to candidate data

**Validator responsibilities:**
- All candidate ID references resolve
- No candidate appears in more than one of primary/supporting/excluded
- `target_duration_s` is a positive integer
- Throughlines array is 1-3 entries
- No invented fields

**Failure behavior:**
- Validation errors: abort, exit code 2.
- Unresolvable candidate reference: exit code 1.

---

## Pass 4: Arrangement Generation

**Purpose:** Given the thesis, candidates, and relationships, produce a chapter-structured arrangement. Select which candidates to include, which trim to use for each, which exclusions to apply, and assign a narrative role for each selection within its chapter context.

**Input files:**
- `editorial_candidates.yaml`
- `candidate_relationships.yaml`
- `selected_thesis.yaml`

**Output file:**
- `arrangement.yaml` (schema v4)

**Allowed outputs:**
- Chapters with `id` (chapter_NNN), `title`, `notes`
- Segment selections with `candidate_id`, `trim_choice_id`, `exclusion_choice_ids`, `narrative_role`, `notes`
- `arrangement_reasoning` (free text)
- `throughline_honoring` (per-throughline notes)
- `unused_candidate_audit` (per-unused-candidate reason)
- `selected_thesis` reference
- `branch: B`

**Forbidden outputs:**
- Timestamps (t, e, in, out, clip_in, clip_out)
- Source paths
- Any ID not present in editorial_candidates.yaml
- trim_choice_id where the trim has mechanical_boundary_safe=false
- trim_choice_id where the trim has content_preserved=false
- Duplicate candidate selections (same candidate_id used twice)
- XML structure or timeline math

**Validator responsibilities:**
- Schema v4 structural validation
- Every candidate_id resolves to editorial_candidates.yaml
- Every trim_choice_id resolves within the referenced candidate
- Every exclusion_choice_id resolves within the referenced candidate
- Selected trim has both mechanical_boundary_safe=true and content_preserved=true
- No duplicate candidate selections
- Max one candidate per cluster (alternate_takes rule)
- narrative_role within enum bounds
- Chapter IDs sequential and unique
- branch=B, selected_thesis non-null

**Failure behavior:**
- Structural errors: exit code 1.
- Constraint violations (bad trim, duplicate, cluster): exit code 1.
- Enum violations: exit code 2.

---

## Pass 5: Arrangement Coherence Review

**Purpose:** Review the generated arrangement for narrative coherence, pacing problems, emotional arc issues, and missed opportunities. Does not modify the arrangement — produces a review document that the constrained revision pass consumes.

**Input files:**
- `arrangement.yaml`
- `editorial_candidates.yaml`
- `candidate_relationships.yaml`
- `selected_thesis.yaml`

**Output file:**
- `arrangement_review.yaml`

**Allowed outputs:**
- `overall_coherence` (strong | adequate | weak)
- `pacing_assessment` (free text, max 100 words)
- `emotional_arc_assessment` (free text, max 100 words)
- `issues` (array of identified problems):
  - `issue_type` (pacing | coherence | missing_setup | missing_payoff | redundancy | ordering | emotional_gap)
  - `location` (chapter_NNN or chapter_NNN/cand_NNN reference)
  - `description` (free text, max 50 words)
  - `severity` (critical | moderate | minor)
  - `suggested_fix_type` (reorder | swap | insert | remove | no_action)
- `unused_opportunities` (array of cand_NNN IDs that could strengthen the edit)
- `verdict` (approve | revise)

**Forbidden outputs:**
- Timestamps, source paths
- New candidate IDs not in editorial_candidates.yaml
- Direct arrangement mutations (new chapters, reordered segments)
- Trim or exclusion selections
- XML or timeline data

**Validator responsibilities:**
- All candidate ID references resolve
- All chapter/segment location references resolve to arrangement.yaml
- Enum values within bounds
- No invented fields
- `unused_opportunities` candidates not already in the arrangement

**Failure behavior:**
- Validation errors: abort, exit code 2.
- Unresolvable references: exit code 1.

---

## Pass 6: Constrained Revision

**Purpose:** Apply review findings to produce a revised arrangement. Operates under strict constraints: may only reorder existing segments, swap trim choices within the same candidate, add/remove candidates from the thesis pool, or insert/remove segments. May not invent new candidates or IDs.

**Input files:**
- `arrangement.yaml` (original)
- `arrangement_review.yaml`
- `editorial_candidates.yaml`
- `candidate_relationships.yaml`
- `selected_thesis.yaml`

**Output file:**
- `final_arrangement.yaml` (schema v4, same structure as arrangement.yaml)

**Allowed outputs:**
- Same structure as Pass 4 (arrangement.yaml schema v4)
- Segments may be reordered within or across chapters
- Segments may be added (from editorial_candidates.yaml pool) or removed
- Trim choice may be changed to a different trim within the same candidate
- Exclusion choice set may be changed within the same candidate
- Chapters may be added, removed, merged, or retitled
- `arrangement_reasoning` must reference the review issues addressed

**Forbidden outputs:**
- Timestamps, source paths
- Candidate IDs not in editorial_candidates.yaml
- Trim IDs not belonging to the referenced candidate
- Exclusion IDs not belonging to the referenced candidate
- trim_choice_id where mechanical_boundary_safe=false or content_preserved=false
- Duplicate candidate selections
- XML structure

**Validator responsibilities:**
- Identical to Pass 4 arrangement validation (full schema v4 check)
- Additionally: verify the revision addresses at least one critical issue from the review (if any critical issues exist)
- If review verdict was `approve`, revision must match the original arrangement exactly (no unnecessary changes)

**Failure behavior:**
- Same as Pass 4. Structural errors: exit code 1. Enum violations: exit code 2.
- Revision that ignores critical issues: exit code 2 with specific message.

---

## Pass Ordering Invariants

1. Each pass completes and validates before the next begins. No partial pipeline execution.
2. If any pass fails validation, the pipeline stops. No downstream passes execute on invalid data.
3. Passes 1-4 are always required. Passes 5-6 (review + revision) may be skipped if the user requests `--skip-review`, in which case `arrangement.yaml` becomes `final_arrangement.yaml` directly.
4. Fingerprint cascade: if an upstream artifact changes, all downstream artifacts are invalidated.

---

## What Is Not an LLM Pass

The following are deterministic script operations, not LLM passes:

- **Candidate substrate generation** (Phase A): deterministic grouping, trim generation, exclusion detection, prosody aggregation.
- **Phase C validation**: enum checking, reference resolution, structural verification.
- **XML export**: ID resolution, timeline math, frame calculations, breathing margin, marker generation.
- **Packaging and editor handoff**: file assembly, delivery format, marker formatting.

These never receive LLM input and never produce LLM output.
