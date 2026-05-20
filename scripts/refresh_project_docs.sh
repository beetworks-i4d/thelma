#!/bin/bash
# Regenerate STATE.md and CLI.md, then remind to re-upload to Claude project.
#
# STATE.md is rebuilt from git/filesystem data directly.
# CLI.md requires Claude (source parsing) — this script detects staleness and warns.
#
# Usage: bash scripts/refresh_project_docs.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

DOCS_DIR="docs"
STATE_MD="$DOCS_DIR/STATE.md"
CLI_MD="$DOCS_DIR/CLI.md"
TODAY=$(date +%Y-%m-%d)

mkdir -p "$DOCS_DIR"

# ─── Helpers ──────────────────────────────────────────────────────────────────

heading()  { printf '\n---\n\n## %s\n\n' "$1"; }
subhead()  { printf '\n### %s\n\n' "$1"; }
fence()    { printf '```\n%s\n```\n' "$1"; }
table_row(){ printf '| %s |\n' "$*"; }

# ─── Collect data ─────────────────────────────────────────────────────────────

GEM_VERSION=$(grep 'VERSION' lib/buttercut/version.rb | head -1 | sed 's/.*"\(.*\)".*/\1/')
GIT_STATUS=$(git status --short 2>/dev/null)
GIT_STATUS_LONG=$(git status 2>/dev/null)
CURRENT_BRANCH=$(git branch --show-current)
LAST_20=$(git log --oneline -20)

# Branches
DEV_LOG=$(git log dev --oneline -5 2>/dev/null || echo "(branch not found)")
MAIN_LOG=$(git log main --oneline -5 2>/dev/null || echo "(branch not found)")
ORIGIN_DEV_LOG=$(git log origin/dev --oneline -5 2>/dev/null || echo "(branch not found)")

DEV_AHEAD_MAIN=$(git rev-list main..dev --count 2>/dev/null || echo "?")
DEV_AHEAD_ORIGIN=$(git rev-list origin/dev..dev --count 2>/dev/null || echo "?")

DEV_DATE=$(git log dev -1 --format='%cs' 2>/dev/null || echo "?")
MAIN_DATE=$(git log main -1 --format='%cs' 2>/dev/null || echo "?")
ORIGIN_DEV_DATE=$(git log origin/dev -1 --format='%cs' 2>/dev/null || echo "?")
ORIGIN_MAIN_DATE=$(git log origin/main -1 --format='%cs' 2>/dev/null || echo "?")

# Tags
TAGS=$(git tag -l --format='%(refname:short) %(creatordate:short)' | sort -t' ' -k2)
TAG_DETAILS=""
while IFS=' ' read -r tag date; do
  [ -z "$tag" ] && continue
  commit=$(git log "$tag" --oneline -1 2>/dev/null)
  TAG_DETAILS="${TAG_DETAILS}| \`${tag}\` | ${date} | ${commit} |\n"
done <<< "$TAGS"

# Stale branches (remote only, older than 90 days)
STALE_BRANCHES=""
CUTOFF=$(date -v-90d +%s 2>/dev/null || date -d '90 days ago' +%s 2>/dev/null || echo 0)
while IFS= read -r line; do
  branch=$(echo "$line" | awk '{print $1}')
  bdate=$(echo "$line" | awk '{print $2}')
  # Skip main, dev, HEAD, origin (bare)
  case "$branch" in main|dev|origin/main|origin/dev|origin|origin/HEAD) continue;; esac
  # Only remote branches
  [[ "$branch" != origin/* ]] && continue
  epoch=$(date -j -f '%Y-%m-%d' "$bdate" +%s 2>/dev/null || echo 999999999999)
  [ "$epoch" -lt "$CUTOFF" ] || continue
  head_commit=$(git log "$branch" --oneline -1 2>/dev/null)
  STALE_BRANCHES="${STALE_BRANCHES}| \`${branch}\` | ${bdate} | ${head_commit} |\n"
done < <(git branch -a --format='%(refname:short) %(committerdate:short)' 2>/dev/null | sort -t' ' -k2)

# Fix commits
FIX_COUNT=$(git log --oneline --all --grep="fix:" | wc -l | tr -d ' ')
FIX_COMMITS=$(git log --oneline --all --grep="fix:" | head -40)

# Test coverage
SPEC_COUNT=$(find spec -name '*_spec.rb' -type f 2>/dev/null | sort -u | wc -l | tr -d ' ')
IT_COUNT=$(grep -r '^[[:space:]]*it ' spec/ --include='*.rb' -c 2>/dev/null \
  | awk -F: '{sum += $2} END {print sum}')

RSPEC_DRY=$(bundle exec rspec --dry-run 2>&1 | tail -5) || RSPEC_DRY="(rspec dry-run failed — see output above)"

# Scripts without specs
SCRIPTS_WITH_SPECS=$(find spec/scripts -name '*_spec.rb' -type f 2>/dev/null \
  | xargs -I{} basename {} _spec.rb | sort)
ALL_SCRIPTS=$(find scripts -maxdepth 1 -name '*.rb' -type f 2>/dev/null \
  | xargs -I{} basename {} .rb | sort)
NO_SPEC=""
for s in $ALL_SCRIPTS; do
  # Skip helper modules
  case "$s" in pool_index|library_resolver|llm_client|load_profile) continue;; esac
  echo "$SCRIPTS_WITH_SPECS" | grep -qx "$s" || NO_SPEC="${NO_SPEC}\`${s}.rb\`, "
done
NO_SPEC="${NO_SPEC%, }"

# Active project dirs
RAW_DIR="$HOME/Desktop/RAW"
RAW_LISTING=""
if [ -d "$RAW_DIR" ]; then
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    RAW_LISTING="${RAW_LISTING}| ${line} |\n"
  done < <(ls -1d "$RAW_DIR"/*/ 2>/dev/null | while read d; do
    ddate=$(stat -f '%Sm' -t '%Y-%m-%d' "$d" 2>/dev/null || date -r "$d" +%Y-%m-%d 2>/dev/null || echo "?")
    printf '%s | %s\n' "\`$(basename "$d")\`" "$ddate"
  done | sort -t'|' -k2 -r)
fi

# ─── Write STATE.md ───────────────────────────────────────────────────────────

cat > "$STATE_MD" << HEADER
# Thelma — Repo State

Generated ${TODAY} by \`scripts/refresh_project_docs.sh\`. Facts from filesystem, not assumptions.

---

## Gem Version

\`lib/buttercut/version.rb\`: **${GEM_VERSION}**

---

## Uncommitted State

\`\`\`
${GIT_STATUS_LONG}
\`\`\`

---

## Current Branches

### Active

| Branch | Last commit | Ahead of main | Notes |
|--------|------------|---------------|-------|
| \`dev\` | ${DEV_DATE} | ${DEV_AHEAD_MAIN} commits | ${DEV_AHEAD_ORIGIN} commits unpushed to origin/dev |
| \`main\` | ${MAIN_DATE} | — | Stable release |
| \`origin/dev\` | ${ORIGIN_DEV_DATE} | — | Remote dev |
| \`origin/main\` | ${ORIGIN_MAIN_DATE} | — | Remote main |

#### dev — last 5 commits

\`\`\`
${DEV_LOG}
\`\`\`

#### main — last 5 commits

\`\`\`
${MAIN_LOG}
\`\`\`

HEADER

if [ -n "$STALE_BRANCHES" ]; then
  cat >> "$STATE_MD" << STALE
### Stale (remote only, >90 days old)

| Branch | Last commit | Head commit |
|--------|------------|-------------|
$(echo -e "$STALE_BRANCHES")

STALE
fi

cat >> "$STATE_MD" << TAGS_SECTION
---

## Shipped Tags

| Tag | Date | Head commit |
|-----|------|-------------|
$(echo -e "$TAG_DETAILS")

---

## Test Coverage

**Spec files:** ${SPEC_COUNT} unique.

**Test examples:** ~${IT_COUNT} \`it\` blocks (grep count).

**rspec --dry-run:**
\`\`\`
${RSPEC_DRY}
\`\`\`

**Scripts without dedicated specs:** ${NO_SPEC}

---

## Known Bugs (fix: commits)

${FIX_COUNT} \`fix:\` commits across all branches. Most recent:

\`\`\`
$(echo "$FIX_COMMITS" | head -20)
\`\`\`

> Bug pattern grouping (time domain, multi-source, LLM integration, transcript cleanup)
> requires Claude analysis. Run: \`Tell Claude to regenerate the Known Bugs section of docs/STATE.md\`

TAGS_SECTION

if [ -n "$RAW_LISTING" ]; then
  cat >> "$STATE_MD" << RAW_SECTION
---

## Active Project Directories

\`~/Desktop/RAW/\` contents:

| Directory | Last modified |
|-----------|---------------|
$(echo -e "$RAW_LISTING")

RAW_SECTION
fi

cat >> "$STATE_MD" << TAIL
---

## Last 20 Commits (${CURRENT_BRANCH})

\`\`\`
${LAST_20}
\`\`\`
TAIL

echo "STATE.md regenerated: ${STATE_MD}"

# ─── CLI.md staleness check ──────────────────────────────────────────────────

if [ -f "$CLI_MD" ]; then
  CLI_DATE=$(stat -f '%Sm' -t '%Y-%m-%d' "$CLI_MD" 2>/dev/null || date -r "$CLI_MD" +%Y-%m-%d)
  NEWEST_SCRIPT=$(find scripts -name '*.rb' -type f -newer "$CLI_MD" 2>/dev/null | head -5)
  if [ -n "$NEWEST_SCRIPT" ]; then
    echo ""
    echo "CLI.md is STALE (last updated ${CLI_DATE}). Scripts modified since:"
    echo "$NEWEST_SCRIPT" | sed 's/^/  /'
    echo ""
    echo "Regenerate with Claude: \"Regenerate docs/CLI.md from source\""
  else
    echo "CLI.md is current (${CLI_DATE}). No scripts modified since."
  fi
else
  echo ""
  echo "CLI.md does not exist. Generate with Claude:"
  echo "  \"Scan all scripts/ and lib/buttercut/ and generate docs/CLI.md\""
fi

# ─── Reminder ─────────────────────────────────────────────────────────────────

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  REMINDER: Re-upload to Claude project knowledge"
echo ""
echo "  1. Open: https://claude.ai → Project → Thelma"
echo "  2. Replace project knowledge files:"
echo "     - docs/STATE.md"
echo "     - docs/CLI.md"
echo "     - CLAUDE.md"
echo "════════════════════════════════════════════════════════════"
