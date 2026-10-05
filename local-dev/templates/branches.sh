#!/bin/bash
# =============================================================================
# branches.sh — Bulk git branch operations across every repo in this workspace
# =============================================================================
# Acts on each git repo under pythoncode/ and sourcecode/ next to this script.
# Copied into each workspace by local-dev/lib/common.sh.
#
# New branch names must be <github-username>/<description>, where the
# description is lowercase words separated by hyphens, e.g.
#   aurashk/mypy-processmanager-oksparser
# =============================================================================

set -o pipefail

WORKSPACE_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# GitHub username: alphanumerics and single hyphens, no leading/trailing
# hyphen, at most 39 characters. Description: kebab-case.
BRANCH_NAME_REGEX='^[A-Za-z0-9]([A-Za-z0-9]|-[A-Za-z0-9]){0,38}/[a-z0-9]+(-[a-z0-9]+)*$'

# Branches that are not ours to name, skipped by "check"
SHARED_BRANCHES=(develop main master)

# -----------------------------------------------------------------------------
# Colour codes and logging helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'  # No colour

log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die()   { error "$1"; exit 1; }

usage() {
    cat << EOF
Usage: $(basename "$0") <command> [options]

Commands:
  status               Show the branch and state of every repo
  fetch                Fetch (and prune) origin in every repo
  switch <branch>      Switch every repo that has <branch>, locally or on
                       origin, to it; other repos are left where they are
  create <branch>      Create <branch> and switch to it in every repo
  check [branch]       Check a branch name, or the current branch of every
                       repo, against the naming convention

Options:
  -r, --repos a,b,c    Only act on these repos (default: all)
      --from <ref>     create: start the branch from <ref>, e.g. origin/develop
                       (default: each repo's current HEAD)
      --fallback <br>  switch: switch repos without <branch> to <br> instead
      --no-fetch       switch: don't fetch origin first
  -h, --help           Show this help message

Branch names for create must be <github-username>/<description>, with the
description in lowercase kebab-case, e.g. aurashk/mypy-processmanager-oksparser.

Repos: $(for r in "${REPOS[@]}"; do printf '%s ' "$(basename "$r")"; done)
EOF
}

# -----------------------------------------------------------------------------
# Repo helpers
# -----------------------------------------------------------------------------
REPOS=()
for repo_dir in "${WORKSPACE_DIR}"/pythoncode/*/ "${WORKSPACE_DIR}"/sourcecode/*/; do
    [[ -e "${repo_dir}.git" ]] && REPOS+=("${repo_dir%/}")
done

# Keep only the repos named in a comma-separated list
filter_repos() {
    local wanted name repo found
    local -a selected=()
    IFS=',' read -ra wanted <<< "$1"
    for name in "${wanted[@]}"; do
        found=""
        for repo in "${REPOS[@]}"; do
            [[ "$(basename "${repo}")" == "${name}" ]] && found="${repo}"
        done
        [[ -n "${found}" ]] || die "No repo named '${name}' in this workspace"
        selected+=("${found}")
    done
    REPOS=("${selected[@]}")
}

current_branch() {
    git -C "$1" symbolic-ref --quiet --short HEAD \
        || echo "(detached at $(git -C "$1" rev-parse --short HEAD))"
}

# Uncommitted changes to tracked files (untracked files are ignored)
is_dirty() {
    ! git -C "$1" diff --quiet || ! git -C "$1" diff --cached --quiet
}

has_local_branch()  { git -C "$1" show-ref --verify --quiet "refs/heads/$2"; }
has_remote_branch() { git -C "$1" show-ref --verify --quiet "refs/remotes/origin/$2"; }

require_clean() {
    local repo dirty=()
    for repo in "${REPOS[@]}"; do
        is_dirty "${repo}" && dirty+=("$(basename "${repo}")")
    done
    if [[ ${#dirty[@]} -gt 0 ]]; then
        die "Uncommitted changes in: ${dirty[*]}. Commit or stash them first."
    fi
}

check_branch_name() {
    [[ "$1" =~ ${BRANCH_NAME_REGEX} ]] && return 0
    error "Invalid branch name '$1'"
    echo "  Expected <github-username>/<description>, with the description in" >&2
    echo "  lowercase kebab-case, e.g. aurashk/mypy-processmanager-oksparser" >&2
    return 1
}

# -----------------------------------------------------------------------------
# Commands
# -----------------------------------------------------------------------------
cmd_status() {
    local repo state counts
    for repo in "${REPOS[@]}"; do
        state="clean"
        is_dirty "${repo}" && state="${YELLOW}uncommitted changes${NC}"
        if counts="$(git -C "${repo}" rev-list --left-right --count '@{upstream}...HEAD' 2>/dev/null)"; then
            read -r behind ahead <<< "${counts}"
            [[ "${ahead}" != 0 ]] && state+=", ${ahead} ahead"
            [[ "${behind}" != 0 ]] && state+=", ${behind} behind"
        fi
        printf "%-18s ${CYAN}%-50s${NC} %b\n" "$(basename "${repo}")" "$(current_branch "${repo}")" "${state}"
    done
}

cmd_fetch() {
    local repo
    for repo in "${REPOS[@]}"; do
        if git -C "${repo}" fetch --prune --quiet origin; then
            log "$(basename "${repo}"): fetched"
        else
            warn "$(basename "${repo}"): fetch failed"
        fi
    done
}

cmd_switch() {
    local branch="$1" fallback="$2" fetch="$3"
    local repo name target switched=() skipped=() failed=()
    [[ -n "${branch}" ]] || die "switch needs a branch name"
    require_clean

    for repo in "${REPOS[@]}"; do
        name="$(basename "${repo}")"
        [[ "${fetch}" == true ]] && { git -C "${repo}" fetch --quiet origin || warn "${name}: fetch failed"; }

        target=""
        if has_local_branch "${repo}" "${branch}" || has_remote_branch "${repo}" "${branch}"; then
            target="${branch}"
        elif [[ -n "${fallback}" ]] && { has_local_branch "${repo}" "${fallback}" || has_remote_branch "${repo}" "${fallback}"; }; then
            target="${fallback}"
        fi

        if [[ -z "${target}" ]]; then
            skipped+=("${name}")
        elif git -C "${repo}" switch --quiet "${target}"; then
            switched+=("${name} -> ${target}")
        else
            failed+=("${name}")
        fi
    done

    [[ ${#switched[@]} -gt 0 ]] && log "Switched: ${switched[*]}"
    # shellcheck disable=SC2016  # the single quotes are literal, inside double quotes
    [[ ${#skipped[@]} -gt 0 ]] && warn "No '${branch}'${fallback:+ or '${fallback}'} branch, left as is: ${skipped[*]}"
    [[ ${#failed[@]} -eq 0 ]] || die "Failed to switch: ${failed[*]}"
}

cmd_create() {
    local branch="$1" from="$2"
    local repo name created=() skipped=() failed=()
    [[ -n "${branch}" ]] || die "create needs a branch name"
    check_branch_name "${branch}" || exit 1

    for repo in "${REPOS[@]}"; do
        name="$(basename "${repo}")"
        if has_local_branch "${repo}" "${branch}"; then
            skipped+=("${name}")
        elif [[ -n "${from}" ]] && ! git -C "${repo}" rev-parse --verify --quiet "${from}^{commit}" >/dev/null; then
            error "${name}: start point '${from}' not found"
            failed+=("${name}")
        elif git -C "${repo}" switch --quiet --no-track -c "${branch}" ${from:+"${from}"}; then
            created+=("${name}")
        else
            failed+=("${name}")
        fi
    done

    [[ ${#created[@]} -gt 0 ]] && log "Created and switched to '${branch}' in: ${created[*]}"
    [[ ${#skipped[@]} -gt 0 ]] && warn "'${branch}' already exists, left as is (use switch): ${skipped[*]}"
    [[ ${#failed[@]} -eq 0 ]] || die "Failed to create '${branch}' in: ${failed[*]}"
}

cmd_check() {
    local branch="$1" repo current invalid=0
    if [[ -n "${branch}" ]]; then
        check_branch_name "${branch}" || exit 1
        log "'${branch}' is a valid branch name"
        return 0
    fi

    for repo in "${REPOS[@]}"; do
        current="$(current_branch "${repo}")"
        if [[ "${current}" == "(detached"* || " ${SHARED_BRANCHES[*]} " == *" ${current} "* ]]; then
            printf "%-18s %-50s %s\n" "$(basename "${repo}")" "${current}" "skipped"
        elif [[ "${current}" =~ ${BRANCH_NAME_REGEX} ]]; then
            printf "%-18s %-50s ${GREEN}%s${NC}\n" "$(basename "${repo}")" "${current}" "ok"
        else
            printf "%-18s %-50s ${RED}%s${NC}\n" "$(basename "${repo}")" "${current}" "invalid name"
            invalid=1
        fi
    done
    return "${invalid}"
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
COMMAND=""
BRANCH=""
FROM=""
FALLBACK=""
FETCH=true
REPO_FILTER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--repos)  [[ $# -ge 2 ]] || die "$1 needs a value"; REPO_FILTER="$2"; shift 2 ;;
        --from)      [[ $# -ge 2 ]] || die "$1 needs a value"; FROM="$2"; shift 2 ;;
        --fallback)  [[ $# -ge 2 ]] || die "$1 needs a value"; FALLBACK="$2"; shift 2 ;;
        --no-fetch)  FETCH=false; shift ;;
        -h|--help)   usage; exit 0 ;;
        -*)          error "Unknown option: $1"; usage >&2; exit 1 ;;
        *)
            if [[ -z "${COMMAND}" ]]; then
                COMMAND="$1"
            elif [[ -z "${BRANCH}" ]]; then
                BRANCH="$1"
            else
                die "Unexpected argument: $1"
            fi
            shift ;;
    esac
done

[[ ${#REPOS[@]} -gt 0 ]] || die "No git repos found in ${WORKSPACE_DIR}/pythoncode or ${WORKSPACE_DIR}/sourcecode"
[[ -n "${REPO_FILTER}" ]] && filter_repos "${REPO_FILTER}"

case "${COMMAND}" in
    status) cmd_status ;;
    fetch)  cmd_fetch ;;
    switch) cmd_switch "${BRANCH}" "${FALLBACK}" "${FETCH}" ;;
    create) cmd_create "${BRANCH}" "${FROM}" ;;
    check)  cmd_check "${BRANCH}" ;;
    "")     usage; exit 1 ;;
    *)      error "Unknown command: ${COMMAND}"; usage >&2; exit 1 ;;
esac
