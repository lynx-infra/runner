#!/usr/bin/env bash
set -euo pipefail

# 1. Read the actual /dev/kvm GID
KVM_GID=$(stat -c '%g' /dev/kvm)
echo "[entrypoint] /dev/kvm gid = ${KVM_GID}" >&2

# 2. If the group with this GID doesn't exist in the container, create one (name doesn't matter, e.g., kvm)
if ! getent group "${KVM_GID}" >/dev/null 2>&1; then
  groupadd -g "${KVM_GID}" kvm || true
fi

# 3. Add runner to this GID regardless of the group name
usermod -aG "${KVM_GID}" runner

# 4. Switch to runner user and execute the original script
exec su -s /bin/bash runner -c "/home/runner/run.sh"
