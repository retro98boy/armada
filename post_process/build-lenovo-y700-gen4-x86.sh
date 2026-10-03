#!/usr/bin/env bash
# Build the Lenovo Y700 Gen4 ARM64 image on an x86_64 Linux host.
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo"

stage=${1:-all}
case "$stage" in
    all|kernel|gamescope|rootfs|raw|efi) ;;
    *) echo "usage: $0 [all|kernel|gamescope|rootfs|raw|efi]" >&2; exit 2 ;;
esac
[[ $(uname -m) == x86_64 ]] || { echo 'This entry point requires an x86_64 host.' >&2; exit 1; }
[[ $EUID == 0 ]] || { echo 'Run with sudo; the build uses rootful Podman and Buildah.' >&2; exit 1; }

for tool in just buildah podman python3 git flock tee losetup blkid blockdev sfdisk wipefs \
    mount umount mountpoint gzip rsync \
    mkfs.fat mkfs.ext4 mkfs.btrfs btrfs btrfstune fsck.fat e2fsck; do
    command -v "$tool" >/dev/null || { echo "Missing host tool: $tool" >&2; exit 1; }
done
[[ -x /usr/bin/qemu-aarch64-static ]] || {
    echo 'Install qemu-user-static and register the aarch64 binfmt handler before building ARM64 containers.' >&2
    exit 1
}

mkdir -p output/lenovo-y700-gen4-build
exec 8>output/lenovo-y700-gen4-build/x86-build.lock
flock -n 8 || { echo 'Another Lenovo Y700 Gen4 x86 build is running.' >&2; exit 1; }

jobs=${JOBS:-2}
cpuset=$(python3 - "$jobs" <<'PY'
import os
import sys

try:
    jobs = int(sys.argv[1])
    assert jobs > 0
except (ValueError, AssertionError):
    raise SystemExit("JOBS must be a positive integer")
print(",".join(map(str, sorted(os.sched_getaffinity(0))[:jobs])))
PY
)

source packages/toolchain.env
source packages/mesa-x86/BASE.env
base_builder=$BUILDER_IMAGE
guest_builder=$GUEST_BUILDER_IMAGE
cross_builder=localhost/armada/lenovo-y700-gen4-x86-kernel-builder:latest
bib_image=${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}
bib_cross_image=localhost/armada/tools/bootc-image-builder-x86-cross:latest
build_dir=$repo/output/lenovo-y700-gen4-build

build_cross_builder() {
    buildah build --platform linux/amd64 --layers \
        -f post_process/Containerfile.y700-gen4-x86-kernel-builder \
        --build-arg "BUILDER_IMAGE=$base_builder" \
        -t "$cross_builder" .
}

build_kernel() {
    local runtime
    build_cross_builder
    runtime=$(mktemp -d "$build_dir/kernel-containerfile.XXXXXXXX")
    python3 - "$runtime/Containerfile" <<'PY'
from pathlib import Path
import sys

source = Path("packages/Containerfile").read_text()
needle = "FROM ${BUILDER_IMAGE} AS builder-base"
replacement = "FROM --platform=linux/amd64 ${BUILDER_IMAGE} AS builder-base"
if source.count(needle) != 1:
    raise SystemExit(f"Expected one builder-base declaration, found {source.count(needle)}")
Path(sys.argv[1]).write_text(source.replace(needle, replacement, 1))
PY
    ARMADA_Y700_GEN4_X86_CROSS=1 JOBS="$jobs" \
        ARMADA_Y700_GEN4_KERNEL_CONTAINERFILE="$runtime/Containerfile" \
        BUILDER_IMAGE_OVERRIDE="$cross_builder" \
        ./post_process/build-lenovo-y700-gen4-arm64.sh kernel
    rm -rf -- "$runtime"
}

build_gamescope() {
    local hash
    hash=$(packages/package-hash.sh gamescope)
    buildah build --platform linux/arm64 --cpuset-cpus "$cpuset" --layers \
        -f packages/Containerfile --target out-gamescope \
        --build-arg "BUILDER_IMAGE=$base_builder" \
        --build-arg "GUEST_BUILDER_IMAGE=$guest_builder" \
        -t "localhost/armada/pkg/gamescope:$hash" packages/
}

build_rootfs() {
    local hash
    hash=$(packages/package-hash.sh gamescope)
    ARMADA_Y700_GEN4_X86_CROSS=1 JOBS="$jobs" \
        GAMESCOPE_REF="localhost/armada/pkg/gamescope:$hash" \
        ./post_process/build-lenovo-y700-gen4-arm64.sh rootfs
}

build_bib_cross() {
    buildah build --platform linux/amd64 --layers \
        -f post_process/Containerfile.y700-gen4-bib-x86-cross \
        --build-arg "BIB_IMAGE=$bib_image" \
        -t "$bib_cross_image" .
}

build_raw() {
    local image_id bib_base_id archive store osbuild_store
    local out new_raw
    out=$build_dir/bib-x86-$(date +%Y%m%d-%H%M%S)-$$
    new_raw=$repo/output/image/disk.raw.new

    build_bib_cross
    image_id=$(podman image inspect localhost/armada:latest --format '{{.Id}}')
    bib_base_id=$(podman image inspect "$bib_image" --format '{{.Id}}')
    archive=$build_dir/armada-rootfs-${image_id:0:16}.oci.tar
    store=$build_dir/bib-storage-${bib_base_id:0:12}-${image_id:0:12}
    osbuild_store=$build_dir/osbuild-store-${bib_base_id:0:12}
    mkdir -p "$store"
    mkdir -p "$osbuild_store"
    if [[ ! -s $archive ]]; then
        podman save --format oci-archive -o "$archive" localhost/armada:latest
    fi
    mkdir -p "$out"

    podman run --rm --privileged --pull=never --network=host --platform linux/amd64 \
        --security-opt label=type:unconfined_t --security-opt apparmor=unconfined \
        --cap-add=CAP_MKNOD \
        -v "$repo/disk_config/disk.toml:/config.toml:ro" \
        -v "$store:/var/lib/containers/storage" \
        -v "$osbuild_store:/store" \
        -v "$archive:/input/rootfs.oci.tar:ro" \
        -v "$out:/output" \
        --env "ROOTFS_IMAGE_ID=$image_id" \
        --entrypoint bash \
        "$bib_cross_image" \
        -euc 'mount --make-rshared /; \
            if [[ $(podman image inspect localhost/armada:latest --format "{{.Id}}" 2>/dev/null || true) != "$ROOTFS_IMAGE_ID" ]]; then \
                podman load -i /input/rootfs.oci.tar; \
            fi; \
            exec /usr/bin/bootc-image-builder --type raw --use-librepo=True \
                --rootfs=ext4 --target-arch arm64 localhost/armada:latest'

    [[ -s $out/image/disk.raw ]] || { echo 'BIB did not produce image/disk.raw.' >&2; return 1; }
    "$repo/post_process/convert-lenovo-y700-gen4-rootfs-btrfs.sh" "$out/image/disk.raw"
    mkdir -p output/image
    mv "$out/image/disk.raw" "$new_raw"
    mv -f "$new_raw" output/image/disk.raw
    rmdir "$out/image"
}

build_efi() {
    OUT="${OUT:-output/lenovo-y700-gen4-images}" \
        ./post_process/make-lenovo-y700-gen4-uefi-image.sh output/image/disk.raw
}

stages=("$stage")
[[ $stage != all ]] || stages=(kernel gamescope rootfs raw efi)
for current in "${stages[@]}"; do
    echo "==> Lenovo Y700 Gen4 x86_64 build: $current ($jobs jobs)"
    case "$current" in
        kernel) build_kernel 2>&1 | tee "$build_dir/x86-kernel.log" ;;
        gamescope) build_gamescope 2>&1 | tee "$build_dir/x86-gamescope.log" ;;
        rootfs) build_rootfs 2>&1 | tee "$build_dir/x86-rootfs.log" ;;
        raw) build_raw 2>&1 | tee "$build_dir/x86-raw.log" ;;
        efi) build_efi 2>&1 | tee "$build_dir/x86-efi.log" ;;
    esac
done
