#!/bin/bash
set -euo pipefail

CLAUDE=$(which claude 2>/dev/null || echo "/opt/homebrew/bin/claude")
WORKVAULT_LOG="$HOME/.workvault/bin/workvault-log.js"

cd "$(git rev-parse --show-toplevel)"
REPO=$(basename "$(pwd)")
INPUT="$*"

if [ -z "$INPUT" ]; then
  echo "Usage: new_branch.sh <branch-name or natural language description>"
  exit 1
fi

if echo "$INPUT" | grep -q ' '; then
  echo "Generating branch name..."
  BRANCH_NAME=$(echo "$INPUT" | \
    "$CLAUDE" -p "Convert this description into a git branch name.
Use the format type/short-description (e.g. feat/add-oauth-login, fix/null-pointer-cart, chore/update-deps).
If there is a ticket id in the input, preserve it in the branch name.
Use lowercase, hyphens only, max 60 chars. Output only the branch name." --dangerously-skip-permissions 2>/dev/null || true)
  if [ -z "$BRANCH_NAME" ]; then
    BRANCH_NAME=$(echo "$INPUT" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
  fi
else
  BRANCH_NAME="$INPUT"
fi

echo "Creating branch: $BRANCH_NAME"
git checkout -b "$BRANCH_NAME"

TICKET=$(echo "$BRANCH_NAME" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -n1 || true)

if [ -x "$WORKVAULT_LOG" ]; then
  node "$WORKVAULT_LOG" open-loop \
    --project "$REPO" \
    --text "${TICKET:+[$TICKET] }Started work on branch $BRANCH_NAME" || true

  node "$WORKVAULT_LOG" activity \
    --ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --repo "$REPO" \
    --branch "$BRANCH_NAME" \
    --ticket "$TICKET" \
    --summary "Started work on $BRANCH_NAME" \
    --type "branch-created" \
    --commit "" \
    --highlight "Started workstream: $BRANCH_NAME" || true
fi
