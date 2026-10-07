# Integration tests on a cluster

`run_integtest_hep.sh` runs the DAQ integration tests (by default the minimal
system quick test) on a cluster login node, inside the same Alma 9 image as the
local-dev devcontainer, at commits you choose: the ones checked out in a local
workspace, or named branches.

```
hep-cluster-testing/
  run_integtest_hep.sh           run from your machine
  cluster/integtest_hep_remote.sh   runs on the cluster (started for you)
  hep.conf.example               settings template
  hep.conf                       your settings (git-ignored)
  results/<run-id>/              console log, junit XML, summary (git-ignored)
```

## Setup

The cluster node needs apptainer, `/cvmfs` with the DUNE DAQ repositories,
outbound access to GitHub and ghcr.io, and a large directory you own. You need
key-based SSH to it, and rsync on both ends.

```bash
cp hep.conf.example hep.conf
$EDITOR hep.conf    # HEP_USER, HEP_HOST, HEP_STORAGE_DIR
```

## Running

```bash
# Every repo at the commit checked out in a local workspace, on its release and profile
./run_integtest_hep.sh -w ../local-dev/workspaces/<release>_<profile>

# Named branches, on the latest nightly; other repos at the release's commits
./run_integtest_hep.sh -r drunc=<user>/my-feature -r druncschema=<user>/my-feature

# Other tests: everything after -- goes to daqsystemtest_integtest_bundle.sh
./run_integtest_hep.sh -w <workspace> -- --stop-on-failure -s core
./run_integtest_hep.sh -w <workspace> -- --stop-on-failure --pytest-options "--tb=long" -k minimal_system_quick_test

./run_integtest_hep.sh --help
```

Commits must be pushed, since the cluster fetches them from GitHub. With `-w`
the script stops if a repo has uncommitted changes or unpushed commits. Set
`HEP_DEFAULT_WORKSPACE` in `hep.conf` to test a workspace when you give no
`-w` or `-r`.

The cluster builds with 8 parallel jobs by default (`HEP_BUILD_JOBS` in
`hep.conf`). Login nodes cap memory per user, and one compile per CPU gets the
compiler OOM-killed (`g++: fatal error: Killed signal terminated program
cc1plus`).

The exit code is 0 only if every test passed. It comes from the junit XML,
because `daqsystemtest_integtest_bundle.sh` exits 0 even when tests fail.

## What happens on the cluster

Everything lives under `HEP_STORAGE_DIR`:

| Path | Contents |
| --- | --- |
| `drunc-dev-scripts/` | this repo's scripts, copied on every run |
| `images/` | the devcontainer image |
| `tools/` | `ps` and `jq`, which the image lacks, unpacked from their RPMs |
| `workspaces/<release>_<profile>/` | dbt work areas, created on first use and reused |
| `integtest/pytest/` | pytest output (`--tmpdir`) |
| `integtest/runs/<run-id>/` | per-run logs, copied back to `results/` |

The first run pulls the image and builds the work area, which takes a while.
After that, a run checks out the requested commits, resets every other repo to
the commit it had when the work area was created, and rebuilds only what
changed. Runs on the same work area wait for each other.

The tests start the DAQ apps over `ssh localhost`. apptainer shares the host's
network, so that would reach the host's sshd and start the apps outside the
container. The script instead starts sshd inside the container on a free port
(as you, not root) and, in the container only, replaces `~/.ssh/config` with
one that sends `localhost` and the node's own name there. It also removes the
`tty` group from the container's `/etc/group`: drunc starts apps with
`ssh -tt`, and a rootless sshd cannot hand a PTY to a group that isn't mapped
into the container.

## Troubleshooting

- **`ps` or `jq` not found:** delete `tools/`; the next run downloads and
  unpacks them again. drunc's own integtests need `ps`, and the bundle script
  needs `jq` to keep the output of failed tests.
- **A work area is broken or half-created:** delete
  `workspaces/<release>_<profile>` and its `.lock` file; the next run recreates it.
- **SSH or PTY errors:** see `results/<run-id>/sshd.log`.
