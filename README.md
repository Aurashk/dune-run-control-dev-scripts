# dune-run-control-dev-scripts

Scripts for developing and testing [drunc](https://github.com/DUNE-DAQ/drunc),
the DUNE DAQ run control.

| Directory | What it does |
| --- | --- |
| [`local-dev/`](local-dev/README.md) | Creates a self-contained development workspace for one DAQ release: a dbt work area with drunc and related repos checked out, a devcontainer and a VS Code workspace. |
| [`hep-cluster-testing/`](hep-cluster-testing/README.md) | Runs the DAQ integration tests on a cluster node, in the same container image as the local devcontainer, at the commits checked out in a local workspace or on named branches. |

Typical flow: create a workspace with `local-dev/`, develop and push your
branches, then test them with `hep-cluster-testing/run_integtest_hep.sh -w <workspace>`.
