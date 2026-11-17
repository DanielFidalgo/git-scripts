#!/bin/bash
set -euo pipefail

REPO_PAGE_SIZE=100
AFFILIATIONS="owner,collaborator,organization_member"
FZF_HEIGHT=20

usage() {
  cat <<'USAGE'
Usage: clone.sh [options] [repo ...]

Clones repositories into the repos home directory.

  no repo arguments   pick repositories in fzf (TAB toggles, additive multi-select)
  repo arguments      clone exactly those (accepts "name" or "owner/name")

Options:
  --all             clone every available repository, no picker
  --into <dir>      repos home for this run (overrides GIT_REPOS_HOME)
  --owner <owner>   list and resolve bare names against this user or org
  --dry-run         print what would be cloned, clone nothing
  -h, --help        show this help

The repos home comes from --into, else $GIT_REPOS_HOME.
USAGE
}

die() {
  echo "$1" >&2
  exit 1
}

resolve_repos_home() {
  local requested="$1"
  local home="${requested:-${GIT_REPOS_HOME:-}}"
  [ -n "$home" ] || die "No repos home. Set GIT_REPOS_HOME or pass --into <dir>."
  mkdir -p "$home"
  cd "$home" && pwd
}

resolve_owner() {
  gh api user --jq '.login' 2>/dev/null || die "Cannot resolve your GitHub login. Run: gh auth login"
}

list_available_repos() {
  local owner="$1"
  if [ -n "$owner" ]; then
    gh repo list "$owner" --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner'
  else
    gh api --paginate \
      "user/repos?per_page=$REPO_PAGE_SIZE&affiliation=$AFFILIATIONS&sort=pushed" \
      --jq '.[].full_name'
  fi
}

pick_repos() {
  local candidates="$1"
  [ -n "$candidates" ] || die "No repositories available to clone."
  printf '%s\n' "$candidates" | fzf \
    --multi \
    --height="$FZF_HEIGHT" \
    --border \
    --prompt='clone> ' \
    --header='TAB to add, ENTER to clone' \
    --preview='gh repo view {} 2>/dev/null | head -40'
}

qualify_name() {
  local name="$1" owner="$2"
  case "$name" in
    */*) printf '%s\n' "$name" ;;
    *) printf '%s/%s\n' "$owner" "$name" ;;
  esac
}

clone_repo() {
  local full_name="$1" repos_home="$2" dry_run="$3"
  local target="$repos_home/${full_name##*/}"

  if [ -d "$target" ]; then
    echo "exists, skipping: $target"
    return 0
  fi
  if [ "$dry_run" = "yes" ]; then
    echo "would clone: $full_name -> $target"
    return 0
  fi
  echo "cloning: $full_name -> $target"
  gh repo clone "$full_name" "$target" || echo "failed: $full_name" >&2
}

main() {
  local requested_home="" owner="" clone_all="no" dry_run="no"
  local -a requested_repos=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --all) clone_all="yes"; shift ;;
      --into) requested_home="${2:-}"; [ -n "$requested_home" ] || die "--into needs a directory"; shift 2 ;;
      --owner) owner="${2:-}"; [ -n "$owner" ] || die "--owner needs a name"; shift 2 ;;
      --dry-run) dry_run="yes"; shift ;;
      -h|--help) usage; exit 0 ;;
      -*) die "Unknown option: $1" ;;
      *) requested_repos+=("$1"); shift ;;
    esac
  done

  command -v gh >/dev/null 2>&1 || die "gh is required. Install it: brew install gh"

  local repos_home
  repos_home="$(resolve_repos_home "$requested_home")"

  local resolved_owner
  resolved_owner="${owner:-$(resolve_owner)}"

  local selection
  if [ "${#requested_repos[@]}" -gt 0 ]; then
    selection="$(printf '%s\n' "${requested_repos[@]}")"
  elif [ "$clone_all" = "yes" ]; then
    selection="$(list_available_repos "$owner")"
  else
    command -v fzf >/dev/null 2>&1 || die "fzf is required for the picker. Pass repo names or --all."
    selection="$(pick_repos "$(list_available_repos "$owner")" || true)"
    [ -n "$selection" ] || die "Nothing selected. Exiting."
  fi

  while IFS= read -r name; do
    [ -n "$name" ] || continue
    clone_repo "$(qualify_name "$name" "$resolved_owner")" "$repos_home" "$dry_run"
  done <<< "$selection"
}

main "$@"
