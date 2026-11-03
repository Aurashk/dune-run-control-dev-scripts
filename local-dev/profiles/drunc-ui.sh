# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are read by lib/common.sh
# drunc_ui development profile with Django configuration editor support
# Includes drunc_ui and druncschema as editable installs with dev and docs extras

PROFILE_DESCRIPTION="drunc_ui with druncschema for Django configuration editor development"

# Cloned into sourcecode/ and built with dbt-build
SOURCE_REPOS=(
    druncschema
)

# Cloned into pythoncode/ and installed with "pip install -e" (extras in brackets)
PYTHON_REPOS=(
    "drunc_ui[dev,docs]"
    druncschema
)
