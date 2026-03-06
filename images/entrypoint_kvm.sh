#!/usr/bin/env bash
set -euo pipefail

# Check if /dev/kvm exists
if [ -e /dev/kvm ]; then
  # 1. Read the actual /dev/kvm GID
  KVM_GID=$(stat -c '%g' /dev/kvm)
  echo "[entrypoint] /dev/kvm gid = ${KVM_GID}" >&2

  # 2. If the group with this GID doesn't exist in the container, create one (name doesn't matter, e.g., kvm)
  if ! getent group "${KVM_GID}" >/dev/null 2>&1; then
    groupadd -g "${KVM_GID}" kvm || true
  fi

  # 3. Add runner to this GID regardless of the group name
  usermod -aG "${KVM_GID}" runner
else
  echo "[entrypoint] /dev/kvm not found, skipping KVM setup" >&2
fi

# 4. Execute the original script
# 关键：用 su 切到 runner，新的进程会根据 /etc/group 重新计算补充组
exec su -s /bin/bash runner -c "/home/runner/run.sh"
