#!/bin/bash
CLAUDE=$(which claude 2>/dev/null || echo "/opt/homebrew/bin/claude")
BRANCH_TO_MERGE=$(git symbolic-ref --short HEAD)
git branch -D development
git fetch origin development
git checkout development
git pull
git merge $BRANCH_TO_MERGE --no-edit

if [ $? -ne 0 ]; then
    echo "Merge conflicts detected. Asking Claude to resolve..."
    $CLAUDE -p "Resolve all git merge conflicts in the current repository. Look at all conflicted files, resolve the conflicts by keeping the most sensible combination of changes, then stage all resolved files with git add."
    git merge --continue --no-edit
fi

git push
git checkout $BRANCH_TO_MERGE
