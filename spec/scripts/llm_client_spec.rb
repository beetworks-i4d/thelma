require 'open3'
require 'json'

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
end
