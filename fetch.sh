#!/bin/bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git fetch origin $BRANCH