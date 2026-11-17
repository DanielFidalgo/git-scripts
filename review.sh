#!/bin/bash
set -euo pipefail

CLAUDE=$(which claude 2>/dev/null || echo "/opt/homebrew/bin/claude")
WORKVAULT_LOG="$HOME/.workvault/bin/workvault-log.js"

if [ -z "${1:-}" ]; then
  echo "Usage: review.sh <source-branch> [target-branch]"
  exit 1
fi

SOURCE_BRANCH="$1"
TARGET_BRANCH="${2:-main}"

cd "$(git rev-parse --show-toplevel)"
REPO=$(basename "$(pwd)")
TICKET=$(echo "$SOURCE_BRANCH" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true)

git fetch origin "$SOURCE_BRANCH"
git checkout "$TARGET_BRANCH"
git fetch origin "$TARGET_BRANCH"
git pull origin "$TARGET_BRANCH"
git merge "origin/$SOURCE_BRANCH" --no-commit --no-ff || true

COMMITS=$(git log "origin/$TARGET_BRANCH..origin/$SOURCE_BRANCH" --oneline 2>/dev/null || true)
DIFF_STAT=$(git diff --cached --stat 2>/dev/null || true)
DIFF=$(git diff --cached 2>/dev/null || true)

echo ""
echo "=== Claude Review Summary ==="
SUMMARY=$(printf "Branch being merged: %s\nInto: %s\n\nCommits:\n%s\n\nFiles changed:\n%s\n\nDiff:\n%s" \
  "$SOURCE_BRANCH" "$TARGET_BRANCH" "$COMMITS" "$DIFF_STAT" "$DIFF" | \
  "$CLAUDE" -p "You are reviewing a pull request merge. Provide a concise review summary with:
- What this does: one or two sentences
- Key changes: bullet points summarizing main changes and their purpose
- Watch out for: risks or areas worth extra attention
- Suggested improvements: specific improvements

Be specific and technical. No filler." --dangerously-skip-permissions 2>/dev/null || true)

echo "${SUMMARY:-"(Claude unavailable)"}"
echo "============================="
echo ""

git merge --abort >/dev/null 2>&1 || true

if [ -x "$WORKVAULT_LOG" ] && [ -n "${SUMMARY:-}" ]; then
  SHORT_SUMMARY=$(echo "$SUMMARY" | head -n 1 | sed 's/^- //' | tr '\n' ' ')
  node "$WORKVAULT_LOG" activity \
    --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --repo "$REPO" \
    --branch "$SOURCE_BRANCH" \
    --ticket "$TICKET" \
    --summary "Reviewed branch $SOURCE_BRANCH into $TARGET_BRANCH" \
    --type "review" \
    --commit "" \
    --highlight "Review completed for $SOURCE_BRANCH" || true

  node "$WORKVAULT_LOG" open-loop \
    --project "$REPO" \
    --text "${TICKET:+[$TICKET] }Review follow-up for $SOURCE_BRANCH: ${SHORT_SUMMARY:-check suggestions}" || true

  node "$WORKVAULT_LOG" architecture \
    --repo "$REPO" \
    --title "Review note for $SOURCE_BRANCH" \
    --note "$SUMMARY" || true
fi
