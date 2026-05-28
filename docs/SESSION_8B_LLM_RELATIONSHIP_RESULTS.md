# Session 8B: LLM Relationship Augmentation — Results

## Summary

Implemented `scripts/augment_candidate_relationships.rb` — a pending-file LLM augmentation layer that critiques and improves deterministic relationship mappings.

**Status:** 30 specs pass, 0 failures. One probe (session6_probe_emphatic_rant) successfully augmented.

## Architecture

Same pending-file pattern as semantic labeling (no API calls, no `claude -p`):

1. Script reads `editorial_candidates.yaml` + `candidate_relationships.yaml`
2. Writes `relationship_augmentation_pending.json` (prompt + candidates + baseline)
3. User/Claude fills `relationship_augmentation_response.json`
4. Script validates response, merges augmentations, writes `augmented_candidate_relationships.yaml`

**Modes:** `--mode mock` (pass-through, no augmentation) | `--mode pending` (default)

## Deterministic vs Augmented: Emphatic Rant Probe

### Baseline (deterministic heuristics): 13 relationships

| Type | Count |
|------|-------|
| supports | 4 |
| contradicts | 5 |
| elaborates | 1 |
| tangent_from | 2 |
| bridge_to | 1 |

**Key problem:** 5 of 13 baseline relationships are false positives — heuristics over-index on contrast markers ("But") and shared stop words ("something", "ask") without understanding context.

### Augmented (after LLM critique): 13 relationships

| Action | Count | Details |
|--------|-------|---------|
| removes | 4 | rel_003, rel_004, rel_007, rel_008 — false positive contradictions/supports involving cand_006 ("But let me ask you something") |
| upgrades | 2 | rel_001 medium→high (genuine evidence-for-claim), rel_013 medium→high (textbook rhetorical bridge) |
| downgrades | 1 | rel_006 medium→low (weak contradiction, same-angle critique) |
| reclassifies | 2 | rel_005 tangent_from→setup_for (setup/payoff arc), rel_012 contradicts→elaborates (shared theme, not opposition) |
| adds | 4 | payoff_of cand_003→cand_002, elaborates cand_004→cand_001, elaborates cand_005→cand_001, setup_for cand_005→cand_007 |

### After augmentation: type distribution

| Type | Count |
|------|-------|
| supports | 2 |
| elaborates | 4 |
| contradicts | 2 |
| tangent_from | 1 |
| bridge_to | 1 |
| setup_for | 2 |
| payoff_of | 1 |

## Where LLM Materially Improved Quality

### 1. False positive removal (biggest win)

The heuristic detected cand_006 ("But let me ask you something") as contradicting/supporting multiple candidates because "something" and "ask" appeared in shared vocabulary. The LLM correctly identified cand_006 as a 1-second rhetorical transition that has no semantic relationship with cand_001 or cand_002. Removing 4 false positives cleans up ~30% of the relationship graph.

### 2. Setup/payoff arc detection

The heuristic labeled cand_003→cand_002 as `tangent_from` because they share no vocabulary. The LLM recognized the semantic arc: cand_002 poses a question about being told you don't fit in, cand_003 delivers the reframe ("the stuff that got you in trouble is exactly what makes you dangerous"). This is a clear setup→payoff that vocabulary overlap cannot detect.

### 3. Thematic elaboration chains

The LLM identified three elaboration chains converging on cand_001 (the thesis candidate about employment vs ownership):
- cand_004→cand_001: generational critique deepens the employment trap
- cand_005→cand_001: identity barrier keeps people in the employment frame
- cand_002→cand_001: personal anecdote supports the thesis (upgraded to high)

These cross-candidate thematic connections are invisible to word-overlap heuristics.

### 4. Contradiction→elaboration reclassification

rel_012 (cand_005→cand_007) was labeled `contradicts` because both mention "business" and "person" with a contrast marker. The LLM recognized they address the same theme from complementary angles — cand_005 names the self-limiting belief, cand_007 demystifies it.

## Hallucination Risks

### Controlled risks (mitigated by validator)
- **Invented IDs:** Validator rejects unknown candidate_ids and relationship_ids
- **Invented fields:** Validator rejects any fields outside the allowed set
- **Invalid enums:** Validator rejects unknown types, confidences, and actions
- **Self-relationships:** Validator catches from==to
- **Missing rationale:** Validator requires explanation for every augmentation

### Residual risks (require human review)
- **Semantic judgment errors:** LLM could incorrectly identify a genuine contradiction as elaboration, or miss a real tangent
- **Over-removal:** LLM could be too aggressive removing relationships that seem like false positives but have editorial value
- **Rationale confabulation:** LLM provides fluent-sounding rationale that may not reflect the actual textual evidence

### Mitigation strategy
The augmented output preserves evidence trails: original heuristic evidence + LLM rationale are concatenated with `|` separator. A human reviewer can trace every change back to its justification.

## Validator Coverage

| Check | Tests |
|-------|-------|
| Invented candidate IDs | 1 |
| Self-relationships | 1 |
| Invalid relationship type | 1 |
| Invalid confidence level | 1 |
| Invalid action | 1 |
| Missing rationale | 1 |
| Unknown baseline relationship_id | 1 |
| Invented fields | 1 |
| Post-merge: ID format, uniqueness, references, enums, triples | via integration tests |
| Baseline file not modified | 1 |
| Unmodified relationships retain original evidence | 1 |

## Test Summary

```
30 examples, 0 failures (4.57s)

  mock mode:                    4 tests
  pending mode (no response):   1 test
  pending mode (with response): 11 tests
  validator rejection:           8 tests
  baseline preservation:         2 tests
  error handling:                2 tests
  missing prereqs:               2 tests
```

## Readiness for Thesis-Selection Pass

The augmented relationship graph is materially better than the deterministic baseline:
- False positives reduced from ~5/13 to ~0/13
- Thematic structure visible: cand_001 as thesis node with 3 supporting elaborations
- Setup/payoff arcs identified for narrative sequencing
- Bridge transitions properly weighted for pacing decisions

**Ready for Pass 4 (thesis selection)**. The relationship graph now provides enough signal to identify:
- **Thesis candidates:** cand_001 (3 inbound elaborates, 1 inbound supports)
- **Arc structure:** cand_002→cand_003 setup/payoff, cand_005→cand_007 setup/payoff
- **Bridge points:** cand_006 as high-confidence rhetorical transition

## Files

| File | Purpose |
|------|---------|
| `scripts/augment_candidate_relationships.rb` | Augmentation script (pending-file workflow) |
| `spec/scripts/augment_candidate_relationships_spec.rb` | 30 tests |
| `spec/fixtures/session6_probe_emphatic_rant/relationship_augmentation_response.json` | Fixture LLM response |
| `docs/SESSION_8B_LLM_RELATIONSHIP_RESULTS.md` | This document |
