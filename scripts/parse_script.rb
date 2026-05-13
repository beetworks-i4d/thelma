#!/usr/bin/env ruby
# Parses a script file (.txt, .md, .pdf, .docx) into a structured YAML
# with a hierarchical beat tree via LLM.
#
# Usage: ruby scripts/parse_script.rb <script_file> [output_dir] [--llm-mode api|claude_code]
# Output: script_parsed.yaml in output_dir (or same dir as input), path to stdout
#
# Supported formats:
#   .txt, .md  → File.read (native Ruby)
#   .pdf       → pdftotext (must be installed)
#   .docx      → pandoc --to plain (must be installed)
#
# Caching: skips re-parse if script_parsed.yaml exists and source_hash matches.

require 'yaml'
require 'json'
require 'digest'

require_relative 'llm_client'

def fmt(msg) = $stderr.puts(msg)

# --- Parse args ---

positional = []
i = 0
while i < ARGV.size
  case ARGV[i]
  when '--llm-mode' then LLMClient.mode = ARGV[i += 1]
  else positional << ARGV[i]
  end
  i += 1
end

path = positional[0]
output_dir = positional[1]
abort "Usage: ruby scripts/parse_script.rb <script_file> [output_dir] [--llm-mode api|claude_code]" unless path
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

# Normalize: clean BOM, bullet chars
text = text.sub(/\A\xEF\xBB\xBF/, '').gsub(/[●​•◦▪▸]\s*/, '')

# Detect multi-short format: lines matching #N "title" or #N "title"
lines = text.lines.map(&:rstrip)
multi_short = lines.any? { |l| l.match?(/^#\d+\s+[""\u201C]/) }

result = { 'source_file' => File.basename(path), 'source_hash' => source_hash }

if multi_short
  # --- Multi-short format: existing regex parser (unchanged) ---
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

    if stripped.match?(/^[A-Z][A-Z\s]{2,}$/) && !stripped.match?(/^(HOOK|CLOSE|TALKING POINTS):?$/)
      current_section = stripped.strip
      sections << { 'name' => current_section, 'shorts' => [] }
      next
    end

    if (m = stripped.match(/^#(\d+)\s+["""\u201C](.+?)["""\u201D]\.?\s*$/))
      current_short = { 'number' => m[1].to_i, 'title' => m[2], 'section' => current_section, 'beats' => [] }
      shorts << current_short
      sections.last['shorts'] << m[1].to_i if sections.last
      current_beat = nil
      in_talking_points = false
      next
    end

    next unless current_short

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
      nil # preamble
    elsif in_talking_points
      if current_beat && !current_beat['text'].match?(/[.!?]$/)
        current_beat['text'] = "#{current_beat['text']} #{stripped}"
      else
        current_beat = { 'role' => 'talking_point', 'text' => stripped }
        current_short['beats'] << current_beat
      end
    elsif current_beat
      current_beat['text'] = "#{current_beat['text']} #{stripped}"
    end
  end

  result['sections'] = sections
  result['shorts'] = shorts

  fmt "Parsed #{shorts.size} shorts across #{sections.size} sections"
  shorts.each { |s| fmt "  ##{s['number']} \"#{s['title']}\" — #{s['beats'].size} beats" }
else
  # --- Single-video / long-form script: LLM tree parser ---
  result['format'] = 'tree'

  # Number non-empty lines for the LLM to reference by line range.
  # This keeps output tokens minimal — LLM returns line ranges, we reconstruct text.
  numbered_lines = []
  line_texts = {}  # 1-indexed line number → original text
  lines.each_with_index do |line, idx|
    ln = idx + 1
    stripped = line.strip
    if stripped.empty?
      numbered_lines << "#{ln}:"
    else
      numbered_lines << "#{ln}: #{stripped}"
      line_texts[ln] = stripped
    end
  end
  numbered_script = numbered_lines.join("\n")

  prompt = <<~PROMPT
  You are a video script structure parser. Parse the following numbered script
  into a hierarchical beat tree. Your job is segmentation and labeling only.

  ## Beat roles (use exactly these strings)
  - hook: opening hook or cold open
  - section: a major named section or thematic block
  - blueprint: a numbered sub-unit within a section (e.g. "BB #N", "Tip #N", "Step N", "Business Blueprint #N")
  - cta: call-to-action (midroll, end-card, subscribe prompt)
  - outro: closing/binge-trap/end-screen
  - transition: bridge sentence(s) between major beats
  - unknown: anything that doesn't fit above

  ## Rules
  1. Reference text by line numbers. Each beat specifies "lines": [start, end]
     (inclusive). Every non-empty line must appear in exactly one beat.
     Line ranges must not overlap and must cover all non-empty lines.
  2. IDs must be short stable slugs: hook, bb_1, bb_2, midroll_cta, end_cta, outro, etc.
  3. Parent/children must be bidirectionally consistent.
  4. Top-level beats have parent: null. Nested beats (e.g. blueprints inside
     a section) have parent set to the section's id.
  5. Keep nesting shallow — max 2 levels (section → blueprint). Do NOT nest deeper.
  6. If the script has numbered items (BB #1, BB #2, etc.), each becomes
     its own blueprint beat nested under its parent section.
  7. A section that contains blueprints may have its OWN lines (intro text before
     the first BB). Set those lines on the section beat. The blueprint lines
     are separate. Section lines + children lines should NOT overlap.

  ## Output
  Return STRICT JSON (no markdown fences, no prose). Schema:
  {
    "beats": [
      {
        "id": "hook",
        "role": "hook",
        "label": "Hook",
        "lines": [1, 5],
        "parent": null,
        "children": []
      }
    ]
  }

  CRITICAL: Return ONLY the JSON object. No commentary before or after.

  ## Numbered Script
  #{numbered_script}
  PROMPT

  fmt "Prompt: #{prompt.length} chars (~#{(prompt.length / 4.0).ceil} tokens)"
  fmt "\nCalling LLM (script parse)..."

  # Use pending_dir for re-entrant path
  pending_dir = File.join(output_dir, '..', 'pending_llm_calls')
  pending_dir = File.expand_path(pending_dir)

  begin
    response = LLMClient.call(prompt, call_type: 'script_parse', model: 'claude-opus-4-6',
                              max_tokens: 16384, pending_dir: pending_dir,
                              call_name: 'parse_script')
  rescue LLMClient::Pending => e
    $stderr.puts e.message
    exit 2
  end

  # --- Parse JSON response ---
  json_blocks = response.scan(/```json?\s*\n?(.*?)```/m).flatten
  json_text = if json_blocks.any?
                json_blocks.last.strip
              else
                response.strip
              end

  begin
    parsed = JSON.parse(json_text)
  rescue JSON::ParserError => e
    last_brace = response.rindex('}')
    first_brace = response.rindex('{', [last_brace - 100_000, 0].max) if last_brace
    if first_brace && last_brace
      begin
        parsed = JSON.parse(response[first_brace..last_brace])
      rescue JSON::ParserError
        abort "JSON parse error: #{e.message}\nRaw (first 500 chars):\n#{response[0..500]}"
      end
    else
      abort "JSON parse error: #{e.message}\nRaw (first 500 chars):\n#{response[0..500]}"
    end
  end

  llm_beats = parsed['beats']
  abort "LLM response missing 'beats' array" unless llm_beats.is_a?(Array)
  abort "LLM returned empty beats array" if llm_beats.empty?

  # --- Reconstruct text from line ranges ---
  max_line = line_texts.keys.max || 0
  llm_beats.each do |b|
    lr = b['lines']
    if lr.is_a?(Array) && lr.size == 2
      start_ln, end_ln = lr[0].to_i, lr[1].to_i
      beat_lines = (start_ln..end_ln).filter_map { |ln| line_texts[ln] }
      b['text'] = beat_lines.join(' ')
    else
      b['text'] ||= ''
    end
  end

  # --- Validate schema properties ---
  errors = []
  ids = llm_beats.map { |b| b['id'] }
  id_set = ids.to_set

  # Unique IDs
  dupes = ids.group_by(&:itself).select { |_, v| v.size > 1 }.keys
  errors << "Duplicate IDs: #{dupes.join(', ')}" unless dupes.empty?

  # Valid roles
  valid_roles = %w[hook section blueprint cta outro transition unknown]
  llm_beats.each do |b|
    errors << "Beat '#{b['id']}': missing id" unless b['id']
    errors << "Beat '#{b['id']}': missing role" unless b['role']
    errors << "Beat '#{b['id']}': invalid role '#{b['role']}'" if b['role'] && !valid_roles.include?(b['role'])

    # Ensure children is an array
    b['children'] ||= []

    # Validate line ranges
    lr = b['lines']
    if lr.is_a?(Array) && lr.size == 2
      errors << "Beat '#{b['id']}': start line #{lr[0]} > end line #{lr[1]}" if lr[0].to_i > lr[1].to_i
      errors << "Beat '#{b['id']}': line #{lr[1]} exceeds script (#{max_line} lines)" if lr[1].to_i > max_line
    else
      errors << "Beat '#{b['id']}': missing or invalid 'lines' array"
    end

    # Parent resolution
    if b['parent'] && !id_set.include?(b['parent'])
      errors << "Beat '#{b['id']}': parent '#{b['parent']}' not found"
    end

    # Cycle check (only 2 levels allowed, so parent's parent must be nil)
    if b['parent']
      parent_beat = llm_beats.find { |pb| pb['id'] == b['parent'] }
      if parent_beat && parent_beat['parent']
        errors << "Beat '#{b['id']}': nesting > 2 levels (parent '#{b['parent']}' has parent '#{parent_beat['parent']}')"
      end
    end
  end

  # Bidirectional consistency: children arrays match parent pointers
  llm_beats.each do |b|
    declared_children = b['children'] || []
    actual_children = llm_beats.select { |c| c['parent'] == b['id'] }.map { |c| c['id'] }
    if declared_children.sort != actual_children.sort
      errors << "Beat '#{b['id']}': children mismatch — declared #{declared_children.sort}, actual #{actual_children.sort}"
    end
  end

  # Line coverage check: every non-empty line must be covered by exactly one beat
  covered_lines = {}
  llm_beats.each do |b|
    lr = b['lines']
    next unless lr.is_a?(Array) && lr.size == 2
    (lr[0].to_i..lr[1].to_i).each do |ln|
      next unless line_texts[ln]  # skip empty lines
      if covered_lines[ln]
        errors << "Line #{ln} covered by both '#{covered_lines[ln]}' and '#{b['id']}'"
      else
        covered_lines[ln] = b['id']
      end
    end
  end

  uncovered = line_texts.keys.sort - covered_lines.keys.sort
  if uncovered.any?
    fmt "WARNING: #{uncovered.size} uncovered lines: #{uncovered.first(10).join(', ')}#{uncovered.size > 10 ? '...' : ''}"
  end

  unless errors.empty?
    abort "Schema validation errors:\n  #{errors.join("\n  ")}"
  end

  # --- Text reconstruction coverage ---
  source_tokens = text.gsub(/\s+/, ' ').strip.split
  recon_tokens = llm_beats.sort_by { |b| b['lines']&.first.to_i }.map { |b| b['text'] }.join(' ').gsub(/\s+/, ' ').strip.split
  recon_set = recon_tokens.join(' ')
  matched = source_tokens.count { |t| recon_set.include?(t) }
  coverage = source_tokens.empty? ? 1.0 : matched.to_f / source_tokens.size

  if coverage < 0.95
    fmt "WARNING: Text reconstruction coverage is #{(coverage * 100).round(1)}% (threshold: 95%)"
    fmt "  Source tokens: #{source_tokens.size}, Matched: #{matched}"
  else
    fmt "Text reconstruction: #{(coverage * 100).round(1)}% coverage (#{source_tokens.size} tokens)"
  end

  # Remove 'lines' from output — downstream consumers use 'text'
  llm_beats.each { |b| b.delete('lines') }

  result['beats'] = llm_beats

  beat_count = llm_beats.size
  top_count = llm_beats.count { |b| b['parent'].nil? }
  child_count = beat_count - top_count
  fmt "Parsed tree: #{beat_count} beats (#{top_count} top-level, #{child_count} nested)"
end

File.write(output_path, YAML.dump(result))
fmt "Saved: #{output_path}"
puts output_path
