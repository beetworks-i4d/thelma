#!/usr/bin/env python3
"""Run Silero VAD on an audio or video file and output speech segments as JSON.

Usage: python3 scripts/audio_analysis.py <input_path> <output_json>

If given a video file, extracts audio to a temp 16kHz mono WAV first.
Outputs JSON with speech_segments and long_pauses (gaps > 300ms).
"""
import json
import os
import subprocess
import sys
import tempfile

SAMPLE_RATE = 16000
PAUSE_THRESHOLD = 0.3  # seconds — gaps longer than this are "long pauses"

AUDIO_EXTENSIONS = {'.wav', '.flac', '.mp3', '.aac', '.ogg', '.m4a'}

def is_audio_file(path):
    return os.path.splitext(path)[1].lower() in AUDIO_EXTENSIONS

def extract_audio(input_path, output_wav):
    """Extract audio from video to 16kHz mono WAV."""
    cmd = [
        'ffmpeg', '-hide_banner', '-loglevel', 'warning', '-y',
        '-i', input_path,
        '-ar', str(SAMPLE_RATE), '-ac', '1',
        output_wav
    ]
    subprocess.run(cmd, check=True)

def load_wav_as_tensor(wav_path):
    """Load 16kHz mono WAV as a torch tensor (avoids torchaudio/torchcodec)."""
    import torch
    from scipy.io import wavfile
    import numpy as np

    rate, data = wavfile.read(wav_path)
    assert rate == SAMPLE_RATE, f"Expected {SAMPLE_RATE}Hz, got {rate}Hz"
    # Normalize to float32 [-1, 1]
    if data.dtype == np.int16:
        data = data.astype(np.float32) / 32768.0
    elif data.dtype == np.int32:
        data = data.astype(np.float32) / 2147483648.0
    elif data.dtype == np.float32:
        pass
    else:
        data = data.astype(np.float32)
    return torch.from_numpy(data)

def run_vad(wav_path):
    """Run Silero VAD and return speech segments."""
    from silero_vad import load_silero_vad, get_speech_timestamps

    model = load_silero_vad()
    audio = load_wav_as_tensor(wav_path)
    timestamps = get_speech_timestamps(audio, model, sampling_rate=SAMPLE_RATE)

    segments = []
    for ts in timestamps:
        segments.append({
            'start': round(ts['start'] / SAMPLE_RATE, 3),
            'end': round(ts['end'] / SAMPLE_RATE, 3),
        })
    return segments

def find_long_pauses(segments):
    """Identify gaps > PAUSE_THRESHOLD between consecutive speech segments."""
    pauses = []
    for i in range(1, len(segments)):
        gap_start = segments[i - 1]['end']
        gap_end = segments[i]['start']
        duration = round(gap_end - gap_start, 3)
        if duration > PAUSE_THRESHOLD:
            pauses.append({
                'start': gap_start,
                'end': gap_end,
                'duration': duration,
            })
    return pauses

def main():
    if len(sys.argv) != 3:
        print("Usage: python3 scripts/audio_analysis.py <input_path> <output_json>", file=sys.stderr)
        sys.exit(1)

    input_path = sys.argv[1]
    output_json = sys.argv[2]

    if not os.path.exists(input_path):
        print(f"Input not found: {input_path}", file=sys.stderr)
        sys.exit(1)

    tmp_wav = None
    try:
        if is_audio_file(input_path):
            # Audio file — convert to 16kHz mono WAV for Silero
            tmp_fd, tmp_wav = tempfile.mkstemp(suffix='.wav', prefix='vad_')
            os.close(tmp_fd)
            print(f"Converting to 16kHz mono: {os.path.basename(input_path)}", file=sys.stderr)
            extract_audio(input_path, tmp_wav)
            wav_path = tmp_wav
        else:
            # Video file — extract audio
            tmp_fd, tmp_wav = tempfile.mkstemp(suffix='.wav', prefix='vad_')
            os.close(tmp_fd)
            print(f"Extracting audio from video: {os.path.basename(input_path)}", file=sys.stderr)
            extract_audio(input_path, tmp_wav)
            wav_path = tmp_wav

        print("Running Silero VAD...", file=sys.stderr)
        segments = run_vad(wav_path)
        pauses = find_long_pauses(segments)

        result = {
            'source_file': os.path.abspath(input_path),
            'sample_rate': SAMPLE_RATE,
            'speech_segments': segments,
            'long_pauses': pauses,
        }

        os.makedirs(os.path.dirname(os.path.abspath(output_json)), exist_ok=True)
        with open(output_json, 'w') as f:
            json.dump(result, f, indent=2)

        print(f"Speech segments: {len(segments)}", file=sys.stderr)
        print(f"Long pauses: {len(pauses)}", file=sys.stderr)
        print(output_json)

    finally:
        if tmp_wav and os.path.exists(tmp_wav):
            os.unlink(tmp_wav)

if __name__ == '__main__':
    main()
