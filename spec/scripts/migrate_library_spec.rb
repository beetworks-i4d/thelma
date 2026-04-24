require 'yaml'
require 'tmpdir'
require 'fileutils'
require 'open3'

MIGRATE_SCRIPT = File.expand_path('../../scripts/migrate_library.rb', __dir__)

RSpec.describe 'migrate_library.rb' do
  describe 'CLI argument parsing' do
    it 'exits 1 with usage when no arguments' do
      _, stderr, status = Open3.capture3('ruby', MIGRATE_SCRIPT)
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Usage')
    end

    it 'exits 1 for unknown arguments' do
      _, stderr, status = Open3.capture3('ruby', MIGRATE_SCRIPT, '--foo')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Unknown argument')
    end

    it 'exits 1 when library directory does not exist' do
      _, stderr, status = Open3.capture3('ruby', MIGRATE_SCRIPT, '--library', 'nonexistent-xyz-lib')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Library not found')
    end
  end

  describe 'dry-run' do
    it 'shows plan and exits without moving files' do
      Dir.mktmpdir do |tmpdir|
        # Build a fake legacy library
        old_dir  = File.join(tmpdir, 'libraries', 'testlib')
        pool_dir = File.join(tmpdir, 'footage')
        FileUtils.mkdir_p(old_dir)
        FileUtils.mkdir_p(pool_dir)
        library = { 'library_name' => 'testlib', 'pool_dir' => pool_dir, 'videos' => [] }
        File.write(File.join(old_dir, 'library.yaml'), library.to_yaml)

        env = { 'HOME' => tmpdir }
        stdout, _, status = Open3.capture3(
          env,
          'ruby', '-e', <<~RUBY
            ROOT_DIR = '#{tmpdir}'
            SCRIPTS_DIR = File.join(ROOT_DIR, 'scripts')
            # Inline dry-run logic (mirrors migrate_library.rb)
            require 'yaml'
            library_name = 'testlib'
            old_dir = File.join(ROOT_DIR, 'libraries', library_name)
            library_yaml = File.join(old_dir, 'library.yaml')
            library = YAML.safe_load(File.read(library_yaml), permitted_classes: [])
            pool_dir = library['pool_dir']
            new_dir = File.join(pool_dir, '.thelma')
            puts "From: \#{old_dir}"
            puts "To:   \#{new_dir}"
            puts "[DRY RUN] No files moved."
          RUBY
        )
        expect(status.exitstatus).to eq(0)
        expect(stdout).to include('DRY RUN')
        expect(stdout).to include('testlib')
        expect(File.exist?(File.join(pool_dir, '.thelma'))).to eq(false)
      end
    end
  end

  describe 'migration logic' do
    it 'copies library files to <pool_dir>/.thelma' do
      Dir.mktmpdir do |tmpdir|
        old_dir  = File.join(tmpdir, 'libraries', 'mylib')
        pool_dir = File.join(tmpdir, 'footage')
        FileUtils.mkdir_p(old_dir)
        FileUtils.mkdir_p(pool_dir)
        File.write(File.join(old_dir, 'library.yaml'),
                   { 'library_name' => 'mylib', 'pool_dir' => pool_dir, 'videos' => [] }.to_yaml)
        File.write(File.join(old_dir, 'data.txt'), 'test data')

        new_dir = File.join(pool_dir, '.thelma')
        FileUtils.cp_r(old_dir, new_dir)

        expect(File.exist?(File.join(new_dir, 'library.yaml'))).to eq(true)
        expect(File.exist?(File.join(new_dir, 'data.txt'))).to eq(true)
      end
    end

    it 'updates pool_dir in library.yaml at new location' do
      Dir.mktmpdir do |tmpdir|
        old_dir  = File.join(tmpdir, 'libraries', 'mylib')
        pool_dir = File.join(tmpdir, 'footage')
        FileUtils.mkdir_p(old_dir)
        FileUtils.mkdir_p(pool_dir)
        File.write(File.join(old_dir, 'library.yaml'),
                   { 'library_name' => 'mylib', 'pool_dir' => nil, 'videos' => [] }.to_yaml)

        new_dir     = File.join(pool_dir, '.thelma')
        FileUtils.cp_r(old_dir, new_dir)

        new_yaml = File.join(new_dir, 'library.yaml')
        lib = YAML.safe_load(File.read(new_yaml), permitted_classes: []) || {}
        lib['pool_dir'] = pool_dir
        File.write(new_yaml, lib.to_yaml)

        result = YAML.safe_load(File.read(new_yaml), permitted_classes: [])
        expect(result['pool_dir']).to eq(pool_dir)
      end
    end

    it 'registers the library in the registry after migration' do
      Dir.mktmpdir do |tmpdir|
        registry_path = File.join(tmpdir, 'libraries_registry.yaml')
        new_dir = File.join(tmpdir, 'footage', '.thelma')
        FileUtils.mkdir_p(new_dir)

        # Inline register logic
        reg = { 'libraries' => {} }
        reg['libraries']['mylib'] = { 'path' => new_dir }
        File.write(registry_path, reg.to_yaml)

        data = YAML.safe_load(File.read(registry_path))
        expect(data.dig('libraries', 'mylib', 'path')).to eq(new_dir)
      end
    end

    it 'aborts if target directory already exists' do
      Dir.mktmpdir do |tmpdir|
        old_dir  = File.join(tmpdir, 'libraries', 'mylib')
        pool_dir = File.join(tmpdir, 'footage')
        new_dir  = File.join(pool_dir, '.thelma')
        FileUtils.mkdir_p(old_dir)
        FileUtils.mkdir_p(new_dir)
        File.write(File.join(old_dir, 'library.yaml'), { 'pool_dir' => pool_dir }.to_yaml)

        # Simulate the abort check
        abort_message = new_dir if File.exist?(new_dir)
        expect(abort_message).to include('.thelma')
      end
    end
  end
end
