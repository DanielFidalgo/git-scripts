#!/bin/bash
BRANCH_TO_MERGE=$(git symbolic-ref --short HEAD) 
git branch -D development
git fetch origin development
git checkout development
git pull 
git merge $BRANCH_TO_MERGE
git push 
git checkout $BRANCH_TO_MERGE