#!/bin/bash
# =============================================================================
# drunc_dev_latest_nightly.sh — Create a drunc dev workspace from the latest nightly
# =============================================================================
# Creates a fresh, self-contained workspace (dbt work area, repos, devcontainer,
# VS Code workspace) for the current last_fddaq nightly. See README.md, or run
# with --help for the options and the available profiles.
# =============================================================================

set -o pipefail

# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

parse_args nightly "$@"
ensure_clean_env "$@"
create_workspace
