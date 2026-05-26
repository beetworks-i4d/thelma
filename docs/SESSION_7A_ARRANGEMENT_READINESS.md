# Session 7A — Arrangement-Readiness Evaluation

**Date:** 2026-05-26
**Branch:** dev
**Baseline:** 94 rspec examples, 0 failures. All 6 probes pass Phase ABC.

---

## Cross-Probe Overview

| Probe | Cands | Fine/Marg/Unus | Pri/Sec/Ter | Clusters | Safe Trims | Exclusions |
|-------|-------|----------------|-------------|----------|------------|------------|
| real_probe | 6 | 5/1/0 | 1/5/0 | 0 | 6 | 1 |
| dead_air_setup | 5 | 5/0/0 | 2/1/2 | 1 | 5 | 1 |
| emphatic_rant | 7 | 7/0/0 | 3/4/0 | 0 | 7 | 2 |
| explainer_rapid | 13 | 13/0/0 | 6/7/0 | 2 | 13 | 0 |
| low_energy_reflective | 6 | 5/1/0 | 1/2/3 | 0 | 6 | 2 |
| pause_heavy_transition | 7 | 7/0/0 | 0/5/2 | 1 | 7 | 1 |
| **TOTALS** | **44** | **42/2/0** | **13/24/7** | **4** | **44** | **7** |

---

## Per-Probe Assessments

### 1. real_probe (6 cands / 8 segs)

**Arrangement-readiness:**
- Too broad: cand_001 at 25.4s (2 atoms) contains realization + math + rhetorical question — should be 2-3 clips
- Too narrow: cand_003 at 1.76s. Emphatic payoff but barely standalone
- Hook: WEAK. cand_003 "that's just the reality" reads as conclusion, not hook
- Close/payoff: YES. cand_003 emphatic close. cand_002 "didn't make sense to stay" as exit
- Claim/evidence: YES. cand_001 (skills claim) → cand_002 (math proof) → cand_003 (conclusion)
- Context preserved: YES but 43s gap between cand_004 and cand_005 (missing segments)
- Missing candidates: seg_258 gap suggests content outside probe window

**Top 5 arrangement-useful:**

| # | ID | Summary | Priority | Roles | States | Why useful |
|---|-----|---------|----------|-------|--------|-----------|
| 1 | cand_003 | "that's just the reality we live in today" | primary | claim, hook | vindication, competence | Emphatic 1.8s punchline. Perfect payoff beat. |
| 2 | cand_002 | "even 10% would be more than the company" | secondary | aside, transition | amusement | 15.5s math argument. Self-contained evidence block. |
| 3 | cand_005 | "when someone asks what I actually do" | secondary | aside, transition | amusement | 14.2s definition of business model. Arrangement-ready. |
| 4 | cand_001 | "once I realized I could take those skills" | secondary | aside, transition | amusement | 25.4s realization narrative. Has exclusion for dead air. |
| 5 | cand_004 | "the information age, the AI age" | secondary | aside, transition | amusement | 4.7s context setter. Usable as transition. |

**Top 3 problematic:**

| # | ID | Failure mode | Cause |
|---|-----|-------------|-------|
| 1 | cand_001 | 25.4s too broad — multiple editorial beats in one candidate | 2 segments merged; underlying atoms too large (15.5s + 9.9s) |
| 2 | cand_006 | Starts mid-sentence ("and get all of this") — marginal usability | Segment boundary from WhisperX falls mid-clause |
| 3 | cand_003 | 1.76s may be too short to anchor arrangement | Emphatic single-sentence segment. Structurally correct but fragile. |

---

### 2. dead_air_setup (5 cands / 6 segs)

**Arrangement-readiness:**
- Too broad: No
- Too narrow: YES — 4/5 candidates are < 1.3s. Not editorial content.
- Hook: NO
- Close/payoff: NO (unless "Seven months" serves as one in a larger arrangement)
- Claim/evidence: NO. Pre-recording tech chatter.
- Context preserved: N/A — content is not editorial
- Missing candidates: No — this IS the full content for this window

**Top 2 arrangement-useful:**

| # | ID | Summary | Priority | Roles | States | Why useful |
|---|-----|---------|----------|-------|--------|-----------|
| 1 | cand_004 | "Seven months." | primary | payoff | catharsis | 0.76s emphatic fragment. Could be a punchline in broader arrangement. |
| 2 | cand_005 | "Seven months." (alternate take) | primary | payoff | catharsis | Correctly clustered with cand_004. Arrangement selects one. |

**Top 3 problematic:**

| # | ID | Failure mode | Cause |
|---|-----|-------------|-------|
| 1 | cand_001 | Pre-recording chatter labeled fine + has no flag for non-content | No mechanism to detect non-editorial speech |
| 2 | cand_002 | "Video recording." labeled fine/secondary — not editorial | Mock has no content-quality judgment |
| 3 | cand_003 | "Oh, come on, come on." — frustration fragment, not content | Same: mock can't distinguish off-camera chatter from content |

---

### 3. emphatic_rant (7 cands / 7 segs) — BEST PROBE

**Arrangement-readiness:**
- Too broad: cand_004 at 22.9s (single atom). Contains 3-4 distinct ideas.
- Too narrow: cand_006 at 1.3s. Pure transition fragment.
- Hook: YES. cand_003 "The stuff that got you in trouble at work is exactly what makes you dangerous on your own." Textbook hook.
- Close/payoff: YES. cand_007 "What do you actually think a business person does all day?" as reframe. cand_005 as challenge.
- Claim/evidence: YES. cand_001 (claim) → cand_002 (identification) → cand_003 (reframe) → cand_004 (context) → cand_005+cand_006+cand_007 (challenge sequence).
- Context preserved: YES. Complete rhetorical arc.
- Missing candidates: None obvious.

**Top 5 arrangement-useful:**

| # | ID | Summary | Priority | Roles | States | Why useful |
|---|-----|---------|----------|-------|--------|-----------|
| 1 | cand_003 | "The stuff that got you in trouble at work is exactly what makes you dangerous" | primary | claim, hook | vindication, competence | 4.4s perfect hook. Emphatic, self-contained, counterintuitive. |
| 2 | cand_001 | "getting good at your job makes your boss's boss rich" | primary | claim, hook | vindication, competence | 6.1s core thesis. Has tighter_start trim option. |
| 3 | cand_002 | "Have you been told you ask too many questions?" | secondary | aside, transition | amusement | 15.4s audience identification. Has exclusion + tighter_end. |
| 4 | cand_005 | "Every time you say I'm not a business person" | secondary | aside, transition | amusement | 5.7s direct challenge to viewer. Call-to-action frame. |
| 5 | cand_007 | "What do you actually think a business person does?" | secondary | aside, transition | amusement | 6.3s reframe question. Strong close candidate. |

**Top 3 problematic:**

| # | ID | Failure mode | Cause |
|---|-----|-------------|-------|
| 1 | cand_004 | 22.9s single atom, 3-4 ideas — too broad for selection | Upstream segment too large; not a candidate_builder problem |
| 2 | cand_006 | "But let me ask you something" — 1.3s pure transition, no standalone value | Correct segmentation but no editorial content. Arrangement should skip. |
| 3 | — | Mock labels cand_002 as aside/transition, but it's clearly setup/identification | Mock Phase B limitation — real LLM would classify correctly |

---

### 4. explainer_rapid (13 cands / 17 segs) — MOST IMPROVED

**Arrangement-readiness:**
- Too broad: No candidates > 11s. The v2 heuristic solved this completely (was 44.7s in v1).
- Too narrow: cand_010 (0.92s), cand_012 (0.76s) — fragments.
- Hook: YES. cand_001 "Here's how I evaluate any business model." + cand_009 "saving the best one for last."
- Close/payoff: YES. cand_013 transitions to actual content (affiliate marketing). cand_008 bridge.
- Claim/evidence: YES. cand_001 (claim frame) → cand_002 (list) → cand_003 (qualifier) → cand_004 (contrast) → cand_005 (takeaway) → cand_006 (punchline) → cand_007 (personal evidence).
- Context preserved: YES. Full 10-beat explanatory arc now properly segmented.
- Missing candidates: None. All 17 segments covered.

**Top 5 arrangement-useful:**

| # | ID | Summary | Priority | Roles | States | Why useful |
|---|-----|---------|----------|-------|--------|-----------|
| 1 | cand_001 | "Here's how I evaluate any business model." | primary | claim, hook | vindication, competence | 1.9s emphatic hook. Perfect arrangement opener. |
| 2 | cand_006 | "And most people don't even think about that." | primary | claim, hook | vindication, competence | 1.6s emphatic punchline. Lands after the contrast beats. |
| 3 | cand_004 | "if you've got a job... if you've got no job..." | secondary | aside, transition | amusement | 9.4s contrast evidence. Two-sided argument. |
| 4 | cand_008 | "So let me walk you through every model I tried" | primary | claim, hook | vindication, competence | 4.0s promise/transition. Bridge to content section. |
| 5 | cand_002 | "six things: profit margin, startup costs..." | secondary | aside, transition | amusement | 8.6s definitional list. Establishes evaluation framework. |

**Top 3 problematic:**

| # | ID | Failure mode | Cause |
|---|-----|-------------|-------|
| 1 | cand_010 | "And how it actually went." — 0.92s fragment, no standalone editorial value | Hard split from large gaps both sides left isolated micro-segment |
| 2 | cand_012 | "So stick around." — 0.76s CTA fragment | Boundary marker split on "So" + profile incompatibility isolated it |
| 3 | cand_007 | 10.88s, 3 segments — includes trailing "OK." filler that adds nothing | Merge signals grouped personal admission + regret + filler together |

---

### 5. low_energy_reflective (6 cands / 6 segs)

**Arrangement-readiness:**
- Too broad: No
- Too narrow: No — all between 3.1s and 14.1s
- Hook: YES. cand_001 "You don't need a bigger plan. You need a worse plan that you actually do something with." Strong counterintuitive claim.
- Close/payoff: YES. cand_004 "You don't need more discipline." Clean aphorism.
- Claim/evidence: YES. cand_001 (claim) → cand_002 (evidence) → cand_003 (insight) → cand_004 (reframe) → cand_005 (context) → cand_006 (conclusion).
- Context preserved: YES. Clean 1:1 mapping, no content lost.
- Missing candidates: 72s gap between cand_004 and cand_005 (content outside probe window).

**Top 5 arrangement-useful:**

| # | ID | Summary | Priority | Roles | States | Why useful |
|---|-----|---------|----------|-------|--------|-----------|
| 1 | cand_001 | "You don't need a bigger plan. You need a worse plan" | primary | claim, hook | vindication, competence | 4.0s emphatic counterintuitive hook. |
| 2 | cand_004 | "You don't need more discipline. You need work that doesn't require it." | tertiary | aside, transition | amusement | 3.1s aphorism. Perfect payoff/close. |
| 3 | cand_002 | "I used to think I was lazy... four hours building without looking at the clock" | secondary | aside, transition | amusement | 14.1s personal story with exclusion. Core evidence beat. |
| 4 | cand_003 | "Same person, completely different output" | tertiary | aside, transition | amusement | 4.4s insight. BUT has problematic exclusion (see below). |
| 5 | cand_006 | "when you turn 18, you become an adult... you have total control" | tertiary | aside, transition | amusement | 6.5s broader context. Usable as setup. |

**Top 3 problematic:**

| # | ID | Failure mode | Cause |
|---|-----|-------------|-------|
| 1 | cand_003 | Exclusion trap: 3.3s exclusion in 4.35s candidate. Applied exclusion leaves ~1s of speech. | Long pause inside short segment creates ratio problem |
| 2 | cand_005 | Marginal (stumble) but no defect exclusion generated | Defect exclusions not implemented |
| 3 | — | Mock labels cand_004 as tertiary/aside — it's clearly a primary claim | casual/low → tertiary. Real LLM would correctly prioritize. |

---

### 6. pause_heavy_transition (7 cands / 8 segs)

**Arrangement-readiness:**
- Too broad: cand_004 at 24.8s (2 atoms). Problem + solution + action = 3 beats compressed.
- Too narrow: No
- Hook: WEAK. No emphatic candidates at all. cand_003 "you have enough information" closest to a claim.
- Close/payoff: YES. cand_007 "getting punched in the face" metaphor is a strong closer.
- Claim/evidence: YES but diffuse. cand_003 (claim) → cand_002 (evidence) → cand_005 (systemic) → cand_006 (summary).
- Context preserved: YES. Permission/action theme runs through all candidates.
- Missing candidates: None obvious within window.

**Top 5 arrangement-useful:**

| # | ID | Summary | Priority | Roles | States | Why useful |
|---|-----|---------|----------|-------|--------|-----------|
| 1 | cand_006 | "The people that get results are those that take action" | secondary | aside, transition | amusement | 4.7s clean summary claim. Best anchor in this probe. |
| 2 | cand_003 | "you have enough information to get results" | secondary | aside, transition | amusement | 7.6s with tighter_end option. Clustered with cand_006. |
| 3 | cand_002 | "what changed everything wasn't a secret tactic" | secondary | aside, transition | amusement | 13.2s turning-point story. Evidence beat. |
| 4 | cand_007 | "most people will never give themselves permission" | tertiary | aside, transition | amusement | 12.2s contrast with metaphor. Has exclusion. |
| 5 | cand_005 | "the system we're thrown into trains us to wait" | secondary | aside, transition | amusement | 15.0s systemic claim. Context frame. |

**Top 3 problematic:**

| # | ID | Failure mode | Cause |
|---|-----|-------------|-------|
| 1 | cand_004 | 24.8s too broad — problem/solution/CTA in one candidate | 2 atoms merged with matching profile. Underlying atoms too large. |
| 2 | — | ZERO primary candidates — arrangement has no emphatic anchors | All casual profile → mock assigns secondary/tertiary. Content IS strong but labels can't signal it. |
| 3 | cand_001 | "And I was that way as well..." — 11.2s opener that restates without adding substance | Segment contains throat-clearing. No mechanism to flag this. |

---

## Systemic Findings

### Phase A (Structure) — READY

| Criterion | Status | Evidence |
|-----------|--------|---------|
| Right-sized candidates | PASS | 38/44 between 1-15s. Only 3 outliers > 20s. |
| Arrangement-safe trims | PASS | 44/44 candidates have at least one safe + preserved trim. |
| Clusters detect alternates | PASS | 4 clusters across 3 probes, all correct. |
| Exclusions placed correctly | PASS | 7 pacing exclusions. All within bounds. |
| No schema violations | PASS | All 6 probes pass Phase C with 0 errors. |
| Narrative structure recoverable | PASS | 5/6 probes have recognizable claim/evidence/payoff arcs. |

### Phase B (Mock Labels) — BLOCKING for production arrangement

| Failure | Impact | Frequency |
|---------|--------|-----------|
| aside/transition for everything casual | Arrangement can't find hooks, claims, evidence | 31/44 candidates get aside |
| amusement for everything casual | No emotional differentiation | 31/44 get amusement |
| 0 primary in pause_heavy | Arrangement has no anchor to start from | 1/6 probes |
| Summaries truncated to first sentence | Loses the point for multi-sentence candidates | 15/44 summaries misleading |
| Distillation is first 5 words, not semantic | No fingerprinting value | 44/44 distillations are mechanical |

### Known Gaps (not blocking arrangement test)

| Gap | Status | Consequence |
|-----|--------|-------------|
| Defect exclusions | NOT IMPLEMENTED | Stumbles in low_energy cand_005 not flagged |
| Non-editorial content detection | NOT IMPLEMENTED | dead_air chatter labeled fine |
| Sub-candidate splitting | NOT IMPLEMENTED | 3 candidates > 20s can't be decomposed |
| Exclusion-ratio guard | NOT IMPLEMENTED | low_energy cand_003: 3.3s exclusion in 4.35s candidate |

---

## Final Evaluation

### 1. Is candidate quality good enough to start arrange.rb v4?

**YES.** Phase A candidate structure is arrangement-ready. Every candidate has valid IDs, arrangement-safe trims, correct boundaries, and passes schema validation. The arrangement.yaml schema v4 selects candidates by ID and trims by ID — the mechanical structure is solid.

The mock Phase B labels are poor but arrangement can be tested against them. A deterministic mock arranger (Branch A, script-driven) can select candidates by prosody/energy/duration without trusting role suggestions.

### 2. If not, what must improve first?

Nothing is blocking a test implementation. For production quality:
- **Real LLM Phase B** — replaces mock. This is the single highest-value improvement.
- **Exclusion-ratio guard** — reject or warn when exclusion removes > 60% of candidate duration.
- **Oversized candidates** — the 3 remaining > 20s candidates. Could add a safety-cap split or accept as-is.

### 3. Which failure modes would most damage arrangement?

Ranked by severity:

1. **Mock role monotony** — aside everywhere means arrangement has no editorial vocabulary. It can't distinguish a hook from evidence from a payoff. Mitigated by ignoring role suggestions and using prosody/energy as proxy.
2. **Zero-primary probes** — pause_heavy has 0 primary candidates. Arrangement needs at least one anchor. Mitigated by allowing arrangement to promote candidates based on text quality.
3. **Oversized candidates** — 22-25s candidates that should be 2-3 clips. Arrangement selects whole candidates. Mitigated by trim_choices (limited) or accepting the duration.
4. **Exclusion-ratio trap** — low_energy cand_003 with exclusion leaves ~1s of speech. Arrangement selecting this with recommended exclusion produces an empty clip. Mitigated by validation at arrangement time.

### 4. What minimal arrangement test should Session 7B implement?

**Test fixture: emphatic_rant probe** (best quality, 7 candidates, clear narrative arc).

Build a deterministic mock arranger that:
1. Reads `editorial_candidates.yaml`
2. Produces a valid `arrangement.yaml` (schema v4, Branch A, selected_thesis: null)
3. Selects candidates by a simple heuristic: emphatic/primary first as hook, then by temporal order, skipping fragments < 1.5s
4. Assigns narrative_role based on position (first = hook, middle = continuation/evidence, last = payoff)
5. Groups into 2-3 chapters

**Validation tests:**
- arrangement.yaml matches schema v4 structure
- All candidate_id references exist in editorial_candidates.yaml
- All trim_choice_id references exist in the referenced candidate
- All exclusion_choice_ids exist in the referenced candidate
- No duplicate candidate_id across chapters
- Every selected trim has mechanical_boundary_safe=true AND content_preserved=true
- Chapter IDs are sequential
- At most one candidate per cluster appears

**Do NOT test:**
- Narrative quality (requires real LLM)
- Duration targets (no thesis)
- Throughline honoring (no discovery_pass)

### 5. What should remain deferred?

| Item | Reason to defer |
|------|----------------|
| Real LLM Phase B | Needs API integration, prompt engineering, cost management |
| Discovery pass / Branch B | Depends on real LLM for thesis generation |
| Multi-source arrangement | All probes are single-source; real libraries will test this |
| Sub-candidate splitting | Design decision: do it in candidate_builder or arrangement? |
| Defect exclusion generation | Useful but not blocking arrangement |
| export_arrangement_xml.rb | Needs a valid arrangement first (Session 7B output) |
| Throughline honoring | Depends on discovery_pass |
| unused_candidate_audit | Nice-to-have; arrangement validation can check this later |
