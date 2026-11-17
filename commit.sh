#!/bin/bash
set -euo pipefail

CLAUDE=$(which claude 2>/dev/null || echo "/opt/homebrew/bin/claude")
WORKVAULT_LOG="$HOME/.workvault/bin/workvault-log.js"

cd "$(git rev-parse --show-toplevel)"
REPO=$(basename "$(pwd)")
BRANCH=$(git rev-parse --abbrev-ref HEAD)
TICKET=$(echo "$BRANCH" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true)

git add .

DIFF=$(git diff --cached)
if [ -z "$DIFF" ]; then
  echo "Nothing staged to commit."
  exit 1
fi

RAW_HINT="${1:-}"
HINT="$RAW_HINT"

extract_prefix() {
  echo "$1" | sed -nE 's/^(decision|debug|arch|architecture|project|loop):[[:space:]]*.*/\1/ip' | head -n1 | tr '[:upper:]' '[:lower:]'
}

strip_prefix() {
  echo "$1" | sed -E 's/^(decision|debug|arch|architecture|project|loop):[[:space:]]*//I'
}

SIGNAL_KIND="$(extract_prefix "$RAW_HINT")"
if [ -n "$SIGNAL_KIND" ]; then
  HINT="$(strip_prefix "$RAW_HINT")"
fi

TMP_JSON=$(mktemp)
cleanup() {
  rm -f "$TMP_JSON"
}
trap cleanup EXIT

PROMPT_INPUT=$(mktemp)
printf 'Branch: %s\nTicket: %s\nRepo: %s\nHint: %s\n\nStaged diff:\n' \
  "$BRANCH" "${TICKET:-none}" "$REPO" "${HINT:-none}" > "$PROMPT_INPUT"
printf '%s\n' "$DIFF" >> "$PROMPT_INPUT"

if [ -n "$SIGNAL_KIND" ]; then
  echo "Generating commit message with explicit signal: $SIGNAL_KIND"
  TMP_ERR=$(mktemp)
  CLAUDE_OUTPUT=$(cat "$PROMPT_INPUT" | "$CLAUDE" -p "
You are generating a git commit message from branch context, an optional hint, and a staged diff.

Return ONLY valid JSON with this exact shape:
{
  \"commit_message\": \"type(scope): description\",
  \"signal\": \"none\",
  \"confidence\": 1.0,
  \"note_title\": \"short title\"
}

Rules:
- commit_message must be a concise conventional commit message derived from the actual diff content.
- The description part MUST name specific files, functions, configs, or behaviors that changed — never use vague words like \"update\", \"fix stuff\", \"update code\", or \"changes\".
- signal must be exactly \"none\" because the user already forced the signal externally.
- confidence must be a number between 0 and 1.
- note_title should be a short reusable title derived from the hint/diff.
- No markdown, no explanation, JSON only.
- Keep commit_message under 90 characters.
" --dangerously-skip-permissions 2>"$TMP_ERR" || true)
  [ -z "${CLAUDE_OUTPUT:-}" ] && [ -s "$TMP_ERR" ] && echo "Claude error: $(cat "$TMP_ERR")" >&2
  rm -f "$TMP_ERR"
else
  echo "Generating commit message and auto-detecting signal..."
  TMP_ERR=$(mktemp)
  CLAUDE_OUTPUT=$(cat "$PROMPT_INPUT" | "$CLAUDE" -p "
You are generating a git commit message and classifying whether the change should create a durable work-memory note.

Return ONLY valid JSON with this exact shape:
{
  \"commit_message\": \"type(scope): description\",
  \"signal\": \"none|project|debug|loop|decision|arch\",
  \"confidence\": 0.0,
  \"note_title\": \"short title\"
}

Classification guidance:
- project: meaningful progress on a ticket/feature/delivery
- debug: bug fix, root cause resolution, tricky failure diagnosis
- loop: important follow-up remains
- decision: explicit technical choice/tradeoff was made
- arch: architectural/module/boundary/ownership change
- none: normal work with no durable-note value

Be conservative:
- Prefer \"none\" if uncertain.
- Only use \"decision\" or \"arch\" when there is strong evidence.
- Confidence must be between 0 and 1.
- commit_message must be a concise conventional commit message derived from the actual diff content.
- The description part MUST name specific files, functions, configs, or behaviors that changed — never use vague words like \"update\", \"fix stuff\", \"update code\", or \"changes\".
- note_title should be short and useful as a note title.
- No markdown, no explanation, JSON only.
- Keep commit_message under 90 characters.
" --dangerously-skip-permissions 2>"$TMP_ERR" || true)
  [ -z "${CLAUDE_OUTPUT:-}" ] && [ -s "$TMP_ERR" ] && echo "Claude error: $(cat "$TMP_ERR")" >&2
  rm -f "$TMP_ERR"
fi

rm -f "$PROMPT_INPUT"

if [ -z "${CLAUDE_OUTPUT:-}" ]; then
  echo '{"commit_message":"chore: update code","signal":"none","confidence":0.0,"note_title":"work update"}' > "$TMP_JSON"
else
  printf '%s' "$CLAUDE_OUTPUT" > "$TMP_JSON"
fi

JSON_VALUE() {
  python3 - "$TMP_JSON" "$1" <<'PY'
import json, sys, re
path = sys.argv[1]
key = sys.argv[2]
try:
    with open(path, 'r', encoding='utf-8') as f:
        content = f.read().strip()
    content = re.sub(r'^```(?:json)?\s*\n?', '', content)
    content = re.sub(r'\n?```\s*$', '', content)
    m = re.search(r'\{[\s\S]*\}', content)
    if m:
        content = m.group(0)
    data = json.loads(content)
    val = data.get(key, "")
    if isinstance(val, (dict, list)):
        print("")
    else:
        print(val)
except Exception:
    print("")
PY
}

COMMIT_MESSAGE="$(JSON_VALUE commit_message)"
AUTO_SIGNAL="$(JSON_VALUE signal | tr '[:upper:]' '[:lower:]')"
CONFIDENCE="$(JSON_VALUE confidence)"
NOTE_TITLE="$(JSON_VALUE note_title)"

if [ -z "$COMMIT_MESSAGE" ]; then
  COMMIT_MESSAGE="chore: update code"
fi

if [ -z "$NOTE_TITLE" ]; then
  NOTE_TITLE="${HINT:-work update}"
fi

if [ -z "$CONFIDENCE" ]; then
  CONFIDENCE="0"
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

FULL_MSG="${BRANCH} - ${COMMIT_MESSAGE}"
if [ "$FINAL_SIGNAL" != "none" ] && [ "$SHOULD_WRITE_NOTE" = "yes" ]; then
  FULL_MSG="${PREFIX}${BRANCH} - ${COMMIT_MESSAGE}"
fi

echo "Committing: $FULL_MSG"
if [ -z "$SIGNAL_KIND" ]; then
  echo "Detected signal: ${FINAL_SIGNAL} (confidence: ${CONFIDENCE})"
fi

git commit -m "$FULL_MSG"

COMMIT_SHA=$(git rev-parse HEAD)
SUMMARY="$COMMIT_MESSAGE"
HIGHLIGHT="Delivered: $COMMIT_MESSAGE"

if [ -x "$WORKVAULT_LOG" ]; then
  node "$WORKVAULT_LOG" activity \
    --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --repo "$REPO" \
    --branch "$BRANCH" \
    --ticket "$TICKET" \
    --summary "$SUMMARY" \
    --type "commit-alias" \
    --commit "$COMMIT_SHA" \
    --highlight "$HIGHLIGHT" || true

  if [ "$SHOULD_WRITE_NOTE" = "yes" ]; then
    case "$FINAL_SIGNAL" in
      decision)
        node "$WORKVAULT_LOG" decision \
          --title "$NOTE_TITLE" \
          --context "Repo: $REPO
Branch: $BRANCH
Ticket: ${TICKET:-N/A}
Commit: $COMMIT_SHA" \
          --decision "$NOTE_TITLE" \
          --outcome "Captured from commit alias" || true
        ;;
      debug)
        node "$WORKVAULT_LOG" debugging \
          --title "$NOTE_TITLE" \
          --problem "$NOTE_TITLE" \
          --rootcause "Investigated in $REPO on branch $BRANCH" \
          --solution "$COMMIT_MESSAGE" \
          --insight "Revisit this debugging pattern if it reappears in $REPO" || true
        ;;
      arch)
        node "$WORKVAULT_LOG" architecture \
          --repo "$REPO" \
          --title "$NOTE_TITLE" \
          --note "Branch: $BRANCH
Ticket: ${TICKET:-N/A}
Commit: $COMMIT_SHA

Architecture note captured from commit alias." || true
        ;;
      project)
        node "$WORKVAULT_LOG" project \
          --repo "$REPO" \
          --achievement "${TICKET:+[$TICKET] }$NOTE_TITLE" || true
        ;;
      loop)
        node "$WORKVAULT_LOG" open-loop \
          --project "$REPO" \
          --text "${TICKET:+[$TICKET] }$NOTE_TITLE" || true
        ;;
    esac
  fi
fi
