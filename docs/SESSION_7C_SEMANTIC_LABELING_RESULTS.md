# Session 7C — Semantic Labeling Quality Results

**Date:** 2026-05-26
**Branch:** dev
**Baseline:** 121 examples, 0 failures (pre-change). 140 examples, 0 failures (post-change, +19 new tests).

---

## Problem

Phase B mock labeling used simple profile-to-label mappings:
- `casual` profile → aside/transition roles, amusement state
- `emphatic` profile → claim/hook roles, vindication/competence states
- Energy alone determined priority (high→primary, medium→secondary, low→tertiary)

This collapsed 61% of candidates to identical labels regardless of what they actually said.

## Approach

Replaced profile-only mappings with multi-signal heuristics using:
- **Transcript text** — regex patterns detecting claims, questions, narratives, system critique, empowerment, transitions, conclusions, reframes, self-deprecation
- **Punctuation** — question marks, sentence structure
- **Rhetorical markers** — "Here's how", "Nobody tells you", "The thing is", "Every time you"
- **Prosody + text alignment** — emphatic delivery WITH claim language scores higher than emphatic alone
- **Duration** — short punchy claims vs. long evidence segments
- **Candidate position** — used for payoff likelihood at end of sequence

No LLM calls. No external dependencies. Fully deterministic.

## Before/After: Role Distribution

| Role | Before | After | Delta |
|------|--------|-------|-------|
| aside | 27 | 1 | -26 |
| transition | 27 | 6 | -21 |
| claim | 11 | 18 | +7 |
| hook | 11 | 5 | -6 |
| evidence | 1 | 13 | +12 |
| continuation | 0 | 14 | +14 |
| payoff | 5 | 11 | +6 |
| setup | 1 | 6 | +5 |

**aside** dropped from 27 to 1. **evidence** went from 1 to 13. Role vocabulary now uses 8 distinct types instead of being dominated by aside/transition.

## Before/After: State Distribution

| State | Before | After | Delta |
|-------|--------|-------|-------|
| amusement | 27 | 9 | -18 |
| vindication | 11 | 15 | +4 |
| competence | 12 | 13 | +1 |
| aspiration | 1 | 11 | +10 |
| catharsis | 5 | 7 | +2 |
| curiosity | 0 | 5 | +5 |
| outrage | 0 | 4 | +4 |
| calm | 0 | 2 | +2 |
| fear | 0 | 2 | +2 |

Before: 3 state types used. After: 9 state types used. **amusement** dropped from 61% to 13%.

## Before/After: Priority Distribution

| Priority | Before | After | Delta |
|----------|--------|-------|-------|
| primary | 13 | 19 | +6 |
| secondary | 24 | 21 | -3 |
| tertiary | 7 | 4 | -3 |

**pause_heavy** went from 0 primary to 3 primary. **low_energy** went from 1 primary to 3 primary.

## Before/After: Durability Distribution

| Durability | Before | After | Delta |
|------------|--------|-------|-------|
| spike | 27 | 9 | -18 |
| mood | 16 | 20 | +4 |
| identity | 1 | 15 | +14 |

**identity** went from 1 to 15 — empowerment/framework/teaching content now correctly gets lasting durability.

## Before/After: Confidence Distribution

| Confidence | Before | After | Delta |
|------------|--------|-------|-------|
| high | 35 | 14 | -21 |
| medium | 9 | 23 | +14 |
| low | 0 | 7 | +7 |

Previously 80% got high confidence. Now calibrated: short ambiguous fragments get low, mixed-signal candidates get medium.

---

## Per-Probe Examples

### emphatic_rant — strongest improvement

| ID | Text (excerpt) | Before | After |
|----|----------------|--------|-------|
| cand_002 | "Have you been told you ask too many questions?" | aside/amusement | evidence/vindication+curiosity |
| cand_004 | "Nobody tells you this growing up..." | aside/amusement | evidence+setup/outrage+fear+competence |
| cand_005 | "Every time you say I'm not a business person" | aside/amusement | claim(high)/vindication+aspiration |
| cand_007 | "What do you actually think a business person does?" | aside/amusement | hook/curiosity+amusement |

All 4 casual candidates now have differentiated, contextually appropriate labels instead of identical aside/amusement.

### pause_heavy_transition — most dramatic rescue

Before: 0 primary candidates, ALL aside/transition, ALL amusement.

| ID | Text (excerpt) | Before | After |
|----|----------------|--------|-------|
| cand_004 | "the problem is most people never do... permission" | tertiary/aside/amusement | primary/claim+payoff/aspiration+vindication |
| cand_005 | "the system we're thrown into from birth trains us" | secondary/aside/amusement | primary/claim+payoff/vindication+outrage |
| cand_006 | "The people that get results take action" | secondary/aside/amusement | primary/claim(high)/aspiration+vindication |
| cand_007 | "most people will never give themselves permission..." | tertiary/aside/amusement | tertiary/evidence/aspiration+fear+outrage |

System critique gets outrage. Empowerment gets aspiration. Permission-giving gets identity durability. The arranger now has 3 primary candidates to work with.

### low_energy_reflective — claim detection through text

| ID | Text (excerpt) | Before | After |
|----|----------------|--------|-------|
| cand_003 | "Same person, different output... problem was never me" | tertiary/aside/amusement | secondary/payoff/vindication+catharsis+calm |
| cand_004 | "You don't need more discipline" | tertiary/aside/amusement | primary/claim+hook/vindication |
| cand_005 | "conditioning runs so deep... from birth" | secondary/aside/amusement | primary/claim+payoff/outrage |

The reframe "You don't need X. You need Y" now correctly triggers primary/claim even with casual/low prosody.

---

## Remaining Obviously Wrong Classifications

1. **cand_001 in emphatic_rant**: "getting good at your job makes your boss's boss rich and getting good at running something makes you rich." Gets `aspiration` but should be `vindication+competence`. The EMPOWERMENT_PATTERNS match "makes you rich" → aspiration, but the candidate is really about vindication (proving the point). The text analysis doesn't distinguish "empowerment for the listener" from "vindication for the speaker."

2. **cand_003 in pause_heavy**: "you have enough information to get results" gets `continuation(low)` but should be `claim`. The text matches EMPOWERMENT_PATTERNS (aspiration state) but the role classifier doesn't score it as claim because the specific patterns don't match ("you have enough information" isn't in CLAIM_PATTERNS). A real LLM would recognize this as a direct claim.

3. **cand_006 in low_energy**: "when you turn 18, you become an adult. You have total control over your life" gets `tertiary/continuation`. The empowerment patterns match for states (aspiration) but the overall signal is weak — no claim patterns fire, short duration doesn't help. A human editor would see this as evidence or setup.

4. **cand_006 in emphatic_rant**: "But let me ask you something." gets `primary` despite being a 1.34s transition fragment with no standalone editorial value. The emphatic profile + "let me ask" question pattern over-fires. The min-duration filter in mock_arrange catches this (1.34s < 1.5s), but the labels themselves overvalue it.

5. **dead_air_setup** candidates: Pre-recording chatter ("OK so", "Video recording", "Oh come on come on") gets varied states (amusement, catharsis) when none of these are editorial content. No mechanism to detect non-editorial speech.

---

## Where Deterministic Heuristics Hit Limits

### 1. Irony and context
"What do you actually think a business person does all day? Because I can tell you right now, it's a lot more boring than you're picturing." — The question is rhetorical, the "boring" is ironic (the speaker means business is simpler than you think, not literally boring). The heuristic correctly gives curiosity+amusement, but misses the vindication frame underneath.

### 2. Multi-beat candidates
cand_004 in emphatic_rant (22.9s) contains system critique → personal history → career advice → aphorism. The heuristics capture the critique (outrage) but can't represent the arc within a single candidate. A real LLM would write a summary capturing the progression.

### 3. Claim vs. evidence distinction
"I used to think I was lazy... four hours building without looking at the clock" — Is this a claim (about motivation) or evidence (for the claim that the right work doesn't need discipline)? The heuristic sees personal narrative → evidence. The real answer depends on context within the larger argument.

### 4. Hook quality judgment
The heuristic can detect hook-shaped language (questions, reframes) but can't judge whether it's a *good* hook. "Here's how I evaluate any business model" is a strong hook because of the promise. "And how it actually went" has similar patterns but is meaningless without context.

### 5. Empowerment vs. vindication
"makes you rich" and "makes you dangerous" trigger the same empowerment pattern, but the emotional quality is different. "Dangerous" carries vindication (reclaiming a negative). "Rich" is aspiration. The regex can't distinguish these semantic nuances.

### 6. Non-editorial content
No text pattern can reliably distinguish pre-recording chatter ("OK so", "come on") from editorial transitions. This requires understanding recording context.

---

## What Clearly Requires Real Semantic Reasoning Later

1. **Summary quality** — Picking the most informative sentence is better than first-sentence truncation, but real summaries need to capture the *point* of multi-sentence candidates, not just quote a sentence.

2. **Claim/evidence in context** — Whether a personal story is evidence depends on what argument it supports. This requires seeing the broader narrative structure.

3. **Alternate-take preference** — Cluster dedup picks first-encountered, but a real LLM would compare delivery quality and content completeness between takes.

4. **Non-editorial detection** — dead_air chatter needs contextual understanding to distinguish from editorial content.

5. **Irony and subtext** — Rhetorical questions, sarcasm, and counterintuitive framing all require understanding speaker intent.

---

## Test Coverage (19 new tests)

| Category | Tests | Assertions |
|----------|-------|------------|
| Role diversity | 3 | aside doesn't dominate, pause_heavy has 3+ role types, not all aside/transition |
| Emphatic claims become hooks/claims | 2 | cand_003 in emphatic_rant, cand_001 in low_energy |
| Evidence detection | 2 | Personal narrative, number-heavy candidates |
| Transition detection | 1 | Short bridge text |
| State diversity | 4 | pause_heavy not all amusement, emphatic has vindication, low_energy has calm/catharsis, system critique gets outrage |
| Priority distribution | 2 | pause_heavy has 1+ primary, low_energy has 2+ primary |
| Durability calibration | 2 | Not all spike, empowerment text gets mood/identity |
| Confidence calibration | 2 | Not all high, short fragments get medium/low |
| Determinism | 1 | Consecutive runs produce identical output |

All 140 tests pass (121 existing + 19 new). 0 failures.
