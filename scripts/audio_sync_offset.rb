#!/usr/bin/env ruby
# Finds the sync offset between a video's scratch audio and an external audio
# file (WAV/FLAC/MP3) using FFT cross-correlation.
#
# Usage: ruby scripts/audio_sync_offset.rb <video_path> <audio_path> [library.yaml]
#
# Output: prints offset in seconds to stdout.
#   Positive = audio started BEFORE video (audio_time - offset = video_time)
#   Negative = audio started AFTER video  (video_time - |offset| = audio_time)
#
# If library.yaml is provided, caches the result under the matching video entry.

require 'fileutils'
require 'shellwords'
require 'yaml'
require 'date'
require 'json'

video_path = ARGV[0]
audio_path = ARGV[1]
library_yaml = ARGV[2]

abort "Usage: ruby scripts/audio_sync_offset.rb <video_path> <audio_path> [library.yaml]" unless video_path && audio_path
abort "Video not found: #{video_path}" unless File.exist?(video_path)
abort "Audio not found: #{audio_path}" unless File.exist?(audio_path)

# Check library.yaml cache first
if library_yaml && File.exist?(library_yaml)
  lib = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date])
  if lib && lib['videos']
    entry = lib['videos'].find { |v| v['path'] == video_path }
    if entry && entry['sync_audio'] && entry['sync_audio']['offset']
      cached = entry['sync_audio']['offset']
      $stderr.puts "Using cached offset from library.yaml: #{cached}s"
      puts cached
      exit 0
    end
  end
end

# Verify scipy is available
scipy_check = `python3 -c "import scipy" 2>&1`
unless $?.success?
  abort "scipy is required but not installed. Run: pip3 install scipy"
end

# Extract both to 16kHz mono WAV in tmp
pid = Process.pid
tmp_dir = "/Users/i4d/buttercut/tmp"
FileUtils.mkdir_p(tmp_dir)
video_wav = File.join(tmp_dir, "sync_video_#{pid}.wav")
audio_wav = File.join(tmp_dir, "sync_audio_#{pid}.wav")

# Get audio duration for segment selection
audio_duration = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{Shellwords.escape(audio_path)}`.strip.to_f
video_duration = `ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 #{Shellwords.escape(video_path)}`.strip.to_f

$stderr.puts "Extracting scratch audio from video (16kHz mono)..."
system("ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
       "-i", video_path, "-ar", "16000", "-ac", "1", video_wav)
abort "Failed to extract video audio" unless File.exist?(video_wav)

$stderr.puts "Converting audio file to 16kHz mono..."
system("ffmpeg", "-hide_banner", "-loglevel", "warning", "-y",
       "-i", audio_path, "-ar", "16000", "-ac", "1", audio_wav)
abort "Failed to convert audio file" unless File.exist?(audio_wav)

# Pick segment: 30% into the audio file, 30-second window
seg_start = (audio_duration * 0.3).round
seg_end = seg_start + 30
seg_end = [seg_end, audio_duration.to_i].min

# Search window: full video or 2x audio duration, whichever is smaller
search_end = [video_duration, audio_duration * 2].min.to_i

$stderr.puts "Cross-correlating: audio #{seg_start}-#{seg_end}s vs video 0-#{search_end}s..."

# Inline Python for scipy cross-correlation
python_script = <<~PYTHON
import numpy as np
from scipy.io import wavfile
from scipy.signal import fftconvolve
import sys

rate1, video = wavfile.read("#{video_wav}")
rate2, audio = wavfile.read("#{audio_wav}")
assert rate1 == rate2, f"Sample rate mismatch: {rate1} vs {rate2}"
rate = rate1

seg_s, seg_e = int(#{seg_start} * rate), int(#{seg_end} * rate)
audio_seg = audio[seg_s:seg_e].astype(np.float64)

search_end = min(int(#{search_end} * rate), len(video))
video_seg = video[0:search_end].astype(np.float64)

audio_seg /= (np.max(np.abs(audio_seg)) + 1e-10)
video_seg /= (np.max(np.abs(video_seg)) + 1e-10)

corr = fftconvolve(video_seg, audio_seg[::-1], mode='valid')
peak = np.argmax(corr)

video_time_at_seg = peak / rate
offset = #{seg_start} - video_time_at_seg

print(f"{offset:.6f}")
PYTHON

result = `python3 -c #{Shellwords.escape(python_script)} 2>&1`
unless $?.success?
  abort "Cross-correlation failed:\n#{result}"
end

offset = result.strip.to_f

# Clean up temp files
[video_wav, audio_wav].each { |f| File.delete(f) if File.exist?(f) }

# Human-readable summary to stderr
if offset.abs < 0.5
  $stderr.puts "Audio is essentially in sync (offset #{offset.round(3)}s)"
elsif offset > 0
  $stderr.puts "Audio started #{offset.round(3)}s BEFORE video"
  $stderr.puts "video_time = audio_time - #{offset.round(3)}"
else
  $stderr.puts "Audio started #{offset.abs.round(3)}s AFTER video"
  $stderr.puts "video_time = audio_time + #{offset.abs.round(3)}"
end

# Cache in library.yaml if provided
if library_yaml && File.exist?(library_yaml)
  lib = YAML.safe_load(File.read(library_yaml), permitted_classes: [Date])
  if lib && lib['videos']
    entry = lib['videos'].find { |v| v['path'] == video_path }
    if entry
      entry['sync_audio'] = {
        'path' => audio_path,
        'offset' => offset.round(6)
      }
      lib['last_updated'] = Date.today.to_s
      File.write(library_yaml, YAML.dump(lib))
      $stderr.puts "Cached offset in library.yaml"
    end
  end
end

# Print offset to stdout for script consumption
puts offset.round(6)
