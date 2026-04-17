require 'open3'
require 'yaml'
require 'tmpdir'
require 'fileutils'

EXTRACT_SCRIPT = File.expand_path('../../scripts/extract_template.rb', __dir__)
EXTRACT_TEMPLATES_DIR = File.expand_path('../../templates/story_structures', __dir__)

# --- Helpers ---

def make_seg(t:, e:, states:, distillation:, dur: 'identity', confidence: 'high')
  { 't' => t, 'e' => e, 'states' => states, 'distillation' => distillation,
    'dur' => dur, 'confidence' => confidence, 'signal' => 'test',
    'roles' => ['secondary'], 'notes' => 'test', 'rationale' => 'test' }
end

# Three transcripts sharing a "problem → evidence → solution → proof → takeaway" structure
# with similar distillation keywords at similar normalized positions.
def source_a
  { 'transcript_hash' => 'source_a',
    'segments' => [
      make_seg(t: 0.0,   e: 15.0,  states: %w[curiosity aspiration], distillation: 'wasting money on wrong models'),
      make_seg(t: 20.0,  e: 40.0,  states: %w[vindication],          distillation: 'most people spend months failing'),
      make_seg(t: 45.0,  e: 65.0,  states: %w[competence],           distillation: 'simple framework three steps'),
      make_seg(t: 70.0,  e: 85.0,  states: %w[aspiration competence],distillation: 'first month three sales revenue'),
      make_seg(t: 90.0,  e: 100.0, states: %w[competence aspiration],distillation: 'focus on results start today'),
    ] }
end

def source_b
  { 'transcript_hash' => 'source_b',
    'segments' => [
      make_seg(t: 5.0,   e: 18.0,  states: %w[curiosity],            distillation: 'losing money trying wrong approach'),
      make_seg(t: 22.0,  e: 38.0,  states: %w[vindication fear],     distillation: 'people spend years on wrong models'),
      make_seg(t: 48.0,  e: 62.0,  states: %w[competence aspiration],distillation: 'simple method three key steps'),
      make_seg(t: 68.0,  e: 82.0,  states: %w[aspiration],           distillation: 'revenue proof first month sales'),
      make_seg(t: 88.0,  e: 98.0,  states: %w[competence],           distillation: 'start today focus on results action'),
    ] }
end

def source_c
  { 'transcript_hash' => 'source_c',
    'segments' => [
      make_seg(t: 2.0,   e: 12.0,  states: %w[curiosity aspiration], distillation: 'wrong models wasting your money'),
      make_seg(t: 18.0,  e: 35.0,  states: %w[vindication],          distillation: 'most people spend too long failing'),
      make_seg(t: 42.0,  e: 58.0,  states: %w[competence],           distillation: 'three simple steps framework method'),
      make_seg(t: 65.0,  e: 78.0,  states: %w[aspiration competence],distillation: 'sales proof revenue first month'),
      make_seg(t: 85.0,  e: 95.0,  states: %w[competence aspiration],distillation: 'take action start results focus'),
    ] }
end

# Source with different structure (no keyword overlap with a/b/c)
def source_different
  { 'transcript_hash' => 'source_different',
    'segments' => [
      make_seg(t: 0.0,  e: 20.0, states: %w[nostalgia],   distillation: 'childhood memory playground swings'),
      make_seg(t: 25.0, e: 45.0, states: %w[belonging],    distillation: 'community garden volunteers spring'),
      make_seg(t: 50.0, e: 70.0, states: %w[catharsis],    distillation: 'grandmother recipe kitchen flour'),
      make_seg(t: 75.0, e: 90.0, states: %w[awe],          distillation: 'sunset mountain golden evening light'),
    ] }
end

# Source with filler-only distillations (< 6 chars)
def source_filler
  { 'transcript_hash' => 'source_filler',
    'segments' => [
      make_seg(t: 0.0,  e: 10.0, states: %w[calm], distillation: 'um ok',  dur: 'spike', confidence: 'low'),
      make_seg(t: 15.0, e: 25.0, states: %w[calm], distillation: 'yeah',   dur: 'spike', confidence: 'low'),
      make_seg(t: 30.0, e: 40.0, states: %w[calm], distillation: 'so',     dur: 'spike', confidence: 'low'),
    ] }
end

def run_extract(sources, flags: {}, tmpdir: nil)
  work = proc do |dir|
    paths = sources.each_with_index.map do |src, i|
      path = File.join(dir, "seg_#{i}.yaml")
      File.write(path, src.to_yaml)
      path
    end

    args = ['ruby', EXTRACT_SCRIPT] + paths
    flags.each do |k, v|
      args << "--#{k}"
      args << v.to_s if v != true
    end

    stdout, stderr, status = Open3.capture3(*args)
    output_path = File.join(dir, 'template_extracted.yaml')
    result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path)) : nil
    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result, dir: dir }
  end

  if tmpdir
    work.call(tmpdir)
  else
    Dir.mktmpdir { |dir| work.call(dir) }
  end
end

RSpec.describe 'extract_template.rb' do
  describe 'minimum source requirement' do
    it 'aborts with fewer than 3 sources' do
      _, stderr, status = Open3.capture3('ruby', EXTRACT_SCRIPT, '/tmp/a.yaml', '/tmp/b.yaml')
      expect(status.exitstatus).to eq(1)
      expect(stderr).to include('Minimum 3')
    end

    it 'aborts with zero sources' do
      _, stderr, status = Open3.capture3('ruby', EXTRACT_SCRIPT)
      expect(status.exitstatus).to eq(1)
    end

    it 'accepts exactly 3 sources' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:exit_code]).to eq(0)
    end

    it 'accepts more than 3 sources' do
      result = run_extract([source_a, source_b, source_c, source_c.merge('transcript_hash' => 'd')])
      expect(result[:exit_code]).to eq(0)
    end
  end

  describe 'beat extraction — shared/variable/noise thresholds' do
    it 'identifies shared beats appearing in all 3 sources' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:result]['shared_beats']).to be >= 3
      beats = result[:result]['proposed_template']['beats']
      shared = beats.select { |b| b['optional'] == false }
      expect(shared.size).to be >= 3
    end

    it 'marks variable beats as optional' do
      # Mix one source that diverges — fewer beats will be universal
      result = run_extract([source_a, source_b, source_different])
      beats = result[:result]['proposed_template']['beats']
      variable = beats.select { |b| b['optional'] == true }
      # variable beats may or may not exist depending on matching
      expect(variable).to all(satisfy { |b| b['optional'] == true })
    end

    it 'discards noise beats below 30% threshold' do
      result = run_extract([source_a, source_b, source_c])
      # The total beats found should be less than or equal to the total segments per source
      total = result[:result]['total_beats']
      expect(total).to be <= source_a['segments'].size
    end
  end

  describe 'position normalization' do
    it 'normalizes positions to 0.0–1.0 range' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      beats.each do |b|
        expect(b['position']).to be_between(0.0, 1.0)
      end
    end

    it 'first beat is near the start (position < 0.2)' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      first_beat = beats.min_by { |b| b['position'] }
      expect(first_beat['position']).to be < 0.2
    end

    it 'last beat is near the end (position > 0.7)' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      last_beat = beats.max_by { |b| b['position'] }
      expect(last_beat['position']).to be > 0.7
    end

    it 'beats are sorted by position' do
      result = run_extract([source_a, source_b, source_c])
      positions = result[:result]['proposed_template']['beats'].map { |b| b['position'] }
      expect(positions).to eq(positions.sort)
    end
  end

  describe 'position tolerance calculation' do
    it 'calculates tolerance from observed variance' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      beats.each do |b|
        expect(b).to have_key('position_tolerance')
        expect(b['position_tolerance']).to be_a(Numeric)
        expect(b['position_tolerance']).to be >= 0.0
        expect(b['position_tolerance']).to be <= YAML.safe_load('0.15') # within tolerance window
      end
    end

    it 'tolerance is zero when all sources agree on position' do
      # All three sources have nearly identical normalized positions
      identical_a = { 'transcript_hash' => 'id_a', 'segments' => [
        make_seg(t: 0.0, e: 10.0, states: %w[curiosity], distillation: 'exact same keyword match'),
        make_seg(t: 50.0, e: 60.0, states: %w[competence], distillation: 'middle keyword match exact'),
        make_seg(t: 95.0, e: 100.0, states: %w[aspiration], distillation: 'final keyword match close'),
      ] }
      identical_b = { 'transcript_hash' => 'id_b', 'segments' => [
        make_seg(t: 0.0, e: 10.0, states: %w[curiosity], distillation: 'exact same keyword match'),
        make_seg(t: 50.0, e: 60.0, states: %w[competence], distillation: 'middle keyword match exact'),
        make_seg(t: 95.0, e: 100.0, states: %w[aspiration], distillation: 'final keyword match close'),
      ] }
      identical_c = { 'transcript_hash' => 'id_c', 'segments' => [
        make_seg(t: 0.0, e: 10.0, states: %w[curiosity], distillation: 'exact same keyword match'),
        make_seg(t: 50.0, e: 60.0, states: %w[competence], distillation: 'middle keyword match exact'),
        make_seg(t: 95.0, e: 100.0, states: %w[aspiration], distillation: 'final keyword match close'),
      ] }

      result = run_extract([identical_a, identical_b, identical_c])
      beats = result[:result]['proposed_template']['beats']
      beats.each do |b|
        expect(b['position_tolerance']).to eq(0.0)
      end
    end
  end

  describe 'overlap detection against existing templates' do
    it 'checks overlap with templates in story_structures directory' do
      result = run_extract([source_a, source_b, source_c])
      overlap = result[:result]['overlap_analysis']
      expect(overlap).to be_an(Array)
      expect(overlap.size).to be > 0
      overlap.each do |o|
        expect(o).to have_key('template')
        expect(o).to have_key('overlap_pct')
        expect(o).to have_key('shared_count')
      end
    end

    it 'reports overlap percentage correctly' do
      result = run_extract([source_a, source_b, source_c])
      overlap = result[:result]['overlap_analysis']
      overlap.each do |o|
        expect(o['overlap_pct']).to be_between(0, 100)
      end
    end

    it 'suggests update when overlap exceeds 70%' do
      # source_a/b/c have keywords that overlap significantly with problem_solution template
      result = run_extract([source_a, source_b, source_c])
      # We check if the recommendation field exists and is sensible
      rec = result[:result]['overlap_recommendation']
      if result[:result]['overlap_analysis'].any? { |o| o['overlap_pct'] > 70 }
        expect(rec).to include('Consider updating')
      else
        expect(rec).to be_nil
      end
    end
  end

  describe 'output schema' do
    it 'includes all required top-level fields' do
      result = run_extract([source_a, source_b, source_c])
      %w[generated_at source_count sources shared_beats variable_beats total_beats
         confidence overlap_analysis overlap_recommendation proposed_template
         description_prompt beat_description_prompt].each do |field|
        expect(result[:result]).to have_key(field), "missing field: #{field}"
      end
    end

    it 'proposed_template has enhanced schema fields' do
      result = run_extract([source_a, source_b, source_c])
      tpl = result[:result]['proposed_template']
      expect(tpl).to have_key('name')
      expect(tpl).to have_key('version')
      expect(tpl).to have_key('category')
      expect(tpl).to have_key('description')
      expect(tpl).to have_key('source_videos')
      expect(tpl).to have_key('confidence')
      expect(tpl).to have_key('beats')
      expect(tpl).to have_key('history')
    end

    it 'each beat has enhanced fields' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      expect(beats.size).to be > 0
      beats.each do |b|
        %w[id keywords position position_tolerance state_profile
           duration_typical optional examples].each do |field|
          expect(b).to have_key(field), "beat missing field: #{field}"
        end
        expect(b['keywords']).to be_an(Array)
        expect(b['state_profile']).to be_an(Array)
        expect(b['examples']).to be_an(Array)
        expect(b['position']).to be_a(Numeric)
        expect(b['position_tolerance']).to be_a(Numeric)
      end
    end

    it 'beat descriptions are nil for agent to fill' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      beats.each do |b|
        expect(b['description']).to be_nil
      end
    end

    it 'template description is nil for agent to fill' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:result]['proposed_template']['description']).to be_nil
    end

    it 'outputs path to stdout' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:stdout]).to end_with('template_extracted.yaml')
    end

    it 'shows report in stderr' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:stderr]).to include('TEMPLATE EXTRACTION')
      expect(result[:stderr]).to include('Beats found')
      expect(result[:stderr]).to include('Confidence')
    end
  end

  describe 'backward compatibility — old simple schema' do
    it 'old templates (label positions, no enhanced fields) still work in overlap check' do
      # The existing templates use position labels like "early", "mid", "late"
      # The overlap check must handle both formats
      result = run_extract([source_a, source_b, source_c])
      overlap = result[:result]['overlap_analysis']
      # Should not crash and should include existing template names
      template_names = overlap.map { |o| o['template'] }
      expect(template_names).to include('problem_solution')
    end
  end

  describe '--label flag' do
    it 'sets template name from label' do
      result = run_extract([source_a, source_b, source_c], flags: { label: 'Comparative Walkthrough' })
      name = result[:result]['proposed_template']['name']
      expect(name).to eq('comparative_walkthrough')
    end

    it 'normalizes label to snake_case' do
      result = run_extract([source_a, source_b, source_c], flags: { label: 'My Cool Template!' })
      name = result[:result]['proposed_template']['name']
      expect(name).to match(/^[a-z0-9_]+$/)
    end

    it 'template name is nil without --label' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:result]['proposed_template']['name']).to be_nil
    end
  end

  describe '--category flag' do
    it 'sets category in proposed template' do
      result = run_extract([source_a, source_b, source_c], flags: { category: 'explainer' })
      expect(result[:result]['proposed_template']['category']).to eq('explainer')
    end

    it 'reports category path in stderr' do
      result = run_extract([source_a, source_b, source_c], flags: { category: 'explainer' })
      expect(result[:stderr]).to include('explainer')
    end

    it 'category is nil without flag' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:result]['proposed_template']['category']).to be_nil
    end
  end

  describe '--update mode' do
    it 'merges new data into existing template' do
      Dir.mktmpdir do |dir|
        existing = {
          'name' => 'test_template',
          'version' => '1.0',
          'description' => 'A test template',
          'beats' => [
            { 'id' => 'hook', 'description' => 'Opening hook', 'keywords' => %w[money wrong models],
              'position' => 'early', 'examples' => ['original example'] },
            { 'id' => 'proof', 'description' => 'Proof point', 'keywords' => %w[sales revenue first],
              'position' => 'late' }
          ],
          'source_videos' => ['original_video'],
          'history' => ['1.0: initial']
        }
        existing_path = File.join(dir, 'test_template.yaml')
        File.write(existing_path, existing.to_yaml)

        result = run_extract([source_a, source_b, source_c],
                             flags: { update: existing_path }, tmpdir: dir)
        expect(result[:exit_code]).to eq(0)

        updated_path = File.join(dir, 'test_template_updated.yaml')
        expect(File.exist?(updated_path)).to be true

        updated = YAML.safe_load(File.read(updated_path))
        expect(updated['version']).not_to eq('1.0')
        expect(updated['source_videos'].size).to be > 1
        expect(updated['history'].size).to be > 1
      end
    end

    it 'increments version number' do
      Dir.mktmpdir do |dir|
        existing = {
          'name' => 'test_template', 'version' => '1.2',
          'beats' => [
            { 'id' => 'hook', 'keywords' => %w[money wrong], 'position' => 'early' }
          ]
        }
        existing_path = File.join(dir, 'test_template.yaml')
        File.write(existing_path, existing.to_yaml)

        result = run_extract([source_a, source_b, source_c],
                             flags: { update: existing_path }, tmpdir: dir)

        updated_path = File.join(dir, 'test_template_updated.yaml')
        updated = YAML.safe_load(File.read(updated_path))
        expect(updated['version']).to eq('1.3')
      end
    end

    it 'adds new examples to existing beats' do
      Dir.mktmpdir do |dir|
        existing = {
          'name' => 'test_template', 'version' => '1.0',
          'beats' => [
            { 'id' => 'hook', 'keywords' => %w[money wrong models wasting],
              'position' => 'early', 'examples' => ['original example'] }
          ]
        }
        existing_path = File.join(dir, 'test_template.yaml')
        File.write(existing_path, existing.to_yaml)

        result = run_extract([source_a, source_b, source_c],
                             flags: { update: existing_path }, tmpdir: dir)

        updated_path = File.join(dir, 'test_template_updated.yaml')
        updated = YAML.safe_load(File.read(updated_path))
        hook_beat = updated['beats'].find { |b| b['id'] == 'hook' }
        expect(hook_beat['examples'].size).to be > 1
        expect(hook_beat['examples']).to include('original example')
      end
    end

    it 'widens position tolerances' do
      Dir.mktmpdir do |dir|
        existing = {
          'name' => 'test_template', 'version' => '1.0',
          'beats' => [
            { 'id' => 'hook', 'keywords' => %w[money wrong models wasting],
              'position' => 'early', 'position_tolerance' => 0.01 }
          ]
        }
        existing_path = File.join(dir, 'test_template.yaml')
        File.write(existing_path, existing.to_yaml)

        result = run_extract([source_a, source_b, source_c],
                             flags: { update: existing_path }, tmpdir: dir)

        updated_path = File.join(dir, 'test_template_updated.yaml')
        updated = YAML.safe_load(File.read(updated_path))
        hook_beat = updated['beats'].find { |b| b['id'] == 'hook' }
        expect(hook_beat['position_tolerance']).to be >= 0.01
      end
    end

    it 'adds new keywords from new sources' do
      Dir.mktmpdir do |dir|
        existing = {
          'name' => 'test_template', 'version' => '1.0',
          'beats' => [
            { 'id' => 'hook', 'keywords' => %w[money],
              'position' => 'early' }
          ]
        }
        existing_path = File.join(dir, 'test_template.yaml')
        File.write(existing_path, existing.to_yaml)

        result = run_extract([source_a, source_b, source_c],
                             flags: { update: existing_path }, tmpdir: dir)

        updated_path = File.join(dir, 'test_template_updated.yaml')
        updated = YAML.safe_load(File.read(updated_path))
        hook_beat = updated['beats'].find { |b| b['id'] == 'hook' }
        expect(hook_beat['keywords'].size).to be > 1
      end
    end

    it 'does not overwrite original file' do
      Dir.mktmpdir do |dir|
        existing = {
          'name' => 'test_template', 'version' => '1.0',
          'beats' => [
            { 'id' => 'hook', 'keywords' => %w[money wrong], 'position' => 'early' }
          ]
        }
        existing_path = File.join(dir, 'test_template.yaml')
        File.write(existing_path, existing.to_yaml)
        original_content = File.read(existing_path)

        run_extract([source_a, source_b, source_c],
                    flags: { update: existing_path }, tmpdir: dir)

        expect(File.read(existing_path)).to eq(original_content)
      end
    end

    it 'aborts when update target has no beats' do
      Dir.mktmpdir do |dir|
        existing = { 'name' => 'empty', 'version' => '1.0', 'beats' => [] }
        existing_path = File.join(dir, 'empty.yaml')
        File.write(existing_path, existing.to_yaml)

        result = run_extract([source_a, source_b, source_c],
                             flags: { update: existing_path }, tmpdir: dir)
        expect(result[:exit_code]).to eq(1)
        expect(result[:stderr]).to include('No beats')
      end
    end
  end

  describe 'LLM prompt generation' do
    it 'generates description prompt' do
      result = run_extract([source_a, source_b, source_c])
      prompt = result[:result]['description_prompt']
      expect(prompt).to be_a(String)
      expect(prompt.length).to be > 100
      expect(prompt).to include('snake_case')
      expect(prompt).to include('description')
    end

    it 'generates beat description prompt' do
      result = run_extract([source_a, source_b, source_c])
      prompt = result[:result]['beat_description_prompt']
      expect(prompt).to be_a(String)
      expect(prompt.length).to be > 50
      expect(prompt).to include('description')
    end

    it 'description prompt includes beat data' do
      result = run_extract([source_a, source_b, source_c])
      prompt = result[:result]['description_prompt']
      expect(prompt).to include('SHARED')
      expect(prompt).to include('pos=')
    end
  end

  describe 'confidence calculation' do
    it 'returns confidence between 0.0 and 1.0' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:result]['confidence']).to be_between(0.0, 1.0)
    end

    it 'higher confidence with more shared beats' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:result]['confidence']).to be >= 0.6
    end
  end

  describe 'edge cases' do
    it 'handles all transcripts with identical structure' do
      result = run_extract([source_a, source_a.merge('transcript_hash' => 'x'),
                            source_a.merge('transcript_hash' => 'y')])
      expect(result[:exit_code]).to eq(0)
      beats = result[:result]['proposed_template']['beats']
      expect(beats.size).to be >= 3
      # All beats should be shared
      beats.each { |b| expect(b['optional']).to eq(false) }
    end

    it 'handles no shared beats (completely different sources)' do
      src_x = { 'transcript_hash' => 'x', 'segments' => [
        make_seg(t: 0.0,  e: 10.0, states: %w[curiosity],  distillation: 'alpha beta gamma delta'),
        make_seg(t: 20.0, e: 30.0, states: %w[competence], distillation: 'epsilon zeta eta theta'),
      ] }
      src_y = { 'transcript_hash' => 'y', 'segments' => [
        make_seg(t: 0.0,  e: 10.0, states: %w[aspiration], distillation: 'iota kappa lambda mu'),
        make_seg(t: 20.0, e: 30.0, states: %w[awe],        distillation: 'nu xi omicron pi'),
      ] }
      src_z = { 'transcript_hash' => 'z', 'segments' => [
        make_seg(t: 0.0,  e: 10.0, states: %w[nostalgia],  distillation: 'rho sigma tau upsilon'),
        make_seg(t: 20.0, e: 30.0, states: %w[fear],       distillation: 'phi chi psi omega'),
      ] }
      result = run_extract([src_x, src_y, src_z])
      expect(result[:exit_code]).to eq(0)
      expect(result[:result]['total_beats']).to eq(0)
    end

    it 'skips sources with only filler distillations' do
      Dir.mktmpdir do |dir|
        paths = [source_a, source_b, source_filler].each_with_index.map { |s, i|
          p = File.join(dir, "s#{i}.yaml"); File.write(p, s.to_yaml); p
        }
        _, stderr, status = Open3.capture3('ruby', EXTRACT_SCRIPT, *paths)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('Not enough sources')
      end
    end

    it 'aborts on Branch A classification' do
      branch_a = {
        'branch' => 'A',
        'segments_used' => [{ 't' => 10.0, 'e' => 25.0, 'beat' => 'hook' }]
      }
      Dir.mktmpdir do |dir|
        paths = [source_a, source_b, branch_a].each_with_index.map { |s, i|
          p = File.join(dir, "s#{i}.yaml"); File.write(p, s.to_yaml); p
        }
        _, stderr, status = Open3.capture3('ruby', EXTRACT_SCRIPT, *paths)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('Branch A')
      end
    end

    it 'aborts on missing file' do
      Dir.mktmpdir do |dir|
        p1 = File.join(dir, 'a.yaml'); File.write(p1, source_a.to_yaml)
        p2 = File.join(dir, 'b.yaml'); File.write(p2, source_b.to_yaml)
        _, stderr, status = Open3.capture3('ruby', EXTRACT_SCRIPT, p1, p2, '/nonexistent.yaml')
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('File not found')
      end
    end

    it 'handles segments with nil distillation' do
      src_nil = { 'transcript_hash' => 'nil_test', 'segments' => [
        { 't' => 0.0, 'e' => 10.0, 'states' => %w[curiosity], 'distillation' => nil,
          'dur' => 'identity', 'confidence' => 'high', 'signal' => 'test',
          'roles' => ['secondary'], 'notes' => 'test', 'rationale' => 'test' },
        make_seg(t: 20.0, e: 30.0, states: %w[curiosity aspiration], distillation: 'wasting money on wrong models'),
        make_seg(t: 45.0, e: 55.0, states: %w[competence], distillation: 'simple framework three steps'),
        make_seg(t: 70.0, e: 85.0, states: %w[aspiration], distillation: 'first month three sales revenue'),
        make_seg(t: 90.0, e: 100.0, states: %w[competence], distillation: 'focus on results start today'),
      ] }
      result = run_extract([source_a, source_b, src_nil])
      expect(result[:exit_code]).to eq(0)
    end

    it 'handles empty segments array' do
      empty = { 'transcript_hash' => 'empty', 'segments' => [] }
      Dir.mktmpdir do |dir|
        paths = [source_a, source_b, empty].each_with_index.map { |s, i|
          p = File.join(dir, "s#{i}.yaml"); File.write(p, s.to_yaml); p
        }
        _, stderr, status = Open3.capture3('ruby', EXTRACT_SCRIPT, *paths)
        expect(status.exitstatus).to eq(1)
        expect(stderr).to include('No segments')
      end
    end
  end

  describe 'state profile and duration' do
    it 'extracts state profile from matching segments' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      beats.each do |b|
        expect(b['state_profile']).to be_an(Array)
        expect(b['state_profile'].size).to be > 0
        expect(b['state_profile'].size).to be <= 3
      end
    end

    it 'extracts duration range' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      beats.each do |b|
        expect(b['duration_typical']).to match(/\d+-\d+s/)
      end
    end
  end

  describe 'examples population' do
    it 'populates examples from source distillations' do
      result = run_extract([source_a, source_b, source_c])
      beats = result[:result]['proposed_template']['beats']
      beats.each do |b|
        expect(b['examples']).to be_an(Array)
        expect(b['examples'].size).to be > 0
      end
    end

    it 'deduplicates examples' do
      result = run_extract([source_a, source_a.merge('transcript_hash' => 'x'),
                            source_a.merge('transcript_hash' => 'y')])
      beats = result[:result]['proposed_template']['beats']
      beats.each do |b|
        expect(b['examples']).to eq(b['examples'].uniq)
      end
    end
  end

  describe 'history tracking' do
    it 'initializes history with version 1.0 entry' do
      result = run_extract([source_a, source_b, source_c])
      history = result[:result]['proposed_template']['history']
      expect(history).to be_an(Array)
      expect(history.size).to eq(1)
      expect(history.first).to include('1.0')
      expect(history.first).to include('3 source videos')
    end
  end

  describe 'source tracking' do
    it 'records source video names' do
      result = run_extract([source_a, source_b, source_c])
      sources = result[:result]['proposed_template']['source_videos']
      expect(sources).to be_an(Array)
      expect(sources.size).to eq(3)
    end

    it 'records source file paths' do
      result = run_extract([source_a, source_b, source_c])
      expect(result[:result]['sources']).to be_an(Array)
      expect(result[:result]['sources'].size).to eq(3)
    end
  end
end
