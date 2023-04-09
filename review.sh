#!/bin/bash
BRANCH="staging"
if [ ! -z "$2" ]
then
   BRANCH=$2
fi
git fetch origin $1
git checkout $BRANCH
git fetch origin $BRANCH
git pull origin $BRANCH
git merge origin/$1 --no-commit --no-ff
