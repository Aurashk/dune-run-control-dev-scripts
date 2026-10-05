#!/bin/bash
# =============================================================================
# drunc_dev_release.sh — Create a drunc dev workspace from a specific DAQ release
# =============================================================================
# Like drunc_dev_latest_nightly.sh, but for a release you name, e.g.
#   ./drunc_dev_release.sh fddaq-v5.7.0-a9
#   ./drunc_dev_release.sh --base nightly NFD_DEV_260930_A9 --profile drunc-full
# Repos are checked out at the commits the release was built from (--no-pin to
# use their default branches). Run with --help for all options and profiles.
# =============================================================================

set -o pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

parse_args release "$@"
ensure_clean_env "$@"
create_workspace
