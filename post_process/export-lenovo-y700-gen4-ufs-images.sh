#!/usr/bin/env bash
# Export a finalized GPT image without changing its filesystems or partition table.
set -euo pipefail
[[ $EUID == 0 && $# == 2 ]] || { echo "usage: sudo $0 DISK_RAW OUTPUT_DIRECTORY" >&2; exit 2; }
raw=$(realpath "$1")
out=$(realpath -m "$2")
prefix=${IMAGE_NAME:-armada-lenovo-y700-gen4-uefi}
[[ $prefix =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Invalid IMAGE_NAME' >&2; exit 1; }
[[ -f $raw && ! -e $out ]] || { echo 'Input missing or output directory already exists.' >&2; exit 1; }
for tool in losetup blkid blockdev mount umount mountpoint rsync mkfs.fat mkfs.ext4 mkfs.btrfs btrfs btrfstune fsck.fat e2fsck python3 gzip sha256sum; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
mkdir -p "$(dirname "$out")"
stage=$(mktemp -d "${out}.tmp.XXXXXXXX")
work=$(mktemp -d)
loop=
checkloop=
cleanup() {
    local status=$? failed=0
    for dir in target source; do
        if mountpoint -q "$work/$dir"; then umount "$work/$dir" || failed=1; fi
    done
    if ((failed == 0)); then
        [[ -z $checkloop ]] || losetup -d "$checkloop" || failed=1
        [[ -z $loop ]] || losetup -d "$loop" || failed=1
    fi
    if ((failed == 0)); then
        rm -rf -- "$work"
        [[ ! -d $stage ]] || rm -rf -- "$stage"
    else
        echo "Cleanup failed; retained $work and $stage" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir "$work/source" "$work/target"
loop=$(losetup --read-only --partscan --find --show "$raw")
for spec in '1 vfat' '2 ext4' '3 btrfs'; do
    read -r part type <<< "$spec"
    [[ $(blkid -s TYPE -o value "${loop}p$part") == "$type" ]] || { echo "Unexpected p$part filesystem" >&2; exit 1; }
done
# Detach the GPT before mounting Btrfs copies with the same filesystem UUID.
for spec in '1 efi' '2 boot' '3 rootfs'; do
    read -r part name <<< "$spec"
    file="$stage/$prefix.$name.img"
    size=$(blockdev --getsize64 "${loop}p$part")
    dd if="${loop}p$part" of="$file" bs=4M conv=sparse,fsync status=progress
    [[ $(stat -c %s "$file") == "$size" ]]
    if ((size % 4096)); then
        [[ $name == rootfs ]] || { echo "p$part size is not 4096-byte aligned" >&2; exit 1; }
        # GPT uses 512-byte LBAs. Btrfs rounds its usable device size down to
        # sectorsize, so omit only the unused tail when exporting the 4K image.
        fs_bytes=$(btrfs inspect-internal dump-super "$file" | awk '$1 == "total_bytes" { print $2; exit }')
        [[ $fs_bytes =~ ^[0-9]+$ ]] && ((fs_bytes <= size && fs_bytes % 4096 == 0)) || {
            echo "Cannot determine a 4096-byte-aligned Btrfs size for p$part" >&2
            exit 1
        }
        truncate -s "$fs_bytes" "$file"
        echo "Trimmed unused Btrfs tail: $size -> $fs_bytes bytes"
    fi
    (( $(stat -c %s "$file") % 4096 == 0 )) || { echo "p$part image is not 4096-byte aligned" >&2; exit 1; }
done
losetup -d "$loop"; loop=

reblock() {
    local image=$1 type=$2 uuid label rebuilt current
    uuid=$(blkid -p -s UUID -o value "$image")
    label=$(blkid -p -s LABEL -o value "$image" || true)
    current=$(blkid -p -s BLOCK_SIZE -o value "$image")
    [[ $current != 4096 ]] || return 0
    rebuilt="$image.rebuilt"
    truncate -s "$(stat -c %s "$image")" "$rebuilt"
    case "$type" in
        vfat)
            mkfs.fat -F 32 -S 4096 -s 1 -i "${uuid//-/}" ${label:+-n "$label"} "$rebuilt"
            mount -o loop,ro "$image" "$work/source"
            mount -o loop "$rebuilt" "$work/target"
            rsync -rt --no-perms --no-owner --no-group "$work/source/" "$work/target/"
            ;;
        ext4)
            mkfs.ext4 -F -m 0 -b 4096 -U "$uuid" ${label:+-L "$label"} "$rebuilt"
            mount -o loop,ro,noload "$image" "$work/source"
            mount -o loop "$rebuilt" "$work/target"
            rsync -aHAXS --numeric-ids "$work/source/" "$work/target/"
            ;;
        btrfs)
            # Use a temporary UUID while both copies are mounted. Recreate
            # subvolumes explicitly: a plain file copy loses OSTree's layout.
            mkfs.btrfs -f -s 4096 ${label:+-L "$label"} "$rebuilt"
            mount -o loop,ro,rescue=nologreplay,subvolid=5 "$image" "$work/source"
            mount -o loop,subvolid=5 "$rebuilt" "$work/target"
            python3 - "$work/source" "$work/target" "$work/subvolumes.json" <<'PY'
import json, pathlib, subprocess, sys
source, target, manifest = map(pathlib.Path, sys.argv[1:])
def run(*args):
    return subprocess.check_output(args, text=True).strip()
volumes = []
for line in run('btrfs', 'subvolume', 'list', '-a', str(source)).splitlines():
    header, path = line.split(' path ', 1)
    path = path.removeprefix('<FS_TREE>/')
    if pathlib.PurePosixPath(path).is_absolute() or '..' in pathlib.PurePosixPath(path).parts:
        raise SystemExit('Unsafe subvolume path')
    volumes.append((int(header.split()[1]), path,
                    run('btrfs', 'property', 'get', '-ts', str(source/path), 'ro') == 'ro=true'))
default_id = int(run('btrfs', 'subvolume', 'get-default', str(source)).split()[1])
for ident, path, readonly in sorted(volumes, key=lambda v: v[1].count('/')):
    (target/path).parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['btrfs', 'subvolume', 'create', str(target/path)], check=True)
manifest.write_text(json.dumps({'volumes': volumes, 'default': default_id}))
PY
            rsync -aHAXS --numeric-ids "$work/source/" "$work/target/"
            python3 - "$work/target" "$work/subvolumes.json" <<'PY'
import json, pathlib, subprocess, sys
target = pathlib.Path(sys.argv[1]); data = json.loads(pathlib.Path(sys.argv[2]).read_text())
for ident, path, readonly in sorted(data['volumes'], key=lambda v: -v[1].count('/')):
    if ident == data['default']:
        new_id = subprocess.check_output(['btrfs', 'inspect-internal', 'rootid', str(target/path)], text=True).strip()
        subprocess.run(['btrfs', 'subvolume', 'set-default', new_id, str(target)], check=True)
    if readonly:
        subprocess.run(['btrfs', 'property', 'set', '-ts', str(target/path), 'ro', 'true'], check=True)
PY
            ;;
    esac
    sync
    umount "$work/target"
    umount "$work/source"
    if [[ $type == btrfs ]]; then btrfstune -f -U "$uuid" "$rebuilt"; fi
    [[ $(blkid -p -s BLOCK_SIZE -o value "$rebuilt") == 4096 ]]
    [[ $(blkid -p -s UUID -o value "$rebuilt") == "$uuid" ]]
    mv "$rebuilt" "$image"
}
for spec in 'efi vfat' 'boot ext4' 'rootfs btrfs'; do
    read -r name type <<< "$spec"
    file="$stage/$prefix.$name.img"
    original_uuid=$(blkid -p -s UUID -o value "$file")
    reblock "$file" "$type"
    [[ $(blkid -p -s UUID -o value "$file") == "$original_uuid" ]]
    [[ $(blkid -p -s BLOCK_SIZE -o value "$file") == 4096 ]]
    case "$type" in
        vfat) fsck.fat -n "$file"; opts=ro ;;
        ext4) e2fsck -fn "$file"; opts=ro,noload ;;
        btrfs) btrfs check --readonly "$file"; opts=ro,rescue=nologreplay,subvolid=5 ;;
    esac
    checkloop=$(losetup --sector-size 4096 --read-only --find --show "$file")
    mount -o "$opts" "$checkloop" "$work/target"
    umount "$work/target"
    losetup -d "$checkloop"; checkloop=
done
gzip -3 -c "$raw" > "$stage/$prefix.img.gz"
(cd "$stage" && sha256sum "$prefix".*img "$prefix.img.gz" > SHA256SUMS)
mv -T "$stage" "$out"
echo "Built GPT and 4096-byte EFI, boot and rootfs images in $out"
