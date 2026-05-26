# Session 6C — Real-Material Probe Report

**Date:** 2026-05-26
**Source:** `dylan-shorts-batch-1` / `MVI_5119.MP4`
**Window:** seg_253–seg_263 (t=863.2..1015.02), 8 atoms, 70.4s spoken
**Command:** `ruby scripts/candidate_builder.rb --fixture spec/fixtures/session6_real_probe --phase abc`
**Result:** Exit 2 (Phase C taxonomy violation)

---

## Counts

| Metric | Value |
|--------|-------|
| Input segments | 8 |
| Candidates produced | 3 |
| Multi-atom candidates | 2 (cand_001: 5 atoms, cand_002: 2 atoms) |
| Single-atom candidates | 1 (cand_003) |
| Exclusions generated | 1 (ex_001: 1508ms pause in cand_001) |
| Clusters detected | 0 |
| Trim choices total | 3 (all full_clean only) |
| Phase C errors | 2 taxonomy (invalid pitch_trend `flat`) |
| Phase C warnings | 0 |

---

## Phase C Errors

```
PHASE C TAXONOMY ERRORS (2):
  cand_001: invalid pitch_trend 'flat'
  cand_003: invalid pitch_trend 'flat'
```

**Root cause:** `merge_prosody.rb` (or `audio_emotion.rb`) produces `audio_pitch_trend: flat`. The schema enum is `[rising, falling, level, varied]`. No `flat` value exists. This affects 243 of 370 segments (66%) in dylan-shorts-batch-1. Hard blocker for any real pipeline run through candidate_builder.

**Fix options:**
1. Map `flat` → `level` in candidate_builder Phase A prosody aggregation
2. Fix upstream (merge_prosody) to produce `level` instead of `flat`
3. Amend schema to add `flat` to the enum

Option 2 is correct — fix the source. Option 1 is a workaround. Option 3 changes the locked schema without clear reason.

---

## 3 Best Candidates (by editorial usefulness)

1. **cand_002** (seg_259–260, 14.2s) — "So when someone asks me what I actually do, the honest answer is I sell services." Clean self-contained claim about business model. Plausible hook/claim material. Good duration for a segment. No defects, no exclusions.

2. **cand_003** (seg_263, 9.4s) — "That takes time. That takes effort. And there's that unknown factor..." Emotional beat about difficulty of entrepreneurship. Good transition/payoff material. Has stumble_count=1 → correctly flagged `marginal` by mock Phase B.

3. **cand_001** is the only remaining candidate but is problematic (see below).

---

## 3 Worst Candidates / Failure Modes

1. **cand_001** (seg_253–257, 48.4s) — Spans 5 atoms and 48.4 seconds. This is an entire argument, not a cuttable editorial moment. Contains multiple distinct ideas: freelancing realization, income math, company comparison, AI age commentary. A 48s candidate is unusable for sequence building — arrangement can't select a portion, only the whole thing. **This is the most critical failure mode: contiguity grouping creates monster candidates from real material.**

2. **All candidates: only full_clean trims.** No tighter_start, tighter_end, both_tighter, or minimal_trim generated for any candidate. The trim heuristic is systematically broken on real data (see analysis below).

3. **cand_003: no defect exclusion despite stumble.** seg_263 has `stumble_count: 1` but produces zero exclusion_choices. The code has no defect-exclusion generation path — only pacing exclusions from VAD long_pauses.

---

## Candidate Span Assessment

| Candidate | Duration | Assessment |
|-----------|----------|------------|
| cand_001 | 48.4s | **Too large.** Should be 3-4 separate candidates. |
| cand_002 | 14.2s | Plausible. Two related sentences. |
| cand_003 | 9.4s | Good. Single atomic editorial moment. |

The contiguity threshold (`CONTIGUITY_GAP_S = 1.0`) is too aggressive for real speech. In talking-head footage, gaps between sentences are typically 0.2–0.6s, so almost all consecutive same-source segments chain together. On this 8-segment sample, 5 segments merged into one candidate.

---

## Weakest Phase A Heuristic: Trim Generation

**Systematic failure.** Zero non-full_clean trims generated across all 3 candidates.

**Why:** Segments were derived from the same transcript by `semantic_segment.rb`, so word boundaries align tightly with segment boundaries. The trim heuristic assumes slack between word onset and segment start:

```
tighter_in = first_word_start - BREATHING_MARGIN (80ms)
condition: tighter_in > t + BOUNDARY_TOLERANCE (20ms)
```

On real data: `first_word_start ≈ t + 1ms`, so `tighter_in ≈ t - 79ms` → condition fails.
Same for tighter_end: `last_word_end ≈ e - 3ms`, so `tighter_out ≈ e + 77ms` → condition fails.

**This means every real candidate will have exactly one trim choice (full_clean).** The entire trim_choices mechanism — a core schema feature — is dead code on real material. Arrangement has no trim options to choose from.

**Fix direction:** Trim choices should compute sub-candidate trims within multi-atom candidates (e.g., trim to first N atoms, or trim around exclusion boundaries), not just tighten word-level margins.

---

## Additional Findings

### Domain mismatch: speech_analysis.json
The `ZOOM0019_speech_analysis.json` timestamps are in WAV domain. `segments_classified.yaml` and `cleaned_transcript.json` are in video domain. The fixture required manual domain conversion (offset -10.246188). In production, candidate_builder would fail to match any pauses to candidates because the domains don't align.

### Exclusion gap: no defect-type exclusions
The spec defines two exclusion types: `defect` (stumbles, false starts, abandonment) and `pacing` (long pauses, trailing off). Only `pacing` from VAD long_pauses is implemented. No code path exists to generate `defect` exclusions from `stumble_count`, `acoustic_pattern`, or other segment fields.

### Mock labeling monotony
All 3 candidates received identical mock labels: state=`amusement`, priority=`secondary`, role=`aside`. This is because all segments have `audio_profile: casual` and `energy: medium`. The mock heuristic can't distinguish between a 48s argument and a 9s emotional beat. Expected for a mock, but highlights that real LLM labeling is essential for editorial quality.

---

## Summary

The probe revealed 5 issues, ordered by severity:

1. **`flat` pitch_trend not in schema** — Phase C hard blocks. **Fixed:** added `flat` to schema enum and validator (Session 6C-fix).
2. **Trim heuristic produces only full_clean** — Dead feature on real material. Needs redesign.
3. **Contiguity grouping too aggressive** — Creates 48s monster candidates. See resolution below.
4. **No defect exclusion generation** — stumble_count tracked but never used for exclusions.
5. **Speech analysis domain mismatch** — WAV vs video domain. Needs conversion in candidate_builder or upstream.

Issues 2, 3, and 4 are Phase A design gaps that would produce structurally valid but editorially useless candidates on real footage.

---

## Resolution: Candidate Span Sizing

Candidate span sizing is unresolved. The 48.4s candidate is a real failure mode, but imposing a fixed duration/atom cap is premature. Next step should be to collect 3–5 real probes across different recording types and derive candidate-boundary heuristics from observed failure patterns.
