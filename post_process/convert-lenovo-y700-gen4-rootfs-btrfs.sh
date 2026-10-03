#!/usr/bin/env bash
# Convert BIB's ARM64 ext4 root partition to a native 4K-sector Btrfs root.
set -euo pipefail

[[ $EUID == 0 && $# == 1 ]] || { echo "usage: sudo $0 DISK_RAW" >&2; exit 2; }
raw=$(realpath "$1")
[[ -f $raw ]] || { echo "Missing raw image: $raw" >&2; exit 1; }
for tool in losetup blkid blockdev mount umount mountpoint rsync mkfs.btrfs \
    btrfs sfdisk python3 wipefs; do
    command -v "$tool" >/dev/null || { echo "Missing host tool: $tool" >&2; exit 1; }
done

root_part_type=B921B045-1DF0-41C3-AF44-4C6F280D3FAE
work=$(mktemp -d "$(dirname "$raw")/.y700-gen4-btrfs.XXXXXXXX")
loop=
cleanup() {
    local status=$? failed=0
    for dir in top source; do
        if mountpoint -q "$work/$dir"; then umount "$work/$dir" || failed=1; fi
    done
    if ((failed == 0)) && [[ -n $loop ]]; then losetup -d "$loop" || failed=1; fi
    if ((failed == 0)); then rm -rf -- "$work"; else
        echo "Cleanup failed; retained $work" >&2
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
mkdir "$work/source" "$work/top" "$work/rootfs"

loop=$(losetup --partscan --find --show "$raw")
root_part=${loop}p3
[[ $(blkid -s TYPE -o value "$root_part") == ext4 ]] || {
    echo "Expected p3 to be ext4 before conversion." >&2
    exit 1
}
root_uuid=$(blkid -s UUID -o value "$root_part")
mount -o ro,noload "$root_part" "$work/source"
echo 'Copying ext4 root contents to temporary staging.'
rsync -aHAXS --numeric-ids "$work/source/" "$work/rootfs/"
umount "$work/source"

wipefs -a "$root_part"
mkfs.btrfs -f -s 4096 -U "$root_uuid" -L root "$root_part"
mount -t btrfs -o subvolid=5 "$root_part" "$work/top"
btrfs subvolume create "$work/top/root"
echo 'Copying root contents into the Btrfs root subvolume.'
rsync -aHAXS --numeric-ids "$work/rootfs/" "$work/top/root/"

mapfile -t root_mount_units < <(find "$work/top/root/ostree/deploy" \
    -path '*/etc/systemd/system/-.mount' -type f -print)
(( ${#root_mount_units[@]} > 0 )) || {
    echo 'BIB root mount unit was not found in the deployed system.' >&2
    exit 1
}
for unit in "${root_mount_units[@]}"; do
    sed -i 's/^Type=ext4$/Type=btrfs/' "$unit"
    grep -q '^Type=btrfs$' "$unit" || {
        echo "Could not update root filesystem type in $unit" >&2
        exit 1
    }
done

root_subvol_id=$(btrfs inspect-internal rootid "$work/top/root")
[[ $root_subvol_id =~ ^[0-9]+$ ]] || { echo 'Invalid Btrfs root subvolume id.' >&2; exit 1; }
btrfs subvolume set-default "$root_subvol_id" "$work/top"
default_subvol_id=$(btrfs subvolume get-default "$work/top" | awk '{print $2}')
[[ $default_subvol_id == "$root_subvol_id" ]] || { echo 'Default Btrfs subvolume is not root.' >&2; exit 1; }
umount "$work/top"
btrfs check --readonly "$root_part"
[[ $(blkid -s TYPE -o value "$root_part") == btrfs ]]
[[ $(blkid -s UUID -o value "$root_part") == "$root_uuid" ]]
[[ $(btrfs inspect-internal dump-super "$root_part" | awk '$1 == "sectorsize" { print $2; exit }') == 4096 ]]
losetup -d "$loop"
loop=

loop=$(losetup --partscan --find --show "$raw")
sfdisk --part-type "$loop" 3 "$root_part_type"
losetup -d "$loop"
loop=

verify_loop=$(losetup --read-only --partscan --find --show "$raw")
verify_type=$(sfdisk --json "$verify_loop" | python3 -c \
    'import json,sys; print(json.load(sys.stdin)["partitiontable"]["partitions"][2]["type"])')
verify_uuid=$(blkid -s UUID -o value "${verify_loop}p3")
losetup -d "$verify_loop"
[[ ${verify_type,,} == "${root_part_type,,}" ]]
[[ $verify_uuid == "$root_uuid" ]]
echo "Converted p3 to 4K-sector Btrfs (UUID $root_uuid, default subvolume root)."
