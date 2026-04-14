# Emotion Markers — Editor Reference

Emotion markers encode audience emotional state data into Premiere Pro timeline markers. They appear automatically when classification data is available from the editorial pipeline.

## What They Look Like in Premiere

In Premiere's marker panel, each emotion marker has two fields:

**Marker Name (headline):**
```
vindication | system rigged but you win
```
Format: `primary_state | distillation` — the dominant emotional state and a 5-word summary of what the segment says.

**Marker Comment (payload):**
```
states: vindication(identity), curiosity(identity) | role: primary | signal: named target, specific claim | confidence: high | t=38.27
```
Pipe-separated structured data. Fields:
- **states** — all classified states with durability class in parentheses
- **role** — narrative role (primary, secondary, tertiary, unclassified)
- **signal** — what verbal/visual element triggers the emotional state
- **confidence** — high, medium, or low certainty of classification
- **t** — source timestamp (seconds) for cross-referencing transcript

## Durability Classes

Each state has a durability class that tells you how long the emotional effect lasts:

| Durability | Duration | Music/SFX Cue | Example |
|---|---|---|---|
| **spike** | 1-3 seconds | High-energy stinger, whoosh, impact hit | Surprise reveal, shocking number |
| **mood** | 10-60 seconds | Sustained underscore, ambient bed | Story arc, emotional buildup |
| **identity** | Persistent | Brand theme, signature sound | Core belief, identity statement |

### Scoring Cues by Durability

- **spike** — Layer a short, punchy SFX or music hit. Think: bass drop, record scratch, ding. Match the energy of the state (curiosity spike = rising tone; fear spike = tension hit).
- **mood** — Start or shift a background music bed. The underscore should sustain through the segment and transition smoothly at the next marker. Match the valence: positive states (aspiration, competence) = major key; negative (fear, outrage) = minor key or tension.
- **identity** — These are the money moments. Consider the brand's signature sound or a distinctive musical motif. These moments anchor the viewer's memory of the content.

## B-Roll Pacing by State

Use the primary state to guide B-roll selection and pacing:

| State | B-Roll Type | Pacing |
|---|---|---|
| **curiosity** | Information graphics, text overlays, question marks | Fast cuts, 1-2s each |
| **aspiration** | Success imagery, lifestyle shots, results | Slow, cinematic, 3-5s holds |
| **competence** | Process shots, tools, frameworks, diagrams | Medium pace, clear visual hierarchy |
| **vindication** | Before/after, proof, receipts | Hold on proof, let it land |
| **fear** | Problem imagery, consequences, warnings | Quick cuts to build tension |
| **belonging** | People, community, shared experiences | Warm, lingering shots |
| **amusement** | Reaction shots, absurd visuals | Snappy timing, comedic beats |
| **outrage** | The offending thing, news clips, evidence | Documentary style, deadpan |
| **schadenfreude** | The target failing, ironic juxtaposition | Slow-mo or freeze frame for emphasis |
| **awe** | Scale shots, nature, impressive feats | Wide, slow, let the image breathe |
| **catharsis** | Resolution imagery, relief, breakthrough | Slow dissolves, exhale pacing |
| **nostalgia** | Archival, retro styling, warm tones | Fade transitions, gentle pace |
| **escape** | Travel, fantasy, open spaces | Sweeping movement, drone shots |
| **calm** | Still life, nature, minimal compositions | Very slow, almost meditative |
| **sensual** | Texture, close-ups, rich color | Smooth, deliberate movement |

## When Markers Are Absent

Emotion markers are automatically skipped in these cases:
- **No classification file** — fast mode builds, or classification hasn't been run yet
- **Branch A (script-driven)** — these have `segments_used` instead of `segments`, so emotion markers don't apply. Branch A classifications describe beat matching, not per-segment emotions.
- **`--no-emotion-markers` flag** — explicitly suppressed at build time

In all these cases, other markers (TITLE, B-ROLL, TRANSITION, SFX, MUSIC, NOTE) are unaffected.

## Color

All emotion markers use **purple** — matching the SFX marker category. This distinguishes them from editorial markers (blue, green, orange, red, yellow) in the timeline.
