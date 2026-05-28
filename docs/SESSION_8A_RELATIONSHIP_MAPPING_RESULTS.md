# Session 8A — Relationship Mapping Results

**Date:** 2026-05-28
**Scope:** Deterministic heuristic relationship mapping (Pass 2 baseline)

---

## Relationship Counts by Probe

| Probe | Candidates | Relationships | By Type |
|-------|-----------|---------------|---------|
| emphatic_rant | 7 | 13 | supports:4, contradicts:5, elaborates:1, tangent_from:2, bridge_to:1 |
| explainer_rapid | 13 | 31 | tangent_from:10, contradicts:6, bridge_to:6, supports:5, elaborates:2, duplicate_of:2 |
| low_energy_reflective | 6 | 5 | tangent_from:3, contradicts:2 |

**Confidence distribution:**

| Probe | high | medium | low |
|-------|------|--------|-----|
| emphatic_rant | 1 | 9 | 3 |
| explainer_rapid | 3 | 16 | 12 |
| low_energy_reflective | 0 | 2 | 3 |

---

## Most Useful Relationship Types

**duplicate_of** — Highest signal. Text overlap threshold (70%) catches real alternate takes cleanly. explainer_rapid correctly identifies cand_008/cand_010 ("So let me walk you through every model...") and cand_009/cand_011 ("I'm saving the best/one that worked for last") as duplicates. These are genuinely the same idea restated. High confidence justified.

**bridge_to** — After tightening to immediate neighbors only, this correctly identifies transition candidates that lead into the next beat. cand_006 ("But let me ask you something") bridging to cand_007 is a textbook editorial transition. The heuristic works because transition-role candidates with bridge markers are rare and specific.

**supports** — Catches evidence-for-claim patterns through role+overlap intersection. cand_002 (personal anecdote about asking too many questions) supporting cand_001 (getting good at your job vs running something) is a real editorial relationship — the anecdote is evidence for the claim.

**tangent_from** — Useful as a negative signal: adjacent candidates with zero lexical overlap indicate topic shifts. These mark natural chapter boundaries.

---

## False Positives

**contradicts** is the noisiest type. The heuristic fires on any contrast marker ("but", "however", "actually") combined with lexical overlap. This produces false contradictions:
- cand_001 "contradicts" cand_006 — the word "something" triggers overlap, "But" in cand_006 triggers contrast, but these aren't actually contradictory.
- cand_002 "contradicts" cand_006 — same pattern.
- Several contradicts relationships in emphatic_rant are really continuation or elaboration.

**supports** also fires false when the overlap is incidental. cand_001 "supports" cand_006 via the word "something" — this is noise, not a real editorial relationship.

The root cause: single-word overlap with common non-stop-words ("something", "because", "it's") creates phantom relationships. The stop word list needs expansion, or the minimum shared term count should be raised to 2+.

---

## False Negatives

**setup_for / payoff_of** — Zero detections across all three probes. The heuristic requires setup markers ("have you", "nobody tells") in an earlier candidate AND payoff markers ("that's why", "that's when") in a later one. The emphatic_rant has a natural setup-payoff arc (cand_002 poses a question about asking too many questions, cand_003 delivers the reframe "what makes you dangerous on your own"), but neither uses the exact marker phrases. This relationship type fundamentally requires semantic understanding that heuristics can't provide.

**example_of** — Zero detections. No candidates use literal "for example" or "such as" phrasing. Real examples in conversational video rarely use academic markers — they're introduced with "like" (too ambiguous to use as a trigger) or by simply telling a story.

**elaborates** — Only detected 1-2 per probe despite obvious elaboration chains (emphatic_rant cand_004 clearly elaborates on cand_001's employment-vs-ownership thesis). The continuation-role + precedes + overlap triple is too strict.

**alternate_take_of** — No detections despite duplicates existing. The cluster-based heuristic requires Phase A to have assigned cluster labels, and the emphatic_rant probe has all nil clusters. duplicate_of catches these via text overlap instead.

---

## What Deterministic Heuristics Can Do

1. **Detect near-duplicate content** reliably via text overlap ratio
2. **Identify transition/bridge points** when role labels are accurate
3. **Flag topic shifts** (tangent_from) via absence of shared vocabulary
4. **Suggest claim-evidence pairs** when role labels align with overlap

These are structural and lexical signals — they don't require understanding what the speaker means.

---

## What Likely Needs LLM Judgment

1. **setup_for / payoff_of** — Requires understanding that a question posed in one candidate is answered by a different candidate. No lexical markers exist.
2. **example_of** — Conversational examples don't announce themselves. An LLM can recognize "a story that illustrates a prior claim" without explicit markers.
3. **contradicts** — Distinguishing real contradiction from rhetorical contrast ("but" as continuation vs. "but" as opposition) requires semantic understanding.
4. **elaborates** — Recognizing that two candidates develop the same argument even with different vocabulary.
5. **supports strength** — Distinguishing incidental overlap from genuine evidential support.
6. **Relationship directionality** — Which candidate is the "from" and which is the "to" often requires understanding the rhetorical flow, not just temporal ordering.

---

## Readiness for Thesis Selection Pass

**Not yet ready.** The relationship map provides useful structural signals but has too much noise in the contradicts and supports categories to drive thesis selection directly. Specific gaps:

1. **No setup/payoff detection** means the thesis pass can't identify narrative arcs.
2. **False contradictions** would confuse thesis coherence scoring.
3. **Low_energy_reflective** produces only 5 relationships for 6 candidates — too sparse for thesis discovery.

**Recommended path to readiness:**
1. Tighten contradicts: require 2+ shared content words, not 1.
2. Add a pending-file LLM pass for relationship mapping (following the same pattern as Pass 1 candidate labeling).
3. Use heuristic relationships as a structural pre-filter, then let the LLM refine, reclassify, and add semantic relationships the heuristics miss.
4. Thesis selection can proceed once the relationship map has reasonable setup/payoff and elaboration coverage.

---

## Tests

30 specs, 0 failures. Coverage:
- Basic execution and file generation
- Duplicate/alternate detection (explainer_rapid clusters)
- Supports detection (claim+evidence role pairs)
- Contradiction detection (contrast markers)
- Bridge detection (transition role + adjacency)
- Tangent detection (low overlap + adjacency)
- Setup/payoff pair invariant
- Deterministic repeatability (byte-identical on consecutive runs)
- Multi-probe execution
- Error handling (missing input, no arguments)

All 129 candidate_builder specs continue to pass. Total: 159 specs, 0 failures.
