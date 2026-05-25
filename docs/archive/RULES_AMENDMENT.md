# CLAUDE_PROJECT_RULES.md Amendment

**Insert into the "Run session protocol" section, after the "Not allowed — ever — in a run session" list, before the "When a defect surfaces mid-run" paragraph.**

---

### LLM call failures during run sessions

Before declaring a defect when an LLM call fails (timeout, malformed output, empty response, billing/auth error), Claude Code must first check the `--llm-mode` in use.

If running in `api` mode:
- Timeout / 5xx / billing-auth error may be transient API issues, not a code defect.
- One re-run with same flags is allowed. Document the retry in the run log.
- If retry fails the same way, end run session, open dev session.
- If retry succeeds, continue normally and note the transient failure.

If running in `claude_code` mode (pending-file workflow):
- Verify the wrapping interactive `claude` session is still active and the pending file mechanism is working before declaring defect.
- A stuck pending file is not a Thelma defect; it's a wrapper-state issue. Resolve at the wrapper level.

If switching `--llm-mode` would resolve the failure cleanly (e.g., API quota exhausted, switching to claude_code mode bypasses it), this is allowed during a run session. It is NOT a code change, NOT a workaround — it is selecting an available infrastructure path. Document the mode switch in the run log.

If the failure persists across one retry and across both LLM modes, that IS a defect: end run session, open dev session, investigate.

This rule exists because LLM infrastructure issues look like code defects but aren't. Treating them as code defects burns dev sessions and obscures real bugs.

---

**No other changes to CLAUDE_PROJECT_RULES.md.**
