# Thelma

**Make Claude your Video Editor**

[thelma.video](https://thelma.video)

Give Claude Code your video footage. Claude analyzes it, then builds roughcuts and sequences for Final Cut, Premiere, and Resolve.

Behind the scenes Claude uses Thelma Skills and a little Ruby library to generate timelines for your editor.

## Watch the Demo

[![I Taught Claude Code to Edit Movies](https://img.youtube.com/vi/FBkfr1yWf_s/maxresdefault.jpg)](https://www.youtube.com/watch?v=FBkfr1yWf_s)

*Click to watch "I Taught Claude Code to Edit Movies" on YouTube*

## Getting Started

[![Thelma Install Video](https://img.youtube.com/vi/BCMQzg-HiTw/maxresdefault.jpg)](https://www.youtube.com/watch?v=BCMQzg-HiTw)

*Click to watch the Thelma install video on YouTube*

**Clone Thelma:**
```bash
git clone https://github.com/barefootford/thelma.git && cd thelma
```

**Open Claude Code:**
```bash
claude

# or skip permission prompts (faster, but riskier):
claude --dangerously-skip-permissions
```

**Tell Claude to install Thelma:**
```
> Install Thelma
```

Claude will check your system and install any missing dependencies (Ruby, Python, FFmpeg, WhisperX).

For manual installation, see [docs/installation.md](docs/installation.md).

## Usage

First tell Claude to create a **Library**. A library organizes your video footage along with audio and visual transcripts. Then tell Claude you want to create a **rough cut** or **sequence**.

### Creating a Video Library

```plaintext
You: "I want to build a new library"

Claude: [Guides you through library setup and asks for details]

You:
  - Library name: "wedding"
  - Video location: "/path/to/videos"
  - Language: "English"

Claude: [Automatically processes all videos]
  ✓ Creates library structure
  ✓ Transcribes audio with WhisperX
  ✓ Analyzes video frames
  ✓ Generates visual transcripts

Result: Full footage analysis ready for rough cut creation
```

Claude handles the parallel processing, metadata extraction, and transcript generation. See the [full walkthrough](docs/example-library-setup.md) for a detailed example of me setting up a library from my wedding footage.

### Creating a Roughcut or Sequence

Once your library is analyzed, Claude can create rough cuts through an interactive conversation:

```plaintext
You: "Let's create a new roughcut"

Claude: [Loads roughcut skill and analyzes footage]
        What should this roughcut focus on?
        - Full story
        - Just the meetup coverage
        - Short teaser sequence

You: "Just the meetup coverage"

Claude: [Asks 3 preference questions]
        - Narrative structure? (chronological, thematic, hook-based)
        - Target duration? (1-2 min, 3-5 min, 6-10 min)
        - Pacing style? (fast & punchy, conversational, cinematic)

You: "Start with presentations (5 sec clips), then interviews,
      then my closing reflection. 3-5 minutes, conversational pacing."

Claude: [Asks which video editor you want to use]
        - Final Cut Pro X
        - Adobe Premiere Pro
        - DaVinci Resolve

You: "Final Cut Pro X"

Claude: [Creates roughcut with editorial decisions]
        ✓ Combined visual transcripts
        ✓ Selected 29 clips (4:32 total)
        ✓ Exported to FCPXML

Result: Ready-to-import timeline at:
        libraries/[library]/roughcuts/[name]_[datetime].fcpxml
```

Claude makes editorial decisions based on transcript analysis and your preferences, then exports a timeline for your editor.

### Speaker Diarization (Optional)

For multi-speaker content (podcasts, interviews, panels), Thelma can identify and label individual speakers using WhisperX's diarization feature. This is **optional** — the pipeline works without it.

**Setup:**

1. Sign up at [huggingface.co](https://huggingface.co)
2. Visit the [pyannote/speaker-diarization-3.1](https://huggingface.co/pyannote/speaker-diarization-3.1) model page and accept the terms
3. Generate an access token at Settings > Access Tokens
4. Set the environment variable:
   ```bash
   export HF_TOKEN=hf_your_token_here
   ```

When `HF_TOKEN` is set, Thelma automatically passes `--diarize` to WhisperX during transcription. Speaker labels appear as `SPEAKER_00`, `SPEAKER_01`, etc. in transcripts and carry through to arc discovery and arrangement.

Without `HF_TOKEN`, the pipeline runs normally — you'll see a note in the output that diarization was skipped. Single-speaker projects don't need this.

**Notes:**
- Speaker labels are generic (`SPEAKER_00`, `SPEAKER_01`) and don't reflect actual names
- You can specify source language explicitly with `--language pt` (or `en`, `es`, etc.) for better accuracy
- Generated metadata (chapter labels, key decisions) appears in English regardless of source language

### XML Generation

For direct XML generation without Claude Code, see [docs/basic-xml-generation.md](docs/basic-xml-generation.md).

## Thanks

Thelma was inspired by ambitious open source work from [Chris Hocking](https://github.com/CommandPost/CommandPost) and [Andrew Arrow](https://github.com/andrewarrow/cutlass/tree/main).

## License

MIT

## Contributing

Bug reports and pull requests welcome, with that said...

**Guidelines:**
- Write the body of your pull request or GitHub issue yourself. Don't use an agent (Claude Code, etc) to generate it.
- Keep pull requests small and limited to a single feature or bugfix at a time. It's a lot easier to write code, I feel like it's just as hard as before to review code.
