#!/bin/bash
# =============================================================================
# run_latest_nightly_hep.sh — Pull the latest DAQ nightly build on the HEP cluster
# =============================================================================
# SSHes into the cluster and runs drunc_dev_latest_nightly_imperial_hep.sh.
# No branch argument is required — this script simply triggers the nightly pull.
#
# Usage:   ./run_latest_nightly_hep.sh
#
# Requires: SSH key-based auth to lx04.hep.ph.ic.ac.uk (no password prompts).
#           hep_test_common.sh must reside in the same directory as this script.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=hep_test_common.sh
source "${SCRIPT_DIR}/hep_test_common.sh"

REMOTE_SCRIPT="drunc_dev_latest_nightly_imperial_hep.sh"

# Accept only -h/--help — no other arguments are meaningful for a nightly pull
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Usage: $(basename "$0")"
            echo ""
            echo "  SSHes into ${REMOTE_TARGET} and runs ${REMOTE_SCRIPT}."
            echo "  No arguments required."
            exit 0
            ;;
        *)
            error "Unknown argument: $1"
            echo "Usage: $(basename "$0")"
            exit 1
            ;;
    esac
done

check_ssh_reachable

log "Opening SSH session on ${REMOTE_TARGET}..."
info "Running: ${REMOTE_SCRIPT}"

ssh -t "${REMOTE_TARGET}" bash << ENDSSH
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
rlog()  { echo -e "\${GREEN}[\$(date +'%Y-%m-%d %H:%M:%S')] [REMOTE]\${NC} \$1"; }
rerror(){ echo -e "\${RED}[\$(date +'%Y-%m-%d %H:%M:%S')] [ERROR] \${NC} \$1" >&2; }

rlog "Session started on \$(hostname -s)"

if [ ! -f "\${HOME}/${REMOTE_SCRIPT}" ]; then
    rerror "Script not found in home directory: ${REMOTE_SCRIPT}"
    exit 1
fi

rlog "Launching: ${REMOTE_SCRIPT}"
"\${HOME}/${REMOTE_SCRIPT}"

rlog "Remote session completed successfully."
ENDSSH

exit_code=$?
[[ $exit_code -ne 0 ]] && { error "Remote session exited with code ${exit_code}."; exit "$exit_code"; }
log "All done."
