#!/usr/bin/env python3
"""Extract per-segment acoustic features from a WAV file using librosa.

Usage: python3 scripts/audio_emotion.py <wav_path> <segments_yaml> <output_yaml>

Reads segments_classified.yaml for segment boundaries (t/e fields).
Computes speaker baseline over the full recording, then per-segment features
relative to that baseline. Derives an audio_profile label from feature combos.

Output: YAML with baseline stats and per-segment acoustic features.
"""
import os
import sys
import yaml
import numpy as np

def load_segments(segments_path):
    """Load segments from classified YAML."""
    with open(segments_path, 'r') as f:
        data = yaml.safe_load(f)
    return data.get('segments', [])

def compute_baseline(y, sr, segments):
    """Compute speaker baseline over all speech segments."""
    import librosa

    # Collect all speech audio
    speech_chunks = []
    total_words = 0
    total_speech_dur = 0.0
    for seg in segments:
        t = float(seg['t'])
        e = float(seg['e'])
        s_start = int(t * sr)
        s_end = int(e * sr)
        if s_start >= len(y) or s_end > len(y):
            continue
        chunk = y[s_start:s_end]
        if len(chunk) > 0:
            speech_chunks.append(chunk)
            total_speech_dur += (e - t)
            # Estimate word count from text if available
            text = seg.get('text', seg.get('distillation', ''))
            total_words += len(text.split()) if text else 0

    if not speech_chunks:
        return None

    all_speech = np.concatenate(speech_chunks)

    # RMS energy baseline
    rms = librosa.feature.rms(y=all_speech)[0]
    rms_mean = float(np.mean(rms))

    # F0 pitch baseline via pyin
    f0, voiced, _ = librosa.pyin(all_speech, fmin=60, fmax=500, sr=sr)
    f0_valid = f0[~np.isnan(f0)] if f0 is not None else np.array([])
    f0_mean = float(np.mean(f0_valid)) if len(f0_valid) > 0 else 150.0

    # Spectral centroid baseline
    centroid = librosa.feature.spectral_centroid(y=all_speech, sr=sr)[0]
    centroid_mean = float(np.mean(centroid))

    # Speaking rate baseline (words/sec)
    speaking_rate = total_words / total_speech_dur if total_speech_dur > 0 else 3.0

    return {
        'rms_mean': rms_mean,
        'f0_mean': f0_mean,
        'centroid_mean': centroid_mean,
        'speaking_rate': speaking_rate,
        'total_speech_duration': round(total_speech_dur, 2),
        'total_words': total_words
    }

def compute_segment_features(y, sr, seg, baseline):
    """Compute acoustic features for a single segment."""
    import librosa

    t = float(seg['t'])
    e = float(seg['e'])
    s_start = int(t * sr)
    s_end = int(e * sr)

    if s_start >= len(y) or s_end > len(y) or s_end <= s_start:
        return None

    y_seg = y[s_start:s_end]
    seg_dur = e - t

    if len(y_seg) < sr * 0.1:  # Skip segments shorter than 100ms
        return None

    # RMS energy
    rms = librosa.feature.rms(y=y_seg)[0]
    rms_mean = float(np.mean(rms))
    energy = rms_mean / baseline['rms_mean'] if baseline['rms_mean'] > 0 else 1.0
    energy_variance = float(np.var(rms))

    # Energy trend (linear regression on RMS frames)
    if len(rms) > 2:
        x = np.arange(len(rms))
        slope = np.polyfit(x, rms, 1)[0]
        energy_trend = float(slope)
    else:
        energy_trend = 0.0

    # F0 pitch
    f0, voiced, _ = librosa.pyin(y_seg, fmin=60, fmax=500, sr=sr)
    f0_valid = f0[~np.isnan(f0)] if f0 is not None else np.array([])

    if len(f0_valid) > 0:
        pitch_mean = float(np.mean(f0_valid))
        pitch_range = float(np.max(f0_valid) - np.min(f0_valid))

        # Pitch trend via linear regression
        if len(f0_valid) > 2:
            x = np.arange(len(f0_valid))
            # Convert frame indices to time
            time_per_frame = seg_dur / len(f0) if len(f0) > 0 else 1.0
            slope_hz_per_frame = np.polyfit(x, f0_valid, 1)[0]
            slope_hz_per_sec = slope_hz_per_frame / time_per_frame if time_per_frame > 0 else 0
            if slope_hz_per_sec > 5:
                pitch_trend = 'rising'
            elif slope_hz_per_sec < -5:
                pitch_trend = 'falling'
            else:
                pitch_trend = 'flat'
        else:
            pitch_trend = 'flat'
    else:
        pitch_mean = baseline['f0_mean']
        pitch_range = 0.0
        pitch_trend = 'flat'

    # Speaking rate (relative to baseline)
    text = seg.get('text', seg.get('distillation', ''))
    word_count = len(text.split()) if text else 0
    seg_rate = word_count / seg_dur if seg_dur > 0 else 0
    speaking_rate = seg_rate / baseline['speaking_rate'] if baseline['speaking_rate'] > 0 else 1.0

    # Spectral centroid (relative to baseline)
    centroid = librosa.feature.spectral_centroid(y=y_seg, sr=sr)[0]
    centroid_mean = float(np.mean(centroid))
    spectral_centroid = centroid_mean / baseline['centroid_mean'] if baseline['centroid_mean'] > 0 else 1.0

    # Derive audio_profile from feature combinations
    audio_profile = derive_profile(energy, energy_variance, energy_trend,
                                    pitch_mean, pitch_range, pitch_trend,
                                    speaking_rate)

    # Derive acoustic_pattern from temporal shape
    acoustic_pattern = compute_acoustic_pattern(rms, energy, pitch_trend)

    return {
        't': t,
        'e': e,
        'energy': round(energy, 3),
        'energy_variance': round(energy_variance, 6),
        'pitch_mean': round(pitch_mean, 1),
        'pitch_trend': pitch_trend,
        'pitch_range': round(pitch_range, 1),
        'speaking_rate': round(speaking_rate, 3),
        'spectral_centroid': round(spectral_centroid, 3),
        'audio_profile': audio_profile,
        'acoustic_pattern': acoustic_pattern
    }

def _classify_contour(rms_frames):
    """Classify the energy contour shape from RMS frames into 3 time windows."""
    if len(rms_frames) < 3:
        return 'steady'

    n = len(rms_frames)
    third = n // 3
    w1 = float(np.mean(rms_frames[:third]))
    w2 = float(np.mean(rms_frames[third:2*third]))
    w3 = float(np.mean(rms_frames[2*third:]))

    mx = max(w1, w2, w3, 1e-10)
    r1, r2, r3 = w1 / mx, w2 / mx, w3 / mx

    thresh = 0.15

    if abs(r1 - r3) < thresh and r2 > r1 + thresh:
        return 'peaks-mid'
    if abs(r1 - r3) < thresh and r2 < r1 - thresh:
        return 'dips-mid'
    if r3 > r1 + thresh:
        if r2 > r1 + thresh:
            return 'rising'
        return 'builds-late'
    if r1 > r3 + thresh:
        if r2 < r1 - thresh:
            return 'falling'
        return 'fades-late'
    return 'steady'


def compute_acoustic_pattern(rms_frames, energy_relative, pitch_trend):
    """Compute a short acoustic pattern descriptor for a segment.

    Returns one of ~20 fixed vocabulary labels describing the temporal
    shape of the segment's delivery.
    """
    # Energy level relative to baseline
    if energy_relative < 0.75:
        level = 'low'
    elif energy_relative > 1.25:
        level = 'high'
    else:
        level = 'mid'

    contour = _classify_contour(rms_frames)

    if contour == 'steady':
        if level == 'low':
            return 'monotone low-energy' if pitch_trend == 'flat' else 'low-energy steady'
        elif level == 'high':
            return 'high-energy steady'
        else:
            if pitch_trend == 'flat':
                return 'even and measured'
            elif pitch_trend == 'rising':
                return 'measured rising pitch'
            else:
                return 'measured falling pitch'

    elif contour == 'rising':
        if level == 'high':
            return 'rising emphasis throughout'
        elif level == 'low':
            return 'low-energy rising'
        else:
            return 'building emphasis'

    elif contour == 'falling':
        if level == 'high':
            return 'opens strong fades out'
        elif level == 'low':
            return 'winding down'
        else:
            return 'trailing off'

    elif contour == 'peaks-mid':
        if level == 'high':
            return 'emphatic mid-peak'
        else:
            return 'opens flat peaks mid ends flat'

    elif contour == 'dips-mid':
        return 'dips mid then recovers'

    elif contour == 'builds-late':
        if level == 'high':
            return 'flat-then-emphatic'
        else:
            return 'builds to emphasis late'

    elif contour == 'fades-late':
        if level == 'high':
            return 'emphatic-then-flat'
        else:
            return 'fades out late'

    return 'even and measured'


def derive_profile(energy, energy_variance, energy_trend,
                   pitch_mean, pitch_range, pitch_trend, speaking_rate):
    """Derive audio_profile label from feature combinations."""
    # emphatic: high energy + wide pitch range + fast speaking
    if energy > 1.3 and pitch_range > 30 and speaking_rate > 1.1:
        return 'emphatic'

    # urgent: high energy + rising pitch + fast speaking
    if energy > 1.2 and pitch_trend == 'rising' and speaking_rate > 1.2:
        return 'urgent'

    # authoritative: high energy + narrow pitch range + normal rate
    if energy > 1.2 and pitch_range < 20 and 0.8 < speaking_rate < 1.2:
        return 'authoritative'

    # building: energy trend rising over segment
    if energy_trend > 0.001 and energy > 0.9:
        return 'building'

    # landing: energy trend falling over segment
    if energy_trend < -0.001 and energy > 0.9:
        return 'landing'

    # reflective: low energy + narrow pitch range + slow speaking
    if energy < 0.8 and pitch_range < 20 and speaking_rate < 0.9:
        return 'reflective'

    return 'casual'

def main():
    if len(sys.argv) != 4:
        print("Usage: python3 scripts/audio_emotion.py <wav_path> <segments_yaml> <output_yaml>",
              file=sys.stderr)
        sys.exit(1)

    wav_path = sys.argv[1]
    segments_path = sys.argv[2]
    output_path = sys.argv[3]

    if not os.path.exists(wav_path):
        print(f"WAV not found: {wav_path}", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(segments_path):
        print(f"Segments not found: {segments_path}", file=sys.stderr)
        sys.exit(1)

    import librosa

    print(f"Loading audio: {os.path.basename(wav_path)}", file=sys.stderr)
    y, sr = librosa.load(wav_path, sr=None)
    print(f"Audio: {len(y)/sr:.1f}s at {sr}Hz", file=sys.stderr)

    segments = load_segments(segments_path)
    if not segments:
        print("No segments found in classification", file=sys.stderr)
        sys.exit(1)

    print(f"Computing speaker baseline from {len(segments)} segments...", file=sys.stderr)
    baseline = compute_baseline(y, sr, segments)
    if baseline is None:
        print("Could not compute baseline (no valid speech found)", file=sys.stderr)
        sys.exit(1)

    print(f"Baseline — RMS: {baseline['rms_mean']:.4f}, F0: {baseline['f0_mean']:.1f}Hz, "
          f"Rate: {baseline['speaking_rate']:.1f} w/s", file=sys.stderr)

    # Process each segment
    segment_features = []
    for i, seg in enumerate(segments):
        feats = compute_segment_features(y, sr, seg, baseline)
        if feats:
            segment_features.append(feats)
        if (i + 1) % 10 == 0:
            print(f"  Processed {i+1}/{len(segments)} segments", file=sys.stderr)

    # Profile distribution
    profile_counts = {}
    for f in segment_features:
        p = f['audio_profile']
        profile_counts[p] = profile_counts.get(p, 0) + 1

    print(f"Processed {len(segment_features)}/{len(segments)} segments", file=sys.stderr)
    print(f"Profiles: {profile_counts}", file=sys.stderr)

    # Write output
    output = {
        'source_wav': os.path.basename(wav_path),
        'sample_rate': sr,
        'baseline': baseline,
        'profile_distribution': profile_counts,
        'segments': segment_features
    }

    os.makedirs(os.path.dirname(os.path.abspath(output_path)), exist_ok=True)
    with open(output_path, 'w') as f:
        yaml.dump(output, f, default_flow_style=False, sort_keys=False)

    print(output_path)

if __name__ == '__main__':
    main()
