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
require 'yaml'
require 'fileutils'

module LLMClient
  DEFAULT_MODEL = 'claude-sonnet-4-20250514'
  DEFAULT_MAX_TOKENS = 8192

  # --- Claude Code mode support ---

  class Pending < StandardError
    attr_reader :pending_path, :response_path

    def initialize(msg, pending_path:, response_path:)
      @pending_path = pending_path
      @response_path = response_path
      super(msg)
    end
  end

  @mode = nil

  def self.mode
    return @mode if @mode
    ENV['ANTHROPIC_API_KEY'] ? :api : :claude_code
  end

  def self.mode=(override)
    @mode = override&.to_sym
  end

  # --- Main entry point ---

  def self.call(prompt, call_type: nil, profile: nil, model: nil, max_tokens: nil,
                pending_dir: nil, call_name: nil)
    model ||= profile&.dig('llm_routing', call_type) if call_type
    model ||= DEFAULT_MODEL
    max_tokens ||= DEFAULT_MAX_TOKENS

    # Step 1: Check for response file (re-entrant path)
    if pending_dir && call_name
      response_path = File.join(pending_dir, "#{call_name}_response.yaml")
      if File.exist?(response_path)
        response_data = YAML.safe_load(File.read(response_path))
        response_text = response_data['response']
        if response_text && !response_text.strip.empty?
          # Clean up pending file if it exists
          pending_path = File.join(pending_dir, "#{call_name}.yaml")
          File.delete(pending_path) if File.exist?(pending_path)
          $stderr.puts "  LLM: loaded response from #{File.basename(response_path)}"
          return response_text
        end
      end
    end

    # Step 2: Claude Code mode — write pending file, raise Pending
    if mode == :claude_code && pending_dir && call_name
      FileUtils.mkdir_p(pending_dir)
      pending_path = File.join(pending_dir, "#{call_name}.yaml")
      response_path = File.join(pending_dir, "#{call_name}_response.yaml")

      pending_data = {
        'call_name' => call_name,
        'call_type' => call_type,
        'model' => model,
        'max_tokens' => max_tokens,
        'response_path' => response_path,
        'created_at' => Time.now.strftime('%Y-%m-%dT%H:%M:%S%:z'),
        'prompt' => prompt
      }
      File.write(pending_path, pending_data.to_yaml)

      raise Pending.new(
        "PENDING LLM CALL: #{call_name}\n" \
        "  Prompt written to: #{pending_path}\n" \
        "  Write response to: #{response_path}",
        pending_path: pending_path,
        response_path: response_path
      )
    end

    # Step 3: API mode — make the call
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
