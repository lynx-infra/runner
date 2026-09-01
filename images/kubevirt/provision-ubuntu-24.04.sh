#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 RUNNER_ARCHIVE" >&2
  exit 2
fi

runner_archive="$(realpath "$1")"
provision_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
manifest="$provision_dir/ubuntu-24.04.env"
package_manifest="$provision_dir/ubuntu-24.04-system-packages.txt"

for required_file in \
  "$manifest" \
  "$package_manifest" \
  "$provision_dir/git-core-ppa.gpg" \
  "$provision_dir/deadsnakes-ppa.gpg" \
  "$provision_dir/runner.env" \
  "$provision_dir/hook.sh"; do
  if [[ ! -f "$required_file" ]]; then
    echo "Required provisioning input is missing: $required_file" >&2
    exit 1
  fi
done

# shellcheck disable=SC1090
source "$manifest"
export DEBIAN_FRONTEND=noninteractive
export TZ=Asia/Shanghai

install -d -m 0755 /etc/apt/keyrings
install -m 0644 "$provision_dir/git-core-ppa.gpg" /etc/apt/keyrings/git-core-ppa.gpg
install -m 0644 "$provision_dir/deadsnakes-ppa.gpg" /etc/apt/keyrings/deadsnakes-ppa.gpg
. /etc/os-release
cat >/etc/apt/sources.list.d/git-core-ppa.list <<EOF
deb [signed-by=/etc/apt/keyrings/git-core-ppa.gpg] https://launchpad.proxy.ustclug.org/git-core/ppa/ubuntu ${VERSION_CODENAME} main
EOF
cat >/etc/apt/sources.list.d/deadsnakes-ppa.list <<EOF
deb [signed-by=/etc/apt/keyrings/deadsnakes-ppa.gpg] https://launchpad.proxy.ustclug.org/deadsnakes/ppa/ubuntu ${VERSION_CODENAME} main
EOF

mapfile -t system_packages < <(sed '/^[[:space:]]*#/d; /^[[:space:]]*$/d' "$package_manifest")
apt-get update
apt-get install -y --no-install-recommends "${system_packages[@]}" \
  cloud-init docker.io nodejs npm libyaml-dev

# Dockerfile.ubuntu-24.04 refreshes Git LFS from packagecloud after the base
# package transaction; keep the guest on the same installation path.
curl -fsSL https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | bash
apt-get install -y --no-install-recommends git-lfs

if ! id runner >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash --uid "$RUNNER_USER_UID" runner
fi
getent group docker >/dev/null 2>&1 || groupadd docker
usermod -aG docker,sudo runner
printf '%s\n' '%sudo ALL=(ALL:ALL) NOPASSWD:ALL' >/etc/sudoers
printf '%s\n' 'Defaults env_keep += "DEBIAN_FRONTEND"' >>/etc/sudoers

curl -fL --retry 3 -o /usr/bin/dumb-init \
  "https://github.com/Yelp/dumb-init/releases/download/v${DUMB_INIT_VERSION}/dumb-init_${DUMB_INIT_VERSION}_x86_64"
chmod 0755 /usr/bin/dumb-init

work_dir="$(mktemp -d /tmp/runner-image-provision.XXXXXX)"
trap 'rm -rf "$work_dir"' EXIT
curl -fL --retry 3 -o "$work_dir/docker.tgz" \
  "https://download.docker.com/linux/static/stable/x86_64/docker-${DOCKER_VERSION}.tgz"
tar -xzf "$work_dir/docker.tgz" -C "$work_dir"
install -o root -g root -m 0755 "$work_dir"/docker/* /usr/bin/

install -d -m 0755 /usr/local/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins
curl -fL --retry 3 -o /usr/local/lib/docker/cli-plugins/docker-buildx \
  "https://github.com/docker/buildx/releases/download/v${BUILDX_VERSION}/buildx-v${BUILDX_VERSION}.linux-amd64"
chmod 0755 /usr/local/lib/docker/cli-plugins/docker-buildx
curl -fL --retry 3 -o /usr/libexec/docker/cli-plugins/docker-compose \
  "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64"
chmod 0755 /usr/libexec/docker/cli-plugins/docker-compose
ln -sfn /usr/libexec/docker/cli-plugins/docker-compose /usr/bin/docker-compose

update-alternatives --install /usr/bin/python3 python3 "/usr/bin/python${PYTHON_VERSION}" 1
update-alternatives --set python3 "/usr/bin/python${PYTHON_VERSION}"

install -d -o runner -g runner -m 0775 /opt/hostedtoolcache
python_manifest="$work_dir/python-versions-manifest.json"
curl -fL --retry 3 -o "$python_manifest" \
  https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json
python3 - "$python_manifest" "$PYTHON_TOOLCACHE_VERSION" >"$work_dir/python-asset.txt" <<'PY'
import json
import sys

manifest_path, wanted_version = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as stream:
    releases = json.load(stream)
for release in releases:
    if release.get("version") != wanted_version:
        continue
    for artifact in release.get("files", []):
        if (
            artifact.get("arch") == "x64"
            and artifact.get("platform") == "linux"
            and artifact.get("platform_version") == "24.04"
        ):
            print(artifact["download_url"])
            print(artifact["filename"])
            raise SystemExit(0)
raise SystemExit(f"Python {wanted_version} linux-24.04-x64 is not in versions-manifest.json")
PY
mapfile -t python_asset_data <"$work_dir/python-asset.txt"
python_archive="$work_dir/python-toolcache.tar.gz"
curl -fL --retry 3 -o "$python_archive" "${python_asset_data[0]}"
python_hashes="$work_dir/python-hashes.sha256"
curl -fL --retry 3 -o "$python_hashes" "${python_asset_data[0]%/*}/hashes.sha256"
python_sha256="$(awk -v filename="${python_asset_data[1]}" '$2 == filename { print $1 }' "$python_hashes")"
if [[ ! "$python_sha256" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "Python tool-cache checksum is missing for ${python_asset_data[1]}" >&2
  exit 1
fi
printf '%s  %s\n' "$python_sha256" "$python_archive" | sha256sum --check --strict
python_extract_dir="$work_dir/python-toolcache"
mkdir -p "$python_extract_dir"
tar -xzf "$python_archive" -C "$python_extract_dir"
(
  cd "$python_extract_dir"
  AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache RUNNER_TOOL_CACHE=/opt/hostedtoolcache ./setup.sh
)

android_home=/home/runner/Android/SDK
install -d -o runner -g runner "$android_home"
curl -fL --retry 3 -o "$work_dir/android-command-line-tools.zip" \
  "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_COMMAND_LINE_TOOLS_VERSION}.zip"
unzip -q "$work_dir/android-command-line-tools.zip" -d "$android_home"
chown -R runner:runner /home/runner/Android
android_path="$android_home/cmdline-tools/bin:$android_home/platform-tools:$android_home/tools/bin:$android_home/emulator"
runuser -u runner -- env HOME=/home/runner ANDROID_HOME="$android_home" PATH="$PATH:$android_path" \
  bash -c 'yes | sdkmanager --licenses --sdk_root="$ANDROID_HOME" >/dev/null'
runuser -u runner -- env HOME=/home/runner ANDROID_HOME="$android_home" PATH="$PATH:$android_path" \
  sdkmanager --sdk_root="$android_home" --install \
    'system-images;android-28;google_apis;x86' \
    'platforms;android-30' \
    'platforms;android-34' \
    'build-tools;29.0.1' \
    'build-tools;34.0.0' \
    'platform-tools' \
    'cmake;3.18.1'
IFS=';' read -r -a ndk_versions <<<"$ANDROID_NDK_LIST"
for ndk_version in "${ndk_versions[@]}"; do
  runuser -u runner -- env HOME=/home/runner ANDROID_HOME="$android_home" PATH="$PATH:$android_path" \
    sdkmanager --sdk_root="$android_home" --install "ndk;$ndk_version"
done
runuser -u runner -- env HOME=/home/runner ANDROID_HOME="$android_home" PATH="$PATH:$android_path" \
  avdmanager create avd --force --name Nexus_5_API_28 \
    --package 'system-images;android-28;google_apis;x86' --device 'Nexus 5'

android_ndk="$android_home/ndk/$ANDROID_NDK_DEFAULT"
runner_path="/usr/lib/jvm/java-11-openjdk-amd64/bin:/home/runner/.local/bin:$android_home/cmdline-tools/bin:$android_ndk/toolchains/llvm/prebuilt/linux-x86_64/share/clang:$android_ndk/toolchains/llvm/prebuilt/linux-x86_64/bin:$android_home/platform-tools:$android_home/tools/bin:$android_home/emulator:$PATH"
cat >/etc/profile.d/runner-image.sh <<EOF
export JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
export RUNNER_TOOL_CACHE=/opt/hostedtoolcache
export ANDROID_HOME=$android_home
export ANDROID_NDK=$android_ndk
export ANDROID_NDK_21=$android_ndk
export ImageOS=$IMAGE_OS
export PATH=$runner_path
EOF
chmod 0644 /etc/profile.d/runner-image.sh
cat >/etc/environment <<EOF
JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
RUNNER_TOOL_CACHE=/opt/hostedtoolcache
ANDROID_HOME=$android_home
ANDROID_NDK=$android_ndk
ANDROID_NDK_21=$android_ndk
ImageOS=$IMAGE_OS
PATH=$runner_path
EOF
ln -sfn "$android_home" "$android_home/SDK"

tar -xzf "$runner_archive" -C /home/runner
(cd /home/runner && ./bin/installdependencies.sh)
hooks_archive="$work_dir/runner-container-hooks.zip"
curl -fL --retry 3 -o "$hooks_archive" \
  "https://github.com/lynx-infra/runner-container-hooks/releases/download/v${RUNNER_HOOKS_VERSION}/actions-runner-hooks-k8s-${RUNNER_HOOKS_VERSION}.zip"
unzip -q "$hooks_archive" -d /home/runner/k8s
install -d -m 0755 /opt/runner
install -m 0755 "$provision_dir/hook.sh" /opt/runner/hook.sh
install -m 0644 "$provision_dir/runner.env" /home/runner/.env
cat >>/home/runner/.env <<EOF
JAVA_HOME=/usr/lib/jvm/java-11-openjdk-amd64
RUNNER_TOOL_CACHE=/opt/hostedtoolcache
ANDROID_HOME=$android_home
ANDROID_NDK=$android_ndk
ANDROID_NDK_21=$android_ndk
ImageOS=$IMAGE_OS
PATH=$runner_path
EOF
chown -R runner:runner /home/runner /opt/hostedtoolcache

systemctl enable docker.service cloud-init-local.service cloud-init.service cloud-config.service cloud-final.service
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
