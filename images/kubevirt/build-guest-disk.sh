#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --base-image PATH --runner-archive PATH --output PATH" >&2
}

base_image=""
runner_archive=""
output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base-image)
      base_image="${2:-}"
      shift 2
      ;;
    --runner-archive)
      runner_archive="${2:-}"
      shift 2
      ;;
    --output)
      output="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

if [[ -z "$base_image" || -z "$runner_archive" || -z "$output" ]]; then
  usage
  exit 2
fi

for command_name in qemu-img virt-customize virt-filesystems virt-resize; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "Required command is missing: $command_name" >&2
    exit 1
  fi
done

for input_path in "$base_image" "$runner_archive"; do
  if [[ ! -f "$input_path" ]]; then
    echo "Input file does not exist: $input_path" >&2
    exit 1
  fi
done

case "$output" in
  /*) ;;
  *)
    echo "--output must be an absolute path" >&2
    exit 2
    ;;
esac

if [[ -e "$output" ]]; then
  echo "Refusing to overwrite existing output: $output" >&2
  exit 1
fi

output_dir="$(dirname "$output")"
mkdir -p "$output_dir"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/arc-runner-guest.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
apt_sources="$script_dir/../sources.list.ubuntu-24.04"
if [[ ! -f "$apt_sources" ]]; then
  echo "APT mirror configuration does not exist: $apt_sources" >&2
  exit 1
fi

disk="$work_dir/disk.qcow2"
qemu-img info --output=json "$base_image"
virt-filesystems --partitions --long --human-readable -a "$base_image"
qemu-img create -f qcow2 "$disk" 40G
virt-resize \
  --format qcow2 \
  --output-format qcow2 \
  --expand /dev/sda1 \
  "$base_image" \
  "$disk"
qemu-img check "$disk"

archive_name="$(basename "$runner_archive")"
cp "$runner_archive" "$work_dir/$archive_name"

virt-customize \
  -a "$disk" \
  --copy-in "$work_dir/$archive_name:/tmp" \
  --upload "$apt_sources:/etc/apt/sources.list" \
  --run-command 'rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources' \
  --run-command 'id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash --uid 1001 runner' \
  --run-command 'apt-get update' \
  --install 'ca-certificates,cloud-init,curl,git,jq,sudo' \
  --run-command "tar -xzf /tmp/$archive_name -C /home/runner" \
  --run-command 'cd /home/runner && ./bin/installdependencies.sh' \
  --run-command "rm -f /tmp/$archive_name" \
  --run-command 'chown -R runner:runner /home/runner' \
  --run-command 'systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service' \
  --truncate '/etc/machine-id' \
  --run-command 'rm -f /var/lib/dbus/machine-id' \
  --run-command 'cloud-init clean --logs --seed || true' \
  --selinux-relabel

qemu-img convert -c -O qcow2 "$disk" "$output"
qemu-img check "$output"
echo "Created KubeVirt guest disk: $output"
