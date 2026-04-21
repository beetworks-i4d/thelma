# Thelma Quickstart

1. Put footage at `~/Desktop/RAW/<ProjectName>/` (B-roll in `B Roll/` subdir if any)
2. If new creator: `cp profiles/creators/ivan.yaml profiles/creators/<name>.yaml` and edit
3. Run:
   ```
   ruby scripts/orchestrate.rb --library <name> --profile <name> --llm-mode claude_code
   ```
4. When pipeline pauses (exit 2), fill `libraries/<name>/pending_llm_calls/<call>_response.yaml` and re-run
5. Approve at review gates: ingest summary (core understanding), arrangement (cut summary + key decisions)
6. Import `~/Desktop/RAW/<ProjectName>/output/<name>_arrangement_<timestamp>.xml` into Premiere
7. Polish in Premiere: compare V2 alt takes, trim remaining stumbles, drop B-roll on V3+, add music on A3+
8. Export

**Re-run a phase:** delete its output file (e.g., `rm libraries/<name>/semantic_ingest.yaml`) and re-run orchestrate.rb.

**Skip review gates:** add `--no-review` flag.

**Full reset:** `rm -rf libraries/<name>/` and start over.

Troubleshooting + full manual: [docs/SOP.md](SOP.md)
