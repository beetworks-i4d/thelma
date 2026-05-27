#!/usr/bin/env ruby
# semantic_label_runner.rb — Subscription-based Claude Code semantic labeling.
#
# Calls `claude -p` (Claude Code CLI) to fill semantic labels using the user's
# Claude subscription. No API keys required.
#
# Usage:
#   # Prepare batches only (safe inside Claude Code):
#   ruby scripts/semantic_label_runner.rb --fixture <dir>
#
#   # Execute labeling (must run from normal Terminal):
#   ruby scripts/semantic_label_runner.rb --fixture <dir> --execute
#
# Resumable: skips batches with valid existing responses.

require 'json'
require 'yaml'
require 'open3'
require 'fileutils'
require 'date'

SCRIPTS_DIR = File.dirname(__FILE__)
require_relative 'semantic_labeler'

# ─── CLI ──────────────────────────────────────────────────────────────────────

fixture_dir = nil
batch_size  = 20
execute     = false
model       = nil

args = ARGV.dup
while args.any?
  case args.first
  when '--fixture'    then args.shift; fixture_dir = args.shift
  when '--batch-size' then args.shift; batch_size  = args.shift.to_i
  when '--execute'    then args.shift; execute = true
  when '--model'      then args.shift; model = args.shift
  else
    abort "Unknown argument: #{args.first}"
  end
end

abort "Usage: ruby scripts/semantic_label_runner.rb --fixture <dir>" unless fixture_dir
abort "--batch-size must be >= 1" if batch_size < 1

# ─── Paths ────────────────────────────────────────────────────────────────────

pending_path  = File.join(fixture_dir, 'semantic_labels_pending.json')
response_path = File.join(fixture_dir, 'semantic_labels_response.json')
batch_dir     = File.join(fixture_dir, 'semantic_label_batches')

# ─── Ensure pending request exists ────────────────────────────────────────────

unless File.exist?(pending_path)
  abort "No pending request found: #{pending_path}\nRun candidate_builder --phase ab --semantic-mode pending first."
end

pending_data = JSON.parse(File.read(pending_path))
all_candidates = pending_data['candidates']
$stderr.puts "Loaded #{all_candidates.size} candidates from pending request."

# ─── Split into batches ──────────────────────────────────────────────────────

FileUtils.mkdir_p(batch_dir)
batches = all_candidates.each_slice(batch_size).to_a

batches.each_with_index do |batch_candidates, i|
  batch_num = format('%03d', i + 1)
  batch_pending = File.join(batch_dir, "batch_#{batch_num}_pending.json")

  batch_request = pending_data.merge('candidates' => batch_candidates)
  File.write(batch_pending, JSON.pretty_generate(batch_request))
end

$stderr.puts "Prepared #{batches.size} batch(es) in #{batch_dir}/"

# ─── Dry-run: stop here unless --execute ──────────────────────────────────────

unless execute
  batches.each_with_index do |batch_candidates, i|
    batch_num = format('%03d', i + 1)
    resp_path = File.join(batch_dir, "batch_#{batch_num}_response.json")
    status = File.exist?(resp_path) ? 'has response' : 'pending'
    $stderr.puts "  batch_#{batch_num}: #{batch_candidates.size} candidates [#{status}]"
  end
  $stderr.puts "Dry-run complete. Pass --execute to call Claude Code CLI."
  exit 0
end

# ─── Execute guard: reject nested Claude Code sessions ────────────────────────

if ENV['CLAUDECODE']
  abort "semantic_label_runner cannot invoke claude from inside Claude Code. Run this command from normal Terminal."
end

# ─── Execute batches ──────────────────────────────────────────────────────────

claude_cmd = ENV['CLAUDE_CMD'] || 'claude'

failed_batches = []

batches.each_with_index do |batch_candidates, i|
  batch_num = format('%03d', i + 1)
  batch_pending  = File.join(batch_dir, "batch_#{batch_num}_pending.json")
  batch_response = File.join(batch_dir, "batch_#{batch_num}_response.json")

  # Resumable: skip if valid response already exists
  if File.exist?(batch_response)
    begin
      existing = JSON.parse(File.read(batch_response))
      existing_labels = existing.is_a?(Hash) ? (existing['candidates'] || existing) : existing
      existing_labels = [existing_labels] unless existing_labels.is_a?(Array)
      result = SemanticLabeler.validate_response(existing_labels, batch_candidates)
      if result[:errors].empty?
        $stderr.puts "  batch_#{batch_num}: skipped (valid response exists)"
        next
      else
        $stderr.puts "  batch_#{batch_num}: existing response invalid, re-running"
      end
    rescue JSON::ParserError
      $stderr.puts "  batch_#{batch_num}: existing response corrupt, re-running"
    end
  end

  # Build prompt
  batch_json = File.read(batch_pending)
  prompt = <<~PROMPT
    You are a semantic labeling system. Read the request below and produce ONLY valid JSON output.
    No markdown fences. No explanation. No text before or after the JSON.

    #{batch_json}

    Respond with ONLY: {"candidates": [<one label object per candidate>]}
  PROMPT

  # Build command
  cmd = [claude_cmd, '-p', '--output-format', 'json', '--no-session-persistence', '--tools', '']
  cmd += ['--model', model] if model

  $stderr.puts "  batch_#{batch_num}: calling claude (#{batch_candidates.size} candidates)..."

  stdout, stderr_out, status = Open3.capture3(*cmd, stdin_data: prompt)

  unless status.success?
    $stderr.puts "  batch_#{batch_num}: FAILED (exit #{status.exitstatus})"
    failed_batches << batch_num
    next
  end

  # Extract label JSON from claude response
  label_json = extract_label_json(stdout)

  unless label_json
    $stderr.puts "  batch_#{batch_num}: FAILED (no valid JSON in response)"
    # Save raw response for debugging
    File.write(batch_response + '.raw', stdout)
    failed_batches << batch_num
    next
  end

  # Validate
  labels = label_json.is_a?(Hash) ? (label_json['candidates'] || label_json) : label_json
  labels = [labels] unless labels.is_a?(Array)
  result = SemanticLabeler.validate_response(labels, batch_candidates)

  if result[:errors].any?
    $stderr.puts "  batch_#{batch_num}: FAILED validation (#{result[:errors].size} errors)"
    result[:errors].first(3).each { |e| $stderr.puts "    #{e}" }
    File.write(batch_response + '.raw', stdout)
    failed_batches << batch_num
    next
  end

  File.write(batch_response, JSON.pretty_generate(label_json))
  $stderr.puts "  batch_#{batch_num}: OK"
end

if failed_batches.any?
  $stderr.puts "#{failed_batches.size} batch(es) failed: #{failed_batches.join(', ')}"
  $stderr.puts "Fix and rerun with --execute to retry failed batches."
  exit 1
end

# ─── Merge batch responses into final response ───────────────────────────────

all_labels = []
batches.each_with_index do |_, i|
  batch_num = format('%03d', i + 1)
  batch_response = File.join(batch_dir, "batch_#{batch_num}_response.json")
  data = JSON.parse(File.read(batch_response))
  labels = data.is_a?(Hash) ? (data['candidates'] || data) : data
  all_labels.concat(labels)
end

merged = { 'candidates' => all_labels }
File.write(response_path, JSON.pretty_generate(merged))
$stderr.puts "Merged #{all_labels.size} labels into #{response_path}"
$stderr.puts "Run candidate_builder --phase abc --semantic-mode pending to complete."

# ─── Helpers ──────────────────────────────────────────────────────────────────

BEGIN {
  def extract_label_json(raw_output)
    # claude --output-format json wraps response in {"result": "...", ...}
    begin
      wrapper = JSON.parse(raw_output)
      if wrapper.is_a?(Hash) && wrapper['result']
        text = wrapper['result']
        # The result text should contain our label JSON
        return parse_json_from_text(text)
      end
    rescue JSON::ParserError
      # Not wrapped JSON, try raw text
    end

    # Fallback: try parsing raw output directly
    parse_json_from_text(raw_output)
  end

  def parse_json_from_text(text)
    # Try direct parse first
    begin
      parsed = JSON.parse(text)
      return parsed if parsed.is_a?(Hash) || parsed.is_a?(Array)
    rescue JSON::ParserError
      # Continue to extraction
    end

    # Extract JSON object from text (skip any preamble/postamble)
    if text =~ /(\{[\s\S]*\})\s*\z/m
      begin
        return JSON.parse($1)
      rescue JSON::ParserError
        # Not valid JSON
      end
    end

    nil
  end
}
