# Session 6E — Candidate-Boundary Heuristic Redesign Proposal

**Date:** 2026-05-26
**Branch:** dev
**Prerequisites:** Session 6C Real-Material Probe Report, Session 6D Multi-Probe Analysis

---

## Problem Diagnosis

Across 6 probes covering 5 speech styles, the current contiguity-based grouper produces monster candidates (>20s) in 4/6 probes and completely fails on rapid/fluent speech (17 segments → 4 candidates, with an 11-atom 44.7s monster). The root cause is a single `CONTIGUITY_GAP_S = 1.0` threshold that treats temporal proximity as editorial relatedness.

The system needs a boundary strategy that:
- Prevents monsters on rapid speech (where inter-sentence gaps are 0.1–0.5s)
- Doesn't fragment reflective speech (where 3s gaps are natural between thoughts)
- Detects semantic shifts that happen without temporal gaps
- Remains deterministic and testable (Phase A invariant)
- Doesn't require LLM calls (no Phase B dependency)

---

## Foundational Analysis

### What "good candidate" means operationally

A good candidate is a **single cuttable editorial moment** that arrangement can select or reject as a unit. Operationally:

1. **Self-contained.** It expresses one idea, one rhetorical beat, one emotional moment. A viewer could watch just this clip and understand what's being said.
2. **Right-sized.** Duration between 2s and 20s. Under 2s is likely a fragment (unusable alone). Over 20s is likely multiple ideas forced into one block (arrangement can't extract sub-parts).
3. **Boundary-clean.** The start and end land on natural speech boundaries — not mid-sentence, mid-word, or mid-thought. An editor can cut to/from this candidate without an awkward jump.
4. **Labelable.** Phase B can assign a meaningful state, role, and priority. A 45s candidate spanning 5 topics cannot receive a single coherent label.

The ideal candidate is what an editor would mark with in/out points in a first pass through footage: "this is a usable moment."

### Why hard duration caps are insufficient

A duration cap (e.g., "split any candidate at 15s") prevents monsters but creates a worse problem: **arbitrary splits**. A 30s candidate containing two 15s ideas would be split correctly by coincidence, but a 25s candidate containing a 10s idea followed by a 15s idea would be split at 15s — right in the middle of the second idea.

Duration caps treat the symptom (oversized candidates) rather than the cause (wrong boundary detection). They also have no concept of where to split. The boundary between idea A and idea B might be at 8s or 22s — a fixed cap at 15s catches neither correctly.

Duration caps belong as a safety net (last-resort split), not as the primary strategy. The primary strategy must detect actual boundaries.

### Why pure gap-based grouping failed

The gap-based grouper has one assumption: temporal proximity implies editorial relatedness. This assumption holds only when the speaker pauses at topic transitions. The probes showed:

| Speech style | Typical inter-sentence gap | Gap > 1.0s? | Grouper result |
|---|---|---|---|
| Emphatic | 2–8s | Yes (83%) | Good: natural splits |
| Reflective | 3–72s | Yes (100%) | Good: every atom is its own candidate |
| Rapid/educational | 0.1–0.5s | No (81%) | Failed: everything merges |
| Setup/dead air | 0.02–44s | Mixed | Mixed: small fragments merge incorrectly |

The gap-based approach succeeds when the speaker's natural rhythm aligns with editorial boundaries. It fails when the speaker delivers multiple distinct ideas in a continuous flow. Since educational, interview, and podcast content commonly features continuous flow, the gap-based approach fails on a large and important class of real footage.

Lowering the threshold doesn't help. At 0.5s, the emphatic probe's good merge (seg_009+010, gap=0.42s, a legitimate continuation) would break. At 0.3s, even ordinary sentence spacing would cause splits. There is no single threshold that works across speech styles.

### Why single-atom candidates often worked

The strongest finding from Session 6D: **24/35 candidates (69%) across all probes were single-atom, and most fell in the 3–15s sweet spot.** Single-atom candidates worked because `semantic_segment.rb` already does the hard work of creating semantically meaningful units.

The implication is that the segmenter produces atoms that are approximately candidate-sized. The multi-atom merging step exists to catch cases where the segmenter split too aggressively — but on real material, it more often merges things that should stay separate.

This suggests a design inversion: **the default should be "one atom = one candidate"** with merging as the exception rather than the rule.

### Whether candidate should sometimes simply equal atom

Yes. For the majority of real material, `candidate = atom` is the correct answer. The probes demonstrate this:

- low_energy: 6/6 candidates are single-atom (perfect)
- emphatic_rant: 5/6 candidates are single-atom (the multi-atom is arguably correct)
- dead_air: 4/5 candidates are single-atom
- pause_heavy: 4/6 candidates are single-atom

The only cases where multi-atom candidates are genuinely useful are when two atoms form a tight rhetorical pair (setup + punchline, question + answer) delivered in the same breath with identical delivery style. These are rare in the probes.

---

## Strategy 1: Gap + Prosody Transition Boundary

### Signal

Inter-segment gap combined with prosody feature discontinuity at each segment junction.

### Concept

Replace the single-threshold check with a multi-signal boundary decision. At each segment junction, evaluate:

```
should_split = (gap > GAP_HARD_SPLIT)
            OR (gap > GAP_SOFT_SPLIT AND profile_changed)
            OR (gap > GAP_SOFT_SPLIT AND energy_discontinuity > ENERGY_THRESHOLD)
```

Example thresholds:
- `GAP_HARD_SPLIT = 0.8s` — always split regardless of other signals
- `GAP_SOFT_SPLIT = 0.15s` — split if reinforced by prosody change
- `ENERGY_THRESHOLD = 0.4` — normalized energy discontinuity

### Failure pattern targeted

**F1 (monster candidates) and F5 (semantic shifts invisible to contiguity).** In the explainer probe, 5 of 8 profile transitions within the monster candidate would trigger splits at the soft threshold. The emphatic→casual transition at gap=0.02s (seg_036→037) would split because profile changed AND gap > 0.15s? No, gap = 0.02s < 0.15s, so this particular one would still merge. But the casual→emphatic at gap=0.44s (seg_041→042) would split.

### Determinism

Fully deterministic. All inputs (gap, audio_profile, audio_energy) are Phase A fields from segments_classified.yaml.

### Rapid speech handling

Moderate improvement. Profile transitions within rapid speech create split opportunities at the soft threshold. However, profile can be stable across topic changes (the explainer has 3 consecutive casual segments with different topics), so not all semantic boundaries are caught.

### Reflective speech handling

Good. GAP_HARD_SPLIT=0.8s would split all reflective speech (minimum gap 2.6s). No change from current behavior.

### Avoids merging semantic shifts?

Partially. Catches shifts that coincide with prosody changes. Misses shifts that happen within the same delivery style (e.g., listing criteria → giving examples, both in casual profile).

### Impact on existing fixture tests

**Moderate.** The session6 synthetic fixture has seg_004(casual)→seg_005(building) with gap=0.40s. Under this strategy: gap=0.40 > GAP_SOFT_SPLIT=0.15 AND profile changes (casual→building) → would SPLIT. The current test expects a merge. Test `creates a multi-atom candidate for contiguous same-source segments` would fail. The golden output fixtures would need regeneration.

### New tests needed

- Test that profile change + gap above soft threshold creates split
- Test that same profile + gap below hard threshold creates merge
- Test that gap above hard threshold always splits regardless of profile
- Test with a sequence of rapid segments where only some have profile transitions

### Overfitting risk

**Moderate.** Three thresholds to tune against 6 probes. The profile change signal is binary and well-defined, reducing tuning surface. The main risk is that GAP_SOFT_SPLIT and ENERGY_THRESHOLD values might be overfit to Dylan's speaking patterns.

---

## Strategy 2: Rhetorical Marker Boundary

### Signal

Text-based discourse markers at segment transitions. Detects sentence-initial phrases that signal topic shifts, rhetorical pivots, or structural changes.

### Concept

Classify the opening words of each segment into boundary strength categories:

**Strong break markers** (nearly always signal a new editorial beat):
- "Here's how", "Here's what", "Here's the thing"
- "So let me", "Let me", "Now let me"
- "OK so", "OK.", "Alright"
- "The problem is", "The thing is", "The reality is"
- "Number one", "First", "Second" (enumeration)

**Moderate break markers** (signal a shift if combined with other evidence):
- "So" (sentence-initial)
- "Now" (sentence-initial)
- "And the" + noun (new subject introduction)
- "But" (sentence-initial, contrastive)

**Continuation markers** (suggest keeping with previous atom):
- "that", "which", "because", "since" (subordinate clause)
- Pronoun reference without new subject ("He then", "She said", "It was")
- Sentence fragments without verbs

Split if: next segment starts with a strong break marker, OR (next segment starts with moderate break marker AND gap > GAP_SOFT_SPLIT).

### Failure pattern targeted

**F5 (semantic boundaries invisible to contiguity).** This directly addresses the hardest failure mode. In the explainer monster, the following segment starts would trigger splits:
- seg_036: "Here's how I evaluate" → strong break
- seg_037: "Now six things" → strong break
- seg_038: "These matter differently" → moderate break
- seg_042: "And most people" → moderate break
- seg_046: "So let me walk you through" → strong break

This would split the 11-atom monster into approximately 5–6 candidates — close to what a human editor would produce.

### Determinism

Fully deterministic. Text is a Phase A field. Marker classification is a static lookup. No LLM required.

### Rapid speech handling

**Best of all strategies.** Discourse markers are present regardless of gap size. Even when the speaker delivers five ideas in 30 seconds with 0.1s between sentences, the text still contains "Here's how," "Now six things," "So let me" — these markers are intrinsic to the content, not dependent on delivery speed.

### Reflective speech handling

No change. Reflective speech already splits on gap. Markers would reinforce existing splits at worst (redundant, not harmful).

### Avoids merging semantic shifts?

**Best of all strategies.** Directly detects topic/rhetorical shifts via linguistic cues. This is the only strategy that can distinguish "I evaluate any business model" (new topic) from "startup costs, how long it takes" (continuation of list) based on content rather than delivery.

### Impact on existing fixture tests

**Moderate.** The session6 fixture has seg_005 starting with "Then we marked where each support beam would go." — "Then" is a continuation marker (temporal sequence), so this would NOT trigger a split. The seg_004+005 merge would be preserved. However, the golden output might still change if other aspects of the strategy shift behavior.

### New tests needed

- Test with strong break marker at segment start → forces split regardless of gap
- Test with continuation marker → preserves merge despite small gap
- Test with moderate marker + large gap → splits
- Test with moderate marker + tiny gap → preserves merge
- Test with marker at sentence start vs. mid-text (only sentence-initial counts)

### Overfitting risk

**High.** The marker list is derived from Dylan's speaking patterns in 6 probes. Different speakers use different discourse patterns. An interview subject might say "Well, I think..." as a continuation. A podcast host might use "So" to continue rather than break. The marker list would need validation across multiple speakers and styles.

**Mitigation:** Keep the marker list short and conservative. Only include markers that are universally strong breaks (enumeration, "here's how," "let me"). Treat everything else as continuation-by-default.

---

## Strategy 3: Atom-Default with Affirmative Merge

### Signal

The atom itself. Every atom starts as its own candidate. Merging requires affirmative evidence.

### Concept

Invert the current logic entirely. Instead of "merge unless gap is large," use "keep separate unless merge evidence is strong."

**Merge conditions (ALL must hold):**
1. Same source
2. Gap < `MERGE_GAP_MAX` (e.g., 0.5s) — tighter than current 1.0s
3. Same `audio_profile`
4. Combined duration ≤ `MERGE_DURATION_MAX` (e.g., 20s)
5. No strong break marker at start of next segment (if Strategy 2 is combined)

If any condition fails, the atoms remain separate candidates.

The key insight: **a split that an editor can undo (by placing adjacent candidates next to each other on the timeline) is less harmful than a merge that an editor can't split** (forced to use the entire 45s block or nothing).

### Failure pattern targeted

**F1 (monster candidates).** Prevents monsters by construction. With condition 3 (same profile), the explainer monster can't form: seg_036(emphatic)→037(casual) differ in profile → split. Even without the profile check, condition 2 (gap < 0.5s) would only allow some merges, and condition 4 (duration cap) provides a safety net.

**F5 (semantic shifts).** The profile requirement catches delivery-style shifts. This won't catch all semantic shifts (two casual segments about different topics would still merge if gap < 0.5s), but it catches the majority observed in probes.

### Determinism

Fully deterministic. All conditions use Phase A fields.

### Rapid speech handling

**Good.** In the explainer probe:
- seg_036(emphatic)→037(casual): profile differs → SPLIT
- seg_037(casual)→038(landing): profile differs → SPLIT
- seg_038(landing)→039(casual): profile differs → SPLIT
- seg_039(casual)→040(casual): same profile, gap=0.36s → MERGE candidate
- seg_040(casual)→041(casual): same profile, gap=0.14s → extends merge
- seg_041(casual)→042(emphatic): profile differs → SPLIT
- etc.

Result: the 11-atom monster would become approximately 7-8 candidates instead of 1. Not as fine-grained as Strategy 2, but a massive improvement.

### Reflective speech handling

**No change.** All reflective speech gaps exceed any reasonable MERGE_GAP_MAX. Every atom remains its own candidate.

### Avoids merging semantic shifts?

**Partially.** Catches shifts accompanied by delivery changes. Misses shifts within same-profile runs. The seg_039→040→041 casual run would merge despite containing different ideas ("if you've got a job" → "if you've got no job" → "you have to know which matters").

### Impact on existing fixture tests

**High.** The session6 fixture seg_004(casual)→seg_005(building) would SPLIT under condition 3 (profiles differ: casual vs building). These tests would need updating:

- `creates a multi-atom candidate for contiguous same-source segments` → would need new fixture data where profiles match
- `creates 4 candidates from 5 segments` → would become 5 candidates from 5 segments
- `computes correct t and e for multi-atom candidates` → needs new multi-atom example
- `concatenates text for multi-atom candidates` → needs new example
- `generates tighter_end for multi-atom candidate with trailing silence` → needs new example
- `aggregates prosody across atoms for multi-atom candidate` → needs new example
- Golden output fixtures → full regeneration

The test fixture would need to include a pair of segments that DO meet all merge conditions (same profile, small gap, etc.) to preserve multi-atom coverage.

### New tests needed

- Test that same-source + same-profile + small-gap atoms merge
- Test that different-profile atoms stay separate regardless of gap
- Test that gap > MERGE_GAP_MAX prevents merge regardless of profile match
- Test that combined duration > MERGE_DURATION_MAX prevents merge
- Test on explainer_rapid probe: produces significantly more candidates than current
- Test on low_energy probe: identical output to current (all single-atom)
- Test on emphatic_rant probe: same or more single-atom candidates

### Overfitting risk

**Low.** The strategy uses a simple, principled default (atoms = candidates) with narrow merge conditions. The merge conditions are conservative — they require multiple signals to agree before merging. With only 2 thresholds (MERGE_GAP_MAX, MERGE_DURATION_MAX) and 1 categorical check (same profile), the tuning surface is small.

---

## Strategy 4: Hybrid Boundary Score Model

### Signal

Weighted combination of gap, prosody transition, text cues, and accumulated duration.

### Concept

At each segment junction, compute a continuous split score:

```
gap_signal        = clamp(gap / GAP_REFERENCE, 0, 1)
profile_signal    = profile_a != profile_b ? 1.0 : 0.0
energy_signal     = clamp(|energy_a - energy_b| / ENERGY_RANGE, 0, 1)
marker_signal     = discourse_marker_strength(next_segment_text)  # 0.0, 0.5, 1.0
duration_signal   = clamp(accumulated_duration / DURATION_SOFT_CAP, 0, 1)

split_score = w_gap * gap_signal
            + w_profile * profile_signal
            + w_energy * energy_signal
            + w_marker * marker_signal
            + w_duration * duration_signal
```

Split if `split_score > SPLIT_THRESHOLD`.

Example weights: `w_gap=0.3, w_profile=0.25, w_energy=0.1, w_marker=0.25, w_duration=0.1`

The duration signal acts as soft pressure — it doesn't force a split at any fixed duration, but it makes splitting increasingly likely as a candidate grows. At 15s accumulated, the duration signal contributes 1.0 (maximum pressure). Combined with even a small gap or profile change, the total score would exceed the threshold.

### Failure pattern targeted

**All failure patterns.** The hybrid score addresses F1 (duration pressure prevents monsters), F5 (marker and profile signals detect semantic shifts), and adapts to all speech styles via the weighted combination.

### Determinism

Fully deterministic. All inputs are Phase A fields or text-derived markers.

### Rapid speech handling

**Good.** Even when gap_signal is near zero (0.1s gap), profile_signal (0.25) + marker_signal (0.25 for moderate marker) can push the score above threshold. In the explainer probe, the combination of profile transitions and discourse markers would split the monster at most editorial boundaries.

### Reflective speech handling

**Good.** Large gaps produce high gap_signal alone, ensuring splits regardless of other factors. The same behavior as current but with added reinforcement from other signals.

### Avoids merging semantic shifts?

**Best theoretical coverage.** The marker signal catches text-level shifts, profile signal catches delivery shifts, and duration pressure provides a safety net. However, the interaction between 5 weights makes it hard to predict edge cases.

### Impact on existing fixture tests

**High.** Same impact as Strategy 3 — depends on whether the net score exceeds threshold for the seg_004→005 junction. With the example weights: gap_signal=0.8/0.5=0.53, profile_signal=1.0 (casual→building), marker_signal≈0 ("Then" is continuation), duration_signal=5.2/15≈0.35. Score = 0.3(0.53) + 0.25(1.0) + 0.1(0) + 0.25(0) + 0.1(0.35) = 0.16 + 0.25 + 0 + 0 + 0.035 = 0.445. If SPLIT_THRESHOLD=0.4, this splits. If 0.5, it doesn't. The outcome depends heavily on weight tuning.

### New tests needed

All tests from Strategy 3, plus:
- Test that score decomposition is accessible for debugging
- Test boundary cases around the threshold
- Test that weights produce expected results on each probe
- Test that duration pressure alone doesn't override strong continuation signals

### Overfitting risk

**High.** Five weights and a threshold to tune against 6 probes (35 candidates). The weight space has enough degrees of freedom to perfectly fit the probe data while failing on unseen content. The interaction between weights creates emergent behaviors that are hard to predict. Debugging "why did this split here?" requires understanding the score decomposition.

**This strategy should be deferred until there are 20+ probes across 5+ speakers and content types.** The current evidence base is insufficient to calibrate it reliably.

---

## Strategy Comparison

| Criterion | Gap+Prosody | Rhetorical Marker | Atom-Default | Hybrid Score |
|---|---|---|---|---|
| Complexity | Medium | Medium | **Low** | High |
| Rapid speech | Moderate | **Best** | Good | Good |
| Reflective speech | Good | Good | **Good** | Good |
| Semantic shift detection | Partial | **Best** | Partial | Good (theoretical) |
| Determinism | Yes | Yes | Yes | Yes |
| Test impact | Moderate | Moderate | High | High |
| Overfitting risk | Moderate | **High** | **Low** | **High** |
| Tuning parameters | 3 | 0 (marker list) | 2 | 6 |
| Debuggability | Good | **Best** | **Best** | Poor |
| Implementation effort | Low | Medium | Low | High |

---

## Recommended Path

### Phase 1 (Session 6F): Implement Strategy 3 — Atom-Default with Affirmative Merge

**Rationale:**
- Exploits the strongest probe finding: single-atom candidates are right-sized 69% of the time
- Lowest overfitting risk — the strategy is principled, not data-fit
- Simplest to implement, test, and debug
- Creates the right default: arrangement can always place adjacent candidates together, but can't split a merged monster
- Only 2 numerical thresholds (MERGE_GAP_MAX, MERGE_DURATION_MAX) plus 1 categorical check (same profile)

**Threshold status:** The proposed MERGE_DURATION_MAX of 20s is a provisional hypothesis, not a locked product rule. It exists solely as a testable starting point for Session 6F. Session 6F must evaluate whether 20s generalizes across all probes before treating it as a default — it may need to move up or down based on what the probes reveal.

**Concrete implementation plan:**

1. Replace the contiguity grouping loop (lines 192–207 of candidate_builder.rb) with atom-default logic:
   - Start with every segment as its own candidate
   - Walk segment pairs: merge only if same source, same profile, gap < 0.5s, and combined duration ≤ 20s

2. Update the session6 synthetic fixture:
   - Modify seg_004 and seg_005 to have the same audio_profile (both `casual` or both `building`) so the merge test still works
   - OR: Accept that they separate and test the new behavior (5 candidates from 5 segments)
   - Regenerate golden output files

3. Add new tests for the merge conditions:
   - Same profile + small gap → merge
   - Different profile + small gap → split
   - Same profile + large gap → split
   - Duration cap enforcement

4. Re-run all 6 probes and compare candidate counts/quality against Session 6D baseline

**Expected results on existing probes:**

| Probe | Current cands | Expected cands (approx) | Change |
|---|---|---|---|
| real_probe | 3 | 6–7 | Massive improvement |
| emphatic_rant | 6 | 6–7 | Minimal change |
| low_energy | 6 | 6 | No change |
| pause_heavy | 6 | 7–8 | Slight improvement |
| dead_air | 5 | 5–6 | Minimal change |
| explainer_rapid | 4 | 8–12 | Major improvement |

### Phase 2 (Session 6G or later): Evaluate Strategy 2 — Rhetorical Markers as Enhancement

After the atom-default baseline is established and validated on more probes, add rhetorical marker detection as an additional split signal. This would handle the remaining failure cases where same-profile segments about different topics merge (e.g., explainer seg_039→040→041 casual run).

**Defer because:** The marker list needs validation across multiple speakers. The atom-default strategy already solves the worst failure (F1: monsters). Strategy 2 adds refinement, not a fundamental fix.

### Defer: Strategy 1 (Gap+Prosody) and Strategy 4 (Hybrid Score)

- **Strategy 1** is a half-measure. If we're changing the grouper, atom-default is simpler and more principled than adjusting thresholds.
- **Strategy 4** requires more data to calibrate. Return to it only if Strategies 3+2 prove insufficient after 20+ probes.

### Also defer: Trim redesign and defect exclusions

Session 6D identified two other major gaps (F2: dead trims, F3: no defect exclusions). These should be addressed in separate sessions after the boundary strategy is settled. The boundary strategy is the foundation — trims and exclusions are refinements that depend on candidates being the right size first.

---

## Success Criteria for Session 6F

### Must pass

1. All existing Phase C validation passes on all probes
2. The explainer_rapid probe produces ≥ 8 candidates (currently: 4)
3. No candidate exceeds 30s on any probe (currently: 48.4s and 44.7s)
4. The low_energy probe produces exactly 6 candidates (unchanged — no regression)
5. The emphatic_rant probe preserves candidates of quality "good" or better (cand_003 "trouble at work" stays intact)
6. 74 existing spec examples pass (with updated fixtures as needed)
7. New specs cover all four merge conditions (source, profile, gap, duration)

### Should pass

8. The real_probe produces ≥ 5 candidates (currently: 3)
9. Average candidate duration across all probes decreases from current 12.1s toward 5–10s
10. The dead_air probe's seg_001+002 merge is broken (different profiles: landing vs casual)

### Informational (observe but don't gate on)

11. Whether the total candidate count increase causes meaningful Phase B token cost increase
12. Whether any new single-atom candidates are too short to be useful (<2s)
13. How cluster detection behavior changes with more, smaller candidates
