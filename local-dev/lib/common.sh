#!/bin/bash
# =============================================================================
# common.sh — Shared workspace-creation logic for the local-dev entry scripts
# =============================================================================
# Sourced by drunc_dev_latest_nightly.sh and drunc_dev_release.sh.
#
# Each run creates one self-contained workspace for one DAQ release:
#   <workspace>/                   dbt work area (env.sh, .venv, build, install)
#     sourcecode/<repo>            profile's CMake repos, built with dbt-build
#     pythoncode/<repo>            profile's Python repos, pip installed editable
#     .devcontainer/               copied from local-dev/.devcontainer
#     <workspace>.code-workspace   VS Code multi-root workspace for the repos
#     branches.sh                  bulk branch helper (templates/branches.sh)
#     vscode.env                   DAQ env snapshot read by the Python extension
#
# Do NOT execute this file directly.
# =============================================================================

LOCAL_DEV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILES_DIR="${LOCAL_DEV_DIR}/profiles"
TEMPLATES_DIR="${LOCAL_DEV_DIR}/templates"
DEVCONTAINER_DIR="${LOCAL_DEV_DIR}/.devcontainer"

DEFAULT_PROFILE="drunc-minimal"
DEFAULT_WORKSPACES_DIR="${DRUNC_WORKSPACES_DIR:-${LOCAL_DEV_DIR}/workspaces}"
GIT_BASE_URL="${DRUNC_GIT_BASE_URL:-https://github.com/DUNE-DAQ}"
DUNEDAQ_SETUP="/cvmfs/dunedaq.opensciencegrid.org/setup_dunedaq.sh"

# Mirrors the release base paths in dbt's dbt_setup_constants.py
declare -A RELEASE_BASEPATHS=(
    [stable]="/cvmfs/dunedaq.opensciencegrid.org/spack/releases"
    [nightly]="/cvmfs/dunedaq-development.opensciencegrid.org/nightly"
    [candidate]="/cvmfs/dunedaq-development.opensciencegrid.org/candidates"
)

# -----------------------------------------------------------------------------
# Colour codes and logging helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No colour

# Not "error": sourcing the dbt setup scripts defines an error() that exits.
log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARNING]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die()   { err "$1"; exit 1; }

# -----------------------------------------------------------------------------
# Profiles
#
# A profile is profiles/<name>.sh, sourced in a subshell, which sets:
#   PROFILE_DESCRIPTION  one-line summary shown by --list-profiles
#   SOURCE_REPOS         DUNE-DAQ repos cloned into sourcecode/ (dbt-build)
#   PYTHON_REPOS         DUNE-DAQ repos cloned into pythoncode/ and installed
#                        with "pip install -e"; pip extras go in brackets,
#                        e.g. "drunc[dev]"
# -----------------------------------------------------------------------------
list_profiles() {
    local profile_file
    for profile_file in "${PROFILES_DIR}"/*.sh; do
        # shellcheck source=/dev/null
        printf "  %-16s %s\n" "$(basename "${profile_file}" .sh)" \
            "$(PROFILE_DESCRIPTION=""; source "${profile_file}"; echo "${PROFILE_DESCRIPTION}")"
    done
}

load_profile() {
    local profile_file="${PROFILES_DIR}/$1.sh"
    if [[ ! -f "${profile_file}" ]]; then
        err "Unknown profile '$1'. Available profiles:"
        list_profiles >&2
        exit 1
    fi
    PROFILE_DESCRIPTION=""
    SOURCE_REPOS=()
    PYTHON_REPOS=()
    # shellcheck source=/dev/null
    source "${profile_file}"
}

# -----------------------------------------------------------------------------
# ensure_alma9 "$@"
#
# DAQ releases are built for AlmaLinux 9, and dbt picks its spack target from
# the host OS, so on anything else (e.g. Alma 10) dbt-create fails. Re-run the
# calling script in the devcontainer's Alma 9 image instead, with cvmfs, this
# repo and the workspaces directory mounted at their host paths: the work area
# contains absolute paths, so it must be created where it will be used.
#
# DRUNC_DEV_CONTAINER=auto (default) | always | never
# DRUNC_CONTAINER_RUNTIME=docker | podman (default: whichever is installed)
# -----------------------------------------------------------------------------
is_alma9() {
    [[ -f /etc/os-release ]] || return 1
    (source /etc/os-release && [[ "${ID}" == almalinux && "${VERSION_ID}" == 9* ]])
}

ensure_alma9() {
    local mode="${DRUNC_DEV_CONTAINER:-auto}"
    case "${mode}" in
        never) return 0 ;;
        auto)  is_alma9 && return 0 ;;
        always) ;;
        *) die "DRUNC_DEV_CONTAINER must be auto, always or never" ;;
    esac

    local runtime="${DRUNC_CONTAINER_RUNTIME:-}"
    if [[ -z "${runtime}" ]]; then
        runtime="$(command -v docker || command -v podman)" \
            || die "This host is not AlmaLinux 9 and neither docker nor podman is installed to run the Alma 9 image"
    fi

    local image
    image="$(sed -n 's/^ *"image": *"\([^"]*\)".*/\1/p' "${DEVCONTAINER_DIR}/devcontainer.json")"
    [[ -n "${image}" ]] || die "Could not read the image from ${DEVCONTAINER_DIR}/devcontainer.json"

    local cvmfs_repo mounts=()
    for cvmfs_repo in dunedaq.opensciencegrid.org dunedaq-development.opensciencegrid.org; do
        [[ -d "/cvmfs/${cvmfs_repo}" ]] || die "/cvmfs/${cvmfs_repo} is not mounted (see README.md, CVMFS setup)"
        mounts+=(-v "/cvmfs/${cvmfs_repo}:/cvmfs/${cvmfs_repo}:ro")
    done

    local repo_dir workspaces_dir
    repo_dir="$(readlink -f "${LOCAL_DEV_DIR}/..")"
    mkdir -p "${WORKSPACES_DIR}"
    workspaces_dir="$(readlink -f "${WORKSPACES_DIR}")"
    mounts+=(-v "${repo_dir}:${repo_dir}")
    [[ "${workspaces_dir}/" == "${repo_dir}/"* ]] || mounts+=(-v "${workspaces_dir}:${workspaces_dir}")

    local tty=()
    [[ -t 0 && -t 1 ]] && tty=(-t)

    log "Not on AlmaLinux 9: running in ${image} with $(basename "${runtime}")"
    log "(the first run pulls the image, which takes a while)"
    # --output-dir last, as the absolute path: the last one given wins
    exec "${runtime}" run --rm -i "${tty[@]}" \
        --userns=host --security-opt label=disable \
        "${mounts[@]}" \
        -e DRUNC_DEV_CONTAINER=never \
        ${DRUNC_GIT_BASE_URL:+-e "DRUNC_GIT_BASE_URL=${DRUNC_GIT_BASE_URL}"} \
        "${image}" \
        bash "$(readlink -f "$0")" "$@" --output-dir "${workspaces_dir}"
}

# -----------------------------------------------------------------------------
# ensure_clean_env "$@"
#
# dbt-create refuses to run where a work area environment is already loaded,
# which is every shell inside the devcontainer (~/.bashrc sources env.sh).
# Re-run the calling script in a minimal environment instead.
# -----------------------------------------------------------------------------
ensure_clean_env() {
    [[ -z "${DBT_WORKAREA_ENV_SCRIPT_SOURCED:-}" ]] && return 0
    [[ -n "${_DRUNC_DEV_CLEAN_ENV:-}" ]] && die "Could not get a clean environment for dbt-create"

    warn "A DAQ work area environment is loaded in this shell; re-running in a clean environment"
    exec env -i _DRUNC_DEV_CLEAN_ENV=1 \
        HOME="${HOME}" USER="${USER:-$(id -un)}" TERM="${TERM:-dumb}" \
        PATH="/usr/local/bin:/usr/bin:/bin" \
        ${SSH_AUTH_SOCK:+"SSH_AUTH_SOCK=${SSH_AUTH_SOCK}"} \
        ${DRUNC_WORKSPACES_DIR:+"DRUNC_WORKSPACES_DIR=${DRUNC_WORKSPACES_DIR}"} \
        ${DRUNC_GIT_BASE_URL:+"DRUNC_GIT_BASE_URL=${DRUNC_GIT_BASE_URL}"} \
        bash "$0" "$@"
}

# -----------------------------------------------------------------------------
# Argument parsing
#
# parse_args <nightly|release> "$@"
#
# Sets PROFILE, WORKSPACE_NAME, WORKSPACES_DIR, PIN, RELEASE_BASE, RELEASE_TAG.
# -----------------------------------------------------------------------------
usage() {
    local mode="$1"
    local script_name
    script_name="$(basename "$0")"

    if [[ "${mode}" == nightly ]]; then
        echo "Usage: ${script_name} [options]"
        echo ""
        echo "Creates a workspace from the latest fddaq nightly (last_fddaq)."
    else
        echo "Usage: ${script_name} [options] <release>"
        echo ""
        echo "Creates a workspace from a specific DAQ release, e.g. fddaq-v5.7.0-a9,"
        echo "or a specific nightly with --base nightly, e.g. NFD_DEV_260930_A9."
        echo "Repos are checked out at the commits the release was built from."
    fi
    cat << EOF

Options:
  -p, --profile NAME     Repos to clone and build (default: ${DEFAULT_PROFILE})
  -n, --name NAME        Workspace directory name (default: <release>_<profile>)
  -o, --output-dir DIR   Where to create the workspace
                         (default: \$DRUNC_WORKSPACES_DIR or local-dev/workspaces)
EOF
    if [[ "${mode}" == nightly ]]; then
        echo "      --pin              Check out the commits the nightly was built from"
        echo "                         (default: each repo's default branch)"
    else
        echo "  -b, --base TYPE        Release type: stable (default), candidate or nightly"
        echo "  -l, --list             List the available releases for --base and exit"
        echo "      --no-pin           Use each repo's default branch instead of the"
        echo "                         commits the release was built from"
    fi
    cat << EOF
      --list-profiles    List the available profiles and exit
  -h, --help             Show this help message

Profiles:
EOF
    list_profiles
}

parse_args() {
    local mode="$1"
    shift

    PROFILE="${DEFAULT_PROFILE}"
    WORKSPACE_NAME=""
    WORKSPACES_DIR="${DEFAULT_WORKSPACES_DIR}"
    RELEASE_TAG=""
    local list_releases=false

    if [[ "${mode}" == nightly ]]; then
        RELEASE_BASE="nightly"
        PIN=false
    else
        RELEASE_BASE="stable"
        PIN=true
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -p|--profile)    [[ $# -ge 2 ]] || die "$1 needs a value"; PROFILE="$2"; shift 2 ;;
            -n|--name)       [[ $# -ge 2 ]] || die "$1 needs a value"; WORKSPACE_NAME="$2"; shift 2 ;;
            -o|--output-dir) [[ $# -ge 2 ]] || die "$1 needs a value"; WORKSPACES_DIR="$2"; shift 2 ;;
            --pin)           PIN=true; shift ;;
            --no-pin)        PIN=false; shift ;;
            --list-profiles) list_profiles; exit 0 ;;
            -h|--help)       usage "${mode}"; exit 0 ;;
            -b|--base)
                [[ "${mode}" == release ]] || die "Unknown option: $1"
                [[ $# -ge 2 ]] || die "$1 needs a value"
                [[ -n "${RELEASE_BASEPATHS[$2]:-}" ]] || die "--base must be one of: ${!RELEASE_BASEPATHS[*]}"
                RELEASE_BASE="$2"
                shift 2 ;;
            -l|--list)
                [[ "${mode}" == release ]] || die "Unknown option: $1"
                list_releases=true
                shift ;;
            -*)
                err "Unknown option: $1"
                usage "${mode}" >&2
                exit 1 ;;
            *)
                [[ "${mode}" == release && -z "${RELEASE_TAG}" ]] || die "Unexpected argument: $1"
                RELEASE_TAG="$1"
                shift ;;
        esac
    done

    if [[ "${list_releases}" == true ]]; then
        log "Available ${RELEASE_BASE} releases in ${RELEASE_BASEPATHS[${RELEASE_BASE}]}:"
        ls -1 "${RELEASE_BASEPATHS[${RELEASE_BASE}]}"
        exit 0
    fi

    if [[ "${mode}" == nightly ]]; then
        RELEASE_TAG="last_fddaq"
    elif [[ -z "${RELEASE_TAG}" ]]; then
        err "A release is required (use --list to see them)"
        usage "${mode}" >&2
        exit 1
    fi

    load_profile "${PROFILE}"
}

# -----------------------------------------------------------------------------
# Workspace creation steps
# -----------------------------------------------------------------------------

# Resolve RELEASE_TAG (which may be a symlink such as last_fddaq) to a fixed
# release, so the workspace stays on one DAQ version.
resolve_release() {
    local base_path="${RELEASE_BASEPATHS[${RELEASE_BASE}]}"
    RELEASE_PATH="$(readlink -f "${base_path}/${RELEASE_TAG}")"
    if [[ ! -d "${RELEASE_PATH}" ]]; then
        die "Release '${RELEASE_TAG}' not found in ${base_path} (is cvmfs mounted? run with --list to see releases)"
    fi
    RELEASE_NAME="$(basename "${RELEASE_PATH}")"
    WORKSPACE_NAME="${WORKSPACE_NAME:-${RELEASE_NAME}_${PROFILE}}"
    mkdir -p "${WORKSPACES_DIR}"
    WORKSPACE_DIR="$(cd "${WORKSPACES_DIR}" && pwd)/${WORKSPACE_NAME}"
    [[ -e "${WORKSPACE_DIR}" ]] && die "Workspace ${WORKSPACE_DIR} already exists"
    return 0
}

# Sourced from a function called with no arguments, so the setup scripts
# don't see the calling script's arguments as their own.
setup_dbt_env() {
    log "Sourcing DUNE-DAQ environment..."
    # shellcheck source=/dev/null
    source "${DUNEDAQ_SETUP}" || die "Failed to source ${DUNEDAQ_SETUP}"
    log "Setting up DBT (latest version)..."
    setup_dbt latest || die "Failed to setup DBT"
}

source_workarea_env() {
    log "Sourcing work area environment..."
    # shellcheck source=/dev/null
    source "${WORKSPACE_DIR}/env.sh" || die "Failed to source ${WORKSPACE_DIR}/env.sh"
}

# Commit the release was built from, from the git metadata in its sourcecode/
release_commit() {
    local release_repo="${RELEASE_PATH}/sourcecode/$1"
    [[ -e "${release_repo}/.git" ]] || return 0
    git -c safe.directory='*' -C "${release_repo}" rev-parse --verify --quiet HEAD
}

# PYTHON_REPOS entry without its pip extras: "drunc[dev]" -> "drunc"
repo_name() { echo "${1%%\[*}"; }

clone_repo() {
    local name="$1" dest="$2" commit
    log "Cloning ${name} into ${dest#"${WORKSPACE_DIR}"/}..."
    git clone --quiet "${GIT_BASE_URL}/${name}.git" "${dest}" || die "Failed to clone ${name}"

    [[ "${PIN}" == true ]] || return 0
    commit="$(release_commit "${name}")"
    if [[ -z "${commit}" ]]; then
        warn "${name} is not in ${RELEASE_NAME}; leaving it on its default branch"
    elif git -C "${dest}" checkout --quiet --detach "${commit}" 2>/dev/null; then
        log "${name} pinned to ${RELEASE_NAME} commit ${commit:0:12} (detached HEAD)"
    else
        warn "${name}: ${RELEASE_NAME} commit ${commit:0:12} not found upstream; leaving it on its default branch"
    fi
}

clone_profile_repos() {
    local repo
    for repo in "${SOURCE_REPOS[@]}"; do
        clone_repo "${repo}" "${WORKSPACE_DIR}/sourcecode/${repo}"
    done
    for repo in "${PYTHON_REPOS[@]}"; do
        clone_repo "$(repo_name "${repo}")" "${WORKSPACE_DIR}/pythoncode/$(repo_name "${repo}")"
    done
}

# dbt-build's own Python step does a non-editable "pip install pythoncode/<repo>",
# so skip it and install the Python repos editable instead.
build_workspace() {
    log "Building work area (dbt-build --skip-python-install)..."
    dbt-build --skip-python-install || die "dbt-build failed"

    local repo
    for repo in "${PYTHON_REPOS[@]}"; do
        log "Installing ${repo} in editable mode..."
        pip install -e "${WORKSPACE_DIR}/pythoncode/${repo}" \
            || die "Failed to pip install ${repo}"
    done

    # dbt-build installs a CMake repo's Python code to install/<repo>/lib64/python
    # without an __init__.py. If the release venv also has the package (as it
    # does druncschema), its regular package wins over that namespace directory
    # and local changes are silently ignored. Install the working copy editable
    # so it takes precedence.
    for repo in "${SOURCE_REPOS[@]}"; do
        [[ -f "${WORKSPACE_DIR}/sourcecode/${repo}/pyproject.toml" ]] || continue
        pip show -q "${repo}" 2>/dev/null || continue
        log "Installing ${repo} in editable mode over the release venv's copy..."
        pip install --no-deps -e "${WORKSPACE_DIR}/sourcecode/${repo}" \
            || die "Failed to pip install ${repo}"
    done
}

install_pre_commit_hooks() {
    local repo_dir
    for repo_dir in "${WORKSPACE_DIR}"/sourcecode/*/ "${WORKSPACE_DIR}"/pythoncode/*/; do
        [[ -f "${repo_dir}.pre-commit-config.yaml" ]] || continue
        log "Installing pre-commit hooks for $(basename "${repo_dir}")..."
        (cd "${repo_dir}" && pre-commit install >/dev/null) \
            || warn "Failed to install pre-commit hooks for $(basename "${repo_dir}") (is pre-commit installed?)"
    done
}

# Per-repo VS Code settings for the Python repos: pytest discovery and Ruff
# formatting. Kept out of git with .git/info/exclude if the repo doesn't
# already ignore .vscode.
write_python_repo_settings() {
    local repo repo_dir
    for repo in "${PYTHON_REPOS[@]}"; do
        repo_dir="${WORKSPACE_DIR}/pythoncode/$(repo_name "${repo}")"
        mkdir -p "${repo_dir}/.vscode"
        cp "${TEMPLATES_DIR}/python-repo-settings.json" "${repo_dir}/.vscode/settings.json"
        if ! git -C "${repo_dir}" check-ignore -q .vscode/settings.json; then
            echo ".vscode/" >> "${repo_dir}/.git/info/exclude"
        fi
    done
}

write_code_workspace() {
    local file="${WORKSPACE_DIR}/${WORKSPACE_NAME}.code-workspace"
    local folders="" repo
    for repo in "${PYTHON_REPOS[@]}"; do
        folders+="    { \"name\": \"$(repo_name "${repo}")\", \"path\": \"pythoncode/$(repo_name "${repo}")\" },"$'\n'
    done
    for repo in "${SOURCE_REPOS[@]}"; do
        folders+="    { \"name\": \"${repo}\", \"path\": \"sourcecode/${repo}\" },"$'\n'
    done

    local line
    while IFS= read -r line; do
        if [[ "${line}" == "@FOLDERS@" ]]; then
            printf '%s' "${folders}"
        else
            echo "${line//@WORKSPACE_DIR@/${WORKSPACE_DIR}}"
        fi
    done < "${TEMPLATES_DIR}/workspace.code-workspace" > "${file}"
}

install_workspace_files() {
    log "Writing devcontainer, VS Code workspace and branches.sh..."
    cp -r "${DEVCONTAINER_DIR}" "${WORKSPACE_DIR}/.devcontainer"
    install -m 755 "${TEMPLATES_DIR}/branches.sh" "${WORKSPACE_DIR}/branches.sh"
    write_python_repo_settings
    write_code_workspace
    bash "${WORKSPACE_DIR}/.devcontainer/write-vscode-env.sh" "${WORKSPACE_DIR}" \
        || warn "Failed to write vscode.env; it is regenerated when the devcontainer starts"
}

# -----------------------------------------------------------------------------
# create_workspace
#
# Runs every step for the release and profile chosen by parse_args.
# -----------------------------------------------------------------------------
create_workspace() {
    resolve_release

    log "Creating workspace ${WORKSPACE_NAME}"
    log "  release: ${RELEASE_NAME} (${RELEASE_BASE})"
    log "  profile: ${PROFILE} — ${PROFILE_DESCRIPTION}"
    log "  pinned:  ${PIN}"
    log "  path:    ${WORKSPACE_DIR}"

    setup_dbt_env

    # Anything failing from here leaves a partial workspace behind
    trap 'err "Setup failed; remove the partial workspace with: rm -rf ${WORKSPACE_DIR}"' EXIT

    log "Creating dbt work area..."
    dbt-create -b "${RELEASE_BASE}" "${RELEASE_NAME}" "${WORKSPACE_DIR}" \
        || die "dbt-create failed"

    # dbt-workarea-env finds the work area from the current directory
    cd "${WORKSPACE_DIR}" || die "Failed to enter ${WORKSPACE_DIR}"
    clone_profile_repos
    source_workarea_env
    build_workspace
    install_pre_commit_hooks
    install_workspace_files

    trap - EXIT

    log "Setup completed successfully!"
    log "Workspace: ${WORKSPACE_DIR}"
    log "Open ${WORKSPACE_NAME}.code-workspace in VS Code and run"
    log "'Dev Containers: Reopen in Container', or in a shell: cd ${WORKSPACE_DIR} && source env.sh"
    log "Rebuild with 'dbt-build --skip-python-install' to keep the editable Python installs"
}
