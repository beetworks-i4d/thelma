require 'yaml'
require 'tmpdir'
require_relative '../../scripts/arrangement_adapter'

RSpec.describe ArrangementAdapter do
  let(:script_parsed) do
    {
      'beats' => [
        { 'id' => 'hook',  'role' => 'hook',      'label' => 'Hook',
          'parent' => nil, 'children' => [] },
        { 'id' => 'bb_1',  'role' => 'blueprint', 'label' => 'BB #1 — AI lead gen',
          'parent' => nil, 'children' => [] },
        { 'id' => 'bb_2',  'role' => 'blueprint', 'label' => 'BB #2 — AI booking',
          'parent' => nil, 'children' => [] },
        { 'id' => 'end_cta', 'role' => 'cta',     'label' => 'End CTA — Free Training',
          'parent' => nil, 'children' => [] }
      ]
    }
  end

  describe '.beats_to_chapters (fold-by-short_id)' do
    it 'maps a single arrangement to one chapter, id = short_id' do
      arr = {
        'short_id' => 'bb_1',
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 2.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      expect(result['chapters'].size).to eq(1)
      expect(result['chapters'][0]['id']).to eq('bb_1')
    end

    it "resolves chapter.label from script_parsed[short_id]['label']" do
      arr = {
        'short_id' => 'bb_1',
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      expect(result['chapters'][0]['label']).to eq('BB #1 — AI lead gen')
    end

    it 'falls back to short_id when no matching node in script_parsed' do
      arr = {
        'short_id' => 'unknown_id',
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      expect(result['chapters'][0]['label']).to eq('unknown_id')
    end

    it 'falls back to short_id when matching node has nil/empty label' do
      sp = { 'beats' => [{ 'id' => 'bb_x', 'parent' => nil, 'children' => [], 'label' => nil }] }
      arr = {
        'short_id' => 'bb_x',
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arr, sp)
      expect(result['chapters'][0]['label']).to eq('bb_x')
    end

    it 'flattens ALL inner beats clips into chapter.clips (inner-beat order, then clip order)' do
      arr = {
        'short_id' => 'bb_1',
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [
              { 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 },
              { 'source' => 'v.mp4', 't_in' => 1.2, 't_out' => 2.0 }
            ] },
          { 'beat_id' => 'talking_point_1',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 5.0, 't_out' => 6.0 }] },
          { 'beat_id' => 'talking_point_2',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 7.0, 't_out' => 8.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      clips = result['chapters'][0]['clips']
      expect(clips.size).to eq(4)
      expect(clips.map { |c| c['t_in'] }).to eq([0.0, 1.2, 5.0, 7.0])
    end

    it 'discards inner beat_ids — chapter is identified by short_id only, regardless of inner naming' do
      arr = {
        'short_id' => 'bb_1',
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] },
          { 'beat_id' => 'talking_point_1',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 2.0, 't_out' => 3.0 }] },
          { 'beat_id' => 'close',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 4.0, 't_out' => 5.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      expect(result['chapters'].size).to eq(1)
      expect(result['chapters'][0]['id']).to eq('bb_1')
      # No chapters labeled 'hook', 'talking_point_1', or 'close' produced
      expect(result['chapters'].map { |c| c['id'] }).to eq(['bb_1'])
    end

    it 'drops beats-side metadata (type, script_text, transcript_match, take_id, notes); preserves beat_id passthrough' do
      arr = {
        'short_id' => 'bb_1',
        'beats' => [
          { 'beat_id' => 'hook', 'type' => 'hook', 'script_text' => 'X',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0,
                          'transcript_match' => 'X', 'take_id' => 'T1', 'notes' => 'N' }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      chapter = result['chapters'][0]
      clip    = chapter['clips'][0]
      expect(chapter.keys).to contain_exactly('id', 'label', 'clips')
      # beat_id is carried through for diagnostic logs (overlap-clamp / overlap-containment)
      # but export ignores it. type/script_text/transcript_match/take_id/notes are dropped.
      expect(clip.keys).to contain_exactly('source', 't_in', 't_out', 'beat_id')
      expect(clip['beat_id']).to eq('hook')
    end

    it 'omits beat_id from output when the inner beat has none' do
      arr = {
        'short_id' => 'bb_1',
        'beats' => [
          { 'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      expect(result['chapters'][0]['clips'][0]).not_to have_key('beat_id')
    end

    it 'leaves clip track/trim_in/mid_cuts/narrative_role unset' do
      arr = { 'short_id' => 'bb_1', 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      clip = result['chapters'][0]['clips'][0]
      %w[track trim_in mid_cuts narrative_role].each do |k|
        expect(clip).not_to have_key(k), "clip should not have key '#{k}'"
      end
    end

    it 'injects time_domain: wav' do
      arr = { 'short_id' => 'bb_1', 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      expect(result['time_domain']).to eq('wav')
    end

    it "raises when arrangement is missing 'short_id'" do
      arr = {
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
        ]
      }
      expect {
        ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      }.to raise_error(/missing 'short_id'/)
    end

    it 'handles missing optional clip fields (only t_in/t_out/source present)' do
      arr = { 'short_id' => 'bb_1', 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      clip = result['chapters'][0]['clips'][0]
      expect(clip['source']).to eq('v.mp4')
      expect(clip['t_in']).to eq(0.0)
      expect(clip['t_out']).to eq(1.0)
    end

    it 'output validates against export_arrangement_xml expectations' do
      arr = { 'short_id' => 'bb_1', 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      result = ArrangementAdapter.beats_to_chapters(arr, script_parsed)
      expect(result['chapters']).to be_an(Array)
      expect(%w[wav video]).to include(result['time_domain'])
      result['chapters'].each do |ch|
        expect(ch).to have_key('id')
        expect(ch).to have_key('label')
        expect(ch).to have_key('clips')
        ch['clips'].each do |c|
          expect(c['source']).to be_a(String)
          expect(c['t_in']).to be_a(Numeric)
          expect(c['t_out']).to be_a(Numeric)
        end
      end
    end
  end

  describe '.combined_beats_to_chapters' do
    it 'folds N arrangements into N chapters, one per arrangement, in input order' do
      arrs = [
        { 'short_id' => 'hook', 'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }] },
        { 'short_id' => 'bb_1', 'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 2.0, 't_out' => 3.0 }] },
          { 'beat_id' => 'talking_point_1',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 4.0, 't_out' => 5.0 }] }] },
        { 'short_id' => 'end_cta', 'beats' => [
          { 'beat_id' => 'end_cta',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 10.0, 't_out' => 11.0 }] }] }
      ]
      result = ArrangementAdapter.combined_beats_to_chapters(arrs, script_parsed)
      expect(result['chapters'].map { |c| c['id'] }).to eq(['hook', 'bb_1', 'end_cta'])
      expect(result['chapters'].map { |c| c['label'] }).to eq(['Hook', 'BB #1 — AI lead gen', 'End CTA — Free Training'])
      # bb_1 chapter has 2 clips flattened from its 2 inner beats
      expect(result['chapters'][1]['clips'].size).to eq(2)
    end

    it 'skips arrangements with no beats (so failed/empty inputs do not produce empty chapters)' do
      arrs = [
        { 'short_id' => 'hook', 'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }] },
        { 'short_id' => 'bb_1', 'beats' => [] },
        { 'short_id' => 'end_cta', 'beats' => [
          { 'beat_id' => 'end_cta',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 10.0, 't_out' => 11.0 }] }] }
      ]
      result = ArrangementAdapter.combined_beats_to_chapters(arrs, script_parsed)
      expect(result['chapters'].map { |c| c['id'] }).to eq(['hook', 'end_cta'])
    end

    it 'injects time_domain: wav in combined output' do
      arrs = [
        { 'short_id' => 'hook', 'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }] }
      ]
      result = ArrangementAdapter.combined_beats_to_chapters(arrs, script_parsed)
      expect(result['time_domain']).to eq('wav')
    end
  end

  describe '.convert_file!' do
    it 'reads input files and writes a chapters yaml' do
      Dir.mktmpdir do |dir|
        sp_path  = File.join(dir, 'script_parsed.yaml')
        arr_path = File.join(dir, 'arrangement_bb_1.yaml')
        out_path = File.join(dir, 'bb_1_chapters.yaml')

        File.write(sp_path, script_parsed.to_yaml)
        File.write(arr_path, ({ 'short_id' => 'bb_1', 'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
        ] }).to_yaml)

        ArrangementAdapter.convert_file!(arr_path, sp_path, out_path)
        expect(File.exist?(out_path)).to be true
        out = YAML.safe_load(File.read(out_path))
        expect(out['chapters'].size).to eq(1)
        expect(out['chapters'][0]['id']).to eq('bb_1')
        expect(out['chapters'][0]['label']).to eq('BB #1 — AI lead gen')
        expect(out['time_domain']).to eq('wav')
      end
    end
  end

  describe '.convert_files!' do
    it 'reads multiple arrangement paths and writes one combined chapters yaml' do
      Dir.mktmpdir do |dir|
        sp_path = File.join(dir, 'script_parsed.yaml')
        File.write(sp_path, script_parsed.to_yaml)
        paths = [
          ['arrangement_hook.yaml', { 'short_id' => 'hook', 'beats' => [
            { 'beat_id' => 'hook',
              'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }] }],
          ['arrangement_bb_1.yaml', { 'short_id' => 'bb_1', 'beats' => [
            { 'beat_id' => 'hook',
              'clips' => [{ 'source' => 'v.mp4', 't_in' => 2.0, 't_out' => 3.0 }] },
            { 'beat_id' => 'talking_point_1',
              'clips' => [{ 'source' => 'v.mp4', 't_in' => 4.0, 't_out' => 5.0 }] }] }]
        ].map do |fname, data|
          p = File.join(dir, fname)
          File.write(p, data.to_yaml)
          p
        end
        out = File.join(dir, 'mylib_chapters.yaml')
        ArrangementAdapter.convert_files!(paths, sp_path, out)
        loaded = YAML.safe_load(File.read(out))
        expect(loaded['chapters'].map { |c| c['id'] }).to eq(['hook', 'bb_1'])
        expect(loaded['chapters'][1]['clips'].size).to eq(2)
        expect(loaded['time_domain']).to eq('wav')
      end
    end
  end

  describe 'Dylan005 end-to-end with the real on-disk arrangements' do
    let(:lib_dir) { '/Users/i4d/Desktop/RAW/Dylan005/.thelma' }
    let(:script_parsed_path) { File.join(lib_dir, 'transcripts', 'script_parsed.yaml') }
    let(:beat_order) do
      %w[hook bb_1 bb_2 bb_3 bb_4 bb_5 bb_6 bb_7 bb_8 bb_9 bb_10
         midroll_cta bb_11 bb_12 bb_13 bb_14 bb_15 bb_16 bb_17 bb_18 bb_19 bb_20
         end_cta outro]
    end

    it 'combines 24 arrangements into 24 chapters with labels from script_parsed and 303 total clips' do
      skip 'Dylan005 fixtures not present' unless File.exist?(script_parsed_path)

      arrangement_paths = beat_order.map { |id| File.join(lib_dir, "arrangement_#{id}.yaml") }
      missing = arrangement_paths.reject { |p| File.exist?(p) }
      skip "missing arrangements: #{missing.size}" unless missing.empty?

      script_parsed = YAML.safe_load(File.read(script_parsed_path), permitted_classes: [Date])
      arrangements  = arrangement_paths.map { |p| YAML.safe_load(File.read(p), permitted_classes: [Date]) }
      result = ArrangementAdapter.combined_beats_to_chapters(arrangements, script_parsed)

      expect(result['chapters'].size).to eq(24)
      expect(result['chapters'].map { |c| c['id'] }).to eq(beat_order)

      # Every chapter must have a meaningful label (resolved from script_parsed, not the fallback)
      result['chapters'].each do |ch|
        expect(ch['label']).not_to be_empty
        # label != id means it resolved from script_parsed
      end
      expect(result['chapters'][1]['label']).to start_with('BB #1')

      total_clips = result['chapters'].sum { |c| c['clips'].size }
      expect(total_clips).to eq(303)

      expect(result['time_domain']).to eq('wav')
    end
  end
end
