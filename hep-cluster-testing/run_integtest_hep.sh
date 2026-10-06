#!/bin/bash
# =============================================================================
# run_integtest_hep.sh — Run DAQ integration tests on a cluster, in the Alma 9
#                        devcontainer image, at the commits you choose
# =============================================================================
# Copies this repo's scripts to the cluster and runs
# cluster/integtest_hep_remote.sh there, which pulls the image, keeps one dbt
# work area per release, checks out the requested commits, rebuilds, and runs
# daqsystemtest_integtest_bundle.sh in apptainer. The run's console log, junit
# XML and summary are copied back to results/<run-id>/. The exit code is 0 only
# if every test passed.
#
# Your cluster user, host and storage directory are read from hep.conf next to
# this script (git-ignored; copy hep.conf.example). See README.md.
#
# Usage:   ./run_integtest_hep.sh [options] [-- <bundle options>]
# Examples:
#   # Every repo at the commit checked out in a local workspace, on its release
#   ./run_integtest_hep.sh -w ../local-dev/workspaces/<release>_<profile>
#
#   # Branches by name, on the latest nightly
#   ./run_integtest_hep.sh -r drunc=<user>/my-feature -r druncschema=<user>/my-feature
#
#   # The core suite instead of the minimal system quick test
#   ./run_integtest_hep.sh -w <workspace> -- --stop-on-failure -s core
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${HEP_CONFIG:-${SCRIPT_DIR}/hep.conf}"
RESULTS_DIR="${SCRIPT_DIR}/results"
DEFAULT_BUNDLE_ARGS=(--stop-on-failure -k minimal_system_quick_test)

# -----------------------------------------------------------------------------
# Colour codes and logging helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'  # No colour

log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] [LOCAL]${NC} $1"; }
info()  { echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] ${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] ${NC} $1"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR]${NC} $1" >&2; }
die()   { error "$1"; exit 1; }

usage() {
    cat << EOF
Usage: $(basename "$0") [options] [-- <bundle options>]

Options:
  -w, --workspace DIR    Test every repo in this local workspace at its checked
                         out commit, on the workspace's release and profile
                         (default: HEP_DEFAULT_WORKSPACE from hep.conf, if set
                         and no -r is given)
  -r, --repo NAME=BRANCH Test NAME at origin/BRANCH (repeatable; overrides -w)
      --release TAG      DAQ release (default: the workspace's, else last_fddaq)
      --base TYPE        stable, candidate or nightly (default: the workspace's,
                         else nightly)
  -p, --profile NAME     local-dev profile for the cluster work area
                         (default: the workspace's, else drunc-minimal)
  -h, --help             Show this help message

Repos not named with -w or -r are tested at the release's own commits.
Bundle options go to daqsystemtest_integtest_bundle.sh; the default is:
  ${DEFAULT_BUNDLE_ARGS[*]}
--junit-xml and --tmpdir are always added.

Settings are read from ${CONFIG_FILE}
(override the path with HEP_CONFIG); see hep.conf.example.
EOF
}

# -----------------------------------------------------------------------------
# Arguments
# -----------------------------------------------------------------------------
WORKSPACE=""
RELEASE_TAG=""
RELEASE_BASE=""
PROFILE=""
declare -A REFS=()
BUNDLE_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        -w|--workspace) [[ $# -ge 2 ]] || die "$1 needs a value"; WORKSPACE="$2"; shift 2 ;;
        -r|--repo)
            [[ $# -ge 2 && "$2" == ?*=?* ]] || die "$1 needs NAME=BRANCH"
            REFS[${2%%=*}]="origin/${2#*=}"
            shift 2 ;;
        --release) [[ $# -ge 2 ]] || die "$1 needs a value"; RELEASE_TAG="$2"; shift 2 ;;
        --base)    [[ $# -ge 2 ]] || die "$1 needs a value"; RELEASE_BASE="$2"; shift 2 ;;
        -p|--profile) [[ $# -ge 2 ]] || die "$1 needs a value"; PROFILE="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; BUNDLE_ARGS=("$@"); break ;;
        *) error "Unknown argument: $1"; usage >&2; exit 1 ;;
    esac
done
[[ ${#BUNDLE_ARGS[@]} -gt 0 ]] || BUNDLE_ARGS=("${DEFAULT_BUNDLE_ARGS[@]}")

# -----------------------------------------------------------------------------
# Settings (hep.conf)
# -----------------------------------------------------------------------------
[[ -f "${CONFIG_FILE}" ]] \
    || die "No settings file ${CONFIG_FILE}; create it with: cp ${SCRIPT_DIR}/hep.conf.example ${SCRIPT_DIR}/hep.conf"
HEP_USER=""
HEP_HOST=""
HEP_STORAGE_DIR=""
HEP_DEFAULT_WORKSPACE=""
# shellcheck source=hep.conf.example
source "${CONFIG_FILE}"
for setting in HEP_USER HEP_HOST HEP_STORAGE_DIR; do
    [[ -n "${!setting}" ]] || die "${setting} is not set in ${CONFIG_FILE}"
done
REMOTE_TARGET="${HEP_USER}@${HEP_HOST}"
REMOTE_SCRIPTS_DIR="${HEP_STORAGE_DIR}/drunc-dev-scripts"

if [[ -z "${WORKSPACE}" && ${#REFS[@]} -eq 0 && -n "${HEP_DEFAULT_WORKSPACE}" ]]; then
    # Relative to this directory, like the other paths in hep.conf
    WORKSPACE="$(cd "${SCRIPT_DIR}" && cd "${HEP_DEFAULT_WORKSPACE}" && pwd)" \
        || die "HEP_DEFAULT_WORKSPACE ${HEP_DEFAULT_WORKSPACE} not found"
    info "Using HEP_DEFAULT_WORKSPACE: ${WORKSPACE}"
fi

# -----------------------------------------------------------------------------
# -w: the release and profile of a local workspace, and each repo's HEAD
# -----------------------------------------------------------------------------
read_workspace() {
    local ws="$1" constants="$1/dbt-workarea-constants.sh"
    [[ -f "${constants}" ]] || die "${ws} is not a dbt work area (no dbt-workarea-constants.sh)"

    local release releases_dir
    release="$(sed -n 's/^export SPACK_RELEASE="\(.*\)"/\1/p' "${constants}")"
    releases_dir="$(sed -n 's/^export SPACK_RELEASES_DIR="\(.*\)"/\1/p' "${constants}")"
    RELEASE_TAG="${RELEASE_TAG:-${release}}"
    if [[ -z "${RELEASE_BASE}" ]]; then
        case "${releases_dir}" in
            */nightly)        RELEASE_BASE=nightly ;;
            */candidates)     RELEASE_BASE=candidate ;;
            */spack/releases) RELEASE_BASE=stable ;;
            *) die "Unknown release type for ${releases_dir}; pass --base" ;;
        esac
    fi
    # Workspaces are named <release>_<profile> by local-dev
    local name
    name="$(basename "${ws}")"
    if [[ -z "${PROFILE}" && "${name}" == "${release}_"* \
          && -f "${REPO_DIR}/local-dev/profiles/${name#"${release}_"}.sh" ]]; then
        PROFILE="${name#"${release}_"}"
    fi

    local repo_dir repo sha problems=0
    for repo_dir in "${ws}"/pythoncode/*/ "${ws}"/sourcecode/*/; do
        [[ -d "${repo_dir}.git" ]] || continue
        repo="$(basename "${repo_dir}")"
        [[ -n "${REFS[${repo}]:-}" ]] && continue  # -r wins
        sha="$(git -C "${repo_dir}" rev-parse HEAD)"
        if [[ -n "$(git -C "${repo_dir}" status --porcelain --untracked-files=no)" ]]; then
            error "${repo} has uncommitted changes; commit and push them first"
            problems=1
            continue
        fi
        git -C "${repo_dir}" fetch --quiet origin || warn "${repo}: git fetch failed"
        if [[ -z "$(git -C "${repo_dir}" branch -r --contains "${sha}" 2>/dev/null)" ]]; then
            error "${repo}: ${sha:0:12} ($(git -C "${repo_dir}" rev-parse --abbrev-ref HEAD)) is not pushed to origin"
            problems=1
            continue
        fi
        REFS[${repo}]="${sha}"
        info "${repo}: $(git -C "${repo_dir}" rev-parse --abbrev-ref HEAD) @ ${sha:0:12}"
    done
    [[ ${problems} -eq 0 ]] || exit 1
}

if [[ -n "${WORKSPACE}" ]]; then
    [[ -d "${WORKSPACE}" ]] || die "Workspace ${WORKSPACE} not found"
    read_workspace "$(cd "${WORKSPACE}" && pwd)"
fi

RUN_ID="$(date +%Y%m%d-%H%M%S)"
remote_args=(--storage-dir "${HEP_STORAGE_DIR}" --run-id "${RUN_ID}")
[[ -n "${RELEASE_TAG}" ]]  && remote_args+=(--release "${RELEASE_TAG}")
[[ -n "${RELEASE_BASE}" ]] && remote_args+=(--base "${RELEASE_BASE}")
[[ -n "${PROFILE}" ]]      && remote_args+=(--profile "${PROFILE}")
for repo in "${!REFS[@]}"; do
    remote_args+=(--repo "${repo}=${REFS[${repo}]}")
done
remote_args+=(-- "${BUNDLE_ARGS[@]}")

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
# BatchMode fails fast instead of hanging on a password prompt
log "Checking SSH connectivity to ${REMOTE_TARGET}..."
timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        "${REMOTE_TARGET}" exit 2>/dev/null \
    || die "Cannot reach ${REMOTE_TARGET} via SSH. Is your key loaded (ssh-add), and are you on the right network or VPN?"

log "Copying scripts to ${HEP_HOST}:${REMOTE_SCRIPTS_DIR}..."
ssh "${REMOTE_TARGET}" "mkdir -p '${REMOTE_SCRIPTS_DIR}'"
rsync -a --delete --exclude 'workspaces/' --exclude 'results/' --exclude 'hep.conf' \
    "${REPO_DIR}/local-dev" "${REPO_DIR}/hep-cluster-testing" \
    "${REMOTE_TARGET}:${REMOTE_SCRIPTS_DIR}/"

log "Run ${RUN_ID} on ${HEP_HOST}"
set +e
# shellcheck disable=SC2029  # expanded locally on purpose, quoted with %q
ssh -t "${REMOTE_TARGET}" \
    "bash ${REMOTE_SCRIPTS_DIR}/hep-cluster-testing/cluster/integtest_hep_remote.sh $(printf '%q ' "${remote_args[@]}")"
status=$?
set -e

log "Copying results to ${RESULTS_DIR}/${RUN_ID}..."
mkdir -p "${RESULTS_DIR}"
rsync -a --exclude 'sshd_host_key*' \
    "${REMOTE_TARGET}:${HEP_STORAGE_DIR}/integtest/runs/${RUN_ID}" "${RESULTS_DIR}/" \
    || warn "Could not copy the results back"

if [[ ${status} -eq 0 ]]; then
    log "All tests passed (results/${RUN_ID}/summary.txt)"
else
    error "Run ${RUN_ID} failed with exit code ${status}; see results/${RUN_ID}/console.log"
fi
exit "${status}"
