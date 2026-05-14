require 'open3'
require 'yaml'
require 'json'
require 'tmpdir'
require 'fileutils'

PARSE_SCRIPT = File.expand_path('../../scripts/parse_script.rb', __dir__)

def write_script(dir, filename, content)
  path = File.join(dir, filename)
  File.write(path, content)
  path
end

def seed_parse_response(output_dir, response_json)
  pending_dir = File.join(output_dir, '..', 'pending_llm_calls')
  pending_dir = File.expand_path(pending_dir)
  FileUtils.mkdir_p(pending_dir)
  response_path = File.join(pending_dir, 'parse_script_response.yaml')
  File.write(response_path, YAML.dump({ 'response' => response_json.to_json }))
end

def run_parse(script_path, output_dir, extra_args: [])
  stdout, stderr, status = Open3.capture3('ruby', PARSE_SCRIPT, script_path, output_dir, *extra_args)
  parsed_path = File.join(output_dir, 'script_parsed.yaml')
  parsed = File.exist?(parsed_path) ? YAML.safe_load(File.read(parsed_path)) : nil
  { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, parsed: parsed }
end

RSpec.describe 'parse_script.rb' do
  describe 'tree format via mocked LLM' do
    it 'produces valid tree from mocked LLM response' do
      Dir.mktmpdir do |dir|
        script_dir = File.join(dir, 'project')
        output_dir = File.join(script_dir, '.thelma', 'transcripts')
        FileUtils.mkdir_p(output_dir)
        FileUtils.mkdir_p(File.join(script_dir, '.thelma', 'pending_llm_calls'))

        # 6-line script: hook, intro text, BB, BB body, end cta, closing
        script_text = "Opening hook line.\nIntro before BB.\nBB #1 — First idea\nFirst idea details.\nEND CTA\nClosing words."
        path = write_script(script_dir, 'test.txt', script_text)

        response = {
          'beats' => [
            { 'id' => 'hook', 'role' => 'hook', 'label' => 'Hook',
              'lines' => [1, 1], 'parent' => nil, 'children' => [] },
            { 'id' => 'intro', 'role' => 'section', 'label' => 'Introduction',
              'lines' => [2, 2], 'parent' => nil, 'children' => ['bb_1'] },
            { 'id' => 'bb_1', 'role' => 'blueprint', 'label' => 'BB #1 — First idea',
              'lines' => [3, 4], 'parent' => 'intro', 'children' => [] },
            { 'id' => 'end_cta', 'role' => 'cta', 'label' => 'END CTA',
              'lines' => [5, 6], 'parent' => nil, 'children' => [] }
          ]
        }
        seed_parse_response(output_dir, response)

        result = run_parse(path, output_dir)
        expect(result[:exit_code]).to eq(0)
        expect(result[:parsed]['format']).to eq('tree')
        expect(result[:parsed]['beats'].size).to eq(4)

        bb = result[:parsed]['beats'].find { |b| b['id'] == 'bb_1' }
        expect(bb['role']).to eq('blueprint')
        expect(bb['parent']).to eq('intro')
        expect(bb['text']).to include('First idea')
        # Lines field should be removed from output
        expect(bb).not_to have_key('lines')
      end
    end

    it 'rejects orphan parent references' do
      Dir.mktmpdir do |dir|
        script_dir = File.join(dir, 'project')
        output_dir = File.join(script_dir, '.thelma', 'transcripts')
        FileUtils.mkdir_p(output_dir)
        FileUtils.mkdir_p(File.join(script_dir, '.thelma', 'pending_llm_calls'))

        path = write_script(script_dir, 'test.txt', 'Some text.')
        response = {
          'beats' => [
            { 'id' => 'orphan', 'role' => 'section', 'label' => 'Orphan',
              'lines' => [1, 1], 'parent' => 'nonexistent', 'children' => [] }
          ]
        }
        seed_parse_response(output_dir, response)

        result = run_parse(path, output_dir)
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include("parent 'nonexistent' not found")
      end
    end

    it 'rejects nesting deeper than 2 levels' do
      Dir.mktmpdir do |dir|
        script_dir = File.join(dir, 'project')
        output_dir = File.join(script_dir, '.thelma', 'transcripts')
        FileUtils.mkdir_p(output_dir)
        FileUtils.mkdir_p(File.join(script_dir, '.thelma', 'pending_llm_calls'))

        path = write_script(script_dir, 'test.txt', "A\nB\nC.")
        response = {
          'beats' => [
            { 'id' => 'root', 'role' => 'section', 'label' => 'Root',
              'lines' => [1, 1], 'parent' => nil, 'children' => ['mid'] },
            { 'id' => 'mid', 'role' => 'section', 'label' => 'Mid',
              'lines' => [2, 2], 'parent' => 'root', 'children' => ['deep'] },
            { 'id' => 'deep', 'role' => 'blueprint', 'label' => 'Deep',
              'lines' => [3, 3], 'parent' => 'mid', 'children' => [] }
          ]
        }
        seed_parse_response(output_dir, response)

        result = run_parse(path, output_dir)
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('nesting > 2 levels')
      end
    end

    it 'warns when text reconstruction drops below 95%' do
      Dir.mktmpdir do |dir|
        script_dir = File.join(dir, 'project')
        output_dir = File.join(script_dir, '.thelma', 'transcripts')
        FileUtils.mkdir_p(output_dir)
        FileUtils.mkdir_p(File.join(script_dir, '.thelma', 'pending_llm_calls'))

        # 2-line script, but LLM only covers line 1
        path = write_script(script_dir, 'test.txt',
          "one two three four five six seven eight nine ten\neleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty")
        response = {
          'beats' => [
            { 'id' => 'partial', 'role' => 'section', 'label' => 'Partial',
              'lines' => [1, 1], 'parent' => nil, 'children' => [] }
          ]
        }
        seed_parse_response(output_dir, response)

        result = run_parse(path, output_dir)
        # Should still succeed (warn, not abort) but with coverage warning
        expect(result[:exit_code]).to eq(0)
        expect(result[:stderr]).to include('WARNING: Text reconstruction coverage')
      end
    end

    it 'strips markdown fences from JSON response' do
      Dir.mktmpdir do |dir|
        script_dir = File.join(dir, 'project')
        output_dir = File.join(script_dir, '.thelma', 'transcripts')
        FileUtils.mkdir_p(output_dir)
        FileUtils.mkdir_p(File.join(script_dir, '.thelma', 'pending_llm_calls'))

        path = write_script(script_dir, 'test.txt', 'Hello world.')
        response = {
          'beats' => [
            { 'id' => 'hook', 'role' => 'hook', 'label' => 'Hook',
              'lines' => [1, 1], 'parent' => nil, 'children' => [] }
          ]
        }
        # Wrap in markdown fences
        fenced = "```json\n#{response.to_json}\n```"
        pending_dir = File.join(output_dir, '..', 'pending_llm_calls')
        pending_dir = File.expand_path(pending_dir)
        FileUtils.mkdir_p(pending_dir)
        File.write(File.join(pending_dir, 'parse_script_response.yaml'),
                   YAML.dump({ 'response' => fenced }))

        result = run_parse(path, output_dir)
        expect(result[:exit_code]).to eq(0)
        expect(result[:parsed]['beats'].size).to eq(1)
      end
    end

    it 'rejects children/parent mismatch' do
      Dir.mktmpdir do |dir|
        script_dir = File.join(dir, 'project')
        output_dir = File.join(script_dir, '.thelma', 'transcripts')
        FileUtils.mkdir_p(output_dir)
        FileUtils.mkdir_p(File.join(script_dir, '.thelma', 'pending_llm_calls'))

        path = write_script(script_dir, 'test.txt', "A\nB.")
        response = {
          'beats' => [
            { 'id' => 'parent', 'role' => 'section', 'label' => 'Parent',
              'lines' => [1, 1], 'parent' => nil, 'children' => ['ghost'] },
            { 'id' => 'child', 'role' => 'blueprint', 'label' => 'Child',
              'lines' => [2, 2], 'parent' => 'parent', 'children' => [] }
          ]
        }
        seed_parse_response(output_dir, response)

        result = run_parse(path, output_dir)
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('children mismatch')
      end
    end
  end

  describe 'format single backwards compatibility' do
    it 'multi_short format still works with regex parser' do
      Dir.mktmpdir do |dir|
        script_text = "#1 \"Test Short\"\nHOOK: This is the hook.\nCLOSE: This is the close."
        path = write_script(dir, 'test.txt', script_text)

        result = run_parse(path, dir)
        expect(result[:exit_code]).to eq(0)
        expect(result[:parsed]['format']).to eq('multi_short')
        expect(result[:parsed]['shorts'].size).to eq(1)
        expect(result[:parsed]['shorts'][0]['beats'].size).to eq(2)
      end
    end
  end
end
