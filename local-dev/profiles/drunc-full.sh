# shellcheck shell=bash
# shellcheck disable=SC2034  # variables are read by lib/common.sh
# drunc-minimal plus the dbt-built packages drunc imports at runtime
# (conffwk, confmodel_dal, opmonlib, kafkaopmon, daqconf), so changes to them
# can be developed and tested together with drunc.

PROFILE_DESCRIPTION="drunc-minimal plus drunc's built dependencies (conffwk, confmodel, opmonlib, kafkaopmon, daqconf)"

# Cloned into sourcecode/ and built with dbt-build
SOURCE_REPOS=(
    druncschema
    daqsystemtest
    conffwk
    confmodel
    opmonlib
    kafkaopmon
    daqconf
)

# Cloned into pythoncode/ and installed with "pip install -e" (extras in brackets)
PYTHON_REPOS=(
    "drunc[dev]"
)
