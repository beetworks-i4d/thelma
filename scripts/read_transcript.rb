#!/usr/bin/env ruby
# Reads a WhisperX JSON transcript and prints formatted segments to stdout.
#
# Usage: ruby scripts/read_transcript.rb <transcript.json>
# Output: [MM:SS.ss - MM:SS.ss] text

require 'json'

path = ARGV[0]
abort "Usage: ruby scripts/read_transcript.rb <transcript.json>" unless path
abort "File not found: #{path}" unless File.exist?(path)

data = JSON.parse(File.read(path))
segments = data['segments'] || []
abort "No segments found in transcript" if segments.empty?

# Print metadata if available
if data['video_path']
  $stderr.puts "Source: #{File.basename(data['video_path'])}"
end

def fmt(seconds)
  m = (seconds / 60).floor
  s = seconds % 60
  format("%02d:%05.2f", m, s)
end

total_duration = 0.0
word_count = 0

segments.each do |seg|
  s = seg['start'].to_f
  e = seg['end'].to_f
  text = seg['text'].to_s.strip
  next if text.empty?

  total_duration = e if e > total_duration
  word_count += text.split.size
  puts "[#{fmt(s)} - #{fmt(e)}] #{text}"
end

# Summary stats to stderr so they don't pollute piped output
mins = (total_duration / 60).floor
secs = (total_duration % 60).round
$stderr.puts "---"
$stderr.puts "#{segments.size} segments | #{word_count} words | #{mins}:#{format('%02d', secs)} duration"
