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
  DEFAULT_MODEL = 'claude-sonnet-4-6'
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
                pending_dir: nil, call_name: nil, cached_system_prompt: nil)
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
    adapter.call(prompt, model: model, max_tokens: max_tokens, cached_system_prompt: cached_system_prompt)
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

    def self.call(prompt, model:, max_tokens: DEFAULT_MAX_TOKENS, cached_system_prompt: nil)
      api_key = ENV['ANTHROPIC_API_KEY']
      abort "LLM ERROR: ANTHROPIC_API_KEY environment variable not set.\n" \
            "Set it with: export ANTHROPIC_API_KEY=sk-ant-..." unless api_key

      uri = URI(API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = true
      http.read_timeout = 300
      http.open_timeout = 30

      body = {
        model: model,
        max_tokens: max_tokens,
        messages: [{ role: 'user', content: prompt }]
      }

      # Prompt caching: place tone guide / static context in system message with cache_control
      if cached_system_prompt
        body[:system] = [
          { type: 'text', text: cached_system_prompt, cache_control: { type: 'ephemeral' } }
        ]
      end

      request = Net::HTTP::Post.new(uri.path)
      request['Content-Type'] = 'application/json'
      request['x-api-key'] = api_key
      request['anthropic-version'] = API_VERSION
      request['anthropic-beta'] = 'prompt-caching-2024-07-31' if cached_system_prompt
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

      # Log usage and cache metrics
      usage = result['usage'] || {}
      input_tokens = usage['input_tokens'] || 0
      output_tokens = usage['output_tokens'] || 0
      cache_creation = usage['cache_creation_input_tokens'] || 0
      cache_read = usage['cache_read_input_tokens'] || 0

      $stderr.puts "  LLM: response received (#{content.length} chars)"
      $stderr.puts "  LLM: tokens — input: #{input_tokens}, output: #{output_tokens}"
      if cache_creation > 0 || cache_read > 0
        $stderr.puts "  LLM: cache — created: #{cache_creation}, read: #{cache_read}"
      end

      # Cost estimation — model-aware pricing
      # Opus: $15/M input, $75/M output, cache write $18.75/M, cache read $1.50/M
      # Sonnet: $3/M input, $15/M output, cache write $3.75/M, cache read $0.30/M
      is_opus = model.include?('opus')
      in_rate = is_opus ? 15.0 : 3.0
      out_rate = is_opus ? 75.0 : 15.0
      cw_rate = is_opus ? 18.75 : 3.75
      cr_rate = is_opus ? 1.50 : 0.30
      # API returns input_tokens as non-cached input; cache tokens are separate
      input_cost = input_tokens * in_rate / 1_000_000
      output_cost = output_tokens * out_rate / 1_000_000
      cache_write_cost = cache_creation * cw_rate / 1_000_000
      cache_read_cost = cache_read * cr_rate / 1_000_000
      total_cost = input_cost + output_cost + cache_write_cost + cache_read_cost
      $stderr.puts "  LLM: cost — $#{'%.4f' % total_cost} (in: $#{'%.4f' % input_cost}, out: $#{'%.4f' % output_cost}, cache_w: $#{'%.4f' % cache_write_cost}, cache_r: $#{'%.4f' % cache_read_cost})"

      content
    end
  end
end
