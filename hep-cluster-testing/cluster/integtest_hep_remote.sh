#!/bin/bash
# =============================================================================
# integtest_hep_remote.sh — Run DAQ integration tests in the Alma 9 container
# =============================================================================
# Runs on the cluster, started by ../run_integtest_hep.sh, which copies this
# repo to <storage-dir>/drunc-dev-scripts first. Everything lives under
# <storage-dir> (HEP_STORAGE_DIR in hep.conf), because cluster home
# directories and /tmp are usually too small:
#
#   images/<image>.sif            the devcontainer image, pulled on first use
#   tools/<image>/                ps and jq, unpacked from their RPMs
#   apptainer/{tmp,cache}         apptainer's build space
#   workspaces/<release>_<prof>/  dbt work areas, created on first use and
#                                 reused; .integtest-baseline records each
#                                 repo's commit at creation, .integtest-built
#                                 the commits of the last successful build
#   integtest/pytest/             pytest output (--tmpdir of the bundle script)
#   integtest/runs/<run-id>/      console log, junit XML and summary per run
#
# On the host it pulls the image if needed and re-runs itself in it with
# apptainer. In the container it:
#   1. creates the work area if it doesn't exist (local-dev/drunc_dev_release.sh)
#   2. checks out the requested ref in each named repo and resets the others
#      to their baseline, so nothing carries over from an earlier run
#   3. rebuilds what changed (dbt-build, pip install -e)
#   4. starts sshd on a free port and points "ssh localhost" at it, because the
#      tests' SSH process manager would otherwise reach the host's sshd and
#      start the DAQ apps outside the container
#   5. runs daqsystemtest_integtest_bundle.sh and passes or fails on its
#      junit XML (the bundle script's own exit code doesn't reflect failures)
#
# Usage: integtest_hep_remote.sh --storage-dir DIR --run-id ID [--release TAG]
#            [--base TYPE] [--profile NAME] [--repo NAME=REF]...
#            [-- <bundle options>]
#   REF is anything git can check out after fetching origin, e.g.
#   origin/<user>/my-feature or a commit hash.
# =============================================================================

set -o pipefail

SCRIPTS_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
LOCAL_DEV_DIR="${SCRIPTS_DIR}/local-dev"

SSH_KEY="${HOME}/.ssh/id_ed25519_integtest"

declare -A RELEASE_BASEPATHS=(
    [stable]="/cvmfs/dunedaq.opensciencegrid.org/spack/releases"
    [nightly]="/cvmfs/dunedaq-development.opensciencegrid.org/nightly"
    [candidate]="/cvmfs/dunedaq-development.opensciencegrid.org/candidates"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'  # No colour

# Not "error": sourcing env.sh defines an error() that exits.
log()  { echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] [REMOTE]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1" >&2; }
die()  { err "$1"; exit 1; }

# -----------------------------------------------------------------------------
# Arguments (the same in both phases)
# -----------------------------------------------------------------------------
STORAGE_DIR=""
RUN_ID=""
RELEASE_TAG="last_fddaq"
RELEASE_BASE="nightly"
PROFILE="drunc-minimal"
REPO_REFS=()
BUNDLE_ARGS=()

ALL_ARGS=("$@")
while [[ $# -gt 0 ]]; do
    case "$1" in
        --storage-dir) [[ $# -ge 2 ]] || die "$1 needs a value"; STORAGE_DIR="$2"; shift 2 ;;
        --run-id)  [[ $# -ge 2 ]] || die "$1 needs a value"; RUN_ID="$2"; shift 2 ;;
        --release) [[ $# -ge 2 ]] || die "$1 needs a value"; RELEASE_TAG="$2"; shift 2 ;;
        --base)    [[ $# -ge 2 ]] || die "$1 needs a value"; RELEASE_BASE="$2"; shift 2 ;;
        --profile) [[ $# -ge 2 ]] || die "$1 needs a value"; PROFILE="$2"; shift 2 ;;
        --repo)
            [[ $# -ge 2 && "$2" == ?*=?* ]] || die "--repo needs NAME=REF"
            REPO_REFS+=("$2"); shift 2 ;;
        --) shift; BUNDLE_ARGS=("$@"); break ;;
        *) die "Unknown argument: $1" ;;
    esac
done
[[ -n "${STORAGE_DIR}" ]] || die "--storage-dir is required"
[[ -n "${RUN_ID}" ]] || die "--run-id is required"
[[ -n "${RELEASE_BASEPATHS[${RELEASE_BASE}]:-}" ]] || die "--base must be one of: ${!RELEASE_BASEPATHS[*]}"
WORKSPACES_DIR="${STORAGE_DIR}/workspaces"
INTEGTEST_DIR="${STORAGE_DIR}/integtest"
PYTEST_TMPDIR="${INTEGTEST_DIR}/pytest"
RUN_DIR="${INTEGTEST_DIR}/runs/${RUN_ID}"

# =============================================================================
# Host phase: image, SSH key and client config, then re-run in the container
# =============================================================================

pull_image() {
    local image
    image="$(sed -n 's/^ *"image": *"\([^"]*\)".*/\1/p' "${LOCAL_DEV_DIR}/.devcontainer/devcontainer.json")"
    [[ -n "${image}" ]] || die "Could not read the image from local-dev/.devcontainer/devcontainer.json"
    SIF="${STORAGE_DIR}/images/$(basename "${image}" | tr ':' '_').sif"
    [[ -f "${SIF}" ]] && return 0

    log "Pulling ${image} into ${SIF} (first run only, takes a few minutes)..."
    mkdir -p "${STORAGE_DIR}/images" "${STORAGE_DIR}/apptainer/tmp" "${STORAGE_DIR}/apptainer/cache"
    APPTAINER_TMPDIR="${STORAGE_DIR}/apptainer/tmp" APPTAINER_CACHEDIR="${STORAGE_DIR}/apptainer/cache" \
        apptainer pull "${SIF}.partial" "docker://${image}" || die "apptainer pull failed"
    mv "${SIF}.partial" "${SIF}"
}

# A key used only for SSH from the container to its own sshd
ensure_ssh_key() {
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    [[ -f "${SSH_KEY}" ]] || ssh-keygen -q -t ed25519 -N "" -C "integtest@$(hostname -s)" -f "${SSH_KEY}"
    touch "${HOME}/.ssh/authorized_keys"
    chmod 600 "${HOME}/.ssh/authorized_keys"
    grep -qF "$(cat "${SSH_KEY}.pub")" "${HOME}/.ssh/authorized_keys" \
        || cat "${SSH_KEY}.pub" >> "${HOME}/.ssh/authorized_keys"
}

# Apptainer shares the host's network, so the port must be free on the host
pick_free_port() {
    local port
    for _ in $(seq 50); do
        port=$(( 20000 + RANDOM % 20000 ))
        timeout 1 bash -c "</dev/tcp/127.0.0.1/${port}" 2>/dev/null || { echo "${port}"; return 0; }
    done
    die "Could not find a free port for sshd"
}

# Bound over ~/.ssh/config in the container only. The tests SSH to localhost
# or to this host's name; both must reach the container's sshd.
write_ssh_config() {
    local port="$1"
    cat > "${RUN_DIR}/ssh_config" << EOF
Host localhost 127.0.0.1 $(hostname -s) $(hostname -f 2>/dev/null)
    HostName 127.0.0.1
    Port ${port}
    User ${USER}
    IdentityFile ${SSH_KEY}
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel error
EOF
    chmod 600 "${RUN_DIR}/ssh_config"
}

# drunc starts each app with "ssh -tt". sshd hands the PTY to the "tty" group
# (gid 5), which isn't mapped in a rootless container, so the chown fails and
# sshd drops the session. Without a "tty" group sshd leaves the PTY's group
# alone. Bound over /etc/group in the container only.
write_group_file() {
    apptainer exec "${SIF}" cat /etc/group | grep -v '^tty:' > "${RUN_DIR}/group" \
        || die "Could not read /etc/group from ${SIF}"
}

enter_container() {
    command -v apptainer >/dev/null || die "apptainer is not installed on $(hostname -s)"
    [[ -d "${STORAGE_DIR}" ]] || die "${STORAGE_DIR} does not exist on $(hostname -s) (HEP_STORAGE_DIR in hep.conf)"
    mkdir -p "${RUN_DIR}" "${PYTEST_TMPDIR}" "${WORKSPACES_DIR}"

    pull_image
    ensure_ssh_key
    local port
    port="$(pick_free_port)"
    write_ssh_config "${port}"
    write_group_file
    # The bind target must exist
    [[ -f "${HOME}/.ssh/config" ]] || { touch "${HOME}/.ssh/config"; chmod 600 "${HOME}/.ssh/config"; }

    log "Entering ${SIF##*/} on $(hostname -s) (sshd port ${port})"
    exec apptainer exec --cleanenv \
        -B "/cvmfs,${STORAGE_DIR}" \
        -B "${RUN_DIR}/ssh_config:${HOME}/.ssh/config" \
        -B "${RUN_DIR}/group:/etc/group" \
        --env "INTEGTEST_IN_CONTAINER=1" \
        --env "USER=${USER}" \
        --env "INTEGTEST_SSHD_PORT=${port}" \
        --env "INTEGTEST_TOOLS_DIR=${STORAGE_DIR}/tools/$(basename "${SIF}" .sif)" \
        --env "TERM=${TERM:-dumb}" \
        "${SIF}" bash "$(readlink -f "$0")" "${ALL_ARGS[@]}"
}

# =============================================================================
# Container phase
# =============================================================================

# Work area for the release and profile, created on first use
ensure_workspace() {
    local base_path="${RELEASE_BASEPATHS[${RELEASE_BASE}]}" release_path
    release_path="$(readlink -f "${base_path}/${RELEASE_TAG}")"
    [[ -d "${release_path}" ]] || die "Release '${RELEASE_TAG}' not found in ${base_path}"
    RELEASE_NAME="$(basename "${release_path}")"
    WORKSPACE_DIR="${WORKSPACES_DIR}/${RELEASE_NAME}_${PROFILE}"

    # One run at a time per work area: runs check out and build in place
    exec 9> "${WORKSPACE_DIR}.lock"
    if ! flock -n 9; then
        log "Another run is using ${WORKSPACE_DIR##*/}; waiting for it to finish..."
        flock 9
    fi

    if [[ ! -f "${WORKSPACE_DIR}/.integtest-baseline" ]]; then
        [[ -e "${WORKSPACE_DIR}" ]] && die "${WORKSPACE_DIR} exists but was not completed; remove it and re-run"
        log "Creating work area ${WORKSPACE_DIR##*/} (first run for this release, takes a while)..."
        bash "${LOCAL_DEV_DIR}/drunc_dev_release.sh" --base "${RELEASE_BASE}" "${RELEASE_NAME}" \
            --profile "${PROFILE}" --output-dir "${WORKSPACES_DIR}" \
            || die "Work area creation failed"
        local repo_dir
        for repo_dir in "${WORKSPACE_DIR}"/pythoncode/*/ "${WORKSPACE_DIR}"/sourcecode/*/; do
            [[ -d "${repo_dir}.git" ]] || continue
            echo "$(basename "${repo_dir}")=$(git -C "${repo_dir}" rev-parse HEAD)"
        done > "${WORKSPACE_DIR}/.integtest-baseline"
    fi
    log "Work area: ${WORKSPACE_DIR}"
}

repo_dir_for() {
    local dir
    for dir in "${WORKSPACE_DIR}/pythoncode/$1" "${WORKSPACE_DIR}/sourcecode/$1"; do
        [[ -d "${dir}/.git" ]] && { echo "${dir}"; return 0; }
    done
    return 1
}

# Every repo goes to its requested ref, or back to its baseline commit.
# Sets CHANGED_SOURCE / CHANGED_PYTHON to the repos now at a different commit
# from the last successful build (.integtest-built, written by
# record_built_commits). Comparing with the checkout before this one instead
# would skip the rebuild on the run after a failed build.
checkout_repos() {
    local -A wanted=() built=()
    local entry name ref dir
    while IFS='=' read -r name ref; do
        wanted[${name}]="${ref}"
    done < "${WORKSPACE_DIR}/.integtest-baseline"
    if [[ -f "${WORKSPACE_DIR}/.integtest-built" ]]; then
        while IFS='=' read -r name ref; do
            built[${name}]="${ref}"
        done < "${WORKSPACE_DIR}/.integtest-built"
    fi
    for entry in "${REPO_REFS[@]}"; do
        name="${entry%%=*}"
        repo_dir_for "${name}" >/dev/null \
            || die "${name} is not in ${WORKSPACE_DIR##*/}; pick a --profile that includes it"
        wanted[${name}]="${entry#*=}"
    done

    CHANGED_SOURCE=()
    CHANGED_PYTHON=()
    local before after
    for name in "${!wanted[@]}"; do
        dir="$(repo_dir_for "${name}")" || { warn "${name} from the baseline is missing; skipping"; continue; }
        ref="${wanted[${name}]}"
        [[ -z "$(git -C "${dir}" status --porcelain --untracked-files=no)" ]] \
            || die "${dir} has local changes; the cluster work area must not be edited by hand"
        git -C "${dir}" fetch --quiet --prune origin || die "git fetch failed in ${name}"
        before="$(git -C "${dir}" rev-parse HEAD)"
        git -C "${dir}" -c advice.detachedHead=false checkout --quiet --detach "${ref}" \
            || die "Could not check out ${ref} in ${name} (is it pushed?)"
        after="$(git -C "${dir}" rev-parse HEAD)"
        log "${name}: ${ref} -> ${after:0:12}"
        # Work areas from before .integtest-built existed: HEAD was built
        [[ "${built[${name}]:-${before}}" == "${after}" ]] && continue
        if [[ "${dir}" == */pythoncode/* ]]; then
            CHANGED_PYTHON+=("${name}")
        else
            CHANGED_SOURCE+=("${name}")
        fi
    done
}

# Mirrors build_workspace in local-dev/lib/common.sh: dbt-build without its
# non-editable pip step, then editable installs.
rebuild() {
    local name
    if [[ ${#CHANGED_SOURCE[@]} -gt 0 ]]; then
        log "Rebuilding (${CHANGED_SOURCE[*]} changed): dbt-build --skip-python-install"
        dbt-build --skip-python-install || die "dbt-build failed"
    fi
    for name in "${CHANGED_PYTHON[@]}"; do
        log "Reinstalling ${name} (pip install -e)..."
        pip install --quiet -e "$(repo_dir_for "${name}")" || die "pip install -e ${name} failed"
    done
}

# Only after rebuild succeeds: a failed build leaves the old record, so the
# next run builds again
record_built_commits() {
    local dir
    for dir in "${WORKSPACE_DIR}"/pythoncode/*/ "${WORKSPACE_DIR}"/sourcecode/*/; do
        [[ -d "${dir}.git" ]] || continue
        echo "$(basename "${dir}")=$(git -C "${dir}" rev-parse HEAD)"
    done > "${WORKSPACE_DIR}/.integtest-built.tmp" \
        && mv "${WORKSPACE_DIR}/.integtest-built.tmp" "${WORKSPACE_DIR}/.integtest-built"
}

# The image lacks ps and jq, which drunc's CI installs as root: drunc's
# integtests run "ps -u", and the bundle script needs jq to keep the output of
# failed tests. Without root (and without a subuid range, "apptainer build
# --fakeroot" can't install packages either), download the RPMs and unpack
# them outside the image. Appended to the paths, so they shadow nothing.
ensure_tools() {
    local tools_dir="${INTEGTEST_TOOLS_DIR:?}"
    if [[ ! -x "${tools_dir}/usr/bin/ps" || ! -x "${tools_dir}/usr/bin/jq" ]]; then
        log "Unpacking procps-ng and jq into ${tools_dir} (first run only)..."
        rm -rf "${tools_dir}"
        mkdir -p "${tools_dir}/rpms"
        # Clean env: the DAQ PYTHONPATH and LD_LIBRARY_PATH can break dnf
        env -i HOME="${HOME}" PATH=/usr/bin:/bin bash -c '
            set -e -o pipefail
            dnf download -q --arch x86_64 --destdir "$1/rpms" procps-ng jq oniguruma
            for rpm in "$1"/rpms/*.rpm; do rpm2archive - < "${rpm}" | tar -xz -C "$1"; done
        ' _ "${tools_dir}" || die "Could not download and unpack the procps-ng and jq RPMs"
    fi
    export PATH="${PATH}:${tools_dir}/usr/bin"
    export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+${LD_LIBRARY_PATH}:}${tools_dir}/usr/lib64"
}

start_sshd() {
    local port="${INTEGTEST_SSHD_PORT:?}"
    ssh-keygen -q -t ed25519 -N "" -f "${RUN_DIR}/sshd_host_key"
    # Clean env so sshd doesn't pass the DAQ environment on to sessions.
    # UsePAM=no: PAM needs root; sshd warns that RHEL doesn't support it.
    env -i /usr/sbin/sshd -D -p "${port}" -o ListenAddress=127.0.0.1 \
        -h "${RUN_DIR}/sshd_host_key" -o PidFile="${RUN_DIR}/sshd.pid" -o UsePAM=no \
        -E "${RUN_DIR}/sshd.log" &
    SSHD_PID=$!
    trap 'kill ${SSHD_PID} 2>/dev/null' EXIT

    local i
    for i in $(seq 20); do
        ssh -o BatchMode=yes -o ConnectTimeout=2 localhost 'test -d /.singularity.d' 2>/dev/null && break
        [[ ${i} -eq 20 ]] && die "SSH to localhost does not reach the container's sshd (see ${RUN_DIR}/sshd.log)"
        sleep 0.5
    done
    log "ssh localhost reaches the container's sshd on port ${port}"

    # The apps are started with "ssh -tt"; fail here rather than mid-test
    if ! ssh -tt -o BatchMode=yes localhost true < /dev/null > /dev/null 2>&1; then
        tail -n 5 "${RUN_DIR}/sshd.log" >&2
        die "sshd in the container cannot allocate a PTY, which drunc needs (see ${RUN_DIR}/sshd.log)"
    fi
}

run_tests() {
    log "Running: daqsystemtest_integtest_bundle.sh --junit-xml --tmpdir ${PYTEST_TMPDIR} ${BUNDLE_ARGS[*]}"
    # The junit XML files are written to the current directory
    cd "${RUN_DIR}" || die "Failed to enter ${RUN_DIR}"
    daqsystemtest_integtest_bundle.sh --junit-xml --tmpdir "${PYTEST_TMPDIR}" "${BUNDLE_ARGS[@]}" \
        2>&1 | tee "${RUN_DIR}/console.log"
}

# Pass only if at least one junit file exists and none has failures or errors
summarise() {
    python3 - "${RUN_DIR}" << 'EOF' | tee "${RUN_DIR}/summary.txt"
import glob, sys
import xml.etree.ElementTree as ET

files = sorted(glob.glob(f"{sys.argv[1]}/*_results.xml"))
if not files:
    print("FAIL: no junit XML was written (no tests matched, or the bundle script failed early)")
    sys.exit(1)
ok = True
for path in files:
    root = ET.parse(path).getroot()
    suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
    t = sum(int(s.get("tests", 0)) for s in suites)
    f = sum(int(s.get("failures", 0)) for s in suites)
    e = sum(int(s.get("errors", 0)) for s in suites)
    k = sum(int(s.get("skipped", 0)) for s in suites)
    ok &= f == 0 and e == 0 and t > k
    print(f"{path.rsplit('/', 1)[-1]}: {t} tests, {f} failures, {e} errors, {k} skipped")
print("PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
EOF
}

in_container() {
    ensure_workspace
    cd "${WORKSPACE_DIR}" || die "Failed to enter ${WORKSPACE_DIR}"
    {
        echo "release: ${RELEASE_NAME} (${RELEASE_BASE}), profile: ${PROFILE}"
        printf 'repo: %s\n' "${REPO_REFS[@]}"
    } > "${RUN_DIR}/request.txt"

    checkout_repos
    log "Sourcing the work area environment..."
    # shellcheck source=/dev/null
    source env.sh >/dev/null 2>&1 || die "Failed to source ${WORKSPACE_DIR}/env.sh"
    rebuild
    record_built_commits
    for dir in "${WORKSPACE_DIR}"/pythoncode/*/ "${WORKSPACE_DIR}"/sourcecode/*/; do
        echo "$(basename "${dir}") $(git -C "${dir}" rev-parse HEAD)"
    done > "${RUN_DIR}/commits.txt"

    ensure_tools
    start_sshd
    run_tests
    summarise
}

if [[ -n "${INTEGTEST_IN_CONTAINER:-}" ]]; then
    in_container
else
    enter_container
fi
