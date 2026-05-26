# Session 7B — Mock Arranger Results

## Objective

Build the smallest viable deterministic arranger prototype that proves arrangement.yaml v4 works mechanically. No LLM calls — pure heuristic scoring replaces semantic judgment.

## Deliverables

- `scripts/mock_arrange.rb` — 357 lines, deterministic mock arranger
- `spec/scripts/mock_arrange_spec.rb` — 27 tests, all passing
- Arrangement.yaml generated for 5 of 6 probes (1 correctly rejected)

## Arrangement Summaries

### emphatic_rant (primary test fixture)

| Chapter | Candidate | Role | Profile/Energy | Duration |
|---------|-----------|------|----------------|----------|
| Opening | cand_003 | hook | emphatic/high | 4.39s |
| Opening | cand_001 | claim | emphatic/high | 6.06s |
| Development | cand_002 | evidence | casual/medium | 15.39s |
| Resolution | cand_004 | evidence | casual/medium | 22.93s |
| Resolution | cand_005 | continuation | casual/medium | 5.67s |
| Resolution | cand_007 | payoff | casual/medium | 6.34s |

- **3 chapters, 6 segments, 1 unused** (cand_006 cut for pacing — 1.34s < 1.5s minimum)
- Hook chosen: cand_003 (score 41) beats cand_001 (score 39) — same priority/energy, cand_003 shorter
- Exclusions: cand_002 has ex_001, cand_004 has ex_002 — both applied (recommended, pass 40% ratio)
- Chapter splits at cand_001→cand_002 (profile shift emphatic→casual) and cand_002→cand_004 (gap + energy)

### explainer_rapid

| Chapter | Segments | Notes |
|---------|----------|-------|
| Opening | cand_006 (hook), cand_001 (claim) | Both emphatic/high/primary |
| Development | cand_002, cand_003, cand_004, cand_005, cand_007 | Mix of evidence/continuation |
| Resolution | cand_008 (claim), cand_009 (claim), cand_013 (payoff) | cand_008,009 primary |

- **3 chapters, 10 segments, 3 unused**
- Cluster dedup active: cand_010 (cluster: actually_how_went, duplicate of cand_008) and cand_011 (cluster: im_last_one, duplicate of cand_009) dropped
- cand_012 dropped as bridge — short (0.76s) and lost its cluster neighbor

### real_probe

| Chapter | Segments | Notes |
|---------|----------|-------|
| Opening | cand_003 (hook) | emphatic/high |
| Development | cand_001 (evidence), cand_002 (evidence), cand_004 (continuation) | |
| Resolution | cand_005 (evidence), cand_006 (payoff) | |

- **3 chapters, 6 segments, 0 unused** — all 6 candidates arranged
- cand_001 has ex_001 applied

### low_energy_reflective

| Chapter | Segments | Notes |
|---------|----------|-------|
| Opening | cand_001 (hook) | Only primary candidate |
| Development | cand_002 (evidence), cand_003 (continuation), cand_004 (continuation) | All secondary/casual |
| Resolution | cand_005 (evidence), cand_006 (payoff) | |

- **3 chapters, 6 segments, 0 unused** — all 6 arranged
- cand_002 has ex_001 applied

### pause_heavy_transition

| Chapter | Segments | Notes |
|---------|----------|-------|
| Opening | cand_006 (hook), cand_001 (evidence), cand_002 (evidence) | |
| Development | cand_004 (evidence) | |
| Resolution | cand_005 (evidence), cand_007 (payoff) | |

- **3 chapters, 6 segments, 1 unused** (cand_003 bridge_dropped)
- cand_007 has ex_001 applied

### dead_air_setup — CORRECTLY REJECTED

- 5 candidates, 4 below 1.5s minimum → 1 eligible (cand_001 at 9.10s)
- Cannot satisfy hook + payoff with 1 candidate → clean abort
- This is the expected outcome: dead_air represents unusable source material

## What Worked

**Schema mechanics are solid.** Every generated arrangement passes self-validation against v4 schema constraints — sequential chapter IDs, candidate/trim/exclusion cross-references, cluster uniqueness, narrative role enums, hook + payoff requirement.

**Trim safety gate works.** Only `full_clean` trims (mechanical_boundary_safe + content_preserved) get selected. Tighter alternatives are correctly ignored.

**Exclusion-ratio guard works.** Recommended exclusions only applied when remaining duration >= 40% of raw. This is a sensible default that prevents gutting a candidate.

**Cluster dedup works.** explainer_rapid's two clusters (actually_how_went, im_last_one) correctly produce one representative each instead of near-duplicate selections.

**Min-duration filter works.** cand_006 in emphatic_rant (1.34s) correctly filtered. dead_air's tiny candidates correctly eliminated.

**Chapter splitting produces reasonable structure.** Energy/profile shifts create natural boundaries. The 3-chapter max keeps output manageable. Hook rewind (pulled from later in source) doesn't create false split scores because negative gaps are ignored.

**Determinism verified.** Running the same probe 3x produces byte-identical output every time.

## What Felt Mechanically Awkward

**Role assignment is position-based, not semantic.** Position 0 = hook, last = payoff, middle = claim/evidence/continuation by priority and duration. This means:
- A candidate that is genuinely a "setup" or "transition" can never get that role
- The suggested_narrative_roles from candidate_builder are completely ignored
- A candidate might be labeled "evidence" purely because it's secondary and > 8s, even if it's actually a personal anecdote

**Hook selection ignores content entirely.** The highest-scoring emphatic/primary candidate wins, regardless of whether it makes a good opening. cand_003 in emphatic_rant ("The stuff that got you in trouble at work...") happens to work as a hook, but that's coincidental — the scoring would pick it even if the text were garbage.

**Chapter titles are generic.** Opening/Development/Resolution tell the editor nothing. A real arranger would name chapters based on content themes.

**Bridge candidates have no special logic.** cand_003 in pause_heavy is dropped as "bridge_dropped" but only because it wasn't selected — there's no concept of needing connective tissue between segments with large temporal gaps.

**Unused audit categories are under-populated.** `cut_by_thesis` and `alternate_take_not_chosen` are always empty because:
- No thesis exists (Branch A, selected_thesis: null)
- No alternate-take detection exists (would require understanding that two candidates say the same thing differently)

## What Clearly Requires Real Semantic Reasoning

1. **Hook selection** — "Which clip grabs attention?" is fundamentally a content judgment. Prosody scoring is a proxy, not an answer. An emphatic delivery of "And how it actually went" (cand_010) is a terrible hook; an emphatic delivery of "The stuff that got you in trouble at work" (cand_003) is excellent. Same score, wildly different editorial quality.

2. **Narrative role assignment** — The difference between "evidence" and "aside" is whether the content supports the argument or is a tangent. Between "claim" and "setup", whether it states a position or prepares for one. These are meaning judgments.

3. **Chapter theming** — Where to split and what to call chapters depends on understanding topic shifts, argument structure, and emotional arc. Energy/profile shifts are a crude proxy.

4. **Alternate-take detection** — cand_008 and cand_010 in explainer_rapid are cluster siblings (actually_how_went), but a real arranger needs to decide which variant is better based on delivery quality, not just "first wins."

5. **Bridge necessity** — After pulling a hook from mid-source, the real arranger may need a bridge segment to smooth the temporal discontinuity. The mock arranger has no concept of this.

6. **Thesis-driven selection** — Branch B/D arrangements will have a selected_thesis that should filter candidates by relevance. The entire `cut_by_thesis` audit category is moot until then.

## Test Coverage

27 tests across 7 categories:
- Arrangement generation (structure, chapters, segments)
- Hook/payoff selection (position, role assignment)
- Candidate/trim/exclusion cross-reference validation
- Cluster dedup (explainer_rapid clusters)
- Min-duration filtering
- Deterministic repeatability
- Validate-only mode

All 27 pass. The existing 94 candidate_builder tests also pass (121 total, 0 failures).

## Conclusion

The v4 arrangement schema works mechanically. All cross-reference constraints, chapter structure, trim safety gates, and unused audit accounting function correctly. The mock arranger is a complete proof-of-concept that exercises every field in the schema.

The gaps are exactly where expected: content judgment (hook quality, role semantics, chapter theming). These are by design — the mock arranger's job was to prove the mechanical envelope works, not to make editorial decisions. The real arranger (LLM-based) will slot into the same schema with semantic reasoning replacing the heuristic scoring.
