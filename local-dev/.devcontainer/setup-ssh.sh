#!/bin/bash
# Passwordless root SSH to localhost, as drunc's SSH process manager tests
# expect. Mirrors the "Install SSH and run the daemon" step in
# drunc/.github/workflows/run_pytest.yml.
#
# Idempotent, and run on every container start (postStartCommand) so it also
# repairs containers created before this script existed.
set -e

# --- keys and client config --------------------------------------------------
ssh-keygen -A >/dev/null
mkdir -p /root/.ssh
chmod 700 /root/.ssh
[ -f /root/.ssh/id_rsa ] || ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa -q
grep -qxF "$(cat /root/.ssh/id_rsa.pub)" /root/.ssh/authorized_keys 2>/dev/null \
    || cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys /root/.ssh/id_rsa

if [ ! -f /root/.ssh/config ]; then
    cat > /root/.ssh/config << 'EOF'
Host localhost
    HostName 127.0.0.1
    User root
    IdentityFile /root/.ssh/id_rsa
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel error
EOF
    chmod 600 /root/.ssh/config
fi

# --- DAQ env in ~/.bashrc ----------------------------------------------------
# Skip env.sh for non-interactive SSH commands: sourcing it takes ~17s, and
# DUNE_WORKAREA reaches SSH sessions too (via /etc/environment), where bash still
# reads ~/.bashrc. Without the guard every `ssh localhost cmd` pays that cost.
# Local non-interactive shells (tasks, agents) still get the env.
# Replaces any earlier (unguarded) version of the line.
touch /root/.bashrc
sed -i '/DUNE_WORKAREA\/env.sh/d' /root/.bashrc
cat >> /root/.bashrc << 'EOF'
if [[ ( $- == *i* || -z $SSH_CONNECTION ) && -f "$DUNE_WORKAREA/env.sh" ]]; then pushd "$DUNE_WORKAREA" >/dev/null && source env.sh >/dev/null 2>&1; popd >/dev/null; fi
EOF

# --- sshd ----------------------------------------------------------------------
# No systemd in the container, so start it by hand. Clean env so it does not
# inherit the DAQ LD_LIBRARY_PATH/PATH.
if ! timeout 2 bash -c '</dev/tcp/127.0.0.1/22' 2>/dev/null; then
    rm -f /run/sshd.pid
    env -i /usr/sbin/sshd
fi

ssh -o BatchMode=yes -o ConnectTimeout=5 root@localhost true
echo "setup-ssh: passwordless ssh root@localhost OK"
