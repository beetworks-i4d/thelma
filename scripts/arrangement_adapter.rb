#!/usr/bin/env ruby
# Bridges arrange_to_script.rb's beats: schema -> export_arrangement_xml.rb's
# chapters: schema.
#
# Fold-by-short_id model: each arrangement file represents one script short
# (one --short call). One arrangement -> one chapter.
#   chapter.id    = arrangement.short_id
#   chapter.label = script_parsed[short_id].label, fall back to short_id
#   chapter.clips = ALL clips from ALL inner beats, flattened in
#                   inner-beat order then clip order.
# Inner beat_ids (hook, talking_point_N, close) are discarded — they only
# determined clip ordering inside the arrangement, which the flatten preserves.

require 'yaml'
require 'date'

module ArrangementAdapter
  module_function

  def beats_to_chapters(arrangement, script_parsed)
    combined_beats_to_chapters([arrangement], script_parsed)
  end

  def combined_beats_to_chapters(arrangements, script_parsed)
    script_index = (script_parsed['beats'] || []).each_with_object({}) { |b, h| h[b['id']] = b }

    chapters = arrangements
               .reject { |arr| (arr['beats'] || []).empty? }
               .map { |arr| arrangement_to_chapter(arr, script_index) }

    { 'time_domain' => 'wav', 'chapters' => chapters }
  end

  def arrangement_to_chapter(arrangement, script_index)
    short_id = arrangement['short_id']
    raise "Arrangement missing 'short_id' — cannot determine chapter identity" \
      if short_id.to_s.empty?

    node = script_index[short_id]
    label = node && node['label']
    label = short_id if label.to_s.empty?

    clips = (arrangement['beats'] || []).flat_map do |b|
      (b['clips'] || []).map { |c| clip_to_chapter_clip(c, b['beat_id']) }
    end

    { 'id' => short_id, 'label' => label, 'clips' => clips }
  end

  # Passthrough fields: t_in/t_out/source for export, beat_id for diagnostic
  # logs only (overlap-clamp / overlap-containment messages name the source
  # beat). Export ignores beat_id; it's not part of the export contract.
  def clip_to_chapter_clip(clip, beat_id)
    out = {
      'source' => clip['source'],
      't_in'   => clip['t_in'].to_f,
      't_out'  => clip['t_out'].to_f
    }
    out['beat_id'] = beat_id if beat_id
    out
  end

  def convert_file!(arrangement_path, script_parsed_path, output_path)
    arrangement   = YAML.safe_load(File.read(arrangement_path), permitted_classes: [Date])
    script_parsed = YAML.safe_load(File.read(script_parsed_path), permitted_classes: [Date])
    chapters_data = beats_to_chapters(arrangement, script_parsed)
    File.write(output_path, chapters_data.to_yaml)
    output_path
  end

  def convert_files!(arrangement_paths, script_parsed_path, output_path)
    script_parsed = YAML.safe_load(File.read(script_parsed_path), permitted_classes: [Date])
    arrangements  = arrangement_paths.map { |p| YAML.safe_load(File.read(p), permitted_classes: [Date]) }
    chapters_data = combined_beats_to_chapters(arrangements, script_parsed)
    File.write(output_path, chapters_data.to_yaml)
    output_path
  end
end
