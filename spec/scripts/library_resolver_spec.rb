require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'

LIBRARY_RESOLVER_PATH = File.expand_path('../../scripts/library_resolver.rb', __dir__)

# Helper: inline resolver code with custom root/registry for testing
def resolver_code(root_dir:, registry_path:)
  <<~RUBY
    require 'yaml'
    RESOLVER_ROOT = '#{root_dir}'
    REGISTRY_PATH = '#{registry_path}'
    module LibraryResolver
      def self.resolve(library_name)
        env = ENV['THELMA_LIBRARY_DIR']
        return env if env && !env.empty?
        reg = read_registry
        if reg
          path = reg.dig('libraries', library_name, 'path')
          return path if path && File.directory?(path)
        end
        File.join(RESOLVER_ROOT, 'libraries', library_name)
      end
      def self.register(library_name, library_dir)
        reg = read_registry || { 'libraries' => {} }
        reg['libraries'][library_name] = { 'path' => library_dir }
        File.write(REGISTRY_PATH, reg.to_yaml)
      end
      def self.read_registry
        return nil unless File.exist?(REGISTRY_PATH)
        YAML.safe_load(File.read(REGISTRY_PATH)) rescue nil
      end
    end
  RUBY
end

RSpec.describe 'LibraryResolver' do
  describe 'ENV priority' do
    it 'returns THELMA_LIBRARY_DIR when set, regardless of registry or legacy' do
      Dir.mktmpdir do |tmpdir|
        stdout, _, status = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '/tmp/env-override' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: File.join(tmpdir, 'reg.yaml'))}
            puts LibraryResolver.resolve('anylib')
          RUBY
        )
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq('/tmp/env-override')
      end
    end

    it 'falls through when THELMA_LIBRARY_DIR is empty string' do
      Dir.mktmpdir do |tmpdir|
        stdout, _, status = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: File.join(tmpdir, 'reg.yaml'))}
            puts LibraryResolver.resolve('mylib')
          RUBY
        )
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq(File.join(tmpdir, 'libraries', 'mylib'))
      end
    end
  end

  describe 'registry lookup' do
    it 'returns registry path when it exists as a directory' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'registry.yaml')
        target_dir    = File.join(tmpdir, 'footage', '.thelma')
        FileUtils.mkdir_p(target_dir)

        registry = { 'libraries' => { 'mylib' => { 'path' => target_dir } } }
        File.write(registry_path, registry.to_yaml)

        stdout, _, status = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: registry_path)}
            puts LibraryResolver.resolve('mylib')
          RUBY
        )
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq(target_dir)
      end
    end

    it 'falls through to legacy when registry path directory does not exist' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'registry.yaml')
        nonexistent   = File.join(tmpdir, 'gone', '.thelma')

        registry = { 'libraries' => { 'mylib' => { 'path' => nonexistent } } }
        File.write(registry_path, registry.to_yaml)

        stdout, _, status = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: registry_path)}
            puts LibraryResolver.resolve('mylib')
          RUBY
        )
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq(File.join(tmpdir, 'libraries', 'mylib'))
      end
    end
  end

  describe 'legacy fallback' do
    it 'returns legacy path when no registry exists' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'no-registry.yaml')  # does not exist

        stdout, _, status = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: registry_path)}
            puts LibraryResolver.resolve('mylib')
          RUBY
        )
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq(File.join(tmpdir, 'libraries', 'mylib'))
      end
    end
  end

  describe 'register' do
    it 'creates registry file when it does not exist' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'registry.yaml')

        _, _, status = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: registry_path)}
            LibraryResolver.register('mylib', '/some/path')
          RUBY
        )
        expect(status.exitstatus).to eq(0)
        expect(File.exist?(registry_path)).to eq(true)
        data = YAML.safe_load(File.read(registry_path))
        expect(data.dig('libraries', 'mylib', 'path')).to eq('/some/path')
      end
    end

    it 'updates existing registry without overwriting other entries' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'registry.yaml')

        _, _, _ = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: registry_path)}
            LibraryResolver.register('lib-a', '/path/a')
            LibraryResolver.register('lib-b', '/path/b')
          RUBY
        )
        data = YAML.safe_load(File.read(registry_path))
        expect(data.dig('libraries', 'lib-a', 'path')).to eq('/path/a')
        expect(data.dig('libraries', 'lib-b', 'path')).to eq('/path/b')
      end
    end

    it 'overwrites existing entry for same library name' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'registry.yaml')

        _, _, _ = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: registry_path)}
            LibraryResolver.register('mylib', '/old/path')
            LibraryResolver.register('mylib', '/new/path')
          RUBY
        )
        data = YAML.safe_load(File.read(registry_path))
        expect(data.dig('libraries', 'mylib', 'path')).to eq('/new/path')
      end
    end
  end

  describe 'read_registry' do
    it 'returns nil when registry file does not exist' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'missing.yaml')

        stdout, _, status = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: registry_path)}
            puts LibraryResolver.read_registry.inspect
          RUBY
        )
        expect(status.exitstatus).to eq(0)
        expect(stdout.strip).to eq('nil')
      end
    end

    it 'returns nil gracefully for corrupt YAML' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'bad.yaml')
        File.write(registry_path, ":\tbad: yaml: {{{")

        _, _, status = Open3.capture3(
          { 'THELMA_LIBRARY_DIR' => '' },
          'ruby', '-e', <<~RUBY
            #{resolver_code(root_dir: tmpdir, registry_path: registry_path)}
            LibraryResolver.read_registry
            puts 'ok'
          RUBY
        )
        expect(status.exitstatus).to eq(0)
      end
    end
  end
end
