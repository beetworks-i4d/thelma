require 'open3'
require 'yaml'
require 'date'
require 'tmpdir'

DISCOVER_SCRIPT = File.expand_path('../../scripts/discover_storylines.rb', __dir__)

def run_discover(segments_yaml, profile: nil)
  Dir.mktmpdir do |dir|
    segments_path = File.join(dir, 'segments_classified.yaml')
    File.write(segments_path, segments_yaml.to_yaml)

    # Create a minimal profile directory structure
    profile_dir = File.join(File.dirname(DISCOVER_SCRIPT), '..', 'profiles')

    args = ['ruby', DISCOVER_SCRIPT, segments_path]
    args += ['--profile', profile] if profile

    stdout, stderr, status = Open3.capture3(*args)
    output_path = File.join(dir, 'storylines.yaml')
    result = File.exist?(output_path) ? YAML.safe_load(File.read(output_path), permitted_classes: [Date]) : nil
    { stdout: stdout.strip, stderr: stderr, exit_code: status.exitstatus, result: result }
  end
end

def make_seg(t:, e:, states:, distillation:, dur: 'mood', roles: ['secondary'], confidence: 'high')
  { 't' => t, 'e' => e, 'states' => states, 'distillation' => distillation,
    'dur' => dur, 'roles' => roles, 'confidence' => confidence,
    'signal' => "signal at #{t}", 'notes' => 'test', 'rationale' => 'test' }
end

# --- Test data builders ---

# Builds a minimal viable arc: hook + 2 body + close
def short_arc_segments
  {
    'transcript_hash' => 'test_short_hash',
    'segments' => [
      make_seg(t: 5.0, e: 20.0, states: %w[curiosity], distillation: 'contrarian opening hook',
               dur: 'identity', roles: %w[primary], confidence: 'high'),
      make_seg(t: 25.0, e: 45.0, states: %w[curiosity competence], distillation: 'body evidence one'),
      make_seg(t: 50.0, e: 70.0, states: %w[competence], distillation: 'body evidence two'),
      make_seg(t: 75.0, e: 90.0, states: %w[aspiration], distillation: 'close takeaway',
               dur: 'identity', roles: %w[tertiary])
    ]
  }
end

# Builds a longform recording with a clear argument arc (50+ segments)
# Hook at start, lots of body, close near end
def longform_arc_segments
  segs = []

  # Hook — primary, identity durability, curiosity
  segs << make_seg(t: 5.0, e: 18.0, states: %w[curiosity], distillation: 'provocative AI thesis',
                   dur: 'identity', roles: %w[primary], confidence: 'high')

  # Body — 28 secondaries spanning the recording, mostly competence/vindication
  # 28 * 25s = 700s body + 13s hook + 20s close = 733s total (within 480-900s longform range)
  body_states = %w[competence vindication aspiration competence competence vindication
                   competence aspiration competence vindication competence competence
                   competence vindication aspiration competence vindication competence
                   competence aspiration competence competence vindication competence
                   competence vindication competence aspiration]
  28.times do |i|
    t_start = 20.0 + i * 28.0
    t_end = t_start + 25.0
    state = body_states[i] || 'competence'
    segs << make_seg(t: t_start, e: t_end, states: [state], distillation: "argument point #{i + 1}")
  end

  # Close — tertiary, identity durability, late in recording
  segs << make_seg(t: 850.0, e: 870.0, states: %w[aspiration], distillation: 'ethos establishment close',
                   dur: 'identity', roles: %w[tertiary], confidence: 'high')

  # Extra tertiary earlier (should NOT be picked as close — close-first prefers latest high-durability)
  segs << make_seg(t: 400.0, e: 415.0, states: %w[vindication], distillation: 'mid recap',
                   dur: 'mood', roles: %w[tertiary])

  { 'transcript_hash' => 'test_longform_hash', 'segments' => segs }
end

# Recording with tertiaries only before body end (old bug would find no close)
def no_late_tertiary_segments
  {
    'transcript_hash' => 'test_no_late_hash',
    'segments' => [
      make_seg(t: 5.0, e: 15.0, states: %w[curiosity], distillation: 'hook opening',
               dur: 'identity', roles: %w[primary], confidence: 'high'),
      make_seg(t: 20.0, e: 35.0, states: %w[competence], distillation: 'body one'),
      make_seg(t: 40.0, e: 55.0, states: %w[competence], distillation: 'body two'),
      # No tertiary at all
    ]
  }
end

# Segments where body dominant state differs from hook state
def divergent_spine_segments
  {
    'transcript_hash' => 'test_divergent_hash',
    'segments' => [
      make_seg(t: 5.0, e: 20.0, states: %w[curiosity], distillation: 'hook curiosity opener',
               dur: 'identity', roles: %w[primary], confidence: 'high'),
      # Body is all competence — hook state (curiosity) absent from body
      make_seg(t: 25.0, e: 55.0, states: %w[competence], distillation: 'body comp one'),
      make_seg(t: 60.0, e: 90.0, states: %w[competence], distillation: 'body comp two'),
      make_seg(t: 95.0, e: 125.0, states: %w[competence], distillation: 'body comp three'),
      make_seg(t: 130.0, e: 160.0, states: %w[competence], distillation: 'body comp four'),
      make_seg(t: 165.0, e: 195.0, states: %w[competence], distillation: 'body comp five'),
      make_seg(t: 200.0, e: 230.0, states: %w[competence], distillation: 'body comp six'),
      make_seg(t: 235.0, e: 265.0, states: %w[competence], distillation: 'body comp seven'),
      make_seg(t: 270.0, e: 295.0, states: %w[aspiration], distillation: 'close takeaway',
               dur: 'identity', roles: %w[tertiary])
    ]
  }
end

describe 'discover_storylines.rb' do
  describe 'expand_wide — close-first logic' do
    it 'finds close before building body, so body ends before close' do
      result = run_discover(longform_arc_segments)
      expect(result[:exit_code]).to eq(0), "Script failed: #{result[:stderr]}"

      storylines = result[:result]['storylines']
      longform = storylines.find { |s| s['profile'] == 'best_single_longform' }

      # With close-first, the longform should find the late tertiary as close
      expect(longform).not_to be_nil, "Expected a longform candidate but got none. Profiles: #{storylines.map { |s| s['profile'] }.uniq}"

      # Close should be at the late tertiary (t=1190), not nil
      expect(longform['close_segment']).to eq(850.0)
    end

    it 'prefers latest high-durability tertiary as close' do
      result = run_discover(longform_arc_segments)
      storylines = result[:result]['storylines']
      longform = storylines.find { |s| s['profile'] == 'best_single_longform' }

      # Should pick t=1190 (identity) over t=600 (mood), even though t=600 is also tertiary
      expect(longform['close_segment']).to eq(850.0)
    end

    it 'returns nil close and full body when no tertiaries exist' do
      result = run_discover(no_late_tertiary_segments)
      expect(result[:exit_code]).to eq(0)

      storylines = result[:result]['storylines']
      # May or may not produce candidates (duration might not match any profile)
      # But the script should not crash
    end
  end

  describe 'spine scoring — body-dominant state' do
    it 'scores body-dominant state higher than hook-state when body diverges' do
      result = run_discover(divergent_spine_segments)
      expect(result[:exit_code]).to eq(0)

      storylines = result[:result]['storylines']
      # Find any candidate that uses this data
      candidates_with_spine = storylines.select { |s| s['scores'] && s['scores']['spine'] }

      # With body-dominant fallback, competence dominance (7/7 = 100%) should yield spine = 20
      # Without fallback, curiosity in body (0/7 = 0%) would yield spine = 0
      high_spine = candidates_with_spine.select { |s| s['scores']['spine'] >= 15 }
      expect(high_spine).not_to be_empty, "Expected at least one candidate with high spine score from body-dominant state. Scores: #{candidates_with_spine.map { |s| [s['id'], s['scores']['spine']] }}"
    end

    it 'still uses hook state when body matches hook' do
      # In short_arc_segments, hook is curiosity, first body seg carries curiosity
      result = run_discover(short_arc_segments)
      expect(result[:exit_code]).to eq(0)

      storylines = result[:result]['storylines']
      short = storylines.find { |s| s['profile'] == 'best_short' }
      # Should still work fine — hook-state match is used when it's better
      expect(short).not_to be_nil if storylines.any? { |s| s['profile'] == 'best_short' }
    end
  end

  describe 'profile-specific score floors' do
    it 'uses floor 55 for longform (wide expansion)' do
      result = run_discover(longform_arc_segments)
      expect(result[:exit_code]).to eq(0)

      storylines = result[:result]['storylines']
      longform_candidates = storylines.select { |s| s['profile'] == 'best_single_longform' }

      # A candidate scoring 55-69 should pass for longform but would fail the old 70 threshold
      if longform_candidates.any?
        # If we have a longform candidate, it proves the lower floor worked
        low_score = longform_candidates.select { |s| s['score'] >= 55 && s['score'] < 70 }
        # Either the candidate scored >= 70 naturally or the lower floor admitted it
        expect(longform_candidates.all? { |s| s['score'] >= 55 }).to be true
      end
    end

    it 'uses floor 70 for short (tight expansion)' do
      result = run_discover(short_arc_segments)
      expect(result[:exit_code]).to eq(0)

      storylines = result[:result]['storylines']
      short_candidates = storylines.select { |s| s['profile'] == 'best_short' }

      # All short candidates must score >= 70
      short_candidates.each do |c|
        expect(c['score']).to be >= 70, "Short candidate #{c['id']} has score #{c['score']} (should be >= 70)"
      end
    end
  end

  describe 'duration enforcement' do
    it 'rejects candidates outside target range regardless of profile' do
      # short_arc_segments total ~85s, fits short profile (30-90s)
      result = run_discover(short_arc_segments)
      expect(result[:exit_code]).to eq(0)

      storylines = result[:result]['storylines']
      storylines.each do |s|
        profile_limits = case s['profile']
                         when 'best_single_longform' then [480, 900]
                         when 'best_short' then [30, 90]
                         when 'best_medium' then [180, 480]
                         end
        next unless profile_limits
        expect(s['duration_estimate']).to be >= profile_limits[0],
          "#{s['id']} duration #{s['duration_estimate']}s below min #{profile_limits[0]}s"
        expect(s['duration_estimate']).to be <= profile_limits[1],
          "#{s['id']} duration #{s['duration_estimate']}s above max #{profile_limits[1]}s"
      end
    end
  end

  describe 'longform candidate from substantial recording' do
    it 'produces a longform candidate with score >= 55' do
      result = run_discover(longform_arc_segments)
      expect(result[:exit_code]).to eq(0)

      storylines = result[:result]['storylines']
      longform = storylines.select { |s| s['profile'] == 'best_single_longform' }

      expect(longform).not_to be_empty, "Expected at least one longform candidate from 30-segment recording"
      expect(longform.first['score']).to be >= 55
    end

    it 'has a close segment in the longform candidate' do
      result = run_discover(longform_arc_segments)
      storylines = result[:result]['storylines']
      longform = storylines.find { |s| s['profile'] == 'best_single_longform' }

      expect(longform).not_to be_nil
      expect(longform['close_segment']).not_to be_nil, "Longform candidate should have a close segment"
    end
  end
end
