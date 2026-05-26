# Session 6F — Boundary Heuristic v2 Results

## Summary

Implemented the atom-default boundary heuristic in `candidate_builder.rb`.
The v2 grouper replaces the simple gap-based merge with a multi-signal
approach: each segment starts as its own candidate and merges only when
positive evidence supports it.

**Result: monster candidates eliminated. 94 tests pass (74 existing + 20 new).**

---

## Design Decisions

### Grouper Architecture

The v1 grouper merged all adjacent same-source segments within `CONTIGUITY_GAP_S`
(1.0s). This created monster candidates in rapid speech (44.7s, 11 atoms).

The v2 grouper uses a two-tier approach:

1. **Hard splits** — always break the chain:
   - Source change
   - Gap > `CONTIGUITY_GAP_S` (1.0s)
   - Strong rhetorical marker at next atom start
   - VAD pause >= `LONG_PAUSE_THRESHOLD_MS` (1500ms) in gap

2. **Merge signals** — require >= `MERGE_SIGNAL_THRESHOLD` (2 of 4):
   - Prosody compatibility (same profile or compatible pair)
   - Sentence continuation (prev doesn't end sentence, or next starts lowercase)
   - Lexical overlap (shared content words after stop-word removal)
   - Pause continuity (no VAD pause >= `VAD_PAUSE_SOFT_MS` 700ms in gap)

### Signal Count: 4, Not 5

The 6E proposal listed 5 merge signals including "no rhetorical boundary marker."
Since strong markers already trigger a hard split, this signal is trivially TRUE
for every pair that reaches merge evaluation — making the threshold effectively
1-of-4 instead of 2-of-5. To maintain meaningful selectivity, the implementation
uses 4 substantive signals with threshold 2.

### Strong Boundary Markers

```
Words:   but, however, so, now, another, second, third, finally, here's
Phrases: "the problem is", "the point is", "that said"
```

These mark discourse boundaries where a speaker shifts topic or rhetorical frame.

### Compatible Profile Pairs

```
casual    <-> building       (warming up)
building  <-> emphatic       (escalating energy)
reflective <-> casual        (low-energy variants)
landing   <-> reflective     (winding down)
authoritative <-> emphatic   (strong delivery)
urgent    <-> emphatic       (high-energy variants)
```

Profile pairs NOT in this list (e.g., emphatic <-> casual, emphatic <-> reflective)
are treated as editorial boundaries — incompatible delivery shifts.

---

## Before/After Comparison

### v1 Baseline (Session 6D)

| Probe | Segs | Cands | Max dur | Avg dur | Multi-atom |
|-------|------|-------|---------|---------|------------|
| real_probe | 8 | 3 | 48.4s | 24.0s | 2 |
| emphatic_rant | 7 | 6 | 22.9s | 10.4s | 1 |
| low_energy_reflective | 6 | 6 | 14.1s | 7.0s | 0 |
| pause_heavy_transition | 8 | 6 | 24.8s | 14.8s | 2 |
| dead_air_setup | 6 | 5 | 9.1s | 2.6s | 1 |
| explainer_rapid | 17 | 4 | 44.7s | 13.9s | 2 |

### v2 Results

| Probe | Segs | Cands | Max dur | Avg dur | Multi-atom |
|-------|------|-------|---------|---------|------------|
| real_probe | 8 | 6 | 25.4s | 11.8s | 2 |
| emphatic_rant | 7 | 7 | 22.9s | 8.9s | 0 |
| low_energy_reflective | 6 | 6 | 14.1s | 7.0s | 0 |
| pause_heavy_transition | 8 | 7 | 24.8s | 12.7s | 1 |
| dead_air_setup | 6 | 5 | 9.1s | 2.6s | 1 |
| explainer_rapid | 17 | 13 | 10.9s | 4.1s | 3 |

### Delta Summary

| Probe | Cands delta | Max dur delta | Avg dur delta |
|-------|-------------|---------------|---------------|
| real_probe | +3 (3->6) | -47% (48.4->25.4s) | -51% |
| emphatic_rant | +1 (6->7) | unchanged | -14% |
| low_energy_reflective | unchanged | unchanged | unchanged |
| pause_heavy_transition | +1 (6->7) | unchanged | -14% |
| dead_air_setup | unchanged | unchanged | unchanged |
| explainer_rapid | +9 (4->13) | -76% (44.7->10.9s) | -70% |

**Key results:**
- Monster candidates eliminated: 44.7s -> 10.9s (explainer), 48.4s -> 25.4s (real)
- Candidate count increased where needed: +9 for rapid speech, +3 for real material
- No regressions: low-energy and dead-air probes unchanged (already well-segmented)
- Conservative behavior: reflective/low-energy speech NOT over-split

---

## Explainer Rapid: Detailed Breakdown

The worst-case probe (17 segments, rapid educational speech) went from 4 candidates
to 13 candidates. Here's what the v2 heuristic did:

| v2 Candidate | Segments | Duration | Why grouped |
|--------------|----------|----------|-------------|
| cand_001 | seg_036 | 1.9s | Standalone (seg_037 starts with "Now") |
| cand_002 | seg_037 | 8.6s | Standalone (no merge signals with neighbors) |
| cand_003 | seg_038 | 2.5s | Standalone (seg_039 starts with "So") |
| cand_004 | seg_039+040 | 9.4s | Prosody match (casual/casual) + lexical overlap |
| cand_005 | seg_041 | 4.1s | Standalone (seg_041 starts with "So" — hard split before) |
| cand_006 | seg_042 | 1.6s | Standalone (emphatic != casual — profile incompatible) |
| cand_007 | seg_043+044+045 | 10.9s | Prosody match (casual/casual) + pause continuity |
| cand_008 | seg_046 | 4.0s | Standalone (starts with "So" + gap > 1s after) |
| cand_009 | seg_047 | 2.4s | Standalone (gap > 1s both sides) |
| cand_010 | seg_048 | 0.9s | Standalone (gap > 1s both sides) |
| cand_011 | seg_049 | 1.7s | Standalone (seg_050 starts with "So") |
| cand_012 | seg_050 | 0.8s | Standalone (building != landing — incompatible) |
| cand_013 | seg_051+052 | 4.7s | Prosody match (landing/landing) + pause continuity |

The v2 heuristic correctly identifies discourse boundaries ("So", "Now", "Here's")
and delivery shifts (casual->emphatic, building->landing) while still merging
naturally flowing content (same-profile segments with shared vocabulary).

---

## Test Coverage

### Existing Tests (74 — all pass unchanged)
- Synthetic fixture produces identical 4-candidate output
- Golden output matches byte-for-byte (no regression)
- Phase A/B/C validation, determinism, ID uniqueness
- Real probe Phase ABC pass

### New Tests (20)
- **Monster reduction**: max duration < 15s for explainer_rapid
- **Candidate count**: more candidates than v1 baseline for rapid speech
- **Single-atom prevalence**: majority of rapid-speech candidates are single-atom
- **Hard split markers**: "So", "Now", "Here's" segments start new candidates
- **Reflective not over-split**: low-energy probe unchanged at 6 candidates
- **Profile incompatibility**: emphatic_rant all single-atom (profile shifts block merge)
- **Pause-heavy**: at least as many candidates as v1
- **Dead air**: passes Phase ABC
- **Determinism**: byte-identical output on consecutive runs for rapid probe

---

## Constants Added

| Constant | Value | Purpose |
|----------|-------|---------|
| `MERGE_SIGNAL_THRESHOLD` | 2 | Minimum continuity signals for merge |
| `VAD_PAUSE_SOFT_MS` | 700 | Soft pause threshold for merge signal |
| `STRONG_BOUNDARY_MARKERS` | 9 words | Discourse markers that force hard split |
| `STRONG_BOUNDARY_PHRASES` | 3 phrases | Multi-word markers that force hard split |
| `COMPATIBLE_PROFILES` | 6 pairs | Profile pairs allowed to merge |

---

## Open Questions for Future Sessions

1. **25.4s real_probe candidate**: The largest v2 candidate is 2 segments / 25.4s.
   This is a single long segment (15.5s) + another (9.9s) that share prosody and
   pause continuity. A safety-net duration cap could catch this, but it's not
   unreasonable for a real editorial clip.

2. **MERGE_DURATION_MAX**: The 6E proposal's provisional 20s cap was NOT implemented.
   The multi-signal approach alone reduced max duration sufficiently. If future
   probes reveal edge cases, a duration cap remains available as a safety net.

3. **Weak boundary markers**: Currently only strong markers trigger hard splits.
   Words like "then", "next", "ok", "basically" are neutral — they don't block
   merging but don't encourage it either. A future iteration could score these
   as negative merge signals.

---

## Files Modified

- `scripts/candidate_builder.rb` — v2 grouper (lines 25-43 constants, 118-166
  helpers, 207-236 grouper)
- `spec/scripts/candidate_builder_spec.rb` — 20 new v2 tests (lines 729-860)

## Files NOT Modified (locked)

- `docs/schemas/editorial_candidate.schema.yaml` — schema v1.2 unchanged
- `spec/fixtures/session6/expected_candidate_substrate.yaml` — golden output identical
- `spec/fixtures/session6/expected_editorial_candidates.yaml` — golden output identical
