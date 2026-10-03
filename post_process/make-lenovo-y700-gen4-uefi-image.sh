#!/usr/bin/env bash
# Keep bootc-image-builder's GPT/ESP and install a UUID-pinned ARM64 GRUB EFI.
set -euo pipefail

raw=${1:-output/image/disk.raw}
out=${OUT:-output/lenovo-y700-gen4-images}
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ ! -e $out ]] || { echo "Output already exists: $out" >&2; exit 1; }
[[ -f $raw ]] || { echo "missing raw image: $raw" >&2; exit 1; }
work=$(mktemp -d)
loop=
cleanup() {
    local failed=0
    if mountpoint -q "$work/boot"; then sudo umount "$work/boot" || failed=1; fi
    if mountpoint -q "$work/esp"; then sudo umount "$work/esp" || failed=1; fi
    if ((failed == 0)) && [[ -n $loop ]]; then sudo losetup -d "$loop" || failed=1; fi
    if ((failed == 0)); then sudo rm -rf -- "$work"; fi
    return "$failed"
}
trap cleanup EXIT
mkdir -p "$work/boot" "$work/esp"
loop=$(sudo losetup -fP --show "$raw")
[[ $(sudo blkid -s TYPE -o value "${loop}p1") == vfat ]] || { echo 'p1 is not an ESP' >&2; exit 1; }
sudo mount "${loop}p1" "$work/esp"
sudo mount "${loop}p2" "$work/boot"
boot_uuid=$(sudo blkid -s UUID -o value "${loop}p2")
[[ $boot_uuid =~ ^[0-9a-fA-F-]+$ ]] || { echo 'invalid /boot UUID' >&2; exit 1; }
[[ -d $work/esp/EFI ]] || { echo 'bootc-image-builder did not create EFI files' >&2; exit 1; }

sudo touch "$work/esp/.armada-lenovo-y700-gen4-uefi"
sudo env BOOTROOT="$work/boot" ESP="$work/esp" BOOT_UUID="$boot_uuid" \
    "$repo/system_files/usr/libexec/armada/armada-uefi-grub-sync"

# This configuration is embedded in BOOTAA64.EFI; GRUB does not depend on
# disk enumeration or an ESP path to locate its mutable menu.
cat > "$work/embedded.cfg" <<EOF
search --no-floppy --fs-uuid --set=root $boot_uuid
set prefix=(\$root)/grub2
configfile /grub2/grub.cfg
EOF

sudo podman run --rm --network=host --platform linux/arm64 --pull=missing \
    -v "$work:/work:Z" "${BUILDER_IMAGE_OVERRIDE:-registry.fedoraproject.org/fedora:44}" bash -euc '
        dnf5 -y install grub2-tools grub2-efi-aa64-modules
        grep -Eq "^devicetree:[[:space:]]+fdt$" /usr/lib/grub/arm64-efi/command.lst
        # Both configurations use search; search_fs_uuid only provides search.fs_uuid.
        grub2-mkimage -O arm64-efi -d /usr/lib/grub/arm64-efi \
            -o /work/BOOTAA64.EFI -p /grub2 -c /work/embedded.cfg \
            part_gpt fat ext2 btrfs search search_fs_uuid configfile normal linux fdt
        test -s /work/BOOTAA64.EFI
    '
sudo mkdir -p "$work/esp/EFI/BOOT"
sudo cp "$work/BOOTAA64.EFI" "$work/esp/EFI/BOOT/BOOTAA64.EFI"
sudo sync
cleanup
trap - EXIT
sudo "$repo/post_process/export-lenovo-y700-gen4-ufs-images.sh" "$raw" "$out"
echo "GRUB searches /boot by filesystem UUID $boot_uuid"
