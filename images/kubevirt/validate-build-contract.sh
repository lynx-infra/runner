#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
images_dir="$(cd "$script_dir/.." && pwd)"
repository_dir="$(cd "$images_dir/.." && pwd)"
manifest="$images_dir/manifests/ubuntu-24.04.env"
dockerfile="$images_dir/Dockerfile.ubuntu-24.04"

# shellcheck disable=SC1090
source "$manifest"

assert_docker_arg() {
  local name="$1"
  local expected="$2"
  local actual
  actual="$(sed -n "s/^ARG ${name}=//p" "$dockerfile")"
  actual="${actual#\"}"
  actual="${actual%\"}"
  [[ "$actual" == "$expected" ]]
}

assert_docker_arg PYTHON_VERSION "$PYTHON_VERSION"
assert_docker_arg DUMB_INIT_VERSION "$DUMB_INIT_VERSION"
assert_docker_arg DOCKER_VERSION "$DOCKER_VERSION"
assert_docker_arg DOCKER_COMPOSE_VERSION "$DOCKER_COMPOSE_VERSION"
assert_docker_arg BUILDX_VERSION "$BUILDX_VERSION"
assert_docker_arg ANDROID_NDK_LIST "$ANDROID_NDK_LIST"
assert_docker_arg ANDROID_NDK_DEFAULT "$ANDROID_NDK_DEFAULT"
assert_docker_arg CMD_LINE_VERSION "$ANDROID_COMMAND_LINE_TOOLS_VERSION"
assert_docker_arg RUNNER_USER_UID "$RUNNER_USER_UID"

test "$(sort "$images_dir/manifests/ubuntu-24.04-system-packages.txt" | uniq -d | wc -l)" -eq 0
grep -Fq 'manifests/ubuntu-24.04-system-packages.txt' "$dockerfile"
grep -Fq "ENV ImageOS=$IMAGE_OS" "$dockerfile"
grep -Fq "runner-container-hooks/releases/download/v${RUNNER_HOOKS_VERSION}/" "$dockerfile"
grep -Fq "PYTHON_TOOLCACHE_VERSION: '${PYTHON_TOOLCACHE_VERSION}'" \
  "$repository_dir/.github/workflows/publish-linux-image.yml"
echo "Ubuntu 24.04 container/guest build contract passed."
