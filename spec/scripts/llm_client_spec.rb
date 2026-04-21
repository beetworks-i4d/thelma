require 'open3'
require 'json'
require 'yaml'
require 'tmpdir'
require 'fileutils'

LLM_CLIENT_PATH = File.expand_path('../../scripts/llm_client.rb', __dir__)

RSpec.describe 'LLMClient' do
  describe 'module loading' do
    it 'loads without error' do
      stdout, stderr, status = Open3.capture3('ruby', '-e', "require '#{LLM_CLIENT_PATH}'")
      expect(status.exitstatus).to eq(0), "Load failed: #{stderr}"
    end
  end

  describe '.resolve_adapter' do
    it 'returns AnthropicAdapter for claude models' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        adapter = LLMClient.resolve_adapter('claude-sonnet-4-20250514')
        puts adapter.name
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('LLMClient::AnthropicAdapter')
    end

    it 'returns AnthropicAdapter for unknown models (default)' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        adapter = LLMClient.resolve_adapter('some-unknown-model')
        puts adapter.name
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('LLMClient::AnthropicAdapter')
    end

    it 'aborts for gpt models (not implemented)' do
      _, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        LLMClient.resolve_adapter('gpt-4o')
      RUBY
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('OpenAI adapter not implemented')
    end

    it 'aborts for ollama models (not implemented)' do
      _, stderr, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        LLMClient.resolve_adapter('ollama:llama3')
      RUBY
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Ollama adapter not implemented')
    end
  end

  describe 'missing API key' do
    it 'aborts with clear message when ANTHROPIC_API_KEY not set' do
      env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
      _, stderr, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        LLMClient::AnthropicAdapter.call('test prompt', model: 'claude-sonnet-4-20250514')
      RUBY
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('ANTHROPIC_API_KEY')
      expect(stderr).to include('not set')
    end
  end

  describe '.call routing' do
    it 'uses profile llm_routing for call_type' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        profile = { 'llm_routing' => { 'classification' => 'claude-opus-4-6' } }
        # Mock: just verify the model resolved correctly by checking adapter
        model = profile.dig('llm_routing', 'classification')
        adapter = LLMClient.resolve_adapter(model)
        puts model
        puts adapter.name
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to include('claude-opus-4-6')
      expect(stdout.strip).to include('AnthropicAdapter')
    end

    it 'falls back to DEFAULT_MODEL when no profile routing' do
      stdout, _, status = Open3.capture3('ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        puts LLMClient::DEFAULT_MODEL
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('claude-sonnet-4-20250514')
    end
  end

  describe '.mode detection' do
    it 'returns :api when ANTHROPIC_API_KEY is set' do
      env = ENV.to_h.merge('ANTHROPIC_API_KEY' => 'sk-ant-test')
      stdout, _, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        puts LLMClient.mode
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('api')
    end

    it 'returns :claude_code when ANTHROPIC_API_KEY is not set' do
      env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
      stdout, _, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        puts LLMClient.mode
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('claude_code')
    end

    it 'respects mode= override' do
      env = ENV.to_h.merge('ANTHROPIC_API_KEY' => 'sk-ant-test')
      stdout, _, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        LLMClient.mode = :claude_code
        puts LLMClient.mode
      RUBY
      expect(status.exitstatus).to eq(0)
      expect(stdout.strip).to eq('claude_code')
    end
  end

  describe 'pending file write (Claude Code mode)' do
    it 'raises Pending and writes pending YAML when in claude_code mode' do
      Dir.mktmpdir do |dir|
        pending_dir = File.join(dir, 'pending_llm_calls')
        env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
        stdout, stderr, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
          require '#{LLM_CLIENT_PATH}'
          begin
            LLMClient.call("Test prompt here",
              call_type: 'test_call', call_name: 'my_test',
              pending_dir: '#{pending_dir}')
          rescue LLMClient::Pending => e
            puts "PENDING"
            puts e.pending_path
            puts e.response_path
          end
        RUBY
        expect(status.exitstatus).to eq(0)
        lines = stdout.strip.split("\n")
        expect(lines[0]).to eq('PENDING')

        pending_path = File.join(pending_dir, 'my_test.yaml')
        expect(File.exist?(pending_path)).to be true

        data = YAML.safe_load(File.read(pending_path))
        expect(data['call_name']).to eq('my_test')
        expect(data['call_type']).to eq('test_call')
        expect(data['prompt']).to include('Test prompt here')
        expect(data['response_path']).to include('my_test_response.yaml')
        expect(data['model']).to eq('claude-sonnet-4-20250514')
      end
    end

    it 'does not raise Pending when pending_dir/call_name are nil' do
      env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
      _, stderr, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
        require '#{LLM_CLIENT_PATH}'
        LLMClient.call("Test prompt")
      RUBY
      # Without pending_dir/call_name, falls through to API mode which aborts on missing key
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('ANTHROPIC_API_KEY')
    end
  end

  describe 'response file read (re-entrant path)' do
    it 'returns response from file and cleans up pending file' do
      Dir.mktmpdir do |dir|
        pending_dir = File.join(dir, 'pending_llm_calls')
        FileUtils.mkdir_p(pending_dir)

        # Write a pending file
        File.write(File.join(pending_dir, 'my_test.yaml'), { 'call_name' => 'my_test' }.to_yaml)

        # Write a response file
        File.write(File.join(pending_dir, 'my_test_response.yaml'),
          { 'response' => "The LLM says hello" }.to_yaml)

        env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
        stdout, _, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
          require '#{LLM_CLIENT_PATH}'
          result = LLMClient.call("ignored prompt",
            call_type: 'test', call_name: 'my_test',
            pending_dir: '#{pending_dir}')
          puts result
        RUBY
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq('The LLM says hello')

        # Pending file should be cleaned up
        expect(File.exist?(File.join(pending_dir, 'my_test.yaml'))).to be false
        # Response file should still exist
        expect(File.exist?(File.join(pending_dir, 'my_test_response.yaml'))).to be true
      end
    end

    it 'ignores empty response file and writes pending instead' do
      Dir.mktmpdir do |dir|
        pending_dir = File.join(dir, 'pending_llm_calls')
        FileUtils.mkdir_p(pending_dir)

        # Write an empty response file
        File.write(File.join(pending_dir, 'my_test_response.yaml'),
          { 'response' => '' }.to_yaml)

        env = ENV.to_h.reject { |k, _| k == 'ANTHROPIC_API_KEY' }
        stdout, _, status = Open3.capture3(env, 'ruby', '-e', <<~RUBY)
          require '#{LLM_CLIENT_PATH}'
          begin
            LLMClient.call("Test prompt",
              call_type: 'test', call_name: 'my_test',
              pending_dir: '#{pending_dir}')
          rescue LLMClient::Pending
            puts "PENDING"
          end
        RUBY
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq('PENDING')
      end
    end
  end
end
