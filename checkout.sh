#!/bin/bash

# Check if a branch argument is provided
if [ -z "$1" ]; then
    # Use fzf to select a remote branch if no argument is provided
    selected_branch=$(git branch -r --sort=-committerdate | awk '{$1=$1};1' | fzf --preview="git log --oneline {}" --height=15 --border | sed 's|^origin/||')

    # If no branch is selected, exit
    if [ -z "$selected_branch" ]; then
        echo "No branch selected. Exiting."
        exit 1
    fi

    # Checkout the selected branch
    git checkout "$selected_branch"
else
    # Checkout the branch provided as an argument
    git checkout "$1"
fi
