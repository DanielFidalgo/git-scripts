#!/bin/bash
set -euo pipefail

CLAUDE=$(which claude 2>/dev/null || echo "/opt/homebrew/bin/claude")
WORKVAULT_LOG="$HOME/.workvault/bin/workvault-log.js"

if [ -z "${1:-}" ]; then
  echo "Usage: squash.sh <base-branch> [optional hint or forced signal]"
  exit 1
fi

BASE_BRANCH="$1"
RAW_HINT="${2:-}"

cd "$(git rev-parse --show-toplevel)"
REPO=$(basename "$(pwd)")
BRANCH=$(git rev-parse --abbrev-ref HEAD)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true)

extract_prefix() {
  echo "$1" | sed -nE 's/^(decision|debug|arch|architecture|project|loop):[[:space:]]*.*/\1/ip' | head -n1 | tr '[:upper:]' '[:lower:]'
}

strip_prefix() {
  echo "$1" | sed -E 's/^(decision|debug|arch|architecture|project|loop):[[:space:]]*//I'
}

SIGNAL_KIND="$(extract_prefix "$RAW_HINT")"
HINT="$RAW_HINT"
if [ -n "$SIGNAL_KIND" ]; then
  HINT="$(strip_prefix "$RAW_HINT")"
fi

echo "Fetching $BASE_BRANCH..."
git fetch origin "$BASE_BRANCH"
git pull origin "$BASE_BRANCH"

MERGE_BASE=$(git merge-base "$BASE_BRANCH" HEAD)
COMMITS=$(git log --oneline "$MERGE_BASE"..HEAD 2>/dev/null || true)
DIFF_STAT=$(git diff "$MERGE_BASE"..HEAD --stat 2>/dev/null || true)
CHANGED_FILES=$(git diff "$MERGE_BASE"..HEAD --name-only 2>/dev/null || true)

if [ -z "$COMMITS" ]; then
  echo "No commits found to squash."
  exit 1
fi

git reset --soft "$MERGE_BASE"

TMP_JSON=$(mktemp)
cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

if [ -n "$SIGNAL_KIND" ]; then
  echo "Generating squash message with explicit signal: $SIGNAL_KIND"
  CLAUDE_OUTPUT=$("$CLAUDE" -p "
You are generating a single squash commit message from a branch history.

Return ONLY valid JSON with this exact shape:
{
  \"commit_message\": \"type(scope): short description\n\n- bullet 1\n- bullet 2\",
  \"signal\": \"none\",
  \"confidence\": 1.0,
  \"note_title\": \"short title\"
}

Rules:
- commit_message must be a conventional commit headline, then a blank line, then bullet points.
- signal must be exactly \"none\" because the user already forced the signal externally.
- confidence must be a number between 0 and 1.
- note_title should be short and reusable.
- No markdown code fences, no explanation, JSON only.

Input:
Repo: $REPO
Branch: $BRANCH
Base branch: $BASE_BRANCH
Ticket: ${TICKET:-none}
Hint: ${HINT:-none}

Commits being squashed:
$COMMITS

Changed files:
$CHANGED_FILES

Diff stat:
$DIFF_STAT
" < /dev/null 2>/dev/null || true)
else
  echo "Generating squash message and auto-detecting signal..."
  CLAUDE_OUTPUT=$("$CLAUDE" -p "
You are generating a single squash commit message and classifying whether this squashed change should create a durable work-memory note.

Return ONLY valid JSON with this exact shape:
{
  \"commit_message\": \"type(scope): short description\n\n- bullet 1\n- bullet 2\",
  \"signal\": \"none|project|debug|loop|decision|arch\",
  \"confidence\": 0.0,
  \"note_title\": \"short title\"
}

Classification guidance:
- project: meaningful progress, delivery, milestone completion
- debug: bug fix, reliability issue, root cause resolution
- loop: important follow-up remains
- decision: explicit technical choice or tradeoff
- arch: architectural/module/boundary/responsibility change
- none: ordinary squash with no durable-note value

Be conservative:
- Prefer \"none\" if uncertain.
- Only use \"decision\" or \"arch\" when there is strong evidence.
- Confidence must be between 0 and 1.
- note_title should be short and useful as a note title.
- commit_message must be a conventional commit headline, then a blank line, then bullet points.
- No markdown code fences, no explanation, JSON only.

Input:
Repo: $REPO
Branch: $BRANCH
Base branch: $BASE_BRANCH
Ticket: ${TICKET:-none}
Hint: ${HINT:-none}

Commits being squashed:
$COMMITS

Changed files:
$CHANGED_FILES

Diff stat:
$DIFF_STAT
" < /dev/null 2>/dev/null || true)
fi

if [ -z "${CLAUDE_OUTPUT:-}" ]; then
  echo '{"commit_message":"chore: squash '"$BRANCH"'","signal":"none","confidence":0.0,"note_title":"squashed branch update"}' > "$TMP_JSON"
else
  printf '%s' "$CLAUDE_OUTPUT" > "$TMP_JSON"
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

MSG="$(JSON_VALUE commit_message)"
AUTO_SIGNAL="$(JSON_VALUE signal | tr '[:upper:]' '[:lower:]')"
CONFIDENCE="$(JSON_VALUE confidence)"
NOTE_TITLE="$(JSON_VALUE note_title)"

if [ -z "$MSG" ]; then
  MSG="chore: squash $BRANCH"
fi
if [ -z "$CONFIDENCE" ]; then
  CONFIDENCE="0"
fi
if [ -z "$NOTE_TITLE" ]; then
  NOTE_TITLE="${HINT:-squashed branch update}"
fi

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

FINAL_SIGNAL=""
if [ -n "$SIGNAL_KIND" ]; then
  FINAL_SIGNAL="$SIGNAL_KIND"
else
  FINAL_SIGNAL="$AUTO_SIGNAL"
fi

SHOULD_WRITE_NOTE="no"
if [ -n "$SIGNAL_KIND" ]; then
  SHOULD_WRITE_NOTE="yes"
else
  SHOULD_WRITE_NOTE="$(should_create_note "$FINAL_SIGNAL" "$CONFIDENCE")"
fi

case "$FINAL_SIGNAL" in
  decision) PREFIX="[decision] " ;;
  debug) PREFIX="[debug] " ;;
  arch|architecture) FINAL_SIGNAL="arch"; PREFIX="[arch] " ;;
  project) PREFIX="[project] " ;;
  loop) PREFIX="[loop] " ;;
  *) FINAL_SIGNAL="none"; PREFIX="" ;;
esac

FULL_MSG="$BRANCH - $MSG"
if [ "$FINAL_SIGNAL" != "none" ] && [ "$SHOULD_WRITE_NOTE" = "yes" ]; then
  FULL_MSG="${PREFIX}${BRANCH} - $MSG"
fi

echo "Squash message:"
echo "$FULL_MSG"

git commit -m "$FULL_MSG"
git push --force origin "$BRANCH"

COMMIT_SHA=$(git rev-parse HEAD)
SUMMARY=$(printf '%s' "$MSG" | head -n 1)
HIGHLIGHT="Delivered final squashed change: $SUMMARY"

if [ -x "$WORKVAULT_LOG" ]; then
  node "$WORKVAULT_LOG" activity \
    --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --repo "$REPO" \
    --branch "$BRANCH" \
    --ticket "$TICKET" \
    --summary "Squashed branch against $BASE_BRANCH: $SUMMARY" \
    --type "squash" \
    --commit "$COMMIT_SHA" \
    --highlight "$HIGHLIGHT" || true

  node "$WORKVAULT_LOG" project \
    --repo "$REPO" \
    --achievement "${TICKET:+[$TICKET] }Squashed final branch narrative: $NOTE_TITLE" || true

  if [ "$SHOULD_WRITE_NOTE" = "yes" ]; then
    case "$FINAL_SIGNAL" in
      decision)
        node "$WORKVAULT_LOG" decision \
          --title "$NOTE_TITLE" \
          --context "Repo: $REPO
Branch: $BRANCH
Base: $BASE_BRANCH
Ticket: ${TICKET:-N/A}
Commit: $COMMIT_SHA

Squashed commits:
$COMMITS" \
          --decision "$NOTE_TITLE" \
          --outcome "Captured from squash alias" || true
        ;;
      debug)
        node "$WORKVAULT_LOG" debugging \
          --title "$NOTE_TITLE" \
          --problem "$NOTE_TITLE" \
          --rootcause "Resolved across squashed branch $BRANCH in $REPO" \
          --solution "$SUMMARY" \
          --insight "This debugging pattern was important enough to survive into the final squashed narrative." || true
        ;;
      arch)
        node "$WORKVAULT_LOG" architecture \
          --repo "$REPO" \
          --title "$NOTE_TITLE" \
          --note "Branch: $BRANCH
Base: $BASE_BRANCH
Ticket: ${TICKET:-N/A}
Commit: $COMMIT_SHA

Final squashed architecture narrative:
$MSG" || true
        ;;
      project)
        node "$WORKVAULT_LOG" project \
          --repo "$REPO" \
          --achievement "${TICKET:+[$TICKET] }$NOTE_TITLE" || true
        ;;
      loop)
        node "$WORKVAULT_LOG" open-loop \
          --project "$REPO" \
          --text "${TICKET:+[$TICKET] }Follow-up after squash: $NOTE_TITLE" || true
        ;;
    esac
  fi
fi

npx gitnexus analyze --embeddings
