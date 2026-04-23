# Thelma v4.0 — Content Intelligence System

> Design doc. Committed to `dev` branch at `docs/v4_design.md`. Scope document, not implementation plan.

---

## Problem Statement

Ivan is a strategist whose day job consumes his bandwidth. Personal content production (brand strategy YouTube channel) is a strategic career priority but sits uncaptured in his head or in sporadic recordings that never become videos. Thelma v3.1 solves the editing bottleneck for structured projects (video essay, multi-source talking head). It does not solve:

1. **Low-friction capture** — Ivan records thoughts sporadically across devices; needs a workflow that turns a pool of mixed-media recordings into videos without folder organization labor.
2. **Format literacy** — what makes high-retention videos work in Ivan's niche is structural (pacing, B-roll correlation, visual rhythms, narrative arc patterns). Hand-written templates miss this. Needs data-derived templates from outlier YouTube videos.
3. **Visual intelligence** — current visual analysis is basic scene detection. For format template extraction AND arrangement quality AND edit review, need shot-level understanding: shot type, B-roll correlation to speech, pacing curves, motion graphics detection.
4. **Edit review** — Ivan reviews Raffiti editor work daily. Needs systematic notes on structure, visuals, brand compliance.

v4.0 addresses all four.

---

## Vision in One Paragraph

Thelma becomes a content intelligence system. Visual analysis captures structural DNA (shot types, B-roll correlation, breathing pacing, motion graphics). Mode C extracts DNA from outlier YouTube videos (with retention data when available) into format templates (tier-ranking, $1-vs-$X, hidden-reveal, etc.) AND creator templates (Hormozi-style, Abdaal-style) AND brand templates (per-client). Mode D mines Ivan's content pool for narrative arcs matching chosen templates, producing Premiere-ready cuts plus editing briefs. Edit Review mode analyzes finished client edits against brand/format templates and surfaces structural notes. Ivan goes from "strategist with no bandwidth" to "strategist who ships content" via infrastructure that does the editorial work.

---

## Architecture

```
┌───────────────────────────────────────────────────────────────┐
│              Visual Analysis (new, cross-cutting)             │
│  - Shot classification (talking head, detail, B-roll types)   │
│  - Motion graphics/text overlay detection                     │
│  - Pacing analysis (breathing curve, speed variance)          │
│  - B-roll ↔ speech semantic correlation                       │
│  - Visual hook detection                                      │
│  - Frame-level analysis (not just scene boundaries)           │
└───────────────────────────────────────────────────────────────┘
                              │
         ┌────────────────────┼────────────────────┐
         │                    │                    │
┌────────▼────────┐ ┌─────────▼────────┐ ┌────────▼──────────┐
│ Mode C:         │ │ Mode D: Mining    │ │ Edit Review Mode  │
│ Template        │ │                   │ │                   │
│ Extraction      │ │ Loose pool lib    │ │ Compare finished  │
│                 │ │ Mixed media       │ │ edit against      │
│ From 3-5 YT     │ │ (video, audio,    │ │ brand/format      │
│ outlier vids +  │ │  B-roll)          │ │ template.         │
│ retention CSVs  │ │                   │ │                   │
│                 │ │ Find narrative    │ │ Output: structural│
│                 │ │ arcs. Match to    │ │ notes, visual     │
│                 │ │ selected template.│ │ notes, brand      │
│                 │ │                   │ │ compliance.       │
│                 │ │ Present candidates│ │                   │
│                 │ │ for selection.    │ │                   │
└─────────┬───────┘ └─────────┬────────┘ └───────────────────┘
          │                   │
          ▼                   ▼
 ┌─────────────────┐ ┌─────────────────┐
 │ Template Library│ │ Production      │
 │  - Format tpls  │ │ Output          │
 │  - Creator tpls │ │  - XML          │
 │  - Brand tpls   │ │  - Edit brief   │
 └─────────────────┘ └─────────────────┘
```

---

## Format Library Seed

10 format primitives identified (expandable). Domain axis is illustrative — format type is what matters.

| Format Type | Structural Signature |
|---|---|
| Tier/Ranking | Rate/compare items, scored list structure |
| $1 vs $X | Price comparison, low-vs-high framing |
| 100 Hours/Days | Extended duration, journey structure |
| Every [X] | Exhaustive completion, systematic coverage |
| Extreme Restriction | Limitation challenge, absence-as-framing |
| Hidden/Secret | Discovery/reveal structure |
| I Survived | Endurance test, stakes narrative |
| Fastest/Slowest | Speed challenge, efficiency framing |
| Real vs Fake | Authenticity test, comparison structure |
| Beginner vs Pro | Skill comparison, progression narrative |

Template data structure must handle 10+ formats cleanly. Schema designed for extensibility, not hardcoded to these 10.

---

## Mode D: Mining (Phase 1 Priority)

### Capture Side

**Pool structure:**
```
~/Desktop/RAW/<pool_name>/
  ├── 20250115_walkthought.m4a     # audio note, single device
  ├── 20250117_deskriff.mp4         # video note, phone
  ├── 20250118_meeting_reflection.mp4
  ├── 20250120_camera_session.mov   # proper camera session
  ├── [... etc, chronological dump, no folder structure]
  └── B Roll/
      ├── logo_montage.mp4
      ├── whiteboard_shots.mp4
      └── [...]
```

**Mixed media support:**
- Video with baked-in audio (standard)
- Video with muted/external audio (allow external audio linking)
- Audio-only (.m4a, .mp3, .wav, .aac) — treated as first-class content source
- B-roll (video only, no speech expected) — matched to A-roll clips

**Device-agnostic:**
- Multiple resolutions, frame rates, codecs in same pool
- Some horizontal, some vertical (portrait gets flagged for handling)
- Timeline assembly normalizes to target resolution from profile

### Production Side

**Command:**
```bash
ruby scripts/orchestrate.rb --mode mine --library <pool_name> --profile <name>
  [--template <format_or_creator_template>]
  [--topic <target_topic>]
  [--format longform|shorts]
```

**Without template/topic:** Tool discovers what videos are possible in the pool. Surfaces 3-5 candidate arcs. User selects one, pipeline produces that cut.

**With template:** Tool filters pool for clips matching template's structural requirements. Surfaces candidate cuts fitting the template.

**With topic:** Semantic filter applied first. Arrangement finds arcs within topically-relevant clips.

**With both:** Topic-filtered clips get arranged per template's structural requirements.

**Flow:**
1. Ingest new clips in pool (incremental — only process what's new since last run)
2. Semantic understanding of every clip
3. Arc discovery (with or without template/topic constraints)
4. Candidate presentation:
   ```
   POSSIBLE VIDEOS IN POOL:

   Candidate 1: "Why every productivity app fails" [8:42, 14 clips]
     - Structure: Problem → Historical parallel → Counter-thesis → Payoff
     - Strongest hook: t=1234 ("I've tried every app. None of them work.")
     - Template match: hidden_reveal (87% fit)

   Candidate 2: "GTD in Notion after 5 years" [6:15, 9 clips]
     - Structure: Personal story → System explanation → Practical close
     - Strongest hook: t=5678 ("Five years. I still use this.")
     - Template match: beginner_vs_pro (74% fit)

   Candidate 3: [...]
   ```
5. User selects candidate (or regenerates with different constraints)
6. Selected candidate → arrangement → XML + edit brief
7. Used clips get marked in pool (optional — avoids re-using same clip across multiple videos)

### Audio-Only Handling

**Track convention (reaffirmed):**
- V1/V2: A-roll primary + alternate
- V3+: B-roll (including over audio-only gaps)
- A1/A2: primary audio
- A3+: overlay audio

**For audio-only clip in arrangement:**
- Transcribed, understood, placed in arrangement like any other clip
- XML: audio clipitem on A1/A2, no video clipitem for V1 at that position
- V1 stays gapped (black in Premiere)
- B-roll matching prioritizes these positions — if match found, placed on V3
- Editor fills remaining V1 gaps manually in Premiere (stock, graphics, pickup shots)

**Flagged in arrangement:**
```yaml
clips:
  - t_in: 12.3
    t_out: 18.7
    source: 20250115_walkthought.m4a
    track: V1
    media_type: audio_only
    broll_matched: true
    broll_source: "B Roll/whiteboard_shots.mp4"
    broll_track: V3
```

### Incremental Library Indexing

Pool may grow over time — adding 5 recordings, running mine, adding 3 more, running mine again. Processing should be incremental:

- `libraries/<pool>/index.yaml` tracks which files have been ingested
- New files get ingested (transcription, semantic understanding)
- Semantic index updated
- Existing indexed clips skipped

Not v5 content librarian (auto-tagging from external drive), but foundation for that later.

### Priority: 4-5 sessions of work

---

## Advanced Visual Analysis (Phase 2 Priority)

### Output Schema

Per clip, structured data capturing visual DNA:

```yaml
visual_analysis:
  shots:
    - shot_id: s001
      t_start: 0.0
      t_end: 2.4
      shot_type: talking_head_medium    # talking_head_close, talking_head_medium,
                                        # talking_head_wide, detail, broll_type_<X>,
                                        # screen_recording, motion_graphic
      composition: centered              # centered, rule_of_thirds, off_center
      camera_motion: static              # static, pan, tilt, zoom_in, zoom_out, handheld
      subject_motion: minimal            # minimal, moderate, active
      lighting: natural                  # natural, studio, mixed, low_key, high_key
      dominant_colors: [warm, earth_tones]
      text_overlay_present: false
      motion_graphic_present: false
      b_roll_semantic_tag: null          # only when shot_type=broll_*
      frames_sampled: [0.2, 1.0, 2.0]    # timestamps of frames analyzed

  pacing:
    shot_duration_distribution:
      mean: 2.1
      median: 1.8
      variance: 1.3
      curve: breathing   # steady, accelerating, decelerating, breathing, erratic

    rhythm_moments:
      - t: 15.2
        type: pace_acceleration
        note: "Shot durations drop from 3s avg to 0.8s avg"
      - t: 42.5
        type: pace_deceleration
        note: "Static wide shot holds for 6s, breathing pause"

  b_roll_correlation:
    coverage: 0.45   # 45% of runtime has B-roll overlay
    matches:
      - a_roll_segment: "speaker says 'I tried Notion first'"
        a_roll_t: 12.3
        b_roll_source: "notion_screenshot.mp4"
        b_roll_t: 14.1
        semantic_relevance: 0.92   # LLM-scored
        timing: cut_on_word         # cut_on_word, cut_on_beat, overlap, L_cut, J_cut

  visual_hook:
    first_3_seconds:
      - shot_type: talking_head_close
        text_overlay: "EVERY PRODUCTIVITY APP IS BROKEN"
        motion_graphic_present: false
        cuts_count: 2
        attention_pattern: rapid_cut_hook
```

### What Feeds This

- **Shot classification:** Claude Vision on representative frames per shot, returns structured classification
- **Motion detection:** Compute optical flow / frame diff to detect static vs moving camera
- **Frame sampling:** Not just scene-change frames — per-shot 3-5 frames for analysis (opening, middle, end, key motion moments)
- **Pacing analysis:** Algorithmic — shot duration distribution, variance calculation, curve fitting
- **B-roll correlation:** Semantic comparison of A-roll transcript at B-roll timestamp vs B-roll visual content (Claude Vision describes B-roll, semantic similarity to adjacent speech)

### Use Cases

- Mode C template extraction (structural DNA capture)
- Mode D arrangement quality (B-roll placement suggestions informed by what's in the B-roll pool)
- Mode D arrangement quality (pacing curve matches target template's rhythm)
- Edit Review mode (compare edited video's visual profile against template)

### Priority: 3-4 sessions of work

---

## Mode C: Template Extraction (Phase 3 Priority)

### Input

One of:
- **Single finished video** (extract this video's structural DNA for reference)
- **Multiple finished videos** (3-5 high-retention videos in a category → synthesize template)
- **YouTube download + retention CSV** (correlate structural moments with retention drops)

CLI:
```bash
# Single video analysis
ruby scripts/orchestrate.rb --mode analyze --video <path> --profile <creator>

# Template extraction from multiple
ruby scripts/orchestrate.rb --mode extract_template \
  --videos <path1> <path2> <path3> \
  --retention-csvs <csv1> <csv2> <csv3> \
  --template-type format:hidden_reveal \
  --output templates/formats/hidden_reveal.yaml

# Creator template extraction
ruby scripts/orchestrate.rb --mode extract_template \
  --videos <hormozi_vid1> <hormozi_vid2> <hormozi_vid3> \
  --template-type creator:hormozi \
  --output templates/creators/hormozi.yaml
```

### Retention Data Correlation

YouTube provides a 100-point retention graph. Ingest CSV, map retention values to video timeline, identify:

- **Retention drops:** Points where % drop > threshold. Correlate with structural moments:
  - Is it an information-dense moment (maybe too much at once)?
  - A slow section (pacing too low)?
  - A topic shift (audience confusion)?
  - Graphics-heavy (reading overload)?

- **Retention plateaus:** Points where audience stays steady. What structural patterns support this?

- **Retention rises:** Points where audience came back (from re-watches, typically). What hooked them back in?

Template learns from these patterns:
```yaml
template:
  name: hidden_reveal
  source_videos: [<vid1>, <vid2>, <vid3>]

  structural_signature:
    opening:
      duration: 3-8s
      shot_type: talking_head_close_or_medium
      text_overlay_frequency: 0.6
      retention_pattern: 98-95%_initial

    setup_phase:
      duration_proportion: 0.15-0.25   # 15-25% of total runtime
      pacing: steady_to_accelerating
      b_roll_coverage: 0.3-0.5
      role: context_for_the_reveal

    development_phase:
      duration_proportion: 0.35-0.50
      pacing: breathing_with_peaks
      retention_risk: info_density_drop_probable

    reveal:
      duration_proportion: 0.10-0.20
      shot_type_shift: typically_static_for_emphasis
      pacing_drop: slows_by_30-50%
      retention_spike: 5-10%_rise_observed

    close:
      duration: 20-40s
      cta_present: 0.85
      retention_end_drop: 10-15%_normal

  visual_signatures:
    b_roll_correlation_avg: 0.82
    motion_graphics_density: 0.4  # events per minute
    cut_rhythm: breathing   # not sustained_rapid, not sustained_slow
    color_palette: warm_with_accent_desaturated_b_roll

  verbal_signatures:
    hook_pattern: contrarian_claim_or_question
    transitional_phrases_frequency: high
    specific_example_density: 4-6_per_minute
    cta_style: invitation_not_command
```

### Template Consumers

- **Mode D:** Use template to filter pool clips, structure discovered arcs, match pacing requirements
- **Edit Review Mode:** Use template as reference for comparing finished edits
- **Packaging Brief:** Use template's visual signatures for thumbnail direction

### Priority: 4-5 sessions of work

---

## Edit Review Mode (Phase 3, Bundled with Mode C)

### Input

- Finished edited video (from Raffiti editor, say)
- Target template (brand template, format template, or creator template)
- Optional: source brief / script for reference

### CLI

```bash
ruby scripts/orchestrate.rb --mode review \
  --video <edited_video_path> \
  --template templates/brands/<client_name>.yaml \
  --brief <brief_path>
```

### Process

1. Run full visual analysis on the edited video
2. Compare against template signatures:
   - Structural phases (did they hit hook-setup-development-reveal-close proportions?)
   - Visual signatures (pacing curve, B-roll coverage, shot type distribution)
   - Verbal signatures (where applicable)
3. Identify:
   - **On-brand moments** — matches template strongly
   - **Off-brand moments** — deviates from template significantly
   - **Structural gaps** — template expects something that isn't there
   - **Unused opportunities** — source brief mentions things the edit missed

### Output

Markdown review document:
```markdown
# Edit Review: <video title>
Template: <brand/format> | Editor: <name>

## Overall assessment
On-brand match: 72%
Pacing match: strong
Visual signature match: moderate
Verbal signature match: weak

## Structural notes
- Hook runs 11s vs template's 3-8s range. Trim for impact.
- Development phase has 4 topic shifts (template expects 2-3). Consider consolidation.
- Close lacks CTA (template has 85% CTA frequency). Add.

## Visual notes
- B-roll coverage 31% vs template 45-55%. Add more.
- Motion graphics density 0.1/min vs template 0.4/min. Graphics feel sparse.
- Shot type balance: 70% talking head close. Template varies — add medium shots.

## Verbal notes
- No contrarian hook in first 10s. Template leads with claim-or-question.
- Transitional phrases thin. Template uses "here's what that means" / "the real question is" to bridge.

## Unused from brief
- Brief mentioned "Tesla comparison" — not present in edit.
- Brief's data point about conversion rate is missing.

## On-brand moments (preserve)
- 2:34 reveal section hits template rhythm perfectly
- 4:12 B-roll correlation is strong
```

### Priority: Bundled with Mode C, shares template infrastructure

---

## Production Output Enhancement (Phase 4)

Mode D's output already produces XML + packaging brief. Phase 4 adds detailed editing brief:

```markdown
# Editing Brief: <video title>
Template: hidden_reveal | Duration: 8:42

## Timeline direction

### Chapter 1: Hook (0:00 - 0:34)
- V1: A-roll talking head close
- V3: B-roll at 0:08-0:14 — illustrate Ghibli moment (screenshot montage)
- V4: Text overlay "EVERY PRODUCTIVITY APP IS BROKEN" at 0:00-0:03
- A3: Ambient music at -18dB, starts at 0:00, ramps at 0:10

### Chapter 2: Setup (0:34 - 1:45)
- V1: Continues A-roll, mostly talking head medium
- V3: B-roll at 0:52-1:02 — 1880s photography / daguerreotypes (source needed)
- V4: Lower third "Ben Franklin 1706-1790" at 0:48-0:52
- V5: Motion graphic: $60B stat at 1:12 (template suggests bold animation)

[... per chapter ...]

## Graphics needed (not in pool)
- Ghibli-style AI art montage — sourced or generated
- 1880s photography archival footage or licensed stock
- $60B productivity industry stat animation
- Baudelaire portrait or period artwork
- ...

## Music direction
- Warm, slightly melancholic for setup
- Energy ramp during development
- Strip for reveal (silence for emphasis)
- Resolution music for close

## Export settings
- 4K 30fps horizontal
- H.264 high profile
```

### Priority: 1-2 sessions, extends existing packaging brief

---

## Infrastructure Requirements

### New Scripts

- `scripts/visual_analysis_advanced.rb` — shot classification, pacing, motion detection, frame analysis
- `scripts/extract_visual_dna.rb` — Mode C template extraction from finished videos
- `scripts/ingest_retention_csv.rb` — YouTube retention CSV parser
- `scripts/mine_content.rb` — expand existing to full Mode D functionality
- `scripts/discover_arcs.rb` — narrative arc discovery in library pool
- `scripts/match_template.rb` — expand existing to score clips against template
- `scripts/review_edit.rb` — Edit Review mode
- `scripts/generate_editing_brief.rb` — detailed brief generation

### Updated Scripts

- `scripts/orchestrate.rb` — new modes: `mine`, `extract_template`, `review`
- `scripts/load_profile.rb` — support template loading alongside creator profiles
- `scripts/detect_scenes.rb` — integrate with advanced visual analysis (may be deprecated or refactored)
- `scripts/semantic_ingest.rb` — consume advanced visual data when present
- `scripts/arrange.rb` — use templates to guide arrangement

### New Data Structures

- `templates/formats/<name>.yaml` — format templates (hidden_reveal, tier_ranking, etc.)
- `templates/creators/<name>.yaml` — creator templates (hormozi, abdaal, etc.)
- `templates/brands/<client>.yaml` — brand templates (for edit review)
- `libraries/<pool>/index.yaml` — incremental ingestion tracking
- `libraries/<pool>/arc_candidates.yaml` — discovered narrative arcs

### Dependencies

- Possible new Python deps: OpenCV for optical flow, motion detection
- YouTube retention CSV parsing
- Frame-level vision analysis expands LLM token usage (costs Phase 2 will increase)

---

## Phase Breakdown

### Phase 1: Mode D Mining (priority 1)
**4-5 sessions**

- Incremental pool indexing
- Mixed media support (audio-only as first-class)
- Arc discovery without template/topic
- Arc discovery with template/topic
- Candidate presentation
- Selection → arrangement → XML flow
- Editing brief generation (basic)

**Uses existing:** templates (hand-written), visual analysis (basic scene detection), arrange.rb
**Doesn't need yet:** advanced visual analysis, data-derived templates

Delivers: unlocked content production workflow. Ivan can capture sporadically, produce videos.

### Phase 2: Advanced Visual Analysis (priority 2)
**3-4 sessions**

- Shot classification module
- Pacing analysis
- B-roll correlation
- Frame-level sampling
- Output schema standardized
- Integration with existing scripts (semantic_ingest, arrange consume when present)

**Improves:** Mode D arrangement quality, future Mode C capability
**Doesn't unlock yet:** Mode C template extraction, Edit Review

Delivers: better arrangement decisions, foundation for Phase 3.

### Phase 3: Mode C + Edit Review (priority 3)
**4-5 sessions**

- Multi-video Mode C input
- Retention CSV ingestion
- Template extraction from outlier videos
- Format, creator, and brand template libraries
- Edit Review mode
- Template consumption across pipeline

**Improves:** Mode D (data-derived templates), unlocks Edit Review workflow for Raffiti work

Delivers: Edit review tooling for daily client work, format literacy for content production.

### Phase 4: Production Output Enhancement (priority 4)
**1-2 sessions**

- Detailed editing brief generation
- Graphics/motion-graphics callouts
- Music direction suggestions
- Export settings codification

**Improves:** Handoff quality when Ivan hands cuts to editors/graphics people

Delivers: complete production-ready output, not just structural.

---

## Total Scope

**11-16 sessions.** Range depends on edge cases, real-world bugs surfaced during development, quality iteration on LLM prompts.

Branch strategy:
- `main` stays on v3.1 (shipped, stable)
- `dev` is v4 development branch
- Bug fixes discovered during v4 work affecting v3 functionality land on main via cherry-pick or direct commit
- v4 merges to main when all phases complete (or earlier with clear versioning — v4.1, v4.2 per phase)

---

## Out of Scope for v4.0

**Deferred to v5:**
- Content librarian / auto-tagging external drive
- Match cut detection / J-cut L-cut generation
- Audio ducking / music beat matching
- Color grading suggestions
- Cross-project template learning (system learns from Ivan's actual edit history)

**Deferred indefinitely:**
- Travel footage / non-speech content modes
- Multi-speaker interview handling
- Final color, graphics generation, music composition
- Rendering/export from Thelma (stays Premiere-native handoff)

---

## Success Criteria

v4.0 is done when:

1. Ivan can record sporadic thoughts for a month, then run Mode D and produce 2-3 videos from that pool without pre-organizing the recordings
2. Mode C has extracted at least 3 format templates and 2 creator templates from real YouTube outliers with retention data
3. Edit Review mode has been used on real Raffiti editor work and produced actionable notes
4. Advanced visual analysis is running on all new Phase 1 projects
5. Full pipeline test passes: fresh pool → mine → produce video → review the output → ship
6. Previous v3.1 single-project workflow still works (no regressions)
7. Documentation updated — SOP covers v4 workflows, QUICKSTART includes mining
8. Tests cover new infrastructure

---

## Review / Open Questions

**Questions for Ivan before phase 1 kickoff:**

1. **Audio-only match/sync for baked-in poor audio:** Spec says "allow for match and sync." What triggers this? User flag per file? Auto-detect poor audio quality? Defer to later?

2. **Incremental ingestion re-indexing:** When the pool grows, should previously-ingested clips be re-evaluated if a new relevant clip arrives (updates clustering), or are old indexes frozen?

3. **Used-clip marking:** Should clips consumed in one video be marked unavailable for future mining by default, or available by default? Reuse across shorts + longform from same footage is probably desired.

4. **Template precedence in Mode D:** If user specifies both `--template` and `--topic`, which constrains first? Current design: topic filters clips, then template structures. Is that right?

5. **Retention CSV format:** Is this YouTube's standard analytics export, or something else? Example file needed.

6. **Edit Review output format:** Markdown sufficient, or do you want this as a PDF / DOCX for sharing with editors?

7. **Brand template source:** Where do brand templates come from? Ivan hand-writes them based on client work? Extracted from existing successful client videos via Mode C?

---

## Next Action

Review this doc. Answer the open questions. If approved, commit doc to `dev` branch as `docs/v4_design.md`. Kick off Phase 1.
