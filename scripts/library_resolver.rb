require 'yaml'

# Central library directory resolution.
# Priority: ENV var → registry → legacy fallback (~/thelma/libraries/<name>/).
#
# Usage:
#   require_relative 'library_resolver'
#   library_dir = LibraryResolver.resolve(library_name)
#
# After auto-creating a new library at <pool_dir>/.thelma:
#   LibraryResolver.register(library_name, library_dir)

module LibraryResolver
  RESOLVER_ROOT  = File.expand_path('../../', __FILE__)
  REGISTRY_PATH  = File.join(RESOLVER_ROOT, 'libraries_registry.yaml')

  def self.resolve(library_name)
    # Priority 1: ENV var (set by orchestrate so sub-processes inherit correct path)
    env = ENV['THELMA_LIBRARY_DIR']
    return env if env && !env.empty?

    # Priority 2: registry (new .thelma-based libraries)
    reg = read_registry
    if reg
      path = reg.dig('libraries', library_name, 'path')
      return path if path && File.directory?(path)
    end

    # Priority 3: legacy fallback (existing libraries/<name>/)
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
