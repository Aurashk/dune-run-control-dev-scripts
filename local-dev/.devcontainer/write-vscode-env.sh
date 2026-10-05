#!/bin/bash
# Snapshot a dbt work area's PATH, PYTHONPATH and LD_LIBRARY_PATH into
# <workarea>/vscode.env. The Python extension (Pylance, test discovery,
# debugger) does not source ~/.bashrc, so it reads them via python.envFile.
#
# Usage: write-vscode-env.sh [workarea]   (default: $DUNE_WORKAREA)
#
# Run on every container start, and by the workspace scripts after a build.
# Re-run it after a dbt-build that adds a package to sourcecode/, so the new
# install/<package> directory reaches PYTHONPATH.
set -eo pipefail

workarea="${1:-${DUNE_WORKAREA:-}}"
if [[ -z "${workarea}" || ! -f "${workarea}/env.sh" ]]; then
    echo "write-vscode-env: no dbt work area at '${workarea}', skipping"
    exit 0
fi

# shellcheck disable=SC2016  # $1 expands in the inner shell
# Clean environment, so the snapshot is exactly what env.sh sets up
env -i HOME="${HOME}" PATH="/usr/local/bin:/usr/bin:/bin" \
    bash -c 'cd "$1" && source ./env.sh >/dev/null 2>&1; env' _ "${workarea}" \
    | grep -E '^(PYTHONPATH|LD_LIBRARY_PATH|PATH)=' > "${workarea}/vscode.env.tmp"

if ! grep -q '^PYTHONPATH=' "${workarea}/vscode.env.tmp"; then
    rm -f "${workarea}/vscode.env.tmp"
    echo "write-vscode-env: sourcing ${workarea}/env.sh did not set PYTHONPATH" >&2
    exit 1
fi
mv "${workarea}/vscode.env.tmp" "${workarea}/vscode.env"
echo "write-vscode-env: wrote ${workarea}/vscode.env"
