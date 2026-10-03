#!/usr/bin/env bash
# Lenovo Y700 Gen4 UEFI image build stages. Use the x86 entry point for
# cross-building on x86_64; this script remains the native ARM64 worker.
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."

stage=${1:-all}
case "$stage" in
    all|kernel|rootfs|raw|efi) ;;
    *) echo "usage: $0 [all|kernel|rootfs|raw|efi]" >&2; exit 2 ;;
esac
host_arch=$(uname -m)
if [[ $host_arch != aarch64 ]]; then
    if [[ $host_arch != x86_64 || ${ARMADA_Y700_GEN4_X86_CROSS:-0} != 1 ]]; then
        echo 'Run on aarch64, or use build-lenovo-y700-gen4-x86.sh on x86_64.' >&2
        exit 1
    fi
fi
[[ $EUID == 0 ]] || { echo 'Run with sudo; all stages share rootful container storage.' >&2; exit 1; }
for tool in just buildah podman python3 sudo git flock tee losetup blkid mount umount mountpoint gzip rsync mkfs.fat mkfs.ext4 mkfs.btrfs btrfs btrfstune fsck.fat e2fsck; do
    command -v "$tool" >/dev/null || { echo "Missing host tool: $tool" >&2; exit 1; }
done

mkdir -p output/lenovo-y700-gen4-build
exec 9>output/lenovo-y700-gen4-build/build.lock
flock -n 9 || { echo 'Another Lenovo Y700 Gen4 build is running.' >&2; exit 1; }
# nproc inside the kernel container follows this CPU affinity limit.
cpuset=$(python3 - "${JOBS:-2}" <<'PY'
import os, sys
try:
    jobs = int(sys.argv[1])
    assert jobs > 0
except (ValueError, AssertionError):
    raise SystemExit('JOBS must be a positive integer')
print(','.join(map(str, sorted(os.sched_getaffinity(0))[:jobs])))
PY
)
runtime=$(mktemp -d "$PWD/output/lenovo-y700-gen4-build/runtime.XXXXXXXX")
trap 'rm -rf "$runtime"' EXIT

kernel() {
    source packages/toolchain.env
    BUILDER_IMAGE=${BUILDER_IMAGE_OVERRIDE:-$BUILDER_IMAGE}
    source packages/mesa-x86/BASE.env
    local containerfile=${ARMADA_Y700_GEN4_KERNEL_CONTAINERFILE:-packages/Containerfile}
    local build_platform=()
    [[ $host_arch != x86_64 ]] || build_platform=(--platform linux/arm64)
    local hash
    hash=$(packages/package-hash.sh kernel)
    local cache_mounts=()
    if [[ -n ${KERNEL_CACHE_DIR:-} ]]; then
        mkdir -p "$KERNEL_CACHE_DIR"
        cache_mounts+=(--volume "$KERNEL_CACHE_DIR:/tmp/armada-kernel-build")
    fi
    buildah build "${build_platform[@]}" --cpuset-cpus "$cpuset" --layers "${cache_mounts[@]}" \
        -f "$containerfile" --target out-kernel \
        --build-arg "BUILDER_IMAGE=$BUILDER_IMAGE" \
        --build-arg "GUEST_BUILDER_IMAGE=$GUEST_BUILDER_IMAGE" \
        -t "localhost/armada/pkg/kernel:$hash" packages/
}

rootfs() {
    # FROM can use only globally declared ARGs. Prepare a build-only copy
    # without changing the shared Containerfile or the package content hashes.
    python3 - "$runtime/Containerfile" <<'PY'
from pathlib import Path
import re, sys
lines = Path('Containerfile').read_text().splitlines(keepends=True)
is_ref = lambda line: re.fullmatch(r'ARG [A-Z0-9_]+_REF\s*', line) is not None
dockerfile = (''.join(line for line in lines if is_ref(line)) +
              ''.join(line for line in lines if not is_ref(line)))
# These stages only supply files; their published images have amd64 metadata.
for pkg in ('mesa-android', 'mesa-x86'):
    var = pkg.upper().replace('-', '_') + '_REF'
    source = 'FROM ${' + var + '} AS ' + pkg
    target = 'FROM --platform=linux/amd64 ${' + var + '} AS ' + pkg
    assert source in dockerfile
    dockerfile = dockerfile.replace(source, target, 1)
Path(sys.argv[1]).write_text(dockerfile)
PY
    local dir pkg hash var ref
    for dir in packages/*/; do
        [[ -f $dir/build.sh ]] || continue
        pkg=$(basename "$dir")
        hash=$(packages/package-hash.sh "$pkg")
        var=$(printf '%s' "$pkg" | tr '[:lower:]-' '[:upper:]_')_REF
        ref="localhost/armada/pkg/$pkg:$hash"
        if [[ $pkg == gamescope && -n ${GAMESCOPE_REF:-} ]]; then
            # The 20260926 OGC 3.16.29-ogc2 Git ref was removed upstream.
            ref=$GAMESCOPE_REF
        elif ! podman image exists "$ref"; then
            [[ $pkg != kernel ]] || { echo 'Build the current kernel first.' >&2; return 1; }
            ref="${ARMADA_PKG_REGISTRY:-ghcr.io/armada-os/armada/pkg}/$pkg:$hash"
        fi
        printf '%s=%s\n' "$var" "$ref" >> "$runtime/refs"
    done
    python3 - "$runtime/Containerfile" "$runtime/refs" <<'PY'
from pathlib import Path
import re, sys
expected = set(re.findall(r'^ARG ([A-Z0-9_]+_REF)$', Path(sys.argv[1]).read_text(), re.M))
resolved = {line.split('=', 1)[0] for line in Path(sys.argv[2]).read_text().splitlines()}
if expected != resolved:
    raise SystemExit(f'Package reference mismatch: {expected ^ resolved}')
PY
    local secret_args=()
    if [[ -n ${GITHUB_TOKEN:-} ]]; then
        secret_args+=(--secret "id=GITHUB_TOKEN,env=GITHUB_TOKEN")
    fi
    podman build --network=host --cpuset-cpus "$cpuset" -f "$runtime/Containerfile" \
        --build-arg "ARMADA_VERSION=$(TZ=America/New_York date +%Y%m%d).$(git -c safe.directory="$PWD" rev-parse --short HEAD)" \
        --build-arg-file "$runtime/refs" "${secret_args[@]}" \
        --platform linux/arm64 --pull=missing --target armada-rootfs \
        --tag localhost/armada:latest .
}

raw() { just build-raw localhost/armada latest; }
efi() { ./post_process/make-lenovo-y700-gen4-uefi-image.sh output/image/disk.raw; }

stages=("$stage")
[[ $stage != all ]] || stages=(kernel rootfs raw efi)
for current in "${stages[@]}"; do
    echo "==> Lenovo Y700 Gen4 $current (CPU set: $cpuset)"
    # A failed stage stops the pipeline; retain its complete log for diagnosis.
    "$current" 2>&1 | tee "output/lenovo-y700-gen4-build/$current.log"
done
