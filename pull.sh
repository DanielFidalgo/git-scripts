#!/bin/bash
BRANCH=$(git rev-parse --abbrev-ref HEAD)
git pull origin $BRANCH