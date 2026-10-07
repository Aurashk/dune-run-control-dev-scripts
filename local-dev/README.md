# drunc local development workspaces

Scripts that create a self-contained drunc development workspace for **one** DAQ
release: a dbt work area, the repos you want to work on, a devcontainer and a
VS Code workspace.

```
local-dev/
  drunc_dev_latest_nightly.sh   workspace from the latest fddaq nightly (last_fddaq)
  drunc_dev_release.sh          workspace from a release you name
  lib/common.sh                 shared logic for both scripts
  profiles/                     which repos go into a workspace
  templates/                    files copied/generated into each workspace
  .devcontainer/                devcontainer, copied into each workspace
  workspaces/                   created workspaces (git-ignored)
```

## Creating a workspace

The scripts need `/cvmfs` (see [CVMFS setup](#cvmfs-setup)) and AlmaLinux 9,
which the DAQ releases are built for. Run them straight from a terminal on any
Linux host. If the host isn't Alma 9, they re-run themselves in the
devcontainer's Alma 9 image with docker or podman. cvmfs, this repo and the
output directory are mounted at their host paths, so the workspace works
from both the host and its devcontainer.

- `DRUNC_DEV_CONTAINER=always|never` forces or disables the container
  (default `auto`).
- `DRUNC_CONTAINER_RUNTIME=podman` picks the runtime (default: docker, then
  podman).

With rootful docker, files the container creates are owned by root on the
host. Rootless podman creates them as your user.

```bash
# Latest nightly, default profile (drunc-minimal)
./drunc_dev_latest_nightly.sh

# Latest nightly with drunc's built dependencies too
./drunc_dev_latest_nightly.sh --profile drunc-full

# A stable release; repos are checked out at the commits it was built from
./drunc_dev_release.sh --list
./drunc_dev_release.sh fddaq-v5.7.0-a9

# A specific nightly
./drunc_dev_release.sh --base nightly NFD_DEV_260930_A9

# All options and profiles
./drunc_dev_release.sh --help
```

Each run creates `workspaces/<release>_<profile>/` (change it with `--name` and
`--output-dir`, or set `DRUNC_WORKSPACES_DIR`). The nightly script resolves
`last_fddaq` to the actual nightly, so a workspace never changes DAQ version.
For a new nightly, create a new workspace.

The steps are: `dbt-create`, clone the profile's repos, `dbt-build`,
`pip install -e` the Python repos, install pre-commit hooks, then write the
workspace files below.

Source repos that are also Python packages in the release venv (druncschema)
get installed editable too. dbt-build puts their Python code in `install/`
without an `__init__.py`, so the venv's own copy would win, and your local
changes would be silently ignored. If you edit a `.proto` in druncschema,
regenerate its `src/` code with druncschema's `generate_protos` script.

| File in the workspace | Purpose |
| --- | --- |
| `<name>.code-workspace` | VS Code workspace: one folder per repo plus the work area |
| `.devcontainer/` | Alma 9 container with cvmfs, mounted at the same path as on the host |
| `branches.sh` | Bulk branch operations over every repo in the workspace |
| `vscode.env` | DAQ `PATH`/`PYTHONPATH`/`LD_LIBRARY_PATH` for the Python extension |
| `pythoncode/<repo>/.vscode/settings.json` | pytest discovery and Ruff format-on-save |

### Opening it

Open `<name>.code-workspace` in VS Code and choose **Reopen in Container**
(or **Dev Containers: Open Workspace in Container...**). Every shell in the
container has the work area environment loaded. Outside the container:
`cd workspaces/<name> && source env.sh`.

The work area and its `.venv` contain absolute paths, so the devcontainer mounts
the workspace at the same path as on the host. Don't move a workspace after
creating it.

### Verifying the host-to-container hand-off

The latest-nightly flow was verified from an AlmaLinux 10 host with rootless
Podman on 2026-10-06, using
`ghcr.io/dune-daq/nightly-release-alma9:development_v5`. It ended with
`Setup completed successfully!`, all workspace entries were owned by the host
user, and both Python packages imported from their local checkouts.

To check a created workspace, run the following from its directory on the host:

```bash
workspace="$PWD"
# No output means every entry is owned by your host user.
find "$workspace" ! -uid "$(id -u)" -print

podman run --rm --entrypoint /bin/bash --userns=host --security-opt label=disable \
  -v /cvmfs/dunedaq.opensciencegrid.org:/cvmfs/dunedaq.opensciencegrid.org:ro \
  -v /cvmfs/dunedaq-development.opensciencegrid.org:/cvmfs/dunedaq-development.opensciencegrid.org:ro \
  -v "$workspace:$workspace" \
  ghcr.io/dune-daq/nightly-release-alma9:development_v5 \
  -c 'cd "$1" && source env.sh >/dev/null 2>&1 && python -c "import drunc, druncschema; print(drunc.__file__, druncschema.__file__)"' \
  bash "$workspace"
```

The import paths must be under this workspace's `pythoncode/drunc/` and
`sourcecode/druncschema/`, not the release's installed packages. The explicit
entrypoint override is required because this image's entrypoint is already
`/bin/bash`; passing another `bash` as its command would try to execute the
shell binary as a script.

### Rebuilding

Use `dbt-build --skip-python-install`. A plain `dbt-build` reinstalls the
`pythoncode/` repos non-editable, so your edits stop being picked up. To get
the editable install back, run `pip install -e pythoncode/drunc[dev]`.

If you add a package to `sourcecode/`, run `.devcontainer/write-vscode-env.sh`
after building, or restart the container, so VS Code sees its Python path.

## Profiles

A profile is a file `profiles/<name>.sh` that sets:

```bash
PROFILE_DESCRIPTION="..."   # shown by --list-profiles / --help
SOURCE_REPOS=(...)          # cloned into sourcecode/, built by dbt-build
PYTHON_REPOS=("drunc[dev]") # cloned into pythoncode/, pip install -e (extras in brackets)
```

| Profile | Repos |
| --- | --- |
| `drunc-minimal` (default) | drunc, druncschema, daqsystemtest |
| `drunc-full` | drunc-minimal + conffwk, confmodel, opmonlib, kafkaopmon, daqconf |

`drunc-full` adds the dbt-built packages drunc imports at runtime. To add a
profile, create a new file in `profiles/`; both scripts pick it up automatically.

## Branches across repos: `branches.sh`

Every workspace has a `branches.sh` that acts on all the repos under
`pythoncode/` and `sourcecode/`, or a subset given with `-r drunc,druncschema`:

```bash
./branches.sh status                                # branch and state of every repo
./branches.sh fetch                                 # fetch --prune origin everywhere
./branches.sh create aurashk/my-feature             # new branch in every repo
./branches.sh create aurashk/my-feature --from origin/develop -r drunc,druncschema
./branches.sh switch aurashk/my-feature --fallback develop
./branches.sh check                                 # check current branch names
```

`create` only accepts names of the form `<github-username>/<description>`, with
the description in lowercase kebab-case, e.g.
`aurashk/mypy-processmanager-oksparser`. `switch` checks out the branch
wherever it exists, locally or on origin. Repos that don't have it stay where
they are, unless you pass `--fallback`. It refuses to start if any repo has
uncommitted changes.

## Editor performance

The generated `.code-workspace` addresses what made the old shared `local-dev`
workspace slow:

- **No overlapping folders.** Pylance and the mypy extension start one server
  per workspace folder. The old workspace also had the whole `local-dev` tree as
  a folder, so its servers analysed every repo a second time, plus every other
  nightly's work area (about 39k files). Each workspace now holds one release,
  and the `workarea` folder excludes `pythoncode/` and `sourcecode/`.
- **Build output is excluded.** `build/`, `install/`, `.venv/` and `log/` are
  kept out of Pylance analysis, the file watcher and search.
- **C++ uses dbt's compile database.** cpptools reads
  `build/compile_commands.json` instead of parsing the workspace itself, and
  CMake Tools doesn't try to configure `sourcecode/CMakeLists.txt`.

The Claude Code extension is no longer force-installed in the devcontainer.
Install it yourself if you want it.

## CVMFS setup

The host needs only a CVMFS client and a container runtime (Docker or Podman).
Everything that builds runs inside the Alma 9 devcontainer, so the host's
Linux distribution doesn't matter.

1. Install the CVMFS client with your distribution's package manager,
   following the [CVMFS quick start](https://cvmfs.readthedocs.io/en/stable/cpt-quickstart.html).

2. Configure it for the DUNE DAQ repositories:

   ```bash
   sudo cvmfs_config setup
   sudo tee /etc/cvmfs/default.local << 'EOF'
   CVMFS_REPOSITORIES=dunedaq.opensciencegrid.org,dunedaq-development.opensciencegrid.org
   CVMFS_CLIENT_PROFILE=single
   EOF
   ```

3. Check that it works (listing a repository mounts it):

   ```bash
   cvmfs_config probe
   ls /cvmfs/dunedaq.opensciencegrid.org/
   ls /cvmfs/dunedaq-development.opensciencegrid.org/
   ```

## Notes

- You need to run `dbt-build` in order to run boot on unified shell (the
  scripts do this for you).

### Setting up on the HEP cluster

The scripts need `lib/`, `profiles/`, `templates/` and `.devcontainer/`, so copy
the whole directory:

```bash
rsync -a --exclude workspaces local-dev/ akarimi1@lx04.hep.ph.ic.ac.uk:local-dev/
```
