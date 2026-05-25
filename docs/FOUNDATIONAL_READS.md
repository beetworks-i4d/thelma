# Foundational Reads Protocol

**Locked:** 2026-05-25

---

## Purpose

Prevent architecture drift by requiring Claude Code to read locked documents before any dev session that touches pipeline code.

---

## Required Reads

Before starting work on any dev session that modifies pipeline scripts, Claude Code MUST read these files in order:

### Tier 1 — Always (every dev session)

1. **`CLAUDE_PROJECT_RULES.md`** — Operating rules, session types, auth separation
2. **`docs/validator_invariants.md`** — Separation of concerns, boundary rules, LLM restrictions
3. **`docs/FOUNDATIONAL_READS.md`** — This file (protocol and lock rules)

### Tier 2 — When touching schemas or pipeline scripts

4. **`docs/schemas/editorial_candidate.schema.yaml`** — Candidate data model (v1.2)
5. **`docs/schemas/arrangement.schema.yaml`** — Arrangement data model (v4)

### Tier 3 — When touching editorial intelligence

6. **`docs/content_psychopharmacology.md`** — 15-state taxonomy, durability tiers, incompatible pairs
7. **`docs/MAIN_BRANCH_AUDIT.md`** — What main had, what dev lost, restoration sequence

### Tier 4 — When implementing a specific session

8. **`docs/SESSION_6_SPEC.md`** (or relevant session spec) — Implementation specification

---

## Locked Foundation Protocol

### What "locked" means

A locked document is the authoritative source of truth for its domain. When a locked document contradicts a non-locked document, a conversation, a memory, or Claude's training data, **the locked document wins**.

Locked documents are identified by:
- A `Locked: YYYY-MM-DD` header
- Presence in the `docs/schemas/` directory (all schemas are locked by default)
- Explicit mention in this protocol

### Current locked documents

| Document | Domain | Version |
|----------|--------|---------|
| `docs/schemas/editorial_candidate.schema.yaml` | Candidate data model | v1.2 |
| `docs/schemas/arrangement.schema.yaml` | Arrangement data model | v4 |
| `docs/validator_invariants.md` | Separation of concerns | 2026-05-25 |
| `docs/SESSION_6_SPEC.md` | Session 6 implementation | 2026-05-25 |
| `docs/FOUNDATIONAL_READS.md` | This protocol | 2026-05-25 |

### How to modify a locked document

1. **Identify the conflict.** State exactly what the locked document says and what you believe it should say instead.
2. **Do not silently override.** Never write code that contradicts a locked schema. Never reinterpret a schema field's meaning to fit your implementation.
3. **Propose the change explicitly.** Tell the user: "The locked schema says X. I need Y. This requires a schema amendment."
4. **Wait for approval.** The user must explicitly approve the amendment.
5. **Version bump.** Schema changes require incrementing the version number (e.g., v1.2 → v1.3).
6. **Update this file.** Add the new version to the locked documents table.

### What you may NOT do with a locked document

- Silently reinterpret field semantics to match your implementation
- Add undocumented fields to a schema ("it's just a small addition")
- Collapse two schema-distinct concepts into one ("they're basically the same")
- Skip reading a required document ("I already know what it says")
- Treat a locked decision as advisory ("the spec says X but Y is better")

---

## Architecture Drift Prevention

### Drift signals

If you notice any of these during a dev session, STOP and flag them:

1. **A script produces a field not in the schema.** The script is wrong, not the schema.
2. **A script skips a validation that the invariants require.** The script is wrong, not the invariants.
3. **An LLM prompt asks for data the invariants say LLMs may not produce.** The prompt is wrong.
4. **Two documents disagree on a data model.** The locked schema wins. Flag the other document for update.
5. **A "temporary workaround" bypasses a locked constraint.** There are no temporary workarounds to locked constraints. Fix the root cause or amend the lock.

### Drift response

When drift is detected:
1. Stop implementation work immediately
2. Report the exact contradiction: "File X line N says A. Locked doc Y says B."
3. Do not propose a resolution — report the conflict and let the user decide
4. Do not continue coding until the conflict is resolved

---

## Override / Escalation Procedure

### When the user explicitly overrides a locked decision

The user (Ivan) may override any locked decision. When this happens:

1. **Acknowledge the override explicitly.** "You're overriding the locked schema for editorial_candidate v1.2. The locked version says [X]. You want [Y]."
2. **Get written confirmation.** The user must confirm in writing (in the conversation).
3. **Update the locked document.** The override becomes the new locked state.
4. **Version bump.** If it's a schema, increment the version.
5. **Commit the amendment.** With message: `amend: [document] — [what changed and why]`

### When Claude believes a locked decision is wrong

1. **State the concern clearly.** "The locked invariant says LLMs may not produce timestamps. But Phase B needs to evaluate content_preserved, which requires understanding where a trim cuts into the text. This works because the LLM reads the text, not the timestamps — it evaluates semantic loss, not mechanical boundaries."
2. **Propose the minimum amendment.** Don't rewrite the document. Propose the smallest change that resolves the issue.
3. **Wait for approval.** Do not implement the change speculatively.

### When two locked documents contradict each other

1. **Flag both documents and the exact contradiction.**
2. **Do not pick a winner.** Let the user decide which document's intent takes precedence.
3. **After resolution, update the losing document** to align with the winning one.
