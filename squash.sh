#!/bin/bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch origin $1
git pull origin $1
git reset --soft $(git merge-base $1 HEAD)
git commit -a -m "$2"
git push --force origin $BRANCH