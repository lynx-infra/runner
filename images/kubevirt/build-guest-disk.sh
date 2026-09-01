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
grub_defaults="$script_dir/grub-serial.cfg"
images_dir="$(cd "$script_dir/.." && pwd)"
provision_inputs=(
  "$script_dir/provision-ubuntu-24.04.sh"
  "$script_dir/validate-guest-capabilities.sh"
  "$images_dir/manifests/ubuntu-24.04.env"
  "$images_dir/manifests/ubuntu-24.04-system-packages.txt"
  "$images_dir/git-core-ppa.gpg"
  "$images_dir/deadsnakes-ppa.gpg"
  "$images_dir/.env"
  "$images_dir/hook.sh"
)
if [[ ! -f "$apt_sources" ]]; then
  echo "APT mirror configuration does not exist: $apt_sources" >&2
  exit 1
fi
if [[ ! -f "$grub_defaults" ]]; then
  echo "GRUB serial configuration does not exist: $grub_defaults" >&2
  exit 1
fi
for provision_input in "${provision_inputs[@]}"; do
  if [[ ! -f "$provision_input" ]]; then
    echo "Guest provisioning input does not exist: $provision_input" >&2
    exit 1
  fi
done

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
provision_dir="$work_dir/runner-image"
mkdir -p "$provision_dir"
install -m 0755 "$script_dir/provision-ubuntu-24.04.sh" "$provision_dir/provision-ubuntu-24.04.sh"
install -m 0755 "$script_dir/validate-guest-capabilities.sh" "$provision_dir/validate-guest-capabilities.sh"
install -m 0644 "$images_dir/manifests/ubuntu-24.04.env" "$provision_dir/ubuntu-24.04.env"
install -m 0644 "$images_dir/manifests/ubuntu-24.04-system-packages.txt" "$provision_dir/ubuntu-24.04-system-packages.txt"
install -m 0644 "$images_dir/git-core-ppa.gpg" "$provision_dir/git-core-ppa.gpg"
install -m 0644 "$images_dir/deadsnakes-ppa.gpg" "$provision_dir/deadsnakes-ppa.gpg"
install -m 0644 "$images_dir/.env" "$provision_dir/runner.env"
install -m 0755 "$images_dir/hook.sh" "$provision_dir/hook.sh"

virt-customize \
  -a "$disk" \
  --copy-in "$work_dir/$archive_name:/tmp" \
  --copy-in "$provision_dir:/opt" \
  --upload "$apt_sources:/etc/apt/sources.list" \
  --upload "$grub_defaults:/etc/default/grub.d/99-arc-runner-serial.cfg" \
  --run-command 'rm -f /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources' \
  --run-command "/opt/runner-image/provision-ubuntu-24.04.sh /tmp/$archive_name" \
  --run-command 'bash -x /opt/runner-image/validate-guest-capabilities.sh' \
  --run-command "rm -f /tmp/$archive_name" \
  --run-command 'grub-install --target=i386-pc /dev/sda' \
  --run-command 'update-grub' \
  --run-command 'systemctl enable cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service' \
  --truncate '/etc/machine-id' \
  --run-command 'rm -f /var/lib/dbus/machine-id' \
  --run-command 'cloud-init clean --logs --seed || true' \
  --selinux-relabel

qemu-img convert -c -O qcow2 "$disk" "$output"
qemu-img check "$output"
echo "Created KubeVirt guest disk: $output"
