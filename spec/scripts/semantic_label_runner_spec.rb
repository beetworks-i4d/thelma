require 'date'
require 'open3'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'

RUNNER_SCRIPT  = File.expand_path('../../scripts/semantic_label_runner.rb', __dir__)
BUILDER_SCRIPT_PATH = File.expand_path('../../scripts/candidate_builder.rb', __dir__) unless defined?(BUILDER_SCRIPT_PATH)
EMPHATIC_DIR   = File.expand_path('../fixtures/session6_probe_emphatic_rant', __dir__)

# ─── Helpers ──────────────────────────────────────────────────────────────────

def setup_pending_fixture(tmp_dir, candidate_count: 7)
  # Copy source fixtures and generate pending JSON
  %w[segments_classified.yaml cleaned_transcript.json speech_analysis.json].each do |f|
    src = File.join(EMPHATIC_DIR, f)
    FileUtils.cp(src, tmp_dir) if File.exist?(src)
  end

  # Generate substrate + pending via candidate_builder
  stdout, stderr, status = Open3.capture3(
    'ruby', BUILDER_SCRIPT_PATH,
    '--fixture', tmp_dir,
    '--phase', 'ab',
    '--semantic-mode', 'pending'
  )
  raise "candidate_builder failed: #{stderr}" unless status.success? || stderr.include?('Pending semantic label request written')
  tmp_dir
end

def build_mock_response(pending_path)
  pending = JSON.parse(File.read(pending_path))
  candidates = pending['candidates'].map do |c|
    trims = c['trim_choices'] || []
    cpt = {}
    trims.each { |t| cpt[t['id']] = (t['label'] == 'full_clean') }

    {
      'id' => c['id'],
      'summary' => "Summary for #{c['id']}",
      'distillation' => 'one two three four five',
      'usability' => 'fine',
      'candidate_priority' => 'primary',
      'suggested_narrative_roles' => [{ 'role' => 'claim', 'confidence' => 'high' }],
      'states' => ['aspiration'],
      'durability' => 'mood',
      'confidence' => 'high',
      'content_preserved_trims' => cpt,
      'edit_notes' => 'mock label'
    }
  end
  { 'candidates' => candidates }
end

def write_fake_claude(tmp_dir, response_data)
  # Write a shell script that simulates `claude -p --output-format json`
  # It reads stdin (ignored), outputs a JSON wrapper like real claude does
  fake_bin = File.join(tmp_dir, 'fake_claude')
  result_text = JSON.generate(response_data)
  wrapper = JSON.generate({
    'type' => 'result',
    'subtype' => 'success',
    'result' => result_text,
    'cost_usd' => 0.001,
    'is_error' => false,
    'num_turns' => 1,
    'session_id' => 'test-session'
  })

  File.write(fake_bin, <<~SH)
    #!/bin/sh
    cat /dev/stdin > /dev/null
    echo '#{wrapper.gsub("'", "'\\''")}'
  SH
  File.chmod(0o755, fake_bin)
  fake_bin
end

def write_failing_claude(tmp_dir)
  fake_bin = File.join(tmp_dir, 'fake_claude')
  File.write(fake_bin, <<~SH)
    #!/bin/sh
    cat /dev/stdin > /dev/null
    echo "Error: something went wrong" >&2
    exit 1
  SH
  File.chmod(0o755, fake_bin)
  fake_bin
end

def write_garbage_claude(tmp_dir)
  fake_bin = File.join(tmp_dir, 'fake_claude')
  File.write(fake_bin, <<~SH)
    #!/bin/sh
    cat /dev/stdin > /dev/null
    echo 'This is not JSON at all, just random text.'
  SH
  File.chmod(0o755, fake_bin)
  fake_bin
end

def run_runner(fixture_dir, execute: false, batch_size: nil, env: {}, model: nil)
  cmd = ['ruby', RUNNER_SCRIPT, '--fixture', fixture_dir]
  cmd += ['--batch-size', batch_size.to_s] if batch_size
  cmd += ['--model', model] if model
  cmd << '--execute' if execute
  # Always clear CLAUDECODE for execute tests (we're testing outside CC)
  env_clean = env.dup
  env_clean['CLAUDECODE'] = nil unless env.key?('CLAUDECODE')
  stdout, stderr, status = Open3.capture3(env_clean, *cmd)
  { stdout: stdout, stderr: stderr, exit_code: status.exitstatus }
end

# ═══════════════════════════════════════════════════════════════════════════════

RSpec.describe 'semantic_label_runner' do

  # ─── Dry-run (default) ─────────────────────────────────────────────────────

  describe 'dry-run mode' do
    it 'prepares batches without calling claude' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        result = run_runner(tmp)
        expect(result[:exit_code]).to eq(0)
        expect(result[:stderr]).to include('Dry-run complete')
        expect(result[:stderr]).not_to include('calling claude')
      end
    end

    it 'creates batch pending files' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        run_runner(tmp, batch_size: 3)
        batch_dir = File.join(tmp, 'semantic_label_batches')
        expect(File.exist?(File.join(batch_dir, 'batch_001_pending.json'))).to be true
        expect(File.exist?(File.join(batch_dir, 'batch_002_pending.json'))).to be true
        expect(File.exist?(File.join(batch_dir, 'batch_003_pending.json'))).to be true
      end
    end

    it 'splits candidates correctly' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        run_runner(tmp, batch_size: 3)
        b1 = JSON.parse(File.read(File.join(tmp, 'semantic_label_batches', 'batch_001_pending.json')))
        b3 = JSON.parse(File.read(File.join(tmp, 'semantic_label_batches', 'batch_003_pending.json')))
        expect(b1['candidates'].size).to eq(3)
        expect(b3['candidates'].size).to eq(1)
      end
    end

    it 'each batch carries full instructions and constraints' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        run_runner(tmp, batch_size: 3)
        b1 = JSON.parse(File.read(File.join(tmp, 'semantic_label_batches', 'batch_001_pending.json')))
        expect(b1).to have_key('instructions')
        expect(b1).to have_key('constraints')
        expect(b1).to have_key('output_format')
        expect(b1['prompt_version']).to eq('7D.1')
      end
    end

    it 'reports existing responses in dry-run' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        # Pre-place a batch response
        batch_dir = File.join(tmp, 'semantic_label_batches')
        FileUtils.mkdir_p(batch_dir)
        # First run to create batch files
        run_runner(tmp)
        # Write a response for batch_001
        pending = JSON.parse(File.read(File.join(batch_dir, 'batch_001_pending.json')))
        resp = build_mock_response(File.join(batch_dir, 'batch_001_pending.json'))
        File.write(File.join(batch_dir, 'batch_001_response.json'), JSON.pretty_generate(resp))

        result = run_runner(tmp)
        expect(result[:stderr]).to include('has response')
      end
    end

    it 'works with single batch for all candidates' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        result = run_runner(tmp, batch_size: 100)
        expect(result[:exit_code]).to eq(0)
        expect(result[:stderr]).to include('1 batch(es)')
      end
    end
  end

  # ─── CLAUDECODE guard ──────────────────────────────────────────────────────

  describe 'CLAUDECODE guard' do
    it 'allows dry-run inside Claude Code' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        result = run_runner(tmp, env: { 'CLAUDECODE' => '1' })
        expect(result[:exit_code]).to eq(0)
        expect(result[:stderr]).to include('Dry-run complete')
      end
    end

    it 'blocks --execute inside Claude Code' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        result = run_runner(tmp, execute: true, env: { 'CLAUDECODE' => '1' })
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('cannot invoke claude from inside Claude Code')
      end
    end
  end

  # ─── Execute mode (mocked claude) ──────────────────────────────────────────

  describe 'execute mode' do
    it 'calls fake claude and writes response' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        # Build mock response from pending data
        pending_path = File.join(tmp, 'semantic_labels_pending.json')
        mock_resp = build_mock_response(pending_path)
        fake_claude = write_fake_claude(tmp, mock_resp)

        result = run_runner(tmp, execute: true, env: { 'CLAUDE_CMD' => fake_claude })
        expect(result[:exit_code]).to eq(0)
        expect(result[:stderr]).to include('batch_001: OK')
        expect(result[:stderr]).to include('Merged')

        # Verify final merged response
        merged = JSON.parse(File.read(File.join(tmp, 'semantic_labels_response.json')))
        expect(merged['candidates'].size).to eq(7)
      end
    end

    it 'handles multi-batch execution' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        pending_path = File.join(tmp, 'semantic_labels_pending.json')

        response_fixture = File.join(tmp, 'mock_responses')
        FileUtils.mkdir_p(response_fixture)

        # Pre-generate responses for each batch
        pending = JSON.parse(File.read(pending_path))
        pending['candidates'].each_slice(3).with_index do |batch, i|
          batch_resp = build_mock_response_for_candidates(batch)
          File.write(File.join(response_fixture, "batch_#{format('%03d', i + 1)}.json"),
                     JSON.generate(batch_resp))
        end

        # Ruby-based fake claude: counter file tracks which batch we're on
        counter_file = File.join(tmp, 'call_counter')
        File.write(counter_file, '0')

        fake_bin = File.join(tmp, 'fake_claude_smart')
        File.write(fake_bin, <<~RUBY)
          #!/usr/bin/env ruby
          require 'json'
          STDIN.read # consume stdin
          counter_file = "#{counter_file}"
          count = File.read(counter_file).strip.to_i + 1
          File.write(counter_file, count.to_s)
          batch = format('%03d', count)
          resp_file = "#{response_fixture}/batch_\#{batch}.json"
          inner = File.exist?(resp_file) ? File.read(resp_file) : '{}'
          wrapper = { 'type' => 'result', 'subtype' => 'success',
                      'result' => inner, 'cost_usd' => 0.001,
                      'is_error' => false, 'num_turns' => 1, 'session_id' => 'test' }
          puts JSON.generate(wrapper)
        RUBY
        File.chmod(0o755, fake_bin)

        result = run_runner(tmp, execute: true, batch_size: 3, env: { 'CLAUDE_CMD' => fake_bin })
        expect(result[:exit_code]).to eq(0)
        expect(result[:stderr]).to include('batch_001: OK')
        expect(result[:stderr]).to include('batch_002: OK')
        expect(result[:stderr]).to include('batch_003: OK')

        merged = JSON.parse(File.read(File.join(tmp, 'semantic_labels_response.json')))
        expect(merged['candidates'].size).to eq(7)
      end
    end

    it 'skips batches with valid existing responses' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        pending_path = File.join(tmp, 'semantic_labels_pending.json')
        mock_resp = build_mock_response(pending_path)
        fake_claude = write_fake_claude(tmp, mock_resp)

        # First run: executes
        result1 = run_runner(tmp, execute: true, env: { 'CLAUDE_CMD' => fake_claude })
        expect(result1[:exit_code]).to eq(0)

        # Second run: should skip
        result2 = run_runner(tmp, execute: true, env: { 'CLAUDE_CMD' => fake_claude })
        expect(result2[:exit_code]).to eq(0)
        expect(result2[:stderr]).to include('skipped (valid response exists)')
      end
    end

    it 'fails gracefully when claude exits non-zero' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        fake_claude = write_failing_claude(tmp)

        result = run_runner(tmp, execute: true, env: { 'CLAUDE_CMD' => fake_claude })
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('FAILED (exit')
      end
    end

    it 'fails gracefully when claude returns garbage' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        fake_claude = write_garbage_claude(tmp)

        result = run_runner(tmp, execute: true, env: { 'CLAUDE_CMD' => fake_claude })
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('FAILED (no valid JSON')
      end
    end

    it 'passes --model to claude when specified' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        # Fake claude that logs its arguments
        args_log = File.join(tmp, 'args.log')
        pending_path = File.join(tmp, 'semantic_labels_pending.json')
        mock_resp = build_mock_response(pending_path)
        result_text = JSON.generate(mock_resp)
        wrapper = JSON.generate({
          'type' => 'result', 'subtype' => 'success',
          'result' => result_text, 'cost_usd' => 0.001,
          'is_error' => false, 'num_turns' => 1, 'session_id' => 'test'
        })

        fake_bin = File.join(tmp, 'fake_claude_log')
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          echo "$@" > #{args_log}
          cat /dev/stdin > /dev/null
          echo '#{wrapper.gsub("'", "'\\''")}'
        SH
        File.chmod(0o755, fake_bin)

        run_runner(tmp, execute: true, model: 'sonnet', env: { 'CLAUDE_CMD' => fake_bin })
        args = File.read(args_log)
        expect(args).to include('--model sonnet')
      end
    end

    it 'does not pass --model when not specified' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        args_log = File.join(tmp, 'args.log')
        pending_path = File.join(tmp, 'semantic_labels_pending.json')
        mock_resp = build_mock_response(pending_path)
        result_text = JSON.generate(mock_resp)
        wrapper = JSON.generate({
          'type' => 'result', 'subtype' => 'success',
          'result' => result_text, 'cost_usd' => 0.001,
          'is_error' => false, 'num_turns' => 1, 'session_id' => 'test'
        })

        fake_bin = File.join(tmp, 'fake_claude_log')
        File.write(fake_bin, <<~SH)
          #!/bin/sh
          echo "$@" > #{args_log}
          cat /dev/stdin > /dev/null
          echo '#{wrapper.gsub("'", "'\\''")}'
        SH
        File.chmod(0o755, fake_bin)

        run_runner(tmp, execute: true, env: { 'CLAUDE_CMD' => fake_bin })
        args = File.read(args_log)
        expect(args).not_to include('--model')
      end
    end
  end

  # ─── Edge cases ────────────────────────────────────────────────────────────

  describe 'error handling' do
    it 'aborts when no pending file exists' do
      Dir.mktmpdir do |tmp|
        result = run_runner(tmp)
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('No pending request found')
      end
    end

    it 'aborts with invalid batch-size' do
      Dir.mktmpdir do |tmp|
        setup_pending_fixture(tmp)
        stdout, stderr, status = Open3.capture3(
          { 'CLAUDECODE' => nil },
          'ruby', RUNNER_SCRIPT, '--fixture', tmp, '--batch-size', '0'
        )
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('batch-size must be >= 1')
      end
    end
  end
end

# ─── Spec helpers ─────────────────────────────────────────────────────────────

def build_mock_response_for_candidates(candidates)
  labels = candidates.map do |c|
    trims = c['trim_choices'] || []
    cpt = {}
    trims.each { |t| cpt[t['id']] = (t['label'] == 'full_clean') }

    {
      'id' => c['id'],
      'summary' => "Summary for #{c['id']}",
      'distillation' => 'one two three four five',
      'usability' => 'fine',
      'candidate_priority' => 'primary',
      'suggested_narrative_roles' => [{ 'role' => 'claim', 'confidence' => 'high' }],
      'states' => ['aspiration'],
      'durability' => 'mood',
      'confidence' => 'high',
      'content_preserved_trims' => cpt,
      'edit_notes' => 'mock label'
    }
  end
  { 'candidates' => labels }
end
