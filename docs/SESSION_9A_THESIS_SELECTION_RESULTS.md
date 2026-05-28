# Session 9A: Thesis / Angle Selection — Results

## Summary

Implemented `scripts/select_thesis.rb` — Pass 3 thesis selection from candidates + relationships. Deterministic baseline from graph analysis, with optional LLM refinement via pending-file workflow.

**Status:** 33 specs pass, 0 failures. 226 total project specs pass.

## Architecture

**Input:** `editorial_candidates.yaml` + `augmented_candidate_relationships.yaml` (falls back to `candidate_relationships.yaml`)

**Output:** `selected_thesis.yaml`

**Modes:** `--mode mock` (deterministic only) | `--mode pending` (LLM augmentation via pending-file)

### Deterministic Baseline

The script scores every candidate as a potential thesis anchor using:

| Signal | Weight |
|--------|--------|
| Inbound reinforcing relationships (supports, elaborates, setup_for, payoff_of) | 1.0-4.5 per relationship (confidence × type bonus) |
| Outbound reinforcing relationships | 0.5-1.5 per relationship |
| candidate_priority (primary/secondary/tertiary) | +2.0/+1.0/+0.0 |
| durability (identity/mood/spike) | +3.0/+1.5/+0.5 |
| Narrative role: claim | +2.0 |
| Narrative role: hook | +1.5 |
| Narrative role: transition | -2.0 |
| Narrative role: aside | -1.0 |

Top-scoring anchors generate theses by clustering supporting candidates via relationship graph traversal (2-degree BFS on reinforcing edges).

### Filters

- Single-candidate theses rejected (can't sustain a narrative)
- Theses with >50% cluster overlap with a higher-ranked thesis rejected
- Unusable candidates scored at -100.0
- Max 3 theses generated

### LLM Augmentation

Pending-file workflow (same pattern as Pass 1 and Pass 2):
- Script writes `thesis_selection_pending.json` with baseline theses + candidates + relationships
- LLM refines thesis wording, adjusts confidence, improves hook/payoff selection, adds throughlines
- Script validates response (all candidate IDs must exist, no invented fields, no group overlap)
- LLM may NOT invent candidate IDs, relationships, or unsupported theses

## Emphatic Rant Probe Results

### Deterministic Baseline (mock mode)

**thesis_001** (score=16.0, confidence=high):
- **Anchor:** cand_001 — "getting good at your job makes your boss's boss rich..."
- **Primary candidates:** cand_001, cand_002, cand_003, cand_004, cand_005, cand_007 (6 of 7)
- **Excluded:** cand_006 (transition phrase — "But let me ask you something")
- **Hook:** cand_003 ("The stuff that got you in trouble at work is exactly what makes you dangerous on your own")
- **Payoff:** cand_003 (same — no distinct payoff candidate identified by heuristics)
- **Throughlines:** core argument, setup/payoff arc, aspiration emotional throughline
- **Duration:** ~61s

No noise theses generated. The single-candidate filter correctly eliminated cand_006 (the transition) which scored 3.5 but had no supporting cluster.

### LLM-Augmented (pending mode)

**thesis_001** (confidence=high, refined):
- **Statement:** "The traits that make you unemployable are the same ones that make you dangerous as an entrepreneur — and the system that told you to get a stable job was optimizing for a world that no longer exists."
- **Primary:** cand_001, cand_002, cand_003, cand_004, cand_005 (moved cand_007 to supporting)
- **Supporting:** cand_007 (demystifies the business person identity)
- **Hook:** cand_003 (same as baseline)
- **Payoff:** cand_007 (new — LLM identified this as the closing beat)
- **Throughlines:** (1) employment weakness = entrepreneurship strength, (2) setup/payoff arc, (3) identity dismantling arc

## Where Deterministic Heuristics Worked

1. **Anchor identification.** cand_001 was correctly identified as the thesis anchor — it has 4 inbound reinforcing relationships (3 elaborates + 1 supports from the augmented graph), primary priority, and identity durability.

2. **Cluster formation.** The 2-degree BFS correctly gathered 5 supporting candidates into the thesis cluster, all connected through reinforcing relationships.

3. **Noise rejection.** cand_006 (1-second transition) was correctly excluded from the thesis via the transition role penalty and the single-candidate filter.

4. **Confidence scoring.** The high-confidence rating is justified: 6 candidates, score=16.0, which reflects the dense relationship graph.

## Where LLM Augmentation Improved Selection

1. **Thesis statement.** The deterministic version uses the raw candidate text as the thesis statement. The LLM synthesized a compelling 35-word thesis that captures the through-argument, not just the anchor moment.

2. **Payoff identification.** The deterministic baseline picked cand_003 for both hook and payoff (same candidate). The LLM identified cand_007 as the closing payoff — "what do you actually think a business person does?" — which provides a better editorial arc.

3. **Primary vs supporting distinction.** The LLM moved cand_007 from primary to supporting, recognizing it serves a different editorial function (identity demystification) than the core employment-vs-ownership argument.

4. **Throughline refinement.** The LLM identified three specific narrative threads versus the heuristic's generic labels. The "identity dismantling" throughline (cand_005 → cand_007) is a genuine editorial insight.

## Hallucination Risks

### Controlled (validator catches)
- Invented candidate IDs
- Candidates in multiple groups (primary + excluded)
- Invalid confidence values
- Invented fields
- Unknown hook/payoff references
- Thesis statement over 50 words

### Residual (require review)
- **Thesis overreach.** LLM could construct a thesis statement that sounds compelling but isn't actually supported by the candidate texts.
- **Hook/payoff misjudgment.** LLM might pick a weaker opening or closing candidate based on a misread of the content.
- **Premature exclusion.** LLM might exclude a candidate that actually strengthens the thesis because it misunderstood the relationship.

### Mitigation
The deterministic baseline provides a sanity check: if the LLM's thesis diverges radically from the graph-derived thesis, something is wrong. The validator ensures structural integrity, and the baseline score provides a numerical anchor.

## Weak/Noise Theses

The emphatic_rant probe generated only 1 thesis in mock mode. Candidates that were considered but rejected:

| Candidate | Score | Rejection Reason |
|-----------|-------|-----------------|
| cand_006 | 3.5 | Single-candidate cluster (transition phrase, no supporters) |
| cand_007 | ~5.0 | Cluster overlapped >50% with thesis_001 |
| Others | <3.5 | Lower scores, already consumed by thesis_001 |

The single-candidate filter is the most important quality gate — it prevents transition phrases, asides, and isolated moments from becoming thesis candidates.

## Test Summary

```
33 examples, 0 failures (5.72s)

  mock mode:                     10 tests
  thesis quality (emphatic_rant): 8 tests
  deterministic repeatability:    1 test
  pending mode (no response):     1 test
  pending mode (with response):   5 tests
  validator rejection:            6 tests
  error handling:                 2 tests
```

## Readiness for Arrangement Generation

The thesis selection pass produces a structured editorial direction with:
- Clear anchor and primary candidates
- Hook and payoff identification
- Throughlines for narrative arc guidance
- Supporting vs excluded candidate groupings
- Target duration estimate

**Ready for Pass 4 (arrangement generation).** The selected thesis provides the constraint set the arrangement pass needs:
- **Which candidates to include** (primary + supporting)
- **Which to exclude** (excluded list + transition phrases)
- **Opening beat** (likely_hook → cand_003)
- **Closing beat** (likely_payoff → cand_007)
- **Narrative threads** to honor across chapters

## Files

| File | Purpose |
|------|---------|
| `scripts/select_thesis.rb` | Thesis selection script (mock + pending modes) |
| `spec/scripts/select_thesis_spec.rb` | 33 tests |
| `spec/fixtures/session6_probe_emphatic_rant/thesis_selection_response.json` | Fixture LLM response |
| `docs/SESSION_9A_THESIS_SELECTION_RESULTS.md` | This document |
