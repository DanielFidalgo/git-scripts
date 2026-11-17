#!/bin/bash
set -euo pipefail

CLAUDE=$(which claude 2>/dev/null || echo "/opt/homebrew/bin/claude")
WORKVAULT_LOG="$HOME/.workvault/bin/workvault-log.js"

cd "$(git rev-parse --show-toplevel)"
REPO=$(basename "$(pwd)")
BRANCH=$(git rev-parse --abbrev-ref HEAD)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true)
BASE_BRANCH=$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "main")

PREV=""
for arg in "$@"; do
  if [ "$PREV" = "--base" ]; then BASE_BRANCH="$arg"; fi
  PREV="$arg"
done

extract_branch_signal() {
  local branch="$1"
  echo "$branch" | sed -nE 's#^(decision|debug|arch|architecture|project|loop)/.*#\1#ip' | head -n1 | tr '[:upper:]' '[:lower:]'
}

BRANCH_SIGNAL="$(extract_branch_signal "$BRANCH")"

echo "Fetching $BASE_BRANCH..."
git fetch origin "$BASE_BRANCH" >/dev/null 2>&1 || true
git pull origin "$BASE_BRANCH" --ff-only >/dev/null 2>&1 || true

COMMITS=$(git log "origin/$BASE_BRANCH..HEAD" --oneline 2>/dev/null || true)
if [ -z "$COMMITS" ]; then
  COMMITS=$(git log HEAD~5..HEAD --oneline 2>/dev/null || true)
fi

DIFF_STAT=$(git diff "origin/$BASE_BRANCH..HEAD" --stat 2>/dev/null || true)
CHANGED_FILES=$(git diff --name-only "origin/$BASE_BRANCH..HEAD" 2>/dev/null || true)

echo "Generating PR title..."
TITLE=$(printf "Branch: %s\nBase: %s\nCommits:\n%s\n\nChanged files:\n%s" \
  "$BRANCH" "$BASE_BRANCH" "$COMMITS" "$DIFF_STAT" | \
  "$CLAUDE" -p "Generate a concise, descriptive pull request title (max 72 chars).
Be specific about what changed. No quotes, no markdown, just the plain title text." --dangerously-skip-permissions 2>/dev/null || true)

if [ -z "$TITLE" ]; then
  TITLE="$BRANCH"
fi

echo "Generating PR description..."
BODY=$(printf "Branch: %s\nBase: %s\nCommits:\n%s\n\nChanged files:\n%s" \
  "$BRANCH" "$BASE_BRANCH" "$COMMITS" "$DIFF_STAT" | \
  "$CLAUDE" -p "Generate a pull request description in markdown with these sections:
## Summary
2-3 bullet points of what changed and why.

## Changes
Specific list of changes made.

## Testing
What reviewers should test or verify.

Be technical and specific. No filler." --dangerously-skip-permissions 2>/dev/null || true)

if [ -z "$BODY" ]; then
  BODY="$COMMITS"
fi

TMP_JSON=$(mktemp)
cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

if [ -n "$BRANCH_SIGNAL" ]; then
  cat > "$TMP_JSON" <<EOF
{"signal":"$BRANCH_SIGNAL","confidence":1.0,"note_title":"$TITLE"}
EOF
else
  echo "Auto-detecting PR signal..."
  SIGNAL_JSON=$("$CLAUDE" -p "
You are classifying whether this pull request should create a durable work-memory note.

Return ONLY valid JSON with this exact shape:
{
  \"signal\": \"none|project|debug|loop|decision|arch\",
  \"confidence\": 0.0,
  \"note_title\": \"short title\"
}

Classification guidance:
- project: meaningful progress, delivery, feature completion, rollout milestone
- debug: bug fix, tricky failure, root cause, reliability fix
- loop: important follow-up, unresolved risk, deferred work
- decision: explicit technical choice or tradeoff
- arch: architectural/module/boundary/responsibility change
- none: ordinary PR without durable-note value

Be conservative:
- Prefer \"none\" if uncertain.
- Only use \"decision\" or \"arch\" when there is strong evidence.
- Confidence must be between 0 and 1.
- note_title should be short and useful as a note title.
- No markdown, no explanation, JSON only.

Input:
Repo: $REPO
Branch: $BRANCH
Ticket: ${TICKET:-none}
Base: $BASE_BRANCH

PR Title:
$TITLE

PR Body:
$BODY

Commits:
$COMMITS

Changed files:
$CHANGED_FILES

Diff stat:
$DIFF_STAT
" --dangerously-skip-permissions < /dev/null 2>/dev/null || true)

  if [ -z "${SIGNAL_JSON:-}" ]; then
    echo '{"signal":"none","confidence":0.0,"note_title":"PR update"}' > "$TMP_JSON"
  else
    printf '%s' "$SIGNAL_JSON" > "$TMP_JSON"
  fi
fi

JSON_VALUE() {
  python3 - "$TMP_JSON" "$1" <<'PY'
import json, sys
path = sys.argv[1]
key = sys.argv[2]
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    val = data.get(key, "")
    if isinstance(val, (dict, list)):
        print("")
    else:
        print(val)
except Exception:
    print("")
PY
}

FINAL_SIGNAL="$(JSON_VALUE signal | tr '[:upper:]' '[:lower:]')"
CONFIDENCE="$(JSON_VALUE confidence)"
NOTE_TITLE="$(JSON_VALUE note_title)"

if [ -z "$FINAL_SIGNAL" ]; then FINAL_SIGNAL="none"; fi
if [ -z "$CONFIDENCE" ]; then CONFIDENCE="0"; fi
if [ -z "$NOTE_TITLE" ]; then NOTE_TITLE="$TITLE"; fi

should_create_note() {
  local signal="$1"
  local confidence="$2"

  python3 - "$signal" "$confidence" <<'PY'
import sys
signal = sys.argv[1]
try:
    conf = float(sys.argv[2])
except Exception:
    conf = 0.0

thresholds = {
    "debug": 0.65,
    "project": 0.65,
    "loop": 0.65,
    "decision": 0.82,
    "arch": 0.82,
}
print("yes" if signal in thresholds and conf >= thresholds[signal] else "no")
PY
}

if [ -n "$BRANCH_SIGNAL" ]; then
  case "$BRANCH_SIGNAL" in
    arch|architecture) FINAL_SIGNAL="arch" ;;
    *) FINAL_SIGNAL="$BRANCH_SIGNAL" ;;
  esac
  SHOULD_WRITE_NOTE="yes"
else
  SHOULD_WRITE_NOTE="$(should_create_note "$FINAL_SIGNAL" "$CONFIDENCE")"
fi

gh label create "in-review" --color "0075ca" --description "PR is ready for review" 2>/dev/null || true

echo "Creating PR: $TITLE"
if [ -z "$BRANCH_SIGNAL" ]; then
  echo "Detected PR signal: ${FINAL_SIGNAL} (confidence: ${CONFIDENCE})"
fi

gh pr create \
  --title "$TITLE" \
  --body "$BODY" \
  --assignee "@me" \
  --label "in-review" \
  "$@"

if [ -x "$WORKVAULT_LOG" ]; then
  node "$WORKVAULT_LOG" activity \
    --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --repo "$REPO" \
    --branch "$BRANCH" \
    --ticket "$TICKET" \
    --summary "Opened PR: $TITLE" \
    --type "pull-request" \
    --commit "" \
    --highlight "Prepared PR: $TITLE" || true

  node "$WORKVAULT_LOG" project \
    --repo "$REPO" \
    --achievement "${TICKET:+[$TICKET] }Opened PR: $TITLE" || true

  if [ "$SHOULD_WRITE_NOTE" = "yes" ]; then
    case "$FINAL_SIGNAL" in
      decision)
        node "$WORKVAULT_LOG" decision \
          --title "$NOTE_TITLE" \
          --context "Repo: $REPO
Branch: $BRANCH
Ticket: ${TICKET:-N/A}
Base: $BASE_BRANCH
PR Title: $TITLE" \
          --decision "$NOTE_TITLE" \
          --outcome "Captured from PR creation" || true
        ;;
      debug)
        node "$WORKVAULT_LOG" debugging \
          --title "$NOTE_TITLE" \
          --problem "$NOTE_TITLE" \
          --rootcause "PR in $REPO from branch $BRANCH" \
          --solution "$TITLE" \
          --insight "Review this PR if similar reliability/debugging issues recur in $REPO" || true
        ;;
      arch)
        node "$WORKVAULT_LOG" architecture \
          --repo "$REPO" \
          --title "$NOTE_TITLE" \
          --note "Branch: $BRANCH
Ticket: ${TICKET:-N/A}
Base: $BASE_BRANCH
PR Title: $TITLE

$BODY" || true
        ;;
      loop)
        node "$WORKVAULT_LOG" open-loop \
          --project "$REPO" \
          --text "${TICKET:+[$TICKET] }Follow-up from PR: $NOTE_TITLE" || true
        ;;
      project)
        node "$WORKVAULT_LOG" project \
          --repo "$REPO" \
          --achievement "${TICKET:+[$TICKET] }$NOTE_TITLE" || true
        ;;
    esac
  fi
fi
