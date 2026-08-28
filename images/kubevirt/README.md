# KubeVirt GitHub Actions runner guest image

This directory contains the reproducible build boundary for the Linux guest
used by the ARC VM Adapter proof of concept. The output is a KubeVirt
`containerDisk` image with the GitHub Actions runner preinstalled at
`/home/runner`.

The build deliberately takes local input files instead of downloading a
moving cloud image or runner release:

- an Ubuntu cloud image in qcow2 format;
- an `actions-runner-linux-x64-<version>.tar.gz` release archive.

Both inputs must be downloaded and checksum-verified by the publishing
workflow before this script is called. Credentials must never be embedded in
the guest disk.

## Local build

Requirements:

- `qemu-img` and `qemu-system-x86_64`
- `virt-customize`, `virt-filesystems`, and `virt-resize` from libguestfs
- Docker or another OCI builder

```bash
./build-guest-disk.sh \
  --base-image /absolute/path/ubuntu-24.04-server-cloudimg-amd64.img \
  --runner-archive /absolute/path/actions-runner-linux-x64-2.336.0.tar.gz \
  --output ./disk.qcow2

docker build \
  --file Dockerfile.containerdisk \
  --tag arc-runner-ubuntu-24.04-containerdisk:poc \
  .
```

The Adapter injects the JIT configuration through KubeVirt cloud-init. The
guest image contains no registration token and does not start a persistent
runner service by itself.

The build creates a new 40 GiB qcow2 disk and uses `virt-resize` to expand the
Noble cloud image root partition (`/dev/sda1`) and its filesystem. Merely
resizing the qcow2 container is insufficient. Before any guest-side APT
operation, it also installs the repository's
`images/sources.list.ubuntu-24.04` and removes the cloud image's default
`archive.ubuntu.com` and `security.ubuntu.com` source definitions.

Ubuntu's cloud image uses non-sequential GPT partition numbers. `virt-resize`
can renumber the root partition while rebuilding that table, so the build
reinstalls GRUB after resizing. It also enables the serial console and runs a
QEMU boot smoke test before the containerDisk is built; structural
`qemu-img check` success alone does not prove that the guest is bootable.

## GitHub Actions publication

The normal build path is `.github/workflows/publish-kubevirt-image.yml`.
Trigger it manually and provide the HTTPS cloud-image URL, its checksum URL,
and the runner version. The runner archive is downloaded directly from the
official GitHub Actions runner release over HTTPS. The cloud-image and
checksum URL inputs default to the mirrored TOS objects. The checksum file
must use standard `sha256sum` format and reference the image object's
basename. Both downloads are verified before `virt-customize` runs. The
`publish` input defaults to `false`; when enabled, the workflow pushes
`sha-<git-sha>` and prints the immutable digest reference.

Pull requests only validate the script and containerDisk layout. They do not
download either input, build a guest disk, or access registry credentials.

## Contract

- user `runner` exists with home `/home/runner`;
- runner files are installed directly in `/home/runner`;
- cloud-init and systemd are enabled;
- the image boots without a JIT configuration but does not register a runner;
- the containerDisk artifact is `/disk/disk.qcow2` and is owned by UID/GID 107.
