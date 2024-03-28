#!/bin/bash
BRANCH_NAME=$(git symbolic-ref --short HEAD)
pbcopy $BRANCH_NAME