#!/bin/bash
# =============================================================================
# hep_test_common.sh — Shared helper library for HEP cluster test launchers
# =============================================================================
# Sourced by the three launcher scripts in this directory.
# Provides SSH connectivity checking, argument parsing, and the core remote
# workflow for branch-switching and test execution on the HEP cluster.
#
# Do NOT execute this file directly.
# =============================================================================

# -----------------------------------------------------------------------------
# Colour codes for terminal output
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'  # No colour

# -----------------------------------------------------------------------------
# Cluster connection settings — update if your username or host changes
# -----------------------------------------------------------------------------
REMOTE_USER="akarimi1"
REMOTE_HOST="lx04.hep.ph.ic.ac.uk"
REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}"

# -----------------------------------------------------------------------------
# Logging helpers (prefixed [LOCAL] to distinguish from remote log messages)
# -----------------------------------------------------------------------------
log()   { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] [LOCAL]${NC} $1"; }
info()  { echo -e "${CYAN}[$(date +'%Y-%m-%d %H:%M:%S')] [INFO] ${NC} $1"; }
warn()  { echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] [WARN] ${NC} $1"; }
error() { echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR]${NC} $1" >&2; }

# -----------------------------------------------------------------------------
# parse_args <script-name> "$@"
#
# Accepts up to two positional arguments:
#   $1  drunc branch name       (required)
#   $2  druncschema branch name (optional — omit to skip switching druncschema)
#
# Sets the global variables DRUNC_BRANCH and DRUNCSCHEMA_BRANCH.
# Exits with formatted usage info on invalid input.
# -----------------------------------------------------------------------------
parse_args() {
    local script_name="$1"
    shift

    DRUNC_BRANCH=""
    DRUNCSCHEMA_BRANCH=""

    # Handle help flag before positional processing
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        echo "Usage: ${script_name} <drunc-branch> [druncschema-branch]"
        echo ""
        echo "  drunc-branch        The git branch to switch drunc to on the remote cluster"
        echo "  druncschema-branch  (Optional) The git branch to switch druncschema to"
        echo "  -h, --help          Show this help message"
        exit 0
    fi

    if [[ $# -eq 0 ]]; then
        error "drunc-branch is required"
        echo "Usage: ${script_name} <drunc-branch> [druncschema-branch]"
        exit 1
    fi

    if [[ $# -gt 2 ]]; then
        error "Too many arguments (expected 1 or 2)"
        echo "Usage: ${script_name} <drunc-branch> [druncschema-branch]"
        exit 1
    fi

    DRUNC_BRANCH="$1"
    if [[ $# -ge 2 ]]; then
        DRUNCSCHEMA_BRANCH="$2"
    fi

    log "Target drunc branch: ${DRUNC_BRANCH}"
    if [[ -n "$DRUNCSCHEMA_BRANCH" ]]; then
        log "Target druncschema branch: ${DRUNCSCHEMA_BRANCH}"
    fi
}

# -----------------------------------------------------------------------------
# check_ssh_reachable
#
# Verifies the remote cluster is reachable via key-based SSH before opening a
# full session. Uses BatchMode=yes so it fails fast rather than hanging on a
# password prompt. Exits with an actionable error message if unreachable.
# -----------------------------------------------------------------------------
check_ssh_reachable() {
    log "Checking SSH connectivity to ${REMOTE_TARGET}..."

    if ! timeout 10 ssh \
            -o BatchMode=yes \
            -o ConnectTimeout=8 \
            -o StrictHostKeyChecking=accept-new \
            "${REMOTE_TARGET}" exit 2>/dev/null; then
        error "Cannot reach ${REMOTE_TARGET} via SSH."
        error "Ensure your key is loaded (e.g. ssh-add) and you are on the correct network or VPN."
        exit 1
    fi

    log "SSH connectivity confirmed."
}

# -----------------------------------------------------------------------------
# run_remote_session <remote-test-script>
#
# Opens a single SSH session and executes the full branch-switching workflow:
#   1. Finds the most recent *-daq-nightly-workspace directory (DD-MM-YYYY).
#   2. Navigates into sourcecode/drunc within that workspace.
#   3. Runs git pull to fetch the latest remote changes.
#   4. Switches to the branch specified by DRUNC_BRANCH via git switch.
#   5. If DRUNCSCHEMA_BRANCH is set, repeats steps 2-4 for sourcecode/druncschema.
#   6. Returns to $HOME and runs the supplied <remote-test-script>.
#
# DRUNC_BRANCH, DRUNCSCHEMA_BRANCH and remote_test_script are expanded locally
# before the heredoc is transmitted. All other variables are escaped (\$var)
# for remote evaluation.
# The -t flag allocates a pseudo-TTY for colour output and Ctrl+C support.
# -----------------------------------------------------------------------------
run_remote_session() {
    local remote_test_script="$1"

    log "Opening SSH session on ${REMOTE_TARGET}..."
    if [[ -n "$DRUNCSCHEMA_BRANCH" ]]; then
        info "Switching drunc to '${DRUNC_BRANCH}', druncschema to '${DRUNCSCHEMA_BRANCH}', then running: ${remote_test_script}"
    else
        info "Switching drunc to '${DRUNC_BRANCH}', then running: ${remote_test_script}"
    fi

    ssh -t "${REMOTE_TARGET}" bash << ENDSSH
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
rlog()  { echo -e "\${GREEN}[\$(date +'%Y-%m-%d %H:%M:%S')] [REMOTE]\${NC} \$1"; }
rerror(){ echo -e "\${RED}[\$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] \${NC} \$1" >&2; }

rlog "Session started on \$(hostname -s)"

# ---- Find the latest DAQ workspace (DD-MM-YYYY-daq-nightly-workspace) ------
rlog "Searching for the latest DAQ workspace in \${HOME}..."

latest_dir=""
latest_sortable=""

for dir in \${HOME}/*-daq-nightly-workspace; do
    [ -d "\$dir" ] || continue
    base="\$(basename "\$dir")"
    date_part="\${base%%-daq-nightly-workspace}"

    # Validate DD-MM-YYYY format strictly to skip any malformed directory names
    if [[ "\$date_part" =~ ^([0-9]{2})-([0-9]{2})-([0-9]{4})$ ]]; then
        sortable="\${BASH_REMATCH[3]}\${BASH_REMATCH[2]}\${BASH_REMATCH[1]}"
        if [ -z "\$latest_sortable" ] || [ "\$sortable" -gt "\$latest_sortable" ]; then
            latest_sortable="\$sortable"
            latest_dir="\$dir"
        fi
    fi
done

if [ -z "\$latest_dir" ]; then
    rerror "No *-daq-nightly-workspace directories found in \${HOME}"
    exit 1
fi

rlog "Latest workspace: \$latest_dir"

# ---- Navigate to drunc, pull remote changes, switch to target branch -------
drunc_path="\${latest_dir}/sourcecode/drunc"

if [ ! -d "\$drunc_path" ]; then
    rerror "drunc source directory not found: \${drunc_path}"
    exit 1
fi

cd "\$drunc_path"
rlog "Working directory: \$(pwd)"

rlog "Running: git pull"
git pull

rlog "Running: git switch ${DRUNC_BRANCH}"
git switch "${DRUNC_BRANCH}"

# ---- Optionally switch druncschema to its target branch --------------------
# druncschema_branch is expanded locally; it will be empty if not supplied.
druncschema_branch="${DRUNCSCHEMA_BRANCH}"

if [ -n "\$druncschema_branch" ]; then
    druncschema_path="\${latest_dir}/sourcecode/druncschema"

    if [ ! -d "\$druncschema_path" ]; then
        rerror "druncschema source directory not found: \${druncschema_path}"
        exit 1
    fi

    cd "\$druncschema_path"
    rlog "Working directory: \$(pwd)"

    rlog "Running: git pull"
    git pull

    rlog "Running: git switch \${druncschema_branch}"
    git switch "\$druncschema_branch"
fi

# ---- Return home and launch the requested test runner ----------------------
cd "\${HOME}"
rlog "Returned to: \$(pwd)"

rlog "Launching: ${remote_test_script}"
./${remote_test_script}

rlog "Remote session completed successfully."
ENDSSH

    exit_code=$?
    [[ $exit_code -ne 0 ]] && { error "Remote session exited with code ${exit_code}."; exit "$exit_code"; }
    log "All done."
}
