require 'set'

module ArrangementValidator
  VALID_NARRATIVE_ROLES = %w[
    hook setup continuation payoff transition claim evidence definition aside
  ].freeze

  def self.validate(arrangement, candidates_data, discovery_data: nil)
    errors = []
    warnings = []

    candidates = candidates_data['candidates'] || []
    candidates_by_id = candidates.each_with_object({}) { |c, h| h[c['id']] = c }

    errors << 'version must be "4"' unless arrangement['version'] == '4'
    errors << 'branch must be A, B, or D' unless %w[A B D].include?(arrangement['branch'])

    if arrangement['branch'] == 'A'
      errors << 'selected_thesis must be null for Branch A' unless arrangement['selected_thesis'].nil?
    elsif %w[B D].include?(arrangement['branch'])
      if arrangement['selected_thesis'].to_s.strip.empty?
        errors << 'selected_thesis required for Branch B/D'
      elsif discovery_data
        thesis_ids = (discovery_data['theses'] || []).map { |t| t['id'] }
        unless thesis_ids.include?(arrangement['selected_thesis'])
          errors << "selected_thesis '#{arrangement['selected_thesis']}' not found in discovery_pass.yaml"
        end
      end
    end

    errors << 'chapters must be non-empty array' if (arrangement['chapters'] || []).empty?
    errors << 'input_fingerprint missing' unless arrangement['input_fingerprint'].is_a?(String) && !arrangement['input_fingerprint'].empty?
    errors << 'generated_at missing' unless arrangement['generated_at'].is_a?(String) && !arrangement['generated_at'].empty?
    errors << 'model missing' unless arrangement['model'].is_a?(String) && !arrangement['model'].empty?

    used_cand_ids = Set.new
    used_clusters = Set.new

    (arrangement['chapters'] || []).each_with_index do |ch, ci|
      expected_id = format('chapter_%03d', ci + 1)
      errors << "chapter #{ci}: id must be #{expected_id}, got #{ch['id']}" unless ch['id'] == expected_id
      errors << "chapter #{ch['id']}: missing title" unless ch['title'].is_a?(String) && !ch['title'].empty?
      errors << "chapter #{ch['id']}: segments must be non-empty" if (ch['segments'] || []).empty?

      (ch['segments'] || []).each do |seg|
        cid = seg['candidate_id']
        tid = seg['trim_choice_id']

        cand = candidates_by_id[cid]
        unless cand
          errors << "#{cid}: candidate not found in editorial_candidates.yaml"
          next
        end

        errors << "#{cid}: duplicate candidate selection" if used_cand_ids.include?(cid)
        used_cand_ids << cid

        cluster = cand['cluster']
        if cluster && !cluster.to_s.strip.empty?
          errors << "#{cid}: cluster '#{cluster}' already used" if used_clusters.include?(cluster)
          used_clusters << cluster
        end

        trim = (cand['trim_choices'] || []).find { |t| t['id'] == tid }
        unless trim
          errors << "#{cid}: trim_choice_id '#{tid}' not found"
          next
        end

        errors << "#{cid}: trim '#{tid}' not mechanical_boundary_safe" unless trim['mechanical_boundary_safe']
        errors << "#{cid}: trim '#{tid}' not content_preserved" unless trim['content_preserved']

        (seg['exclusion_choice_ids'] || []).each do |eid|
          ex = (cand['exclusion_choices'] || []).find { |e| e['id'] == eid }
          unless ex
            errors << "#{cid}: exclusion '#{eid}' not found"
            next
          end
          warnings << "[WARN] #{cid}: exclusion '#{eid}' not recommended" unless ex['recommended']
        end

        unless VALID_NARRATIVE_ROLES.include?(seg['narrative_role'])
          errors << "#{cid}: narrative_role '#{seg['narrative_role']}' not in enum"
        end
      end
    end

    selected_ids = used_cand_ids.to_a
    audited_ids = []
    audit = arrangement['unused_candidate_audit'] || {}
    %w[cut_by_thesis alternate_take_not_chosen cut_for_pacing bridge_dropped].each do |k|
      audited_ids.concat(audit[k] || [])
    end

    missing_audit = candidates.map { |c| c['id'] } - selected_ids - audited_ids
    warnings << "[WARN] unused_candidate_audit missing: #{missing_audit.join(', ')}" if missing_audit.any?

    roles = (arrangement['chapters'] || []).flat_map { |ch| (ch['segments'] || []).map { |s| s['narrative_role'] } }
    warnings << '[WARN] arrangement has no hook' unless roles.include?('hook')
    warnings << '[WARN] arrangement has no payoff' unless roles.include?('payoff')

    { errors: errors, warnings: warnings }
  end
end
