# dune-run-control-dev-scripts

Scripts for developing and testing [drunc](https://github.com/DUNE-DAQ/drunc),
the DUNE DAQ run control.

| Directory | What it does |
| --- | --- |
| [`local-dev/`](local-dev/README.md) | Creates a self-contained development workspace for one DAQ release: a dbt work area with drunc and related repos checked out, a devcontainer and a VS Code workspace. |
| [`cluster-testing/`](cluster-testing/README.md) | Runs the DAQ integration tests on a cluster node, in the same container image as the local devcontainer, at the commits checked out in a local workspace or on named branches. Only tested on `lx04.hep.ph.ic.ac.uk`. |

## Quick start

The simple use case: make a workspace, change drunc on a branch, then test it
on the cluster.

```bash
# 1. Create a workspace from the latest nightly (drunc-full: drunc, druncschema, daqsystemtest,
#    conffwk, confmodel, opmonlib, kafkaopmon, daqconf).
#    Takes a while: it runs dbt-create and dbt-build. Needs /cvmfs and docker or podman.
cd local-dev
./drunc_dev_latest_nightly.sh --profile drunc-full -j 2   # -j limits build jobs to avoid OOM
#    -> local-dev/workspaces/<release>_drunc-full/

# 2. Open <release>_drunc-full.code-workspace in VS Code and choose
#    "Reopen in Container". Or use it from a plain shell:
cd workspaces/<release>_drunc-full
source env.sh                          # load the DAQ work area environment

# 3. Create a feature branch in every repo (name must be <github-user>/<kebab-case>)
./branches.sh create aurashk/my-feature

# 4. Edit pythoncode/drunc/..., then run its tests (installed editable, so edits are live)
cd pythoncode/drunc && pytest
git add -A && git commit -m "Describe the change" && git push -u origin HEAD
cd ../..

# 5. One-off setup for cluster testing: set CLUSTER_USER, CLUSTER_HOST, CLUSTER_STORAGE_DIR
cd ../../../cluster-testing
cp cluster.conf.example cluster.conf && $EDITOR cluster.conf

# 6. Run the integration tests on the cluster at the commits checked out in the workspace
#    (refuses if anything is uncommitted or unpushed). Exit code 0 means all tests passed.
./run_integtest_cluster.sh -w ../local-dev/workspaces/<release>_drunc-full

# Results (console log, junit XML, summary) are in cluster-testing/results/<run-id>/
```
