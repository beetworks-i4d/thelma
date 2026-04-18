#!/usr/bin/env ruby
# LLM Client — Single interface for all LLM calls in the Thelma pipeline.
# Routes to provider adapters based on profile config.
#
# Usage (as library):
#   require_relative 'llm_client'
#   response = LLMClient.call("Classify these segments...", call_type: 'classification', profile: profile)
#
# Requires ANTHROPIC_API_KEY environment variable for Anthropic adapter.

require 'net/http'
require 'json'
require 'uri'

module LLMClient
  DEFAULT_MODEL = 'claude-sonnet-4-20250514'
  DEFAULT_MAX_TOKENS = 8192

  # --- Main entry point ---

  def self.call(prompt, call_type: nil, profile: nil, model: nil, max_tokens: nil)
    model ||= profile&.dig('llm_routing', call_type) if call_type
    model ||= DEFAULT_MODEL
    max_tokens ||= DEFAULT_MAX_TOKENS

    adapter = resolve_adapter(model)
    adapter.call(prompt, model: model, max_tokens: max_tokens)
  end

  # --- Adapter resolution ---

  def self.resolve_adapter(model)
    case model
    when /^claude/
      AnthropicAdapter
    when /^gpt/, /^o[1-9]/
      abort "LLM ERROR: OpenAI adapter not implemented. Use a Claude model or implement OpenAI adapter."
    when /^ollama:/
      abort "LLM ERROR: Ollama adapter not implemented. Use a Claude model or implement Ollama adapter."
    else
      AnthropicAdapter # default to Anthropic
    end
  end

  # --- Anthropic adapter ---

  class AnthropicAdapter
    API_URL = 'https://api.anthropic.com/v1/messages'
    API_VERSION = '2023-06-01'

    def self.call(prompt, model:, max_tokens: DEFAULT_MAX_TOKENS)
      api_key = ENV['ANTHROPIC_API_KEY']
      abort "LLM ERROR: ANTHROPIC_API_KEY environment variable not set.\n" \
            "Set it with: export ANTHROPIC_API_KEY=sk-ant-..." unless api_key

      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 120
      http.open_timeout = 10

      body = {
        model: model,
        max_tokens: max_tokens,
        messages: [{ role: 'user', content: prompt }]
      }

      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = api_key
      request['anthropic-version'] = API_VERSION
      request.body = body.to_json

      $stderr.puts "  LLM: calling #{model} (#{prompt.length} chars)..."

      response = http.request(request)

      unless response.is_a?(Net::HTTPSuccess)
        error_body = begin
          JSON.parse(response.body)
        rescue
          response.body
        end
        abort "LLM ERROR: API returned #{response.code}\n#{error_body}"
      end

      result = JSON.parse(response.body)
      content = result.dig('content', 0, 'text')
      abort "LLM ERROR: Empty response from API" unless content && !content.strip.empty?

      $stderr.puts "  LLM: response received (#{content.length} chars)"
      content
    end
  end
end
