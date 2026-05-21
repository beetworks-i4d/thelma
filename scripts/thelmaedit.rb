#!/usr/bin/env ruby
# thelmaedit — wrapper around orchestrate.rb that auto-fulfills pending LLM
# calls using `claude -p` (Claude Code subscription) instead of the API.
#
# Usage:
#   thelmaedit <library> <pool-dir>          # subscription mode (default)
#   thelmaedit <library> <pool-dir> --api    # passthrough to API mode

require 'open3'
require 'yaml'
require 'date'
require 'fileutils'
require_relative 'library_resolver'

THELMA_ROOT    = File.expand_path('..', File.dirname(__FILE__))
ORCHESTRATE    = File.join(THELMA_ROOT, 'scripts', 'orchestrate.rb')
MAX_ITERATIONS = 50

def die(msg)
  $stderr.puts "thelmaedit: #{msg}"
  exit 1
end

# --- CLI parsing ---

args = ARGV.dup
api_mode = !!args.delete('--api')
library_name, pool_dir = args
die 'usage: thelmaedit <library> <pool-dir> [--api]' unless library_name && pool_dir
pool_dir = File.expand_path(pool_dir)
die "pool dir not found: #{pool_dir}" unless File.directory?(pool_dir)

# --- API passthrough ---

if api_mode
  cmd = ['ruby', ORCHESTRATE, '--library', library_name, '--pool-dir', pool_dir, '--llm-mode', 'api']
  $stderr.puts "thelmaedit: API mode — #{cmd.join(' ')}"
  exec(*cmd)
end

# --- Subscription mode ---

die '`claude` CLI not found in PATH. Install Claude Code or use --api.' if `command -v claude`.strip.empty?

def pending_dir_for(library_name)
  File.join(LibraryResolver.resolve(library_name), 'pending_llm_calls')
end

def newest_pending(dir)
  return nil unless File.directory?(dir)
  Dir.glob(File.join(dir, '*.yaml'))
    .reject { |p| p.end_with?('_response.yaml') }
    .max_by { |p| File.mtime(p) }
end

def fulfill_pending!(pending_path, pool_dir)
  call_name = File.basename(pending_path, '.yaml')
  $stderr.puts "  Fulfilling LLM call: #{call_name}"

  begin
    pending = YAML.safe_load(File.read(pending_path), permitted_classes: [Time, Date, Symbol])
  rescue => e
    die "could not parse pending file #{pending_path}: #{e.message}"
  end

  prompt        = pending['prompt']
  response_path = pending['response_path']
  die "pending file missing `prompt`: #{pending_path}"        if prompt.to_s.empty?
  die "pending file missing `response_path`: #{pending_path}" if response_path.to_s.empty?

  $stderr.puts "    prompt: #{prompt.length} chars  →  #{File.basename(response_path)}"
  $stderr.puts '    calling claude -p…'

  env = ENV.to_h
  env.delete('ANTHROPIC_API_KEY') # force subscription auth, not API

  stdout, stderr_out, status = Open3.capture3(
    env,
    'claude', '-p',
    '--tools', '',
    '--disable-slash-commands',
    stdin_data: prompt,
    chdir: pool_dir
  )

  unless status.success?
    $stderr.puts stderr_out
    die "`claude -p` exited #{status.exitstatus} for #{call_name}"
  end
  die "`claude -p` returned empty output for #{call_name}" if stdout.strip.empty?

  FileUtils.mkdir_p(File.dirname(response_path))
  File.write(response_path, { 'response' => stdout }.to_yaml)
  $stderr.puts "    wrote #{stdout.length} chars → #{response_path}"
end

# --- Main loop ---

iteration = 0
loop do
  iteration += 1
  die "loop limit (#{MAX_ITERATIONS}) reached — bailing out" if iteration > MAX_ITERATIONS

  $stderr.puts "\n[thelmaedit] iteration #{iteration}/#{MAX_ITERATIONS} — running orchestrate.rb"
  cmd = ['ruby', ORCHESTRATE, '--library', library_name, '--pool-dir', pool_dir, '--llm-mode', 'claude_code']
  system(*cmd)
  exit_code = $?.exitstatus

  case exit_code
  when 0
    output_dir = File.join(LibraryResolver.resolve(library_name), 'output')
    xml = Dir.glob(File.join(output_dir, '*.xml')).max_by { |p| File.mtime(p) }
    $stderr.puts "\n[thelmaedit] done — orchestrate.rb exited 0 after #{iteration} iteration(s)."
    $stderr.puts "  output XML: #{xml || '(none found in ' + output_dir + ')'}"
    exit 0
  when 2
    pending = newest_pending(pending_dir_for(library_name))
    die "orchestrate exited 2 but no pending file found in #{pending_dir_for(library_name)}" unless pending
    fulfill_pending!(pending, pool_dir)
  else
    die "orchestrate.rb failed (exit #{exit_code})"
  end
end
