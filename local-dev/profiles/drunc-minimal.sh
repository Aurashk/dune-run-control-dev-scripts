# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are read by lib/common.sh
# drunc plus the repos needed to develop and integration-test it.

PROFILE_DESCRIPTION="drunc, druncschema and daqsystemtest"

# Cloned into sourcecode/ and built with dbt-build
SOURCE_REPOS=(
    druncschema
    daqsystemtest
)

# Cloned into pythoncode/ and installed with "pip install -e" (extras in brackets)
PYTHON_REPOS=(
    "drunc[dev]"
)
