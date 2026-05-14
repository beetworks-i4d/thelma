# Known Issues

Open bugs deferred to future debugging sessions. **Do not debug these on
Dylan005** — it is a 49-minute multi-take longform recording, too large and
too noisy a fixture for incremental QA. Reproduce on a 3–5 minute
single-script test video instead, where any one cut is auditable end-to-end.

The Branch A pipeline's mechanical layer (timeline arithmetic, A/V sync,
overlap clamp, chapter assembly) is sound — verified on Dylan005 with the
final run on 2026-05-14: video span == audio span == WAV span (57402
frames), 0 per-clip duration divergence, constant 50-frame WAV offset, 0
substantive consecutive-pair overlaps, 24 chapters, 293 clipitems. The
remaining defects are arrangement-quality issues that surface only in
playback.

---

## 1. Phrase ends swallowed by cuts

**Symptom (Dylan005 Premiere QA):** The last word or syllable of a phrase
gets clipped at clip boundaries — the cut lands before the speech tail
fully decays.

**Likely cause:** The phrase-snap pass in `build_structure_cut.rb` is
either still under-buffering at the end of each clip, or snapping the end
to a speech segment boundary that lands before the natural breath. The
`END_BUFFER` (200ms) plus fallback path were tuned earlier in the session
but never empirically closed against an audible-cut test.

**Investigation status:** The snap behavior was probed twice during the
Dylan005 session and abandoned both times once other defects took priority
(overlap clamp, frame-rounding drift, prompt overlap-takes). It has not
been closed.

**Investigate against:** a short single-take recording with clearly audible
phrase tails. Check the actual end-frame against the audible end-of-phrase
sample. Specifically inspect cases where `snap_to_boundary` falls through
to the bare `END_BUFFER` fallback (`scripts/build_structure_cut.rb:445`) —
that path may be the one cutting tight.

**Do not patch on Dylan005.** Too many simultaneous mechanisms (snap,
clamp, sync offset, breathing room) to isolate any one of them in a 49-min
cut.

---

## 2. In-clip repetition (intra-span stutter)

**Symptom:** A single clip's `[t_in, t_out]` window contains an audible
stutter or repeated phrase — Dylan said the word, restarted, said it
again, and the cleaned transcript didn't catch the restart so both
deliveries are inside the same clip span.

**Likely cause:** Either `transcript_cleanup.rb` is not detecting and
trimming the false-start within a span, or `arrange_to_script.rb` is
choosing a span that happens to contain the stutter even when a cleaner
non-stuttered region of the same line is available.

**Distinct from issue #3:** This is an intra-span artifact (one clip,
duplicated audio inside its window), not a multi-clip overlap. The
overlap-clamp work earlier in this session addressed clip-to-clip
overlaps; this one is inside a single clip.

**Investigate against:** a recording where the speaker deliberately
stumbles on a known phrase mid-line then continues. Compare the cleaned
transcript word list to the audio, and trace whether `arrange_to_script`'s
take-selection scoring (STUMBLE / MID_BREAK / trailing-pause) was honored
or bypassed.

---

## 3. Residual outtakes selected

**Symptom:** A clip's chosen span includes a take that the speaker
explicitly flubbed and restarted — the LLM picked the bad take.

**Likely cause:** The prompt rewrite on 2026-05-14 added pick-exactly-one-
take and non-overlap rules, which eliminated overlapping-take clips at
the clip-window layer. But the underlying take-selection within a span
remains an LLM judgment call — when multiple takes of a line exist and
none is "obviously" stumble-free, the LLM can still pick a less-clean
one.

**Investigate against:** a recording with multiple deliberate takes of
each line, where one take is clearly clean and the others have obvious
stumbles. If the LLM picks a stumbled take when a clean one is in the
transcript, the take-selection criteria need sharpening — possibly with
explicit scoring per span fed into the prompt rather than relying on
LLM judgment.

---

## Suggested fixture

`~/Desktop/RAW/qa-shorts/` (does not exist yet) — a 3–5 minute test
recording with:
- 2 takes of a line where take 2 is clearly cleaner (tests #3)
- 1 line with a mid-phrase stutter and self-correction (tests #2)
- A phrase ending in a long held vowel or trailing consonant (tests #1)

Build it once, keep it as a regression fixture.
