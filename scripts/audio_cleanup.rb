#!/usr/bin/env ruby
# Audio cleanup script: extracts audio from video, applies noise reduction
# and loudness normalization, outputs a treated WAV file for transcription.
#
# Usage: ruby scripts/audio_cleanup.rb <input_video> <output_dir>
# Output: <output_dir>/<basename>_treated.wav

require 'fileutils'
require 'json'

input = ARGV[0]
output_dir = ARGV[1]

abort "Usage: ruby scripts/audio_cleanup.rb <input_video> <output_dir>" unless input && output_dir
abort "Input file not found: #{input}" unless File.exist?(input)

FileUtils.mkdir_p(output_dir)

basename = File.basename(input, File.extname(input))
output = File.join(output_dir, "#{basename}_treated.wav")

if File.exist?(output)
  puts "Already exists: #{output}"
  exit 0
end

puts "Analyzing loudness: #{File.basename(input)}..."

# Pass 1: Measure loudness
require 'shellwords'
quoted_input = Shellwords.escape(input)
loudness_cmd = "ffmpeg -hide_banner -i #{quoted_input} -af loudnorm=I=-16:TP=-1.5:LRA=11:print_format=json -f null -"

stderr_output = `#{loudness_cmd} 2>&1`
# Extract the JSON block from ffmpeg output
json_match = stderr_output.match(/\{[^}]*"input_i"[^}]*\}/m)
abort "Failed to analyze loudness" unless json_match

stats = JSON.parse(json_match[0])

puts "Applying audio cleanup: normalization + highpass filter..."

# Pass 2: Apply measured normalization + gentle highpass to reduce rumble
filter = [
  "highpass=f=80",
  "loudnorm=I=-16:TP=-1.5:LRA=11:" \
    "measured_I=#{stats['input_i']}:" \
    "measured_TP=#{stats['input_tp']}:" \
    "measured_LRA=#{stats['input_lra']}:" \
    "measured_thresh=#{stats['input_thresh']}:" \
    "offset=#{stats['target_offset']}:" \
    "linear=true"
].join(',')

system("ffmpeg", "-hide_banner", "-loglevel", "warning",
       "-i", input,
       "-af", filter,
       "-ar", "16000", "-ac", "1",
       output)

abort "Audio cleanup failed" unless File.exist?(output)
puts "Done: #{output}"
