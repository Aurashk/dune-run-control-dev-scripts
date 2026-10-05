#!/bin/bash
# Runs on every container start (devcontainer.json postStartCommand).
#   setup-ssh.sh:        ~/.bashrc DAQ env line, passwordless root ssh, sshd.
#   write-vscode-env.sh: snapshot the DAQ env for the Python extension.
set -e
here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
bash "${here}/setup-ssh.sh"
bash "${here}/write-vscode-env.sh"
