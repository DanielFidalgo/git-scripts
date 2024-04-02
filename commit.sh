#!/bin/bash
cd $(git rev-parse --show-toplevel)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git add .
git commit -a -m "$BRANCH - $1"