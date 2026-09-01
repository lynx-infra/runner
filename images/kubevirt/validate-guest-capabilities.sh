#!/usr/bin/env bash
set -uo pipefail

validation_failed=0
trap 'validation_failed=1' ERR

provision_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$provision_dir/ubuntu-24.04.env"
# shellcheck disable=SC1091
source /etc/profile.d/runner-image.sh

mapfile -t system_packages < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' \
  "$provision_dir/ubuntu-24.04-system-packages.txt")
for package_name in "${system_packages[@]}"; do
  # qemu-kvm is a virtual package provided by qemu-system-x86 on Ubuntu 24.04,
  # so it has no same-named dpkg status record to query.
  if [[ "$package_name" == qemu-kvm ]]; then
    continue
  fi
  dpkg-query --show --showformat='${db:Status-Abbrev}\n' "$package_name" | grep -qx 'ii '
done

for command_name in \
  autoconf automake avdmanager bison cmake curl docker flex g++ gcc gdb git git-lfs \
  java javac jq lldb make npm node pkg-config python3 qemu-system-x86_64 sdkmanager ssh swig unzip xxd zip; do
  command -v "$command_name" >/dev/null
done

id -u runner | grep -qx "$RUNNER_USER_UID"
id -nG runner | tr ' ' '\n' | grep -qx docker
id -nG runner | tr ' ' '\n' | grep -qx sudo
runuser -u runner -- sudo -n true

python3 --version | grep -Eq "Python ${PYTHON_VERSION}([.]|$)"
docker --version | grep -Fq "$DOCKER_VERSION"
docker buildx version | grep -Fq "$BUILDX_VERSION"
docker compose version | grep -Fq "${DOCKER_COMPOSE_VERSION#v}"
dumb-init --version 2>&1 | grep -Fq "$DUMB_INIT_VERSION"
git lfs version

test -x /home/runner/bin/Runner.Listener
test -x /home/runner/run.sh
test -s /home/runner/.env
test -x /opt/runner/hook.sh
test -d /home/runner/k8s
test -x "/opt/hostedtoolcache/Python/${PYTHON_TOOLCACHE_VERSION}/x64/bin/python"
test -f "/opt/hostedtoolcache/Python/${PYTHON_TOOLCACHE_VERSION}/x64.complete"

android_home=/home/runner/Android/SDK
for android_component in \
  'platforms/android-30' \
  'platforms/android-34' \
  'build-tools/29.0.1' \
  'build-tools/34.0.0' \
  'platform-tools' \
  'cmake/3.18.1' \
  'ndk/21.1.6352462' \
  'ndk/26.3.11579264'; do
  test -d "$android_home/$android_component"
done
test -f /home/runner/.android/avd/Nexus_5_API_28.avd/config.ini

grep -Fxq "RUNNER_TOOL_CACHE=/opt/hostedtoolcache" /etc/environment
grep -Fxq "ImageOS=$IMAGE_OS" /etc/environment
grep -Fxq "RUNNER_TOOL_CACHE=/opt/hostedtoolcache" /home/runner/.env
if ((validation_failed)); then
  echo "Guest dependency and capability contract failed." >&2
  exit 1
fi
echo "Guest dependency and capability contract passed."
