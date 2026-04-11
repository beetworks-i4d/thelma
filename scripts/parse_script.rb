#!/usr/bin/env ruby
# Parses a script file (.txt, .md, .pdf, .docx) into a structured YAML
# with beats (hook, talking_point, close) for each short.
#
# Usage: ruby scripts/parse_script.rb <script_file> [output_dir]
# Output: script_parsed.yaml in output_dir (or same dir as input), path to stdout
#
# Supported formats:
#   .txt, .md  → File.read (native Ruby)
#   .pdf       → pdftotext (must be installed)
#   .docx      → pandoc --to plain (must be installed)
#
# Caching: skips re-parse if script_parsed.yaml exists and source_hash matches.

require 'yaml'
require 'digest'

def fmt(msg) = $stderr.puts(msg)

path = ARGV[0]
output_dir = ARGV[1]
abort "Usage: ruby scripts/parse_script.rb <script_file> [output_dir]" unless path
abort "File not found: #{path}" unless File.exist?(path)

output_dir ||= File.dirname(path)
output_path = File.join(output_dir, "script_parsed.yaml")
source_hash = Digest::MD5.hexdigest(File.read(path))

# Cache check
if File.exist?(output_path)
  existing = YAML.safe_load(File.read(output_path), permitted_classes: [Symbol]) rescue nil
  if existing && existing['source_hash'] == source_hash
    fmt "Cache hit — script_parsed.yaml is current (hash #{source_hash[0..7]})"
    puts output_path
    exit 0
  end
end

# Extract plain text based on format
ext = File.extname(path).downcase
text = case ext
when '.txt', '.md'
  File.read(path, encoding: 'utf-8')
when '.pdf'
  bin = `which pdftotext 2>/dev/null`.strip
  bin = '/opt/homebrew/bin/pdftotext' if bin.empty? && File.exist?('/opt/homebrew/bin/pdftotext')
  abort "pdftotext not found. Install with: brew install poppler" if bin.empty?
  `"#{bin}" "#{path}" -`
when '.docx'
  bin = `which pandoc 2>/dev/null`.strip
  abort "pandoc not found. Install with: brew install pandoc" if bin.empty?
  `"#{bin}" --to plain "#{path}"`
else
  abort "Unsupported format: #{ext} (supported: .txt, .md, .pdf, .docx)"
end

# Normalize: join pdftotext line-wrapped sentences, clean bullet chars
lines = text.lines.map { |l| l.gsub(/[●​•◦▪▸]\s*/, '').rstrip }

# Detect multi-short format: lines matching #N "title" or #N "title"
multi_short = lines.any? { |l| l.match?(/^#\d+\s+[""\u201C]/) }

result = { 'source_file' => File.basename(path), 'source_hash' => source_hash }

if multi_short
  result['format'] = 'multi_short'
  sections = []
  shorts = []
  current_section = nil
  current_short = nil
  current_beat = nil
  in_talking_points = false

  lines.each do |line|
    stripped = line.strip
    next if stripped.empty?

    # Section header: ALL-CAPS line that isn't a beat label and isn't a short number
    if stripped.match?(/^[A-Z][A-Z\s]{2,}$/) && !stripped.match?(/^(HOOK|CLOSE|TALKING POINTS):?$/)
      current_section = stripped.strip
      sections << { 'name' => current_section, 'shorts' => [] }
      next
    end

    # Short boundary: #N "title" (handles smart quotes)
    if (m = stripped.match(/^#(\d+)\s+["""\u201C](.+?)["""\u201D]\.?\s*$/))
      current_short = { 'number' => m[1].to_i, 'title' => m[2], 'section' => current_section, 'beats' => [] }
      shorts << current_short
      sections.last['shorts'] << m[1].to_i if sections.last
      current_beat = nil
      in_talking_points = false
      next
    end

    next unless current_short

    # Beat labels
    if stripped.match?(/^HOOK:\s*/i)
      in_talking_points = false
      current_beat = { 'role' => 'hook', 'text' => stripped.sub(/^HOOK:\s*/i, '') }
      current_short['beats'] << current_beat
    elsif stripped.match?(/^TALKING POINTS:\s*/i)
      in_talking_points = true
      current_beat = nil
    elsif stripped.match?(/^CLOSE:\s*/i)
      in_talking_points = false
      current_beat = { 'role' => 'close', 'text' => stripped.sub(/^CLOSE:\s*/i, '') }
      current_short['beats'] << current_beat
    elsif current_short['beats'].empty?
      # Text before first beat label — continuation of title or preamble, skip
    elsif in_talking_points
      # In TALKING POINTS section: each new line starts a new talking_point beat,
      # but pdftotext wraps long lines — detect continuation by checking if the
      # previous beat text ends without terminal punctuation
      if current_beat && !current_beat['text'].match?(/[.!?]$/)
        current_beat['text'] = "#{current_beat['text']} #{stripped}"
      else
        current_beat = { 'role' => 'talking_point', 'text' => stripped }
        current_short['beats'] << current_beat
      end
    elsif current_beat
      # Continuation of previous beat text (pdftotext line wrapping)
      current_beat['text'] = "#{current_beat['text']} #{stripped}"
    end
  end

  result['sections'] = sections
  result['shorts'] = shorts

  fmt "Parsed #{shorts.size} shorts across #{sections.size} sections"
  shorts.each { |s| fmt "  ##{s['number']} \"#{s['title']}\" — #{s['beats'].size} beats" }
else
  # Single-video script: flat beat list from paragraphs/headers
  result['format'] = 'single'
  beats = []
  current_label = "Introduction"

  lines.each do |line|
    stripped = line.strip
    next if stripped.empty?

    # Headers become section labels (ALL-CAPS or markdown-style)
    if stripped.match?(/^[A-Z][A-Z\s]{4,}$/) || stripped.match?(/^#+\s+/)
      current_label = stripped.sub(/^#+\s+/, '').strip
      next
    end

    # Each paragraph is a beat
    if beats.last && beats.last['label'] == current_label
      beats.last['text'] = "#{beats.last['text']} #{stripped}"
    else
      beats << { 'role' => 'section', 'label' => current_label, 'text' => stripped }
    end
  end

  result['beats'] = beats
  fmt "Parsed single-video script with #{beats.size} beats"
end

File.write(output_path, YAML.dump(result))
fmt "Saved: #{output_path}"
puts output_path
