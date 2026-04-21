# Thelma Pipeline

## Pipeline Phases

| Phase | Script | Input | Output | LLM? |
|-------|--------|-------|--------|------|
| 1a | `audio_cleanup.rb` | raw video | treated WAV | No |
| 1b | WhisperX (inline) | treated WAV | transcript JSON | No |
| 1c | `audio_sync_offset.rb` | video + audio | sync offset | No |
| 1d | `audio_analysis.rb` | audio/video | speech_analysis JSON | No |
| 1e | `transcript_cleanup.rb` | transcript JSON | cleaned transcript | No |
| 0 | `detect_content_type.rb` | library.yaml | content_type in library.yaml | No |
| 1.5 | classification (inline) | transcript | segments_classified.yaml | Yes |
| 1.5c | `audio_emotion.rb` | WAV + classification | audio_features.yaml | No |
| 1.5d | `detect_scenes.rb` + `extract_visual_frames.rb` | video | scene_changes.yaml + visual_frames.yaml | No |
| 2 | `semantic_ingest.rb` | transcripts + classification | semantic_ingest.yaml | Yes |
| 3 | `arrange.rb` | semantic_ingest.yaml + classification | arrangement.yaml | Yes |
| 4 | `export_arrangement_xml.rb` + `build_structure_cut.rb` | arrangement.yaml | Premiere XML | No |
| 5 | `export_packaging_brief.rb` | classification + XML | packaging_brief.md | Yes |

## Running Orchestrated

```
ruby scripts/orchestrate.rb --library <name> [--profile <name>] [--llm-mode api|claude_code] [--no-review]
```

Each phase checks for cached output and skips if present. Delete cached files to force re-run.

### Flags

| Flag | Purpose |
|------|---------|
| `--library <name>` | Library name (resolves to `libraries/<name>/`) |
| `--profile <name>` | Creator profile (resolves to `profiles/creators/<name>.yaml`) |
| `--llm-mode api\|claude_code` | LLM execution mode (default: auto-detect from `ANTHROPIC_API_KEY`) |
| `--no-review` | Skip interactive review gates on semantic_ingest and arrange |
| `--analyze-only` | Run analysis phases only (1-1.5d + Branch C report), no arrangement/export |

## Running Individual Scripts

Each pipeline script accepts `--library <name>` and `--profile <name>`:

```
ruby scripts/semantic_ingest.rb --library <name> [--profile <name>] [--llm-mode api|claude_code] [--no-review]
ruby scripts/arrange.rb --library <name> [--profile <name>] [--llm-mode api|claude_code] [--no-review]
ruby scripts/export_arrangement_xml.rb --library <name> [--profile <name>]
ruby scripts/export_packaging_brief.rb --library <name> [--output <xml-path>] [--profile <name>] [--llm-mode api|claude_code]
```

## Claude Code Mode

When `--llm-mode claude_code` is set (or no `ANTHROPIC_API_KEY` is available), LLM calls write pending files and exit with code 2.

### Pending/Response File Flow

```
libraries/<name>/pending_llm_calls/
  <call_name>.yaml              <- prompt (written by script)
  <call_name>_response.yaml     <- response (written by Claude Code)
```

**Response file format:**
```yaml
response: |
  <LLM response text here>
```

Fill the response file and re-run the same command. The script picks up from where it left off.

### Batched Pending Calls

`export_packaging_brief.rb` writes all pending files (thumbnail + title) in a single run before exiting 2. Fill both response files and re-run once.

## Resuming from a Specific Phase

Delete the output file for the phase you want to re-run, then re-run `orchestrate.rb`. Earlier phases skip (cached), and the pipeline resumes from the missing output.

| To re-run | Delete |
|-----------|--------|
| Classification | `segments_classified.yaml` |
| Semantic ingest | `semantic_ingest.yaml` |
| Arrangement | `arrangement.yaml` |
| XML export | (always regenerates with new timestamp) |
| Packaging brief | `*_packaging_brief.md` in output/ |

Also delete `pending_llm_calls/*_response.yaml` files for the relevant call if you want to re-prompt.

## Cache Strategy

- **File-based:** Phase skips if output file exists and is non-empty
- **Hash-based:** Classification checks MD5 of transcript content; re-runs if transcript changed
- **Semantic ingest:** Checks MD5 of transcript content + format string
- **Arrangement:** Checks MD5 of semantic_ingest.yaml content + target_format
