#!/bin/bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git commit -a -m "$BRANCH - $1"