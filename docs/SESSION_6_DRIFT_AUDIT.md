# Session 6 Architecture Drift Audit

**Date:** 2026-05-25
**Scope:** Cross-document consistency between locked architecture files
**Documents audited:**
1. `docs/schemas/editorial_candidate.schema.yaml` (v1.2)
2. `docs/schemas/arrangement.schema.yaml` (v4)
3. `docs/validator_invariants.md`
4. `docs/SESSION_6_SPEC.md`

---

## BLOCKING

### B1. Exit Code 3 — Conflicting definitions

**editorial_candidate.schema.yaml** (line 361):
> `3: data errors (time violations, range overlaps)`

**arrangement.schema.yaml** (line 259):
> `3: data errors (invalid version, thesis not found)`

**validator_invariants.md** (line 197):
> `3: Data error | Abort. Time violations, range overlaps, referential integrity failures.`

**SESSION_6_SPEC.md** (lines 227-232):
> Exit 3 — "Data" checks include `trim_choice.t < trim_choice.e`, `trim_choice.t >= candidate.t`, etc.

**Issue:** The arrangement schema assigns "invalid version, thesis not found" to exit code 3, but those are referential/structural errors (broken references, wrong version string). The validator_invariants doc categorizes referential integrity as exit code 3 ("Data error") while the candidate schema categorizes it under exit code 1 ("structural errors — broken references"). The arrangement schema puts "thesis not found" under code 3 but the invariants doc says "Broken references are structural errors (exit code 1)."

Three contradictory mappings exist simultaneously:
- "thesis not found" → exit 3 (arrangement schema) vs. "broken references → exit 1" (invariants)
- "referential integrity failures" → exit 3 (invariants) vs. "broken references" → exit 1 (candidate schema, arrangement schema)
- "invalid version" → exit 3 (arrangement) vs. structural/missing field → exit 1 (invariants, candidate schema)

**Impact:** Implementation will fork — validators will disagree on what error code to emit for the same failure class.

**Recommended canonical source:** validator_invariants.md should be authoritative for exit code semantics. The arrangement schema's exit code 3 definition should be rewritten to match.

---

### B2. `trim_choice_id` vs. `trim_id` — naming inconsistency in arrangement schema

**arrangement.schema.yaml** (line 177):
> Field name: `trim_choice_id`
> Description: "Must be a valid trim_id belonging to the referenced candidate."

**editorial_candidate.schema.yaml** (line 86):
> Field name on the candidate side: `trim_id`
> Format: `"trim_NNN_<type>"`

**arrangement.schema.yaml** (line 239):
> Validation rule: "Every segment_selection.trim_choice_id must be a valid trim_id within the referenced candidate"

**validator_invariants.md** (line 138):
> `trim_choice_id` in an arrangement → must exist in the referenced candidate's `trim_choices`

**SESSION_6_SPEC.md** (line 87):
> "LLM selects candidates by cand_id, trim_choices by trim_id, exclusion_choices by exclusion_id"

**Issue:** The arrangement schema names the field `trim_choice_id` but SESSION_6_SPEC says the LLM selects "by trim_id". The arrangement example (line 306) uses values like `trim_001_full` which match the `trim_id` format, not a separate `trim_choice_id` format. The field is called `trim_choice_id` (container reference) but its *values* are in `trim_id` format.

This is internally consistent in meaning but creates an unnecessary naming split. The LLM is told to "choose trim_choices by trim_id" (spec), then must populate a field called `trim_choice_id` (schema). Prompt writers and validators will stumble on whether to validate against `trim_id` or `trim_choice_id`.

**Impact:** Prompt confusion during arrange.rb implementation. LLM output might use key `trim_id` instead of `trim_choice_id`.

**Recommended canonical source:** arrangement.schema.yaml is canonical for the *field name* (`trim_choice_id`). SESSION_6_SPEC should clarify that the field is `trim_choice_id` whose *value* is a `trim_id` from the candidate.

---

### B3. `exclusion_choice_ids` (plural array) vs. singular pattern inconsistency

**arrangement.schema.yaml** (line 184-189):
> Field: `exclusion_choice_ids` — type: array of strings

**validator_invariants.md** (line 139):
> `exclusion_choice_id` in an arrangement → must exist in the referenced candidate's `exclusion_choices`

**Issue:** The schema uses plural `exclusion_choice_ids` (an array), but the invariants doc references `exclusion_choice_id` (singular). Validators written from the invariants doc will look for a singular field. Code written from the schema will use the plural array field.

**Impact:** Validator implementation will reference wrong field name or misunderstand the data structure.

**Recommended canonical source:** arrangement.schema.yaml is canonical (`exclusion_choice_ids` as array). Invariants doc should be updated to match plural form.

---

## MAJOR

### M1. Candidate `roles` field — semantic ambiguity across documents

**editorial_candidate.schema.yaml** (lines 213-222):
> `roles`: array, enum: `[primary, secondary, tertiary]`
> Description: "primary=hook candidate, secondary=body fill, tertiary=close candidate"

**SESSION_6_SPEC.md** (line 152):
> Phase B assigns `roles` (listed as just "roles" without expansion)

**validator_invariants.md** (line 70):
> "Classify states, distillation, durability, roles" — LLM Phase B responsibility

**Issue:** The schema defines `roles` with values `[primary, secondary, tertiary]` meaning *editorial function* (hook/body/close), but the same candidate also has `suggested_narrative_roles` with values `[hook, setup, continuation, payoff, transition, claim, evidence, definition, aside, close]`. The schema description says "primary=hook candidate" but that conflates the *role tier* with the *narrative function*. A candidate could be `roles: [primary]` AND `suggested_narrative_roles: [claim]` — is it a hook or a claim?

The description "primary=hook candidate, secondary=body fill, tertiary=close candidate" is misleading because it implies a 1:1 mapping that the `suggested_narrative_roles` field explicitly exists to break.

**Impact:** LLM labeling prompt will confuse the two role systems. Phase B implementers may not understand whether `roles: [primary]` means "use this as a hook" or "this is a first-choice candidate."

**Recommended canonical source:** editorial_candidate.schema.yaml should clarify that `roles` is a *priority tier* (not a narrative function) and remove the "hook/body/close" equivalence from the description. `suggested_narrative_roles` is the narrative function field.

---

### M2. Pipeline ordering contradiction — Phase 1.45 numbering

**SESSION_6_SPEC.md** (lines 71-79):
```
Phase 1.4  — extract_segments
Phase 1.5c — audio_emotion
           — merge_prosody
Phase 1.45 — candidate_builder     ← NEW
Phase 1.5d — scene detection
Phase 2    — discovery_pass
```

**Issue:** Phase 1.45 is listed as running AFTER Phase 1.5c, but 1.45 < 1.5c numerically. The spec adds a note (line 81): "The numbering reflects logical dependency, not strict numeric ordering." However, `orchestrate.rb` dispatches phases by number. If orchestrate.rb sorts numerically, Phase 1.45 would run BEFORE 1.5c (audio_emotion), which would mean it runs without acoustic data — violating its own input requirement.

The spec acknowledges this paradox but doesn't resolve it. Any implementer reading just the phase numbers will get the order wrong.

**Impact:** Orchestrate.rb implementer may wire candidate_builder before audio_emotion, producing candidates without acoustic data.

**Recommended canonical source:** SESSION_6_SPEC.md should assign an unambiguous phase number (e.g., 1.6 or 1.55) that sorts correctly, or define an explicit execution_order array.

---

### M3. `discovery_pass.yaml` — chicken-and-egg with cluster propagation

**editorial_candidate.schema.yaml** (lines 263-270):
> `cluster_id`: Reference to a clip_group from discovery_pass.yaml.
> `cluster_role`: Within an alternate_takes cluster.

**SESSION_6_SPEC.md** (lines 126-127):
> Phase A step 6: "Propagate cluster membership from discovery_pass.yaml clip_groups (if discovery_pass has already run; otherwise leave null — discovery_pass runs after candidate_builder and will enrich later)."

**SESSION_6_SPEC.md** (lines 85-86):
> Downstream change 1: "discovery_pass.rb — Update prompt to read editorial_candidates.yaml"

**validator_invariants.md** (lines 123-129):
> Cascade chain: `segments_classified → editorial_candidates → discovery_pass → arrangement → XML`

**Issue:** The cascade chain shows `editorial_candidates → discovery_pass` (candidates are INPUT to discovery). But cluster_id on candidates comes FROM discovery_pass. This creates a circular dependency:
- candidate_builder needs discovery_pass for cluster_id
- discovery_pass needs editorial_candidates for enriched labeling

The spec acknowledges this ("if discovery_pass has already run") but the cascade chain in validator_invariants.md doesn't model the back-propagation step. If candidates are invalidated and regenerated, cluster_ids are lost and must be re-propagated from a discovery_pass that itself depends on the now-regenerated candidates.

**Impact:** Cache invalidation logic will either create infinite loops or silently drop cluster data.

**Recommended canonical source:** validator_invariants.md should explicitly model the two-pass pattern: candidates (Phase A+B) → discovery_pass → cluster back-propagation into candidates (Phase A amendment). The cascade chain needs a notation for this cycle.

---

### M4. `content_preserved` — required vs. optional disagreement

**editorial_candidate.schema.yaml** (lines 118-122):
> Listed under `optional_fields` of trim_choice:
> `content_preserved`: type boolean, description says "null until Phase B runs"

**editorial_candidate.schema.yaml** (lines 353-354):
> Validation rule: "content_preserved must be evaluated for every trim_choice (Phase B responsibility)"
> "At least one trim_choice must have content_preserved=true"

**arrangement.schema.yaml** (line 244):
> "Selected trim_choice must have content_preserved=true (or null if Phase B hasn't run)"

**SESSION_6_SPEC.md** (line 232):
> "content_preserved evaluated for all non-full trim_choices"

**Issue:** Four conflicting rules:
1. Schema says `content_preserved` is optional (nullable, null until Phase B)
2. Candidate validation says it must be evaluated for EVERY trim_choice
3. Arrangement validation allows null (if Phase B hasn't run)
4. SESSION_6_SPEC says evaluate only for "non-full" trim_choices

Rule 2 says every trim_choice. Rule 4 says non-full only. Are full trims evaluated? (They're trivially content_preserved=true, but rule 2 requires evaluation while rule 4 exempts them.)

Rule 3 allows null in arrangement validation, but rule 2 says Phase B must evaluate all. If Phase B has run, can content_preserved still be null?

**Impact:** Validators will disagree on whether to fail when content_preserved is null on a full-type trim_choice.

**Recommended canonical source:** SESSION_6_SPEC.md rule 4 is the most precise ("non-full only"). The candidate schema validation section should be amended to match. Full-type trims should be implicitly content_preserved=true without requiring LLM evaluation.

---

### M5. `durability` vs. `dur` — terminology inconsistency

**editorial_candidate.schema.yaml** (line 206):
> Field name: `dur`

**SESSION_6_SPEC.md** (line 14):
> "atoms enriched with ... durability"

**SESSION_6_SPEC.md** (line 153):
> "Assign durability tier"

**validator_invariants.md** (line 70):
> "Classify states, distillation, durability, roles"

**Issue:** The actual field name is `dur` (3 chars), but all prose refers to it as "durability" (10 chars). When implementers write code, they'll use the schema field name `dur`. When they write prompts or documentation, they'll use "durability." The LLM Phase B prompt (spec line 153) says "dur (spike | mood | identity)" mixing both conventions in one line.

Not inherently breaking, but contributes to prompt drift. An LLM might output `durability: spike` instead of `dur: spike` if the prompt says "assign durability tier."

**Impact:** LLM Phase B responses may use wrong field name. Validators would catch this but it wastes tokens on retries.

**Recommended canonical source:** editorial_candidate.schema.yaml (`dur`). Prompt templates should consistently use the field name `dur` with a parenthetical "(durability tier)" on first use.

---

### M6. `arrange.rb` vs. `arrange_v4.rb` — naming confusion

**SESSION_6_SPEC.md** (line 87):
> "arrange.rb — New v4 prompt"

**validator_invariants.md** (line 81):
> "arrange.rb produces candidate-based arrangement (v4)"

**validator_invariants.md** (line 165):
> "arrange_to_script.rb matches segments to beats" (Branch A)

**Issue:** The documents reference `arrange.rb` for Branch B v4, but also reference `arrange_to_script.rb` (Branch A) and `arrangement_adapter.rb` (Branch A normalization). Backward compatibility requires the existing v3 path to continue working (SESSION_6_SPEC acceptance criterion 6: "existing v3 arrangement path still works").

Does `arrange.rb` handle both v3 and v4? Or is v4 a separate file? The spec says "New v4 prompt" for the same `arrange.rb`, implying the same script handles both versions via detection. But if the same script has v3 and v4 code paths, what triggers which path? The spec doesn't define the switch logic.

**Impact:** Implementer uncertainty about whether to modify `arrange.rb` in place or create a new file.

**Recommended canonical source:** SESSION_6_SPEC.md should explicitly state whether arrange.rb is modified in place (with version branching) or split into arrange_v3.rb and arrange_v4.rb. Given the acceptance criterion for backward compat, in-place modification with version detection is implied but not stated.

---

## MINOR

### N1. `segments` vs. `segment_selections` — naming within chapters

**arrangement.schema.yaml** (line 146-151):
> Chapter field name: `segments`
> Description: "Ordered array of segment selections"

**arrangement.schema.yaml** (line 167):
> Object name: `segment_selection`

**Issue:** The field is called `segments` but contains `segment_selection` objects. Minor naming asymmetry. A reader might expect `segment_selections` as the field name given the object type.

**Impact:** Cosmetic. No functional risk.

---

### N2. `suggested_narrative_roles` enum — `close` overlap with `roles` description

**editorial_candidate.schema.yaml** (line 236):
> `suggested_narrative_roles` enum includes `close`

**editorial_candidate.schema.yaml** (line 219):
> `roles` description: "tertiary=close candidate"

**Issue:** The word "close" appears in both `roles` (as the description of `tertiary`) and `suggested_narrative_roles` (as an explicit enum value). This reinforces the M1 conflation between the two systems.

**Impact:** Cosmetic confusion, compounds M1.

---

### N3. Breathing margin — 80ms stated in two locations, nowhere as a constant name

**arrangement.schema.yaml** (line 218):
> "BREATHING_MARGIN (80ms) applied per clip side"

**SESSION_6_SPEC.md** (line 109):
> "BREATHING_MARGIN (80ms before) and last word offset + BREATHING_MARGIN (80ms after)"

**validator_invariants.md** (line 100):
> "Apply BREATHING_MARGIN (80ms per side)"

**editorial_candidate.schema.yaml**: Not mentioned by name — only the concept appears implicitly in `tight` trim description.

**Issue:** BREATHING_MARGIN is referenced 3 times with consistent value (80ms) but never defined as a canonical constant location. If the value changes, three docs must be updated. The candidate schema doesn't name it, describing the same concept as "first/last word boundaries + BREATHING_MARGIN" without defining the constant.

**Impact:** Maintenance burden. Low risk since all docs agree on 80ms currently.

---

### N4. `audio_profile` enum — undocumented in Session 6 Spec

**editorial_candidate.schema.yaml** (line 285):
> `audio_profile` enum: `[casual, emphatic, building, landing]`

**SESSION_6_SPEC.md** (line 147):
> Phase B prompt includes `audio_profile` in the candidate table, but the spec never defines what values are valid or where they come from.

**Issue:** The spec lists `audio_profile` as a column in the Phase B prompt table but doesn't specify that it's inherited from segments_classified.yaml or define its enum. An implementer would need to cross-reference the candidate schema to find the valid values.

**Impact:** Minor — the schema is authoritative, but the spec is incomplete as a standalone implementation guide.

---

### N5. Example uses `candidate_priority: null` but field is optional

**editorial_candidate.schema.yaml** (line 403):
> Example: `candidate_priority: null`

**editorial_candidate.schema.yaml** (line 242-248):
> `candidate_priority` is listed under `optional_fields`

**Issue:** Optional fields can be omitted entirely rather than set to null. The example shows explicit null, which is valid YAML but suggests the field is always present. This is a style inconsistency — if optional means "may be absent," the example should omit it rather than null it.

**Impact:** Cosmetic. Both representations (absent and null) should be accepted by validators.

---

### N6. `cluster_role` enum includes `null` as string value

**editorial_candidate.schema.yaml** (line 275):
> `enum: [recommended, alternate, null]`

**Issue:** Including `null` in the enum as a string value is ambiguous in YAML. Is it the YAML null type or the string "null"? The field is also marked `nullable: true`, which is the proper way to indicate null allowance. Having `null` in the enum is redundant and potentially confusing (YAML parsers may interpret unquoted `null` as nil, not the string "null").

**Impact:** Minor parser behavior difference depending on YAML library. Ruby's `YAML.safe_load` will parse unquoted `null` as nil, which happens to be correct — but the schema definition is technically ambiguous.

---

---

## Summary

| Severity | Count | IDs |
|----------|-------|-----|
| BLOCKING | 3 | B1, B2, B3 |
| MAJOR | 6 | M1, M2, M3, M4, M5, M6 |
| MINOR | 6 | N1, N2, N3, N4, N5, N6 |

### Priority Resolution Order

1. **B1** (exit codes) — Must resolve before any validator is written
2. **B2** (trim_choice_id naming) — Must resolve before arrange.rb prompt is written
3. **B3** (exclusion_choice_ids plural) — Must resolve before validator is written
4. **M3** (cluster circular dependency) — Must resolve before cache invalidation is implemented
5. **M4** (content_preserved rules) — Must resolve before Phase C validation is written
6. **M2** (phase numbering) — Must resolve before orchestrate.rb wiring
7. **M1, M5, M6** — Must resolve before Phase B prompt is finalized

---

*Audit complete. No files modified. No harmonization applied.*
