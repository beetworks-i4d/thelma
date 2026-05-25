# Main-Branch Architectural Audit

**Date:** 2026-05-25
**Comparison:** `main` branch (v3.1-multisource tag) vs `dev` branch (Session 5 atom architecture)
**Purpose:** Forensic mapping of what existed in main, what's gone in dev, and what should be ported forward to restore v3.1 editorial intelligence on the Session 5 atom architecture.

---

## 1. Script Inventory — main branch

35 scripts, 12,252 total lines of Ruby.

| # | Script | Lines | Purpose |
|---|--------|-------|---------|
| 1 | `001_migrate_0.2_to_0.3.rb` | 90 | Migration: full transcript paths → filenames in library.yaml |
| 2 | `arrange.rb` | 517 | Phase 3 — Arrangement: semantic understanding → proposed cut |
| 3 | `audio_analysis.rb` | 84 | Silero VAD speech analysis with caching |
| 4 | `audio_cleanup.rb` | 62 | FFmpeg audio extraction + noise reduction + loudness normalization |
| 5 | `audio_emotion.rb` | 98 | Vocal emotion features via librosa (Python) |
| 6 | `audio_sync_offset.rb` | 147 | FFT cross-correlation sync between video scratch and external audio |
| 7 | `branch_a_batch.rb` | 637 | Batch Branch A: sequential forward-only hook discovery |
| 8 | `build_structure_cut.rb` | 1597 | Core XML builder — FCPXML or xmeml from YAML definition |
| 9 | `detect_content_type.rb` | 469 | Phase 0 — Content type detection and routing |
| 10 | `detect_scenes.rb` | 179 | FFmpeg scene change detection (zero token cost) |
| 11 | `detect_structure.rb` | 264 | Phase 1.9.4 — Adaptive structure detection when templates don't fit |
| 12 | `discover_storylines.rb` | 447 | Phase 1.6 — Cluster segments into ranked storyline candidates |
| 13 | `export_arrangement_xml.rb` | 231 | Exports arrangement.yaml to Premiere XML |
| 14 | `export_packaging_brief.rb` | 616 | Packaging handoff document with thumbnail/title direction |
| 15 | `extract_creator_profile.rb` | 248 | Cross-video style fingerprint from accumulated reports |
| 16 | `extract_edit_patterns.rb` | 227 | Aggregate overlay patterns from finished edits |
| 17 | `extract_template.rb` | 519 | Phase 2.1 — Extract reusable narrative templates |
| 18 | `extract_visual_frames.rb` | 203 | One frame per scene change for Claude Vision |
| 19 | `generate_report.rb` | 293 | Phase C — Analysis report from all pipeline outputs |
| 20 | `generate_short_bodies.rb` | 677 | Batch 30-short body-only XML generation |
| 21 | `llm_client.rb` | 200 | Unified LLM interface with provider routing |
| 22 | `load_profile.rb` | 223 | Profile loader (creator YAML + _default merge) |
| 23 | `match_templates.rb` | 230 | Phase 1.7 — Score storylines against narrative templates |
| 24 | `mine_content.rb` | 255 | Content inventory mode — footage assessment without editorial intent |
| 25 | `orchestrate.rb` | 936 | Pipeline orchestrator with inline `classify()` in BEGIN block |
| 26 | `parse_finished_edit.rb` | 228 | Parse Premiere XML to correlate overlays with segments |
| 27 | `parse_script.rb` | 162 | Script file → structured YAML with beats |
| 28 | `read_transcript.rb` | 46 | Debug utility — print transcript segments |
| 29 | `rebuild_clips_from_cleaned.rb` | 134 | Split clips to exclude removed segments |
| 30 | `sanity_check.rb` | 514 | Phase 2.5 — Pre-build review data generation |
| 31 | `score_coherence.rb` | 313 | Phase 1.8 — Algorithmic pre-filter + LLM coherence scoring |
| 32 | `semantic_dedup.rb` | 226 | Phase 1.5b — Detect retakes via distillation overlap |
| 33 | `semantic_ingest.rb` | 489 | Phase 2 — Unified directorial understanding pass |
| 34 | `transcript_cleanup.rb` | 455 | Deterministic transcript cleanup (regex/overlap) |
| 35 | `validate_classification.rb` | 236 | Phase 1.1 — Validate segments against 15-state taxonomy |

**Critical node scripts** (heavily imported): `llm_client.rb` (12+ consumers), `load_profile.rb` (8+ consumers), `build_structure_cut.rb` (4 consumers).

---

## 2. Script Inventory — dev branch

56 scripts, 17,083 total lines (Ruby + 2 Python + 1 Bash).

**New scripts not in main (21):**

| Script | Lines | Purpose |
|--------|-------|---------|
| `arrange_to_script.rb` | 377 | Script-driven arrangement: match beats → picks → arrangement YAML |
| `arrangement_adapter.rb` | 78 | Bridge beats schema → chapters schema for export |
| `audio_analysis.py` | 136 | Python VAD runner (Silero) |
| `audio_emotion.py` | 370 | Python per-segment acoustic features (librosa) |
| `audio_prosody.rb` | 122 | Repackage VAD + transcript → per-word prosody |
| `convert_candidate.rb` | 263 | DEPRECATED — arc candidate → arrangement.yaml |
| `detect_scenes.rb` | 189 | Expanded scene detection (+10 lines over main) |
| `discover_arcs.rb` | 412 | DEPRECATED — pool arc discovery |
| `discovery_pass.rb` | 428 | Phase 2 — Ranked thesis candidates + clip_groups + throughlines |
| `extract_segments.rb` | 169 | Phase 1.4 — Deterministic segment aggregation with global seg_ids |
| `library_resolver.rb` | 43 | Central library directory resolution |
| `match_hq_audio.rb` | 162 | Pool mode: detect HQ audio / video transcript pairs |
| `merge_prosody_segments.rb` | 72 | Aggregate word-level prosody into segment summaries |
| `migrate_library.rb` | 83 | Library path migration + registry |
| `normalize_transcript_domain.rb` | 136 | Video-time → WAV-time transcript conversion |
| `pool_index.rb` | 201 | Pool index lifecycle for Mode D (mining) |
| `present_candidates.rb` | 76 | DEPRECATED — display arc candidate summary |
| `refresh_project_docs.sh` | 265 | Bash: regenerate STATE.md and CLI.md |
| `register_pool_sources.rb` | 141 | Phase D.2.5 — Register pool sources into library.yaml |
| `semantic_segment.rb` | 725 | Phase 1.35 — LLM-powered per-source segmentation |
| `thelmaedit.rb` | 125 | Wrapper: auto-fulfill pending LLM calls via `claude -p` |

**Scripts carried from main (35):** All 35 main scripts exist in dev, though several are marked DEPRECATED: `discover_storylines.rb`, `match_templates.rb`, `score_coherence.rb`, `semantic_ingest.rb`, `transcript_cleanup.rb`, `detect_structure.rb`, `extract_template.rb`, `generate_report.rb`, `sanity_check.rb`.

---

## 3. Profiles — complete contents

### `_default.yaml`

```yaml
name: _default
description: "Base defaults for all content"
content_type: auto
default_arrival_context: algorithmic_feed
closing_durability_preference: identity
format_defaults:
  shorts: { orientation: vertical, target_duration: 30-60 }
  longform: { orientation: horizontal, target_duration: 480-900 }
analysis_depth_default: deep
branch_preference: auto
include_ctas: true
auto_remove_pauses_above: 800
min_segment_duration: 2
snap_end_tolerance_ms: 100          # dev: 300
template_categories: []
strong_threshold: 80
acceptable_threshold: 65
generate_packaging_brief: true
llm_routing:
  semantic_ingest: claude-opus-4-6
  classification: claude-sonnet-4-6
  coherence: claude-opus-4-6
  arrangement: claude-opus-4-6
  loglines: claude-sonnet-4-6
  structure_detection: claude-opus-4-6
  packaging: claude-sonnet-4-6
```

**Delta:** `snap_end_tolerance_ms` is 100 in main, 300 in dev (relaxed for atom architecture).

### `creators/dylan.yaml`

```yaml
name: dylan
content_type: talking_head_business
primary_state_preferences: [vindication, aspiration, competence]
template_categories: [explainer, argumentative]
template_affinities: [three_item_framework, contrarian_argument, comparative_walkthrough]
notes: "Recordings often have hooks/closes first, bodies later in same file.
        Dual-system audio (ZOOM recorder). 1.15x tempo boost in final render."
```

### `creators/ivan.yaml`

```yaml
name: ivan
content_type: talking_head_business
primary_state_preferences: [competence, vindication, curiosity]
template_categories: [argumentative, explainer]
template_affinities: [hidden_truth_reveal, problem_solution, three_item_framework]
tone_profile:
  guide_doc: docs/tone/ivan.md
  compact_guide_doc: docs/tone/ivan_compact.md
  humor_register: [absurdist, dry, crude_ok]
  profanity_limit: one_per_script_after_60s
  tangent_tolerance: moderate
  formality: conversational
  preserve_strongly:
    - specific_concrete_examples_grounding_claims
    - flat_delivery_on_uncomfortable_truths
    - analogies_from_outside_domain
    - signature_phrasings
    - comedic_beats_with_payoff
    - parallel_rhetorical_structures
  cut_preferentially:
    - hedging_qualifiers
    - premature_jargon
    - melodrama_and_grandiosity
    - academic_citations_as_lead
    - self_censored_tangents_without_payoff
    - over_transmission
    - self_deprecation_as_shtick
    - empty_filler_phrases
```

**Both profiles are identical between main and dev.**

---

## 4. Story Structure Templates

7 templates across 3 categories. All present and identical in both branches.

### Argumentative (3)

**`contrarian_argument`** — 5 beats: bold_claim → target_behavior → diagnosis → alternative → proof

**`hidden_truth_reveal`** — 5 beats: conventional_wisdom → challenge → hidden_truth → evidence → reframe

**`problem_solution`** — 5 beats: problem_statement → evidence → solution_reveal → proof → takeaway

### Explainer (2)

**`three_item_framework`** — 6 beats: hook_claim → setup → item_1 → item_2 → item_3 → application

**`comparative_walkthrough`** — 8 beats: hook_claim → backstory_origin → framework_setup → item_evaluation → winner_reveal → deeper_insight → personal_proof → ranking_summary

### Narrative (2)

**`origin_story_lesson`** — 5 beats: personal_context → struggle → discovery → result → universal_principle

**`personal_transformation`** — 5 beats: before_state → turning_point → action → result → lesson

Each template has: `name`, `category`, `description`, and a `beats` array where each beat has `id`, `description`, `keywords` (for text matching), and `position` (early/early_mid/mid/late_mid/late or a float 0.0–1.0).

---

## 5. The 15-State Content Psychopharmacology Taxonomy

Defined in `docs/content_psychopharmacology.md` (361 lines, present in both branches).

| # | State | Viewer Transaction | Durability Class |
|---|-------|--------------------|------------------|
| 1 | Vindication | Unseen/uncertain → confirmed, correct | Identity |
| 2 | Controlled Outrage | Frustration → righteous anger | Mood |
| 3 | Awe / Elevation | Ordinary → expanded, moved | Mood |
| 4 | Competence / Insight | Under-stimulated → sharper, new model | Identity |
| 5 | Controlled Fear | Uneasy → informed, prepared | Spike |
| 6 | Schadenfreude | Inadequate → relieved, superior | Spike |
| 7 | Amusement / Play | Bored → entertained, relaxed | Spike |
| 8 | Catharsis | Emotionally congested → released | Mood |
| 9 | Nostalgia | Dislocated → grounded | Mood |
| 10 | Belonging | Lonely → among one's people | Identity |
| 11 | Escape / Absorption | Aversive → attention displaced | Mood |
| 12 | Calm / Tranquility | Overstimulated → baseline | Mood |
| 13 | Aspiration | Dissatisfied → inhabiting ideal self | Identity |
| 14 | Sensual / Sexual Arousal | Under-stimulated → activated | Spike |
| 15 | Curiosity / Information Gap | Incomplete → resolved | Spike |

**Three independent axes per state:** Induction speed, Context dependence, Signal compressibility.

**Durability tiers (DUR_RANK):** spike=1, mood=2, identity=3.

**Incompatible pairs (cannot be adjacent without tonal break):**
- sensual ↔ calm
- schadenfreude ↔ awe
- outrage ↔ amusement
- belonging ↔ schadenfreude
- calm ↔ fear

**42 files across main reference this taxonomy** (scripts, profiles, templates, docs, specs). In dev, 25+ files reference it, primarily through `validate_classification.rb` which preserves the full `VALID_STATES` array.

---

## 6. `discover_storylines.rb` — Deep Read

**Purpose:** Phase 1.6 — Clusters classified segments into ranked candidate storylines. This is the editorial intelligence layer that decides what story can be told from the raw footage.

**Input:** `segments_classified.yaml`
**Output:** `storylines.yaml`

### Three Expansion Profiles

| Profile | Duration Target | Expansion | Quality Floor |
|---------|----------------|-----------|---------------|
| `best_single_longform` | 480–900s | `:wide` (pick best close first) | 55 |
| `best_short` | 30–90s | `:tight` (nearest close) | 70 |
| `best_medium` | 180–480s | `:balanced` (spine ratio ≥ 0.3) | 65 |

### Expansion Algorithms

**`:tight`** — Picks the nearest compatible tertiary after the hook as close. Fills body between hook and close with secondaries. Prioritizes close proximity.

**`:wide`** — Finds the BEST close first (highest durability, latest position), then fills body between hook and close. Mimics "pick your ending first" behavior.

**`:balanced`** — Accumulates secondaries chronologically, interleaving spine-carrying segments (same `primary_state` as hook) with fill. Stops when: (a) `target_max` exceeded, or (b) within target range AND `spine_ratio >= 0.3`. Then finds close after last body segment.

### 7-Dimension Scoring (100 pts total)

| Dimension | Max | Logic |
|-----------|-----|-------|
| Spine continuity | 20 | `max(hook-state body ratio, body-dominant-state ratio) × 20` |
| Arc completeness | 20 | +8 hook, +4 if body ≥ 3 segments, +8 close |
| State density | 15 | `(classified_time / arc_span) × 15` |
| Cold viability | 15 | Hook durability (identity=15, mood=10, spike=5) + confidence (high=+5, medium=+3) + audio_profile (emphatic=+3, casual=-2), capped at 15 |
| Closing durability | 15 | identity=15, mood=10, spike=5 |
| No broken refs | 5 | All t-values exist in original segment set |
| Structural integrity | 10 | -5 if body segs after close; -2 per incompatible adjacent pair (capped -5) |

### Key Constants

```ruby
INCOMPATIBLE_PAIRS = [
  Set['sensual', 'calm'], Set['schadenfreude', 'awe'],
  Set['outrage', 'amusement'], Set['belonging', 'schadenfreude'],
  Set['calm', 'fear']
]
DUR_RANK  = { 'identity' => 3, 'mood' => 2, 'spike' => 1 }
CONF_RANK = { 'high' => 3, 'medium' => 2, 'low' => 1 }
```

**Output confidence mapping:** total ≥ 80 = 'high', ≥ 70 = 'medium', else 'low'.

**Script-aligned pass:** If `library['script_parsed']` exists, a fourth storyline `script_aligned` is generated using all segments in original order.

---

## 7. `match_templates.rb` — Deep Read

**Purpose:** Phase 1.7 — Scores each storyline candidate against known narrative templates.

**Input:** `storylines.yaml`, `segments_classified.yaml`
**Output:** `storylines_matched.yaml` (adds `template_match` key per storyline)

### Scoring Formula

```
fit_score = completeness × 0.6 + order_score × 0.4
```

**Beat matching:** For each template beat, scan storyline distillations chronologically. Match when any keyword appears (case-insensitive substring). First match wins, no re-matching.

**Completeness:** `matched_beats / total_beats × 100`

**Order score:** For each matched beat, compute `normalized_position = match_index / (total_distillations - 1)`. Compare against position ranges with ±0.15 tolerance:

```ruby
POSITION_RANGES = {
  'early'     => [0.0, 0.2],
  'early_mid' => [0.2, 0.4],
  'mid'       => [0.4, 0.6],
  'late_mid'  => [0.6, 0.8],
  'late'      => [0.8, 1.0]
}
```

**Runner-up:** Reported if within 15 points of best-fit template.

---

## 8. Classification Entrypoint — `classify()` in `orchestrate.rb`

**There is no standalone `classify_segments.rb`.** Classification lives as an inline method in `orchestrate.rb`'s `BEGIN` block (lines 861–936). Ruby's `BEGIN` executes at parse time, so the method is available despite being below `exit 0`.

### What it does:
1. Reads WhisperX JSON transcript
2. Builds segment listing: `[start-end] text` per segment
3. Creates MD5 hash for cache invalidation
4. Sends LLM prompt with Content Psychopharmacology framework instructions
5. Parses YAML response → writes `segments_classified.yaml`

### Per-segment output fields:
- `t`, `e` — start/end times
- `states` — array of 1–3 states (from 15-state taxonomy), primary first
- `distillation` — 5-word max summary of WHAT the segment says
- `signal` — verbal/visual element triggering the state
- `dur` — spike | mood | identity
- `roles` — array: primary, secondary, tertiary
- `notes` — 10-word editorial note
- `rationale` — 5–15 word explanation
- `confidence` — high | medium | low
- `signpost` — true if meta-commentary

### Validation:
Called by `validate_classification.rb` immediately after, checking:
- All states in VALID_STATES (15-state taxonomy)
- Durability in {spike, mood, identity}
- Roles in {primary, secondary, tertiary}
- Confidence in {high, medium, low}
- `t < e` for every segment, no overlaps
- Exit codes: 0=valid, 1=structural, 2=taxonomy, 3=data

---

## 9. `score_coherence.rb` — Deep Read

**Purpose:** Phase 1.8 — Two-layer coherence scoring + combined ranking.

**Input:** `storylines_matched.yaml`, `segments_classified.yaml`
**Output:** `storylines_scored.yaml`

### Combined Scoring Formula

```
combined_score = state_score × 0.3 + template_fit × 0.4 + coherence_score × 0.3
```

Where:
- `state_score` = from `discover_storylines.rb` (0–100)
- `template_fit` = `fit_score` from `match_templates.rb` (0–100)
- `coherence_score` = `algorithmic_coherence` initially; replaced by `llm_coherence` when filled

### Profile Bonuses (additive post-formula)
- **+5** if best-matched template in profile's `template_affinities`
- **+3** if close segment durability matches profile's `closing_durability_preference`

**Quality floor:** `combined >= 60` → `passed_floor: true`

### Layer 1 — Algorithmic Deductions (starts at 100)

| Condition | Penalty |
|-----------|---------|
| No close segment | -15 |
| Hook/close states share nothing | -10 |
| Incompatible adjacent transitions | -min(count × 5, 25) |
| State redundancy (runs > 3 same state) | -min(excess × 3, 25) |
| Low distillation diversity (unique_ratio < 0.7) | -(0.7 - ratio)/0.7 × 15 |
| Short body (< 3 segments) | -10 |

### Layer 2 — LLM Coherence

Only for candidates with `algorithmic_coherence >= 50`. The script builds `llm_eval_prompt` per storyline but does NOT make the LLM call itself — it writes the prompt into the YAML for an external agent to evaluate. Prompt instructs scoring 0–100 on whether distillation sequence makes sense as complete communication from a cold viewer. Profile's `preserve_strongly` voice moves must not be penalized.

---

## 10. `orchestrate.rb` — Phase-by-Phase Delta

### main branch phase sequence (live code only)

| Phase | Script(s) |
|-------|-----------|
| 1 — Ingest (per-video) | audio_cleanup, whisperx, audio_sync_offset, audio_analysis, transcript_cleanup |
| 0 — Content Type Detection | detect_content_type |
| 1.5 — Classification (Branch B) | classify() inline, validate_classification, semantic_dedup |
| 1.5c — Audio Emotion | audio_emotion (per-video) |
| 1.5d — Scene + Visual | detect_scenes, extract_visual_frames |
| 2 — Semantic Ingest | semantic_ingest |
| 3 — Arrangement | arrange |
| 4 — Export | export_arrangement_xml |
| 5 — Packaging | export_packaging_brief |

**Branch C (analyze-only):** Phases 1.6 (discover_storylines) → 1.7 (match_templates) → 1.7.5 (detect_structure + inline LLM) → 1.8 (score_coherence --no-llm) → C (generate_report) → exit 0.

**Dead code after exit 0:** ~375 lines of legacy phases 1.6–4 (old storyline selection UI, old build loop). The `BEGIN { def classify() }` block IS live despite being below exit 0 (Ruby `BEGIN` executes at parse time).

### dev branch phase sequence

| Phase | Script(s) |
|-------|-----------|
| MINE (Mode D only) | pool_index, audio_cleanup, whisperx, detect_scenes, extract_visual_frames, match_hq_audio |
| 1 — Ingest (per-video) | audio_cleanup, whisperx (+diarize), audio_sync_offset, audio_analysis + transcript_domain stamp |
| A — Script (Branch A, exits) | parse_script, audio_prosody, beat selection, arrange_to_script (per-beat), arrangement_adapter, export_arrangement_xml |
| 0 — Content Type Detection | detect_content_type |
| 1.25 — Prosody | audio_prosody |
| 1.35 — Semantic Segmentation | semantic_segment (per-source, LLM) |
| 1.4 — Extract Segments | extract_segments |
| 1.5c — Audio Emotion | audio_emotion (per-video) + merge_prosody_segments |
| 1.5d — Scene + Visual | detect_scenes, extract_visual_frames |
| 2 — Discovery Pass | discovery_pass (forward_stdin) |
| D.2.5 — Register Sources (Mode D) | register_pool_sources |
| 3 — Arrangement | arrange |
| 4 — Export | export_arrangement_xml |
| 5 — Packaging | export_packaging_brief |

### Key differences

| Feature | main | dev |
|---------|------|-----|
| Branch A | Sub-step inside Phase 1, falls through | Full self-contained pipeline, exits early |
| Branch C | Live (phases 1.6–C report) | Deprecated, hard abort |
| Branch D (mine) | Does not exist | New complete pool ingestion mode |
| Phase 1.25 Prosody | Branch A only | Branch A and B |
| Phase 1.35 Semantic Segment | Does not exist | New (replaces classify + transcript_cleanup) |
| Phase 1.4 Extract Segments | Does not exist | New (deterministic aggregation) |
| Phase 1.5 Classification | Live (inline LLM + validate + dedup) | Removed entirely |
| Phase 2 | semantic_ingest | discovery_pass (thesis selection) |
| classify() method | Inline BEGIN block | Does not exist |
| Inline LLM calls | Yes (classify, structure detection) | None — all delegated to child scripts |
| transcript_domain guard | No | Fail-fast at Phase 1 entry |
| Diarization support | No | --diarize flag |
| Library auto-creation | No | Via LibraryResolver |
| Cache fingerprint | MD5 | SHA256 |
| Dead code after exit 0 | ~375 lines | 2-line comment |

---

## 11. `semantic_ingest.rb` (main) vs `discovery_pass.rb` (dev)

These serve analogous Phase 2 roles but with fundamentally different philosophies.

### semantic_ingest.rb (main)

**Inputs:** Full transcript JSON + audio features YAML + visual frames YAML + scene changes YAML + optional script files + profile/tone guide.

**Output:** `semantic_ingest.yaml` with:
- `core_understanding` — 2–3 paragraph editorial briefing
- `central_tension` — thesis/question statement
- `clip_groups` — organized by semantic topic, each clip with: `t`, `source`, `usability` (fine/marginal/unusable), `content_summary`, `cluster` (retake label), `trim_in`, `mid_cuts`
- `open_loops` — structural (cross-group) and local (within-group)

**Philosophy:** Single directorial understanding of the footage as-is. One interpretation, no competing hypotheses.

### discovery_pass.rb (dev)

**Inputs:** Single enriched `segments_classified.yaml` (pre-enriched with acoustic + prosody fields) + profile.

**Output:** `discovery_pass.yaml` with:
- `theses` — up to 5 ranked candidate videos, each with logline, estimated duration, shape/risk
- `clip_groups` — five typed relationships: alternate_takes (with recommended take), setup_payoff, tangent, bridge, run-on
- `throughlines` — explicit open/middle/close seg_id loops with distance_guidance
- `visual_context` — reserved null stub

**Philosophy:** Multiple competing editorial hypotheses. Human picks one thesis. Choice is locked into the file before arrangement begins, making editorial intent explicit and traceable.

### Comparison Matrix

| Dimension | semantic_ingest | discovery_pass |
|-----------|----------------|----------------|
| Input format | Raw transcripts + multiple feature files | Single pre-enriched flat segment table |
| Primary output | One interpretation (clip_groups) | Multiple competing theses (ranked) |
| Clip relationships | Flat cluster labels + usability | Five typed groups with selection_guidance |
| Narrative structure | open_loops (referenced by group_id) | throughlines (referenced by seg_id) |
| Visual data | Consumed from visual transcripts | Reserved null stub (deferred) |
| Duration awareness | None | --duration flag constrains candidates |
| Review gate | Binary: proceed or abort | Selection: pick one thesis |
| Token budget | 8,192 | 32,768 |
| Hash algorithm | MD5 | SHA256 |
| Cache granularity | Transcript content only | Segments + profile + duration |

---

## 12. Concept Inventory — What Dev Lost

These capabilities existed in main's live or Branch C paths and have no equivalent in dev:

### 12.1 Per-Segment State Classification

**Main:** `classify()` inline method assigns each segment: `states` (1–3 from 15-state taxonomy), `distillation` (5-word summary), `signal`, `dur` (spike/mood/identity), `roles` (primary/secondary/tertiary), `confidence` (high/medium/low), `rationale`, `signpost`.

**Dev:** `semantic_segment.rb` produces atoms with text, timing, and word arrays. No emotional state classification. No distillation. No durability tier. No role assignment. No confidence scoring. The segment is a pure editorial atom — content without editorial metadata.

**Impact:** All downstream intelligence that consumes states, roles, durability, and distillation is cut off. This includes storyline discovery, template matching, coherence scoring, and algorithmic ranking.

### 12.2 Distillation (5-word summaries)

**Main:** Every segment has a `distillation` — a 5-word-max semantic fingerprint. These are the tokens that `match_templates.rb` keyword-matches against and that `score_coherence.rb` checks for diversity.

**Dev:** No distillation field exists. The discovery_pass LLM prompt receives full segment text and produces thesis-level summaries, but individual segment-level distillation is gone.

### 12.3 Durability Tier Assignment

**Main:** Every segment gets `dur: spike|mood|identity`. `DUR_RANK` (identity=3, mood=2, spike=1) drives storyline scoring dimensions: cold viability, closing durability, and the profile's `closing_durability_preference` bonus.

**Dev:** No durability field. Discovery_pass LLM implicitly evaluates segment impact but doesn't emit per-segment durability scores.

### 12.4 Role Assignment (primary/secondary/tertiary)

**Main:** Segments get roles that directly control storyline assembly. `primary` = hook candidates. `secondary` = body fill. `tertiary` = close candidates. `discover_storylines.rb` uses these roles as the entry points for arc construction.

**Dev:** No role assignment. Discovery_pass identifies thesis candidates holistically, but doesn't classify individual segments by editorial function.

### 12.5 Storyline Discovery (3-profile expansion)

**Main:** `discover_storylines.rb` runs three algorithmic expansion profiles (tight/balanced/wide) to generate storyline candidates. Each profile has different duration targets, expansion strategies, and quality floors.

**Dev:** Discovery_pass asks the LLM to propose up to 5 theses. Duration targeting is available via `--duration` flag. But the algorithmic expansion logic — spine ratio checking, incompatible pair detection, body filling strategies — is all gone, replaced by LLM judgment.

### 12.6 Template Matching (keyword + position scoring)

**Main:** `match_templates.rb` scores storylines against 7 narrative templates using keyword matching + position validation. `fit_score = completeness × 0.6 + order_score × 0.4`. Templates provide structural priors.

**Dev:** Templates exist in `templates/story_structures/` but nothing reads them. `discovery_pass.rb` doesn't reference templates. The 7 templates are dormant assets.

### 12.7 Coherence Scoring (algorithmic + LLM two-layer)

**Main:** `score_coherence.rb` runs algorithmic deductions (100 → penalties for missing close, incompatible adjacencies, state redundancy, low diversity, short body) then builds LLM evaluation prompts. Combined formula: `state × 0.3 + template_fit × 0.4 + coherence × 0.3`. Profile bonuses: +5 template affinity, +3 closing durability preference.

**Dev:** No coherence scoring pipeline. Discovery_pass LLM implicitly evaluates thesis quality but doesn't produce numeric scores or apply algorithmic deductions.

### 12.8 Combined Ranking Formula

**Main:** `state_score × 0.3 + template_fit × 0.4 + coherence_score × 0.3 + bonuses`. This is a composable, tunable ranking that weights three independent dimensions.

**Dev:** Theses are ranked by the LLM's judgment only. No decomposed scoring. No tunable weights. No profile bonuses.

### 12.9 Usability Tiers (fine/marginal/unusable)

**Main:** `semantic_ingest.rb` assigns per-clip usability. `arrange.rb` can prefer `fine` clips and avoid `unusable` ones.

**Dev:** `semantic_segment.rb` separates usable from discarded atoms (binary), with a `discarded_segments.yaml` audit file. No marginal tier. The boundary is cleaner but loses gradation.

### 12.10 Branch C (Analyze-Only Report)

**Main:** `--analyze-only` runs phases 1.6–1.8 + generate_report without producing an edit. Useful for assessing footage quality before committing to a cut.

**Dev:** Deprecated. Hard abort on `--analyze-only` or `--branch C`.

### 12.11 Adaptive Structure Detection

**Main:** Phase 1.7.5 — `detect_structure.rb` runs when no template fits well. Two-pass: viability check (is there enough to work with?) then ad-hoc template synthesis.

**Dev:** Gone. No fallback when templates don't fit.

### 12.12 Production Design Feedback Loop

**Main:** `parse_finished_edit.rb` → `extract_edit_patterns.rb` → `edit_patterns.yaml` → `build_structure_cut.rb` (SUGGEST markers). Partially wired — only in legacy dead code path, but the scripts and data flow exist.

**Dev:** Scripts still exist but no orchestrator path calls them.

---

## 13. Concept Inventory — What Dev Gained

### 13.1 Atom Architecture (semantic_segment.rb)

LLM-powered per-source segmentation produces whole-utterance editorial atoms with precise word-level timing. Strict validation (word count exact match, boundary consistency, chronological ordering). Auditable discarded trail. Atoms are inviolate downstream — `t`/`e` never modified.

### 13.2 Thesis-Based Editorial Model

Discovery_pass proposes up to 5 competing video candidates. Human picks one. Selected thesis becomes the explicit editorial intent, locked into the YAML before arrangement begins. This makes the edit traceable and repeatable.

### 13.3 Typed Clip Groups

Five relationship types (alternate_takes, setup_payoff, tangent, bridge, run-on) with selection_guidance. More structured than main's flat cluster labels.

### 13.4 Throughlines with Distance Guidance

Explicit open/middle/close narrative loops referenced by seg_id. `distance_guidance` field advises arrangement on minimum separation for setup/payoff tension.

### 13.5 Multi-Source Rendering

`export_arrangement_xml.rb` resolves atoms across multiple source videos. Per-source WAV sync. Multi-video timelines work end-to-end.

### 13.6 Pool-Based Ingestion (Mode D)

New mining mode for incremental content pools. Pool index, HQ audio matching, source registration. Enables "add footage over time" workflows.

### 13.7 Branch A Complete Redesign

Self-contained script-driven pipeline: parse_script → prosody → beat selection → arrange_to_script (per-beat) → adapter → export. Exits cleanly without touching Phase 0+.

### 13.8 Prosody in Branch B

`audio_prosody.rb` + `merge_prosody_segments.rb` give Branch B per-segment prosody data: stumble_count, mid_word_break_count, pause statistics. Main only ran prosody for Branch A.

### 13.9 BREATHING_MARGIN (80ms fixed)

Replaced variable `breathing_room_frames / fps` with a fixed 80ms per-clip-side. Simpler, predictable, no frame-rate dependency.

### 13.10 SHA256 Fingerprints + Cascade Invalidation

`extract_segments.rb` actively deletes downstream files (`discovery_pass.yaml`, `arrangement.yaml`, response caches) when its inputs change. Pipeline consistency is enforced by cascading invalidation rather than trusting timestamps.

### 13.11 Pending File LLM Pattern

`orchestrate.rb` exits code 2, writes pending YAML. External agent reads pending, generates response, writes response YAML. Pipeline resumes. Decouples LLM execution from pipeline orchestration.

### 13.12 thelmaedit.rb Wrapper

Auto-fulfills pending LLM calls using `claude -p` (Claude Code subscription) instead of API. Enables running the full pipeline without an API key.

---

## 14. Hybrid Recommendations — Porting v3.1 Intelligence onto Session 5 Atoms

The core challenge: dev's atoms are content-pure (text + timing + acoustic prosody). Main's editorial intelligence requires metadata-enriched segments (states, distillation, durability, roles, confidence). The question is where to inject that metadata in dev's pipeline.

### 14.1 PRIORITY 1 — Segment-Level Enrichment Pass

**What:** A new Phase 1.45 (after extract_segments, before audio_emotion) that adds per-segment: `states` (1–3 from taxonomy), `distillation` (5-word summary), `dur` (spike/mood/identity), `roles` (primary/secondary/tertiary), `confidence` (high/medium/low).

**Why:** This single addition re-enables all of: storyline discovery (needs roles), template matching (needs distillations), coherence scoring (needs states + distillations + durability), combined ranking (needs all scores), profile bonuses (needs durability for closing_durability_preference). Without this, everything in sections 12.1–12.8 stays dead.

**How:** Port `classify()`'s LLM prompt from main's orchestrate.rb. Run it on `segments_classified.yaml` after extract_segments. Write fields back into the same file (same pattern as audio_emotion). Add `validate_classification.rb` call after enrichment.

**Risk:** Token cost. Main classified raw transcript segments (fewer, longer). Dev has 370 atoms (more, shorter). Cost per library increases. Mitigation: batch atoms by source, use Sonnet for classification (main already routes classification to Sonnet).

### 14.2 PRIORITY 2 — Template Matching Integration

**What:** Wire `match_templates.rb` into the pipeline after discovery_pass produces theses. Run template matching against the selected thesis's segment sequence (not against storyline candidates — against the thesis).

**Why:** Templates provide structural priors. If thesis_004's arrangement maps cleanly to `contrarian_argument`, the arrangement LLM can use that template as a scaffold.

**How:** After thesis selection, extract the thesis's implied segment list from clip_groups + throughlines. Build a pseudo-storyline entry with distillations. Run match_templates. Inject best-fit template into the arrangement prompt.

**Risk:** Coupling. If templates don't fit (thesis is novel structure), this adds noise. Mitigation: only inject template when `fit_score >= 60`.

### 14.3 PRIORITY 3 — Coherence Pre-Filter

**What:** Port `score_coherence.rb`'s Layer 1 algorithmic deductions as a post-arrangement validation step. Run after arrange.rb produces chapters — check for incompatible adjacent states, missing close, state redundancy, low diversity.

**Why:** Catches structural problems before XML generation. Currently the only quality gate is the LLM's own judgment during arrangement.

**How:** New Phase 3.5 between arrange and export. Read arrangement.yaml chapters, look up each atom's states from enriched segments_classified.yaml, run deductions. Warn on score < 60 but don't block.

**Risk:** Requires Priority 1 (segment enrichment) first. Without states, there's nothing to check.

### 14.4 PRIORITY 4 — Storyline Discovery as Alternative to Discovery Pass

**What:** Offer `discover_storylines.rb` as an alternative Phase 2 path (selectable via flag). For users who want algorithmic storyline proposals instead of LLM thesis proposals.

**Why:** Algorithmic storylines are faster, cheaper, deterministic, and composable. LLM theses are more creative but opaque.

**How:** Gate on a `--discovery-mode algorithmic|llm` flag (default: llm). If algorithmic: run discover_storylines → match_templates → score_coherence → present ranked candidates. If llm: run discovery_pass (current behavior).

**Risk:** Maintaining two parallel paths. Mitigation: both produce the same downstream interface (selected storyline/thesis → arrangement prompt).

### 14.5 PRIORITY 5 — Production Design Feedback Loop

**What:** Wire `parse_finished_edit.rb` → `extract_edit_patterns.rb` → `edit_patterns.yaml` into the orchestrator. Inject patterns as SUGGEST markers in build_structure_cut.rb.

**Why:** Learning from finished edits improves future rough cuts. The scripts exist in both branches but are dead code.

**How:** Add a `--learn-from /path/to/finished.xml` flag. Run parse → extract → save patterns. On subsequent runs, load patterns and inject into arrangement prompt or marker generation.

**Risk:** Low — additive feature, no pipeline disruption.

### 14.6 PRIORITY 6 — Restore Branch C (Analyze-Only)

**What:** Re-enable `--analyze-only` as a non-destructive assessment mode. Run: enrichment → discover_storylines → match_templates → score_coherence → report. No arrangement, no export.

**Why:** Useful for footage assessment before committing to a cut. Currently the only way to assess footage is to run the full pipeline.

**How:** After Priority 1 (enrichment) is implemented, Branch C becomes trivially re-enableable.

---

## 15. Restoration Sequence

Ordered by dependency chain. Each step unlocks the next.

### Step 1: Segment Enrichment Pass (Priority 1)

**New file:** `scripts/enrich_segments.rb` (~200 lines)
**Phase:** 1.45 (after extract_segments, before audio_emotion)
**Depends on:** segments_classified.yaml from extract_segments.rb
**Produces:** Enriched segments_classified.yaml with states, distillation, dur, roles, confidence
**Unlocks:** Steps 2–4

**Implementation notes:**
- Port classify() prompt from main's orchestrate.rb BEGIN block
- Adapt to read atom-format segments (seg_id, t, e, text, source) instead of raw transcript segments
- Write enrichment fields back into segments_classified.yaml (same merge pattern as audio_emotion.rb)
- Run validate_classification.rb after enrichment
- Add SHA256 fingerprint gate (same pattern as other dev phases)
- Add cascade invalidation: stale enrichment deletes discovery_pass.yaml

### Step 2: Template Matching (Priority 2)

**Existing file:** `scripts/match_templates.rb` (231 lines, no modification needed)
**Phase:** 2.5 (after discovery_pass thesis selection, before arrange)
**Depends on:** Enriched segments + selected thesis
**Produces:** Template match score + best-fit template for the thesis
**Unlocks:** Template injection into arrangement prompt

**Implementation notes:**
- Build a pseudo-storyline from selected thesis's segment list
- Run match_templates.rb against it
- Inject winning template (if fit_score >= 60) into arrange.rb's LLM prompt as structural scaffold
- Minor change to arrange.rb prompt: add optional `## Template Scaffold` section

### Step 3: Coherence Pre-Filter (Priority 3)

**New file:** `scripts/validate_arrangement.rb` (~150 lines)
**Phase:** 3.5 (after arrange, before export)
**Depends on:** arrangement.yaml + enriched segments_classified.yaml
**Produces:** Coherence warnings (advisory, non-blocking)
**Unlocks:** Quality visibility before XML generation

**Implementation notes:**
- Port Layer 1 algorithmic deductions from score_coherence.rb
- Read arrangement chapters, resolve seg_ids → states from enriched segments
- Apply: incompatible adjacency check, state redundancy check, diversity check
- Warn to stderr if algorithmic_coherence < 60
- Do NOT block export — advisory only

### Step 4: Dual Discovery Mode (Priority 4)

**Existing files:** `discover_storylines.rb`, `match_templates.rb`, `score_coherence.rb`
**New flag:** `--discovery-mode algorithmic|llm` (default: llm)
**Phase:** 2 (alternative to discovery_pass)
**Depends on:** Enriched segments (Step 1)
**Unlocks:** Algorithmic storyline proposals as alternative to LLM theses

**Implementation notes:**
- Add branch in orchestrate.rb Phase 2 section
- If algorithmic: run discover_storylines → match_templates → score_coherence → present ranked
- Map selected storyline into discovery_pass.yaml format for downstream compatibility
- This is the largest change — requires ensuring all three scripts work with dev's atom format

### Step 5: Production Design Loop (Priority 5)

**Existing files:** `parse_finished_edit.rb`, `extract_edit_patterns.rb`
**New flag:** `--learn-from /path/to/finished.xml`
**Produces:** `edit_patterns.yaml`

### Step 6: Branch C Restoration (Priority 6)

**Depends on:** Step 1 (enrichment) + Step 4 (algorithmic discovery)
**Restores:** `--analyze-only` mode for non-destructive footage assessment

---

## Appendix A: Files Referenced by the 15-State Taxonomy

42 files in main, 25+ in dev. Key files:

**Scripts:** validate_classification.rb, discover_storylines.rb, score_coherence.rb, match_templates.rb, semantic_ingest.rb, mine_content.rb, detect_structure.rb, classify() in orchestrate.rb, branch_a_batch.rb

**Profiles:** _default.yaml (closing_durability_preference), dylan.yaml (primary_state_preferences), ivan.yaml (primary_state_preferences)

**Templates:** All 7 templates use beat keywords that correlate with state-inducing content

**Documentation:** docs/content_psychopharmacology.md (canonical definition)

## Appendix B: Dead Code in main (after exit 0)

Lines 563–936 contain legacy phases:
- Phase 1.6 — discover_storylines
- Phase 1.7 — match_templates
- Phase 1.7.5 — detect_structure + inline LLM
- Phase 1.8 — score_coherence
- Phase 1.9 — sanity_check (ONLY exists here — never in live path)
- Phase 2 (old) — interactive storyline selection UI
- Phase 3 (old) — inline XML construction
- Phase 4 (old) — output + packaging

The `BEGIN { def classify() }` block (lines 861–936) is technically in this region but IS live code because Ruby `BEGIN` blocks execute at parse time.

## Appendix C: mine_content.rb — Dead-End Analysis

`mine_content.rb` produces `content_inventory.yaml` with thematic clusters, quality scores, and standalone short candidates. **No downstream consumer exists in either branch.** The `theme_prompt` field suggests it was designed for interactive agent triage, but no script reads `content_inventory.yaml` as input. The stderr output suggests manual follow-up actions. This is an assessment tool, not a pipeline stage.
