require 'yaml'
require 'tmpdir'
require_relative '../../scripts/arrangement_adapter'

RSpec.describe ArrangementAdapter do
  let(:script_parsed) do
    {
      'beats' => [
        { 'id' => 'hook',  'role' => 'hook',      'label' => 'Hook',
          'parent' => nil, 'children' => [] },
        { 'id' => 'intro', 'role' => 'section',   'label' => 'Introduction',
          'parent' => nil, 'children' => ['bb_1', 'bb_2'] },
        { 'id' => 'bb_1',  'role' => 'blueprint', 'label' => 'BB #1',
          'parent' => 'intro', 'children' => [] },
        { 'id' => 'bb_2',  'role' => 'blueprint', 'label' => 'BB #2',
          'parent' => 'intro', 'children' => [] },
        { 'id' => 'cta',   'role' => 'cta',       'label' => 'End CTA',
          'parent' => nil, 'children' => [] }
      ]
    }
  end

  describe '.beats_to_chapters' do
    it 'maps a single top-level script node to one chapter' do
      arrangement = {
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 2.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      expect(result['chapters'].size).to eq(1)
      expect(result['chapters'][0]['id']).to eq('hook')
    end

    it 'flattens clips from multiple arrangement beats under one ancestor in beat order then clip order' do
      arrangement = {
        'beats' => [
          { 'beat_id' => 'bb_1',
            'clips' => [
              { 'source' => 'v.mp4', 't_in' => 1.0, 't_out' => 2.0 },
              { 'source' => 'v.mp4', 't_in' => 2.5, 't_out' => 3.5 }
            ] },
          { 'beat_id' => 'bb_2',
            'clips' => [
              { 'source' => 'v.mp4', 't_in' => 5.0, 't_out' => 6.0 }
            ] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      # bb_1 and bb_2 both have parent='intro' — they collapse into one chapter
      expect(result['chapters'].size).to eq(1)
      expect(result['chapters'][0]['id']).to eq('intro')
      expect(result['chapters'][0]['label']).to eq('Introduction')
      clips = result['chapters'][0]['clips']
      expect(clips.size).to eq(3)
      expect(clips.map { |c| c['t_in'] }).to eq([1.0, 2.5, 5.0])
    end

    it 'produces multiple chapters when arrangement spans multiple top-level nodes (preserves arrangement order)' do
      arrangement = {
        'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 2.0 }] },
          { 'beat_id' => 'bb_1',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 3.0, 't_out' => 5.0 }] },
          { 'beat_id' => 'cta',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 10.0, 't_out' => 12.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      expect(result['chapters'].map { |c| c['id'] }).to eq(['hook', 'intro', 'cta'])
    end

    it 'injects time_domain: wav' do
      arrangement = { 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      expect(result['time_domain']).to eq('wav')
    end

    it 'sources chapter label from script_parsed, not from arrangement' do
      arrangement = {
        'beats' => [
          { 'beat_id'     => 'hook',
            'type'        => 'hook',
            'script_text' => 'Original hook text from arrangement',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      expect(result['chapters'][0]['label']).to eq('Hook')
      expect(result['chapters'][0]['label']).not_to eq('Original hook text from arrangement')
    end

    it 'drops beats-side metadata (type, script_text, transcript_match, take_id, notes)' do
      arrangement = {
        'beats' => [
          { 'beat_id' => 'hook',
            'type' => 'hook', 'script_text' => 'X',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0,
                          'transcript_match' => 'X', 'take_id' => 'T1', 'notes' => 'N' }] }
        ]
      }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      chapter = result['chapters'][0]
      clip    = chapter['clips'][0]
      expect(chapter.keys).to contain_exactly('id', 'label', 'clips')
      expect(clip.keys).to contain_exactly('source', 't_in', 't_out')
    end

    it 'leaves clip track/trim_in/mid_cuts/narrative_role unset' do
      arrangement = { 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      clip = result['chapters'][0]['clips'][0]
      %w[track trim_in mid_cuts narrative_role].each do |k|
        expect(clip).not_to have_key(k), "clip should not have key '#{k}'"
      end
    end

    it 'raises on unmapped beat_id' do
      arrangement = { 'beats' => [
        { 'beat_id' => 'no_such_beat',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      expect {
        ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      }.to raise_error(/Unmapped beat_id 'no_such_beat'/)
    end

    it 'handles missing optional clip fields (only t_in/t_out/source present)' do
      arrangement = { 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      clip = result['chapters'][0]['clips'][0]
      expect(clip['source']).to eq('v.mp4')
      expect(clip['t_in']).to eq(0.0)
      expect(clip['t_out']).to eq(1.0)
    end

    it 'output validates against export_arrangement_xml expectations' do
      arrangement = { 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
      ] }
      result = ArrangementAdapter.beats_to_chapters(arrangement, script_parsed)
      # top-level invariants export reads
      expect(result['chapters']).to be_an(Array)
      expect(%w[wav video]).to include(result['time_domain'])
      # per-chapter invariants
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

    it 'preserves whole-tree run: each Dylan005-style flat top-level beat becomes its own chapter' do
      # Simulates the Dylan005 case: 24 top-level beats with no parent/child relationships.
      flat_script = {
        'beats' => (1..5).map { |i| { 'id' => "tp_#{i}", 'role' => 'talking_point',
                                       'label' => "TP ##{i}", 'parent' => nil, 'children' => [] } }
      }
      arrangement = {
        'beats' => (1..5).map { |i|
          { 'beat_id' => "tp_#{i}",
            'clips' => [{ 'source' => 'v.mp4', 't_in' => i.to_f, 't_out' => i + 1.0 }] }
        }
      }
      result = ArrangementAdapter.beats_to_chapters(arrangement, flat_script)
      expect(result['chapters'].size).to eq(5)
      expect(result['chapters'].map { |c| c['id'] }).to eq(%w[tp_1 tp_2 tp_3 tp_4 tp_5])
      expect(result['chapters'].map { |c| c['label'] }).to eq(['TP #1', 'TP #2', 'TP #3', 'TP #4', 'TP #5'])
    end
  end

  describe '.combined_beats_to_chapters' do
    it 'folds N per-beat arrangements into one multi-chapter result, in input order' do
      a_hook = { 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 2.0 }] }
      ] }
      a_intro_bb1 = { 'beats' => [
        { 'beat_id' => 'bb_1',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 3.0, 't_out' => 4.0 }] }
      ] }
      a_intro_bb2 = { 'beats' => [
        { 'beat_id' => 'bb_2',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 5.0, 't_out' => 6.0 }] }
      ] }
      a_cta = { 'beats' => [
        { 'beat_id' => 'cta',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 10.0, 't_out' => 11.0 }] }
      ] }
      result = ArrangementAdapter.combined_beats_to_chapters(
        [a_hook, a_intro_bb1, a_intro_bb2, a_cta], script_parsed)
      # bb_1 + bb_2 collapse into intro chapter
      expect(result['chapters'].map { |c| c['id'] }).to eq(['hook', 'intro', 'cta'])
      intro = result['chapters'].find { |c| c['id'] == 'intro' }
      expect(intro['clips'].size).to eq(2)
      expect(intro['clips'].map { |c| c['t_in'] }).to eq([3.0, 5.0])
    end

    it 'skips empty arrangements (failed beats produced no input) without losing the rest' do
      a_hook = { 'beats' => [
        { 'beat_id' => 'hook',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 2.0 }] }
      ] }
      a_empty = { 'beats' => [] }
      a_cta = { 'beats' => [
        { 'beat_id' => 'cta',
          'clips' => [{ 'source' => 'v.mp4', 't_in' => 10.0, 't_out' => 11.0 }] }
      ] }
      result = ArrangementAdapter.combined_beats_to_chapters([a_hook, a_empty, a_cta], script_parsed)
      expect(result['chapters'].map { |c| c['id'] }).to eq(['hook', 'cta'])
    end

    it 'injects time_domain: wav in combined output' do
      result = ArrangementAdapter.combined_beats_to_chapters(
        [{ 'beats' => [{ 'beat_id' => 'hook',
                         'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }] }],
        script_parsed)
      expect(result['time_domain']).to eq('wav')
    end
  end

  describe '.convert_files!' do
    it 'reads multiple arrangement paths and writes one combined chapters yaml' do
      Dir.mktmpdir do |dir|
        sp_path = File.join(dir, 'script_parsed.yaml')
        File.write(sp_path, script_parsed.to_yaml)
        paths = [
          ['arrangement_hook.yaml', { 'beats' => [
            { 'beat_id' => 'hook',
              'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
          ] }],
          ['arrangement_cta.yaml', { 'beats' => [
            { 'beat_id' => 'cta',
              'clips' => [{ 'source' => 'v.mp4', 't_in' => 10.0, 't_out' => 11.0 }] }
          ] }]
        ].map do |fname, data|
          p = File.join(dir, fname)
          File.write(p, data.to_yaml)
          p
        end
        out = File.join(dir, 'mylib_chapters.yaml')
        ArrangementAdapter.convert_files!(paths, sp_path, out)
        loaded = YAML.safe_load(File.read(out))
        expect(loaded['chapters'].size).to eq(2)
        expect(loaded['chapters'].map { |c| c['id'] }).to eq(['hook', 'cta'])
        expect(loaded['time_domain']).to eq('wav')
      end
    end
  end

  describe '.convert_file!' do
    it 'reads input files and writes a chapters yaml' do
      Dir.mktmpdir do |dir|
        sp_path  = File.join(dir, 'script_parsed.yaml')
        arr_path = File.join(dir, 'arrangement_hook.yaml')
        out_path = File.join(dir, 'hook_chapters.yaml')

        File.write(sp_path, script_parsed.to_yaml)
        File.write(arr_path, ({ 'beats' => [
          { 'beat_id' => 'hook',
            'clips' => [{ 'source' => 'v.mp4', 't_in' => 0.0, 't_out' => 1.0 }] }
        ] }).to_yaml)

        ArrangementAdapter.convert_file!(arr_path, sp_path, out_path)
        expect(File.exist?(out_path)).to be true
        out = YAML.safe_load(File.read(out_path))
        expect(out['chapters']).to be_an(Array)
        expect(out['time_domain']).to eq('wav')
        expect(out['chapters'][0]['label']).to eq('Hook')
      end
    end
  end
end
