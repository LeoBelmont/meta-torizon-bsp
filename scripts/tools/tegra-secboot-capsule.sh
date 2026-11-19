#!/bin/sh
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT
#
# Install a boot firmware update capsule on a running NVIDIA Jetson
# (torizon-signed), or show the result of the last one. Run as root:
#
#   tegra-secboot-capsule status
#   tegra-secboot-capsule install [CAPSULE]
#
# "install" copies the capsule to the EFI system partition and asks the UEFI
# firmware to process it at the next boot: reboot to install it. The firmware
# verifies the capsule with the certificate it was built with, writes the
# boot chain that is not running, and boots from it. Without CAPSULE, the
# capsule of the image is used (TEGRA_SECBOOT_CAPSULE_IN_IMAGE = "1").
#
# See docs/README-nvidia-secure-boot.md, "Firmware update capsules".

EFIVARS=/sys/firmware/efi/efivars
EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
NVIDIA_GUID=781e084c-a330-417c-b678-38e696380cb9
DEFAULT_CAPSULE=/usr/share/tegra-uefi-capsules/tegra-bl.cap
ESP_DEV=/dev/disk/by-partlabel/esp
ESP_FILE=EFI/UpdateCapsule/TEGRA_BL.Cap

die() { echo "tegra-secboot-capsule: $*" >&2; exit 1; }

# efi_ascii NAME: an ASCII variable of the NVIDIA GUID, as text
efi_ascii() {
	[ -e "${EFIVARS}/$1-${NVIDIA_GUID}" ] || return 0
	dd if="${EFIVARS}/$1-${NVIDIA_GUID}" bs=1 skip=4 2>/dev/null | tr -d '\000\r\n'
}

status() {
	spec="$(efi_ascii TegraPlatformSpec)"
	compat="$(efi_ascii TegraPlatformCompatSpec)"
	echo "platform spec:        ${spec:-not set}"
	echo "platform compat spec: ${compat:-not set}"
	if [ -z "$spec" ]; then
		echo "  The firmware selects the images of a capsule with these variables;"
		echo "  without them it refuses the capsule (status 0x1807). The"
		echo "  setup-nv-boot-control service sets them at boot."
	fi
	if command -v nvbootctrl >/dev/null 2>&1; then
		nvbootctrl dump-slots-info 2>/dev/null |
			grep -E "^(Current version|Capsule update status|Current bootloader slot|Active bootloader slot)"
	fi
	for e in /sys/firmware/efi/esrt/entries/entry*; do
		[ -e "$e/fw_class" ] || continue
		s="$(cat "$e/last_attempt_status")"
		case "$s" in
		0) t="success, or no attempt yet" ;;
		6151) t="0x1807, a required image is not in the capsule for this board" ;;
		*) t="$(printf '0x%x' "$s"), failed" ;;
		esac
		echo "firmware $(cat "$e/fw_class"): version $(cat "$e/fw_version"), last attempt: $t"
	done
	if [ -e "${EFIVARS}/OsIndications-${EFI_GLOBAL}" ] &&
	   [ "$(od -An -tu1 -j4 -N1 "${EFIVARS}/OsIndications-${EFI_GLOBAL}" | tr -d ' ')" = "4" ]; then
		echo "a capsule is waiting to be processed at the next boot"
	fi
}

install_capsule() {
	cap="${1:-$DEFAULT_CAPSULE}"
	[ "$(id -u)" = "0" ] || die "run as root"
	[ -d "$EFIVARS" ] || die "$EFIVARS is not there: not booted with UEFI?"
	[ -s "$cap" ] || die "no capsule at $cap"
	[ -n "$(efi_ascii TegraPlatformSpec)" ] ||
		die "the TegraPlatformSpec variable is not set: the firmware would refuse the capsule (see \"status\")"

	# The EFI system partition: where it is mounted already, or mounted here
	esp="$(findmnt -n -o TARGET --source "$(readlink -f "$ESP_DEV")" 2>/dev/null | head -n 1)"
	mounted=""
	if [ -z "$esp" ]; then
		[ -b "$ESP_DEV" ] || die "no EFI system partition at $ESP_DEV"
		esp="$(mktemp -d)" || die "cannot create a mount point"
		mount "$ESP_DEV" "$esp" || { rmdir "$esp"; die "cannot mount $ESP_DEV"; }
		mounted="1"
	fi
	rc=0
	mkdir -p "$esp/$(dirname "$ESP_FILE")" &&
		cp "$cap" "$esp/$ESP_FILE" && sync && cmp -s "$cap" "$esp/$ESP_FILE" || rc=1
	if [ -n "$mounted" ]; then
		umount "$esp" && rmdir "$esp"
	fi
	[ "$rc" = "0" ] || die "could not copy the capsule to the EFI system partition"

	# OsIndications: EFI_OS_INDICATIONS_FILE_CAPSULE_DELIVERY_SUPPORTED (bit 2).
	# The four bytes before the value are the attributes of the variable
	# (non-volatile, boot service and runtime access).
	var="${EFIVARS}/OsIndications-${EFI_GLOBAL}"
	[ -e "$var" ] && chattr -i "$var" 2>/dev/null
	tmp="$(mktemp)" || die "cannot create a temporary file"
	printf '\007\000\000\000\004\000\000\000\000\000\000\000' > "$tmp"
	dd if="$tmp" of="$var" bs=12 2>/dev/null || rc=1
	rm -f "$tmp"
	sync
	[ "$rc" = "0" ] || die "could not set the OsIndications variable"

	echo "The capsule $cap is ready on the EFI system partition."
	echo "Reboot to install it, then run \"tegra-secboot-capsule status\"."
}

case "$1" in
status) status ;;
install) install_capsule "$2" ;;
*) sed -n '5,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
