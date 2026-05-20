# Thelma & Bass — Vision

## Thelma (current)

Ruby pipeline. Semantic understanding of raw footage + script-aware
arrangement. Output: Premiere XML, not finished video.

Named after Thelma Schoonmaker — the indie editor's editor, mining
emotional moments from raw material.

### Modes

- **A: Script-driven cutdown** — REFACTOR PENDING (lean rewrite).
  Current implementation inherits Mode B's full pipeline
  (classification, semantic ingest, arrangement reasoning, audio
  emotion, scene detection, visual frames). For script-driven content
  this is architectural overhead — script defines structure, no
  discovery needed. Lean scope: WhisperX + phrase snapping + prosody
  markers → single Opus call (script + transcript + prosody) →
  arrangement.yaml → ButterCut XML. Skip everything else.
  `--target-duration <mm:ss>` flag triggers tightened-script generation
  step.

- **B: Discovery cut from script + transcript classification** —
  Shipped. Full pipeline. Used for explainer/argumentative cuts where
  raw delivery roughly matches script intent.

- **C: Template extraction** — Future. Reverse-engineer format
  formulas from existing videos for reuse.

- **D: Pool mining, no script** — Shipped v4.0. Discovers arcs across
  multiple sources without script input. Validated on dbtest pool.

### Phase 2 (in flight)

Visual analysis layer. Frame extraction shipped (Session 1). LLM-based
shot classification populating visual_analysis schema pending
(Session 2). Pacing analysis and B-roll correlation later sessions.

## Bass (future)

Motion graphics finishing. Takes arrangement transcript, generates
on-brand visual treatment:

- Multi-item lists → bullet lists
- Key ideas → big text over A/B roll
- Diagrams → templates based on data presentation

Named after Saul Bass. (Originally considered Louise, no stature-
equivalent female motion graphics anchor surfaced in research.)

Output: Premiere-importable, not finished video. Editorial control
stays with the editor.

## Suite logic

Thelma cuts. Bass finishes. Shared intelligence backbone:

- Semantic taxonomy
- Format templates
- Tone profile per creator
- Performance memory (YouTube analytics feedback)

Strategist editorial perspective as differentiator vs engineering-built
AI editor tools.

## What this is not

- Not an AI video editor (no full-render output)
- Not a transcription tool (WhisperX is plumbing)
- Not a finishing-house replacement (strategist editorial layer only)
- Not audio mixing, music selection, subtitle generation

## Adjacent tools (parking lot, not active)

- Hook bank / opening generator
- Title/thumbnail iteration with performance memory + format taxonomy
- Layered editable thumbnail generator (PSD/Figma output) — flagged
  top-desired
- TAV estimator
- Script/shot generator from Branch C format formulas
- Performance feedback loop (YouTube analytics → tool memory)
- Riverside multi-track support (Phase 1.6 — deferred)
- Content librarian / external drive auto-tagging (v5)

## Productization framing

Content intelligence platform. Shared backbone, specialized tools as
interfaces. Strategist editorial layer is the moat.

## Active context

Independent operation. Primary use: Raffiti and Dylan client work.
Branch A refactor blocks upcoming cutdowns series — top priority.
