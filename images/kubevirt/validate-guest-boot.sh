#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 DISK.qcow2" >&2
  exit 2
fi

for command_name in qemu-img qemu-system-x86_64 timeout; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
done

disk="$(realpath "$1")"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/arc-runner-guest-boot.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
boot_log="$work_dir/serial.log"

acceleration=(-accel tcg,thread=multi -cpu max)
if [[ -r /dev/kvm && -w /dev/kvm ]]; then
  acceleration=(-enable-kvm -cpu host)
fi

set +e
timeout --signal=TERM --kill-after=10s 180s \
  qemu-system-x86_64 \
    "${acceleration[@]}" \
    -machine q35 \
    -m 2048 \
    -smp 2 \
    -display none \
    -serial stdio \
    -monitor none \
    -no-reboot \
    -snapshot \
    -nic none \
    -drive "file=$disk,format=qcow2,if=virtio" \
    >"$boot_log" 2>&1
qemu_rc=$?
set -e

if grep -Eq 'grub rescue>|error: no such partition|Kernel panic' "$boot_log"; then
  echo "Guest boot validation detected a fatal boot error:" >&2
  tail -n 120 "$boot_log" >&2
  exit 1
fi

if ! grep -Eq 'Linux version |Welcome to Ubuntu|Reached target .*Multi-User System|Ubuntu 24\.04.*ttyS0' "$boot_log"; then
  echo "Guest did not reach a recognizable Linux boot stage within 180 seconds (qemu rc=$qemu_rc):" >&2
  tail -n 120 "$boot_log" >&2
  exit 1
fi

echo "Guest disk passed the QEMU boot smoke test."
