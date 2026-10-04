#!/bin/bash
# Container start for the BEAT RunPod image: the minimum of RunPod's own start.sh that a pod needs to be ssh-able
# (https://github.com/runpod/containers/blob/main/container-template/start.sh: setup_ssh, export_env_vars,
# sleep infinity), without nginx or Jupyter. Runs as tini's child (Dockerfile ENTRYPOINT), so nohup'd solves whose
# ssh session has gone are still reaped.
set -euo pipefail

# 1. The container's environment, for ssh sessions.
# sshd starts sessions with a clean environment, so the image ENV (JULIA_DEPOT_PATH, JULIA_CPU_TARGET,
# OPENBLAS_NUM_THREADS, JULIA_PKG_OFFLINE, ...) and RunPod's injected variables (RUNPOD_*, NVIDIA_*) would be missing
# in `ssh pod cmd`. RunPod's script writes them to /etc/rp_environment sourced from ~/.bashrc, which Ubuntu's .bashrc
# skips for non-interactive shells. /etc/environment is read by pam_env for every ssh session, interactive or not
# (checked at build time in the Dockerfile).
#   https://help.ubuntu.com/community/EnvironmentVariables#A.2Fetc.2Fenvironment
# PUBLIC_KEY stays out (RunPod's script excludes it too). A value pam_env cannot carry (newline or double quote) is
# reported, not silently dropped.
python3 - <<'EOF'
import os, sys
skip = {"PUBLIC_KEY", "HOSTNAME", "HOME", "PWD", "SHLVL", "_", "TERM"}
lines = []
for key, value in sorted(os.environ.items()):
    if key in skip:
        continue
    if "\n" in value or '"' in value:
        print(f"start.sh: NOT exporting {key} to ssh sessions: its value has a newline or double quote", file=sys.stderr)
        continue
    lines.append(f'{key}="{value}"\n')
with open("/etc/environment", "w") as f:
    f.writelines(lines)
print(f"start.sh: {len(lines)} variables written to /etc/environment for ssh sessions")
EOF

# 2. sshd with the account's key.
# RunPod injects the account's SSH public keys as PUBLIC_KEY (https://docs.runpod.io/pods/templates/environment-variables.md,
# "Runpod-provided variables"); a pod-level PUBLIC_KEY env, as the studio pod.sh passes, takes its place.
# Host keys are made here, per pod, never baked into the image (ssh-keygen -A: every missing default type).
if [[ -n "${PUBLIC_KEY:-}" ]]; then
  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  printf '%s\n' "$PUBLIC_KEY" >> /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  ssh-keygen -A
  mkdir -p /run/sshd
  /usr/sbin/sshd
  pgrep -x sshd >/dev/null || { echo "start.sh: sshd did not stay up" >&2; exit 1; }
  echo "start.sh: sshd up; host key fingerprints:"
  for key in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$key"; done
else
  # Loud, but the container stays up: RunPod's web terminal still works for a look inside.
  echo "start.sh: ERROR: PUBLIC_KEY is empty -- sshd NOT started, the pod is not reachable over ssh." >&2
  echo "start.sh: add a key to the RunPod account or pass PUBLIC_KEY in the pod's env." >&2
fi

echo "start.sh: pod ready"
exec sleep infinity
