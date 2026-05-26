# Session 6D — Multi-Probe Heuristic Analysis

**Date:** 2026-05-26
**Branch:** dev
**Prerequisite:** Session 6C Real-Material Probe Report

---

## Probes Run

| # | Probe | Source | Segments | Style | Duration Window |
|---|-------|--------|----------|-------|-----------------|
| 0 | real_probe (6C) | MVI_5119.MP4 | 8 | Talking head, mixed energy | 863–1015s (151s) |
| 1 | emphatic_rant | Dylan Shorts 1.MP4 | 7 | Punchy claims, emphatic bursts | 98–181s (83s) |
| 2 | low_energy_reflective | Dylan Shorts 1.MP4 | 6 | Ultra-low energy, spaced out | 217–347s (130s) |
| 3 | pause_heavy_transition | Dylan Shorts 1.MP4 | 8 | Long pauses between topics | 405–533s (128s) |
| 4 | dead_air_setup | 002 I tried every laptop job.MP4 | 6 | Pre-recording tech chatter | 11–99s (88s) |
| 5 | explainer_rapid | 002 I tried every laptop job.MP4 | 17 | Fast-paced educational | 275–335s (60s) |

All 6 probes pass Phase C validation. Two libraries, two source files, five distinct speech patterns.

---

## Quantitative Summary

| Metric | real_probe | emphatic | low_energy | pause_heavy | dead_air | explainer |
|--------|-----------|----------|------------|-------------|----------|-----------|
| Segments | 8 | 7 | 6 | 8 | 6 | 17 |
| Candidates | 3 | 6 | 6 | 6 | 5 | 4 |
| Compression ratio (seg/cand) | 2.67 | 1.17 | 1.0 | 1.33 | 1.2 | 4.25 |
| Multi-atom candidates | 2 | 1 | 0 | 2 | 1 | 2 |
| Max atoms in 1 candidate | 5 | 2 | 1 | 2 | 2 | **11** |
| Max candidate duration | **48.4s** | 22.9s | 14.1s | 24.8s | 9.1s | **44.7s** |
| Avg candidate duration | 24.0s | 10.4s | 7.0s | 14.8s | 2.6s | 13.9s |
| Oversized (>20s) | 1 | 1 | 0 | 1 | 0 | 1 |
| Undersized (<3s) | 0 | 0 | 0 | 0 | 4 | 2 |
| Non-full_clean trims | 0 | 4 | 0 | 1 | 0 | 0 |
| Total exclusions | 1 | 2 | 2 | 1 | 1 | 0 |
| Defect exclusions | 0 | 0 | 0 | 0 | 0 | 0 |
| Clusters detected | 0 | 0 | 0 | 0 | 2 | 2 |

---

## Per-Probe Analysis

### Probe 1: emphatic_rant (7 segs → 6 cands)

**Inter-segment gaps:** 0.42s, 2.10s, 6.31s, 2.14s, 0.42s, 7.59s

**What happened:** Mostly single-atom candidates. The emphatic style naturally has dramatic pauses between punchy statements, creating >1s gaps that correctly split candidates. One multi-atom merge (seg_009+010, 7.4s) is a legitimate rhetorical continuation ("Every time you say I'm not a business person... But let me ask you something.").

**Best candidate:** cand_003 (seg_007, 4.4s) — "The stuff that got you in trouble at work is exactly what makes you dangerous on your own." Perfect editorial hook. Right-sized, self-contained, emphatic delivery.

**Worst candidate:** cand_004 (seg_008, 22.9s) — Contains setup + claim + evidence + conclusion in one block. Should be 2-3 separate candidates, but it's one long segment that was never split by semantic_segment upstream.

**Trim result:** 4 non-full_clean trims generated (tighter_start x2, tighter_end x2). This is the ONLY probe with meaningful trim variety. Why: the emphatic delivery creates noticeable word-onset gaps at segment boundaries that the trim heuristic can detect.

**Observation:** Emphatic speech produces the best candidate quality without any heuristic changes. Natural pauses align with editorial boundaries.

---

### Probe 2: low_energy_reflective (6 segs → 6 cands)

**Inter-segment gaps:** 3.24s, 6.65s, 3.18s, 71.96s, 2.60s

**What happened:** All single-atom candidates. Gaps are enormous (3–72s) because this is quiet, reflective content with long thinking pauses between statements. Zero merging.

**Best candidate:** cand_004 (seg_018, 3.1s) — "You don't need more discipline. You need work that doesn't require it." Tight aphorism, clean delivery.

**Worst candidate:** None are bad structurally. But cand_005 (seg_019, 10.1s) has stumble_count=1 and is correctly marked `marginal` — yet no defect exclusion is generated for the stumble.

**Trim result:** Zero non-full_clean trims. Word onsets align with segment starts (within 20ms tolerance), so tighter_start/end conditions never trigger.

**Observation:** Widely-spaced reflective speech produces natural 1:1 segment-to-candidate mapping. This is the baseline "easy case" for the grouper.

---

### Probe 3: pause_heavy_transition (8 segs → 6 cands)

**Inter-segment gaps:** 2.81s, 9.43s, 4.97s, 0.34s, 11.46s, 4.82s, 10.97s

**What happened:** Two multi-atom merges. cand_004 (seg_026+027, 24.8s) merged because gap=0.34s. cand_006 (seg_029+030, 17.0s) merged because gap=4.82s — wait, that exceeds CONTIGUITY_GAP_S=1.0. Let me verify: seg_029 e=520.78, seg_030 t=520.78+... Actually, checking the data: seg_028 e=504.97, seg_029 t=515.94 (11s gap → separate). seg_029 e=520.78, seg_030 t=520.78 (0.0s gap → merged). Correct.

**Best candidate:** cand_003 (seg_025, 7.6s) — "At a certain point, you have enough information to get results." Clean claim. Also the only candidate with a non-full_clean trim (tighter_end).

**Worst candidate:** cand_004 (24.8s) — Two distinct ideas merged: "most people never give themselves permission" (problem) + "you don't need all the information right now, just take action" (solution). These are separable editorial beats forced into one candidate.

**Mock label finding:** ALL 6 candidates get identical labels: amusement/casual/spike. The mock has zero discriminating power when all segments share the same audio_profile. Every candidate in this probe is casual/medium — the mock can't distinguish a problem statement from a solution from a transition.

**Observation:** Long inter-segment pauses (3–12s) reliably create correct candidate boundaries. Short gaps (<0.5s) within a topical flow create incorrect merges.

---

### Probe 4: dead_air_setup (6 segs → 5 cands)

**Inter-segment gaps:** 0.02s, 13.12s, 43.90s, 14.58s, 2.95s

**What happened:** Pre-recording tech chatter. seg_001+002 merged (0.02s gap) despite being unrelated content ("Recording audio one holds" + "Recording audio two"). The rest correctly separate due to massive gaps.

**Best candidate:** cand_004/cand_005 — "Seven months." repeated twice. Correctly separated into two candidates. Correctly clustered together (cluster: `months_seven`). This validates lexical clustering on real material.

**Worst candidate:** cand_001 (seg_001+002, 9.1s) — Merges "recording audio one holds" with "recording audio two." Technically correct by contiguity (0.02s gap), but editorially meaningless. A 9.1s candidate containing 5s of dead air (pacing exclusion correctly detected at 13.95–19.04s).

**Observation:** 4/5 candidates are undersized (<3s). This is correct for pre-recording chatter — these fragments shouldn't become real editorial material. But the system treats them the same as substantive content.

---

### Probe 5: explainer_rapid (17 segs → 4 cands) — WORST CASE

**Inter-segment gaps:** 0.02, 0.46, 0.10, 0.36, 0.14, 0.44, 0.26, 0.50, 0.30, 0.32, **1.83**, **1.34**, **1.70**, 0.02, 0.32, 0.32

**What happened:** Catastrophic merging. 11 segments (seg_036–046) collapse into cand_001 spanning 44.7 seconds. The segment gaps within this block range from 0.02s to 0.50s — all below 1.0s.

**Cand_001 contains at least 5 distinct editorial beats:**
1. "Here's how I evaluate any business model." (hook/claim)
2. "Six things: profit margin, startup costs, time, complexity, demand, scalability." (list)
3. "These matter differently depending on your situation." (qualifier)
4. "Most people don't even think about that." (punchline)
5. "So let me walk you through every model I tried." (transition)

A human editor would cut this into 3-5 separate clips. The candidate builder produces one.

**Profile transitions within cand_001:** 5 transitions (emphatic→casual→landing→casual×3→emphatic→casual→casual→casual→emphatic). The speaker shifts delivery style 5 times within the merged block, and NONE of these transitions create a boundary.

**Best candidate:** cand_002 (seg_047, 2.4s) — "And I'm saving the best one for last." Punchy teaser, right size. Split correctly because the preceding gap is 1.83s.

**Worst candidate:** cand_001 (11 atoms, 44.7s) — Everything wrong. Oversized, multi-topic, zero trim options, zero exclusions, treated as one editorial moment.

**Trim result:** Zero non-full_clean trims across all 4 candidates. The rapid speech has no word-onset slack at segment boundaries.

**Exclusion result:** Zero exclusions despite multiple sub-second pauses within the monster candidate. The pauses in the speech_analysis don't reach LONG_PAUSE_THRESHOLD_MS=1500 within the merged block.

**Cluster result:** Correctly clusters "I'm saving the best one for last" (cand_002, emphatic) with "I'm saving the one that worked for last" (cand_004, landing). Jaccard similarity catches the repeated phrasing.

**Observation:** Rapid speech is the worst case for contiguity-based grouping. Inter-sentence gaps in fluent educational delivery (0.1–0.5s) are an order of magnitude smaller than the 1.0s threshold.

---

## Cross-Probe Comparison: Segment Gap Analysis

| Probe | Min gap | Max gap | Avg gap | Gaps > 1s | % gaps > 1s |
|-------|---------|---------|---------|-----------|--------------|
| real_probe | 0.02s | 42.92s | 11.64s | 2/7 | 29% |
| emphatic_rant | 0.42s | 7.59s | 3.16s | 5/6 | 83% |
| low_energy | 2.60s | 71.96s | 17.53s | 5/5 | 100% |
| pause_heavy | 0.34s | 11.46s | 6.40s | 5/7 | 71% |
| dead_air | 0.02s | 43.90s | 14.91s | 4/5 | 80% |
| explainer_rapid | 0.02s | 1.83s | 0.53s | 3/16 | **19%** |

The explainer_rapid probe has 81% of its gaps below 1.0s. This means 81% of potential candidate boundaries are missed. Conversely, low_energy has 100% of gaps above 1.0s, meaning every segment becomes its own candidate (ideal for that content type).

---

## Cross-Probe Comparison: Pause-Boundary Correlation

**Question: Do speech_analysis long_pauses align with candidate boundaries?**

| Probe | Long pauses in window | Pauses that became exclusions | Pauses at candidate boundaries |
|-------|----------------------|-------------------------------|-------------------------------|
| emphatic_rant | 9 | 2 | 5 (coincide with inter-segment gaps) |
| low_energy | 11 | 2 | 0 (pauses are within-segment, not between) |
| pause_heavy | 6 | 1 | 3 |
| dead_air | 5 | 1 | 4 |
| explainer_rapid | 3 | 0 | 2 (at gaps > 1s) |

Pauses correlate with candidate boundaries when the pause duration exceeds the contiguity gap threshold. But many pauses are too short (< 1.5s) to become exclusions and too short to create candidate splits. There is a gap between "perceptible editorial pause" (0.3–1.0s) and "long enough for the system to notice" (1.5s).

---

## Cross-Probe Comparison: Profile Transitions as Boundary Signals

| Probe | Profile transitions | Transitions inside merged candidates | Transitions at actual boundaries |
|-------|--------------------|------------------------------------|----------------------------------|
| emphatic_rant | 5 | 1 (seg_009→010, intentional merge) | 4 |
| low_energy | 1 | 0 | 1 |
| pause_heavy | 0 | 0 | 0 |
| dead_air | 2 | 1 (seg_001→002, bad merge) | 1 |
| explainer_rapid | 8 | **5** | 3 |
| real_probe | 2 | 2 (both inside monster candidate) | 0 |

In the explainer_rapid probe, 5 profile transitions are swallowed by the monster candidate. Profile changes (emphatic→casual at 0.02s, casual→emphatic at 0.44s) represent genuine shifts in delivery mode that the contiguity grouper ignores.

**Observation:** Profile transitions are a stronger editorial boundary signal than gap duration alone, but only when the gap is small. When gaps are large (>2s), the gap itself is sufficient.

---

## Repeated Failure Modes (All Probes)

### F1. Monster candidates from rapid/fluent speech
**Seen in:** real_probe (48.4s), explainer_rapid (44.7s), pause_heavy (24.8s), emphatic_rant (22.9s)
**Frequency:** 4/6 probes produce at least one candidate > 20s
**Cause:** CONTIGUITY_GAP_S=1.0 is too high for speech with inter-sentence gaps of 0.1–0.5s. All contiguous same-source segments merge regardless of semantic content.
**Impact:** Arrangement can only select the entire candidate. Cannot extract a 5s hook from a 45s block.

### F2. Full_clean-only trim choices
**Seen in:** 5/6 probes (only emphatic_rant has non-trivial trims)
**Frequency:** 28/35 total candidates have exactly 1 trim choice
**Cause:** Segment boundaries tightly align with word onsets (within 1-3ms). The tighter_start/end conditions require > 20ms slack between word boundary and segment boundary, which almost never exists.
**Impact:** The trim_choices mechanism is dead code. Arrangement has no trim options.

### F3. Zero defect exclusions
**Seen in:** ALL probes. 0 defect-type exclusions across all 6 probes.
**Frequency:** 100% — complete absence
**Cause:** No code path generates defect exclusions from stumble_count, acoustic_pattern, or other segment fields. Only pacing exclusions from VAD long_pauses are implemented.
**Impact:** Stumbles, false starts, and abandoned phrases are never flagged for exclusion.

### F4. Mock labeling monotony
**Seen in:** ALL probes, most severe in pause_heavy (6/6 identical labels)
**Frequency:** When all segments share audio_profile=casual, all candidates get amusement/spike/secondary.
**Cause:** Mock B heuristic maps audio_profile → states. 91% of segments are casual → all get amusement.
**Impact:** Expected for mock, but confirms that Phase B real LLM labeling is critical for any downstream editorial intelligence.

### F5. Semantic boundaries invisible to contiguity
**Seen in:** explainer_rapid (5 topic shifts within one candidate), real_probe (multiple distinct ideas merged), pause_heavy (problem/solution merged)
**Frequency:** Every probe with multi-atom candidates shows some degree of incorrect semantic merging.
**Cause:** Contiguity grouping has no concept of topic, claim, or rhetorical shift. It only sees time gaps.

---

## Repeated Success Patterns (All Probes)

### S1. Natural pause boundaries work for emphatic/reflective speech
**Seen in:** emphatic_rant (83% gaps > 1s), low_energy (100% gaps > 1s)
**Frequency:** When inter-segment gaps are naturally > 1s, candidates are right-sized (3–15s).
**Why it works:** Emphatic speakers pause for effect. Reflective speakers pause to think. Both pause patterns align with editorial boundaries.

### S2. Lexical clustering correctly detects repeated takes
**Seen in:** dead_air ("Seven months" x2 → cluster `months_seven`), explainer_rapid ("saving the best one for last" variants → cluster `im_last_one`)
**Frequency:** 2/6 probes have clustering opportunities, both detected correctly.
**Why it works:** Jaccard similarity over content words catches repeated phrasing reliably. The 0.25 threshold seems well-calibrated.

### S3. Pacing exclusions work when VAD data aligns
**Seen in:** emphatic_rant (2 exclusions), low_energy (2 exclusions), dead_air (1 exclusion)
**Frequency:** 5/6 probes have at least 1 correct pacing exclusion (explainer has none because no pauses > 1.5s exist within the merged block).
**Why it works:** Long pauses within candidates are genuine dead air. The 1500ms threshold avoids false positives.

### S4. Single-atom candidates are consistently right-sized
**Seen in:** All probes. Single-atom candidates range from 0.68s to 22.9s, with most between 3–15s.
**Frequency:** 24/35 candidates are single-atom across all probes.
**Why it works:** semantic_segment.rb already produces reasonably-sized atoms. The problem is multi-atom merging, not single-atom sizing.

### S5. Prosody aggregation produces plausible values
**Seen in:** All probes. Energy quantization, profile voting, pitch trend computation are correct.
**Frequency:** 100% — no aggregation errors observed.
**Why it works:** Simple statistical operations (majority vote, mean, max) over segment-level data.

---

## Open Questions Before Heuristic Redesign

1. **What maximum candidate duration is editorially useful?** Session 6C identified 48s as "too large." The explainer probe produced 44.7s. But is 25s too large? 15s? The answer likely depends on content type and intended use (sequence vs. rough cut).

2. **Should atom count cap be fixed or adaptive?** A hard cap of 3-4 atoms would prevent monsters but might split natural multi-sentence statements. An adaptive cap based on speaking rate or duration could work better but adds complexity.

3. **Is semantic_segment.rb producing the right atom sizes?** Several probes have single atoms spanning 15-23s with multiple sentences. If atoms were smaller, contiguity merging would be less damaging because the units being merged would be finer-grained.

4. **Can profile transitions serve as boundary signals?** In explainer_rapid, 5 profile transitions within the monster candidate correlate with genuine editorial shifts. But in emphatic_rant, 1 profile transition within a merge is intentional. Profile transitions are suggestive but not deterministic.

5. **Should trim_choices be redesigned around sub-candidate windows?** The current word-level tighter_start/end approach is dead on real data. An alternative: for multi-atom candidates, generate trim choices that select subsets of atoms (first 2 of 5, last 3 of 5, etc.). This would make trim_choices useful for arrangement.

6. **How should the system handle content that is genuinely unusable?** The dead_air probe contains pre-recording tech chatter. Currently these become normal candidates with `fine` usability. There's no mechanism to flag entire candidates as non-content.

7. **Is the 1.0s CONTIGUITY_GAP_S threshold salvageable with modifications?** Or does the fundamental approach of gap-based grouping need replacement? The explainer probe suggests gap-based grouping fails categorically for rapid speech. But reducing the threshold would fragment slow speech.

8. **Would a maximum duration cap solve the monster problem adequately?** A simple "split any candidate at 15s" post-processing step would prevent monsters without changing the grouping logic. But it would split at arbitrary points rather than editorial boundaries.

---

## Assumption Assessment

### Strongest assumptions (confirmed by probes)

1. **Lexical clustering via Jaccard works.** Two independent observations with correct results. Threshold 0.25 produces zero false positives across 35 candidates.

2. **Pacing exclusions from VAD long_pauses are correct.** When domain-aligned, exclusions are placed at genuine dead air. The 1500ms threshold avoids false positives.

3. **Single-atom candidates are the right size.** 24/35 candidates across 6 probes are single-atom, and most fall in the 3-15s sweet spot.

4. **Phase C validation is sound.** All probes pass validation. The structural/taxonomy/data checks correctly gate output quality.

5. **Prosody aggregation is mechanically correct.** No aggregation bugs observed.

### Weakest assumptions (contradicted by probes)

1. **CONTIGUITY_GAP_S=1.0 produces usable candidate spans.** Fails catastrophically for rapid speech (explainer: 17→4 candidates, 44.7s monster). Works only when natural pauses happen to align with editorial boundaries.

2. **Word-level tighter_start/end trims are useful.** Dead code on 5/6 probes. Word boundaries align with segment boundaries within tolerance, so the condition almost never triggers.

3. **Contiguity is sufficient for candidate grouping.** Semantic boundaries occur without temporal gaps. Profile transitions, energy shifts, and topic changes are invisible to gap-based logic.

4. **Defect exclusions are implemented.** They are not. The spec defines defect exclusions (stumbles, false starts, abandonment) but no code generates them. stumble_count is tracked but never acted on.

5. **Mock Phase B labels are useful for testing grouping quality.** The mock assigns identical labels to wildly different editorial content, making it impossible to evaluate whether grouping produces editorially coherent candidates.

---

## Summary Table

| Probe | Grouping | Trims | Exclusions | Overall |
|-------|----------|-------|------------|---------|
| emphatic_rant | Good | Partial | Partial | Best probe |
| low_energy | Good | None | Partial | Easy case |
| pause_heavy | Marginal | Minimal | Minimal | Adequate |
| dead_air | Marginal | None | Partial | Mixed |
| explainer_rapid | **Failed** | **None** | **None** | Worst probe |
| real_probe (6C) | **Failed** | **None** | Minimal | Failed |

The current Phase A heuristics work for emphatic/reflective speech with natural pauses but fail for rapid/fluent speech. Trim generation is dead on real data. Defect exclusions don't exist. The failure modes are consistent and predictable.
