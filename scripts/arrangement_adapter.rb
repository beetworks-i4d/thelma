#!/usr/bin/env ruby
# Bridges arrange_to_script.rb's beats: schema -> export_arrangement_xml.rb's
# chapters: schema. Each top-level script tree node becomes one chapter; all
# arrangement beats under that node contribute their clips in beat order then
# clip order. Chapter labels come from script_parsed.yaml.

require 'yaml'
require 'date'

module ArrangementAdapter
  module_function

  def beats_to_chapters(arrangement, script_parsed)
    script_index = (script_parsed['beats'] || []).each_with_object({}) { |b, h| h[b['id']] = b }

    chapters_order = []
    chapters_by_ancestor = {}

    (arrangement['beats'] || []).each do |a_beat|
      beat_id = a_beat['beat_id']
      ancestor = top_level_ancestor(beat_id, script_index)
      raise "Unmapped beat_id '#{beat_id}' — not found in script_parsed.yaml" unless ancestor

      key = ancestor['id']
      unless chapters_by_ancestor.key?(key)
        chapters_by_ancestor[key] = { node: ancestor, beats: [] }
        chapters_order << key
      end
      chapters_by_ancestor[key][:beats] << a_beat
    end

    chapters = chapters_order.map do |key|
      group = chapters_by_ancestor[key]
      node  = group[:node]
      clips = group[:beats].flat_map { |b| (b['clips'] || []).map { |c| clip_to_chapter_clip(c) } }
      {
        'id'    => node['id'],
        'label' => node['label'] || node['id'],
        'clips' => clips
      }
    end

    { 'time_domain' => 'wav', 'chapters' => chapters }
  end

  def top_level_ancestor(beat_id, script_index)
    node = script_index[beat_id]
    return nil unless node
    visited = {}
    while node && node['parent']
      break if visited[node['id']]
      visited[node['id']] = true
      parent = script_index[node['parent']]
      break unless parent
      node = parent
    end
    node
  end

  def clip_to_chapter_clip(clip)
    {
      'source' => clip['source'],
      't_in'   => clip['t_in'].to_f,
      't_out'  => clip['t_out'].to_f
    }
  end

  def convert_file!(arrangement_path, script_parsed_path, output_path)
    arrangement   = YAML.safe_load(File.read(arrangement_path), permitted_classes: [Date])
    script_parsed = YAML.safe_load(File.read(script_parsed_path), permitted_classes: [Date])
    chapters_data = beats_to_chapters(arrangement, script_parsed)
    File.write(output_path, chapters_data.to_yaml)
    output_path
  end
end
