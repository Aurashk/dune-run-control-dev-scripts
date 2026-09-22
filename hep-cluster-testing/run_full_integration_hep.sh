#!/bin/bash
# =============================================================================
# run_full_integration_hep.sh — Run the full integration test suite on the HEP cluster
# =============================================================================
# Switches drunc (and optionally druncschema) to the specified branch(es) in
# the latest DAQ workspace, then runs
# drunc_dev_run_full_integration_tests_hep.sh on the remote cluster.
#
# Usage:   ./run_full_integration_hep.sh <drunc-branch> [druncschema-branch]
# Example: ./run_full_integration_hep.sh aurashk/improve-process-exit-tracking
#          ./run_full_integration_hep.sh aurashk/improve-process-exit-tracking aurashk/schema-changes
#
# Requires: SSH key-based auth to lx04.hep.ph.ic.ac.uk (no password prompts).
#           hep_test_common.sh must reside in the same directory as this script.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=hep_test_common.sh
source "${SCRIPT_DIR}/hep_test_common.sh"

REMOTE_TEST_SCRIPT="drunc_dev_run_full_integration_tests_hep.sh"

parse_args "$(basename "$0")" "$@"
check_ssh_reachable
run_remote_session "${REMOTE_TEST_SCRIPT}"
