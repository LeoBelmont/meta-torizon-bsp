#!/bin/sh
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT
#
# Install a boot firmware update capsule on a running NVIDIA Jetson
# (torizon-signed), or show the result of the last one. Run as root:
#
#   tegra-secboot-capsule status
#   tegra-secboot-capsule install [CAPSULE]
#   tegra-secboot-capsule auto [CAPSULE]
#
# "install" copies the capsule to the EFI system partition and asks the UEFI
# firmware to process it at the next boot: reboot to install it. The firmware
# verifies the capsule with the certificate it was built with, writes the
# boot chain that is not running, and boots from it. Without CAPSULE, the
# capsule of the image is used (TEGRA_SECBOOT_CAPSULE_IN_IMAGE = "1").
#
# "auto" is what tegra-secboot-capsule-auto.timer runs, to install the
# capsule that an update of the operating system brings: it does "install"
# when the capsule is another one than the last one installed, and the
# update is confirmed. The capsule is then installed at the next reboot,
# whenever that is. The first run only records the capsule of the image as
# the one installed, as on a device that was just flashed.
#
# See docs/README-nvidia-secure-boot.md, "Firmware update capsules".

EFIVARS=/sys/firmware/efi/efivars
EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
NVIDIA_GUID=781e084c-a330-417c-b678-38e696380cb9
DEFAULT_CAPSULE=/usr/share/tegra-uefi-capsules/tegra-bl.cap
STATE_DIR="${TEGRA_SECBOOT_STATE_DIR:-/var/lib/tegra-secboot}"
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

# state NAME: the content of a state file, or nothing
state() { cat "${STATE_DIR}/$1" 2>/dev/null; }

auto() {
	cap="${1:-$DEFAULT_CAPSULE}"
	[ "$(id -u)" = "0" ] || die "run as root"
	if [ ! -s "$cap" ]; then
		echo "no capsule at $cap: nothing to do"
		return 0
	fi
	mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"
	sum="$(sha256sum "$cap" | cut -d' ' -f1)"
	boot="$(cat /proc/sys/kernel/random/boot_id)"

	# A capsule staged in an earlier boot: record what the firmware did with it
	if [ -n "$(state staged)" ] && [ "$(state staged-boot)" != "$boot" ]; then
		staged="$(state staged)"
		rm -f "${STATE_DIR}/staged" "${STATE_DIR}/staged-boot"
		if nvbootctrl dump-slots-info 2>/dev/null | grep -q "^Capsule update status: 1"; then
			echo "$staged" > "${STATE_DIR}/installed"
			rm -f "${STATE_DIR}/failed"
			echo "the capsule ${staged%${staged#????????????}} was installed"
		else
			echo "$staged" > "${STATE_DIR}/failed"
			echo "the firmware did not install the capsule ${staged%${staged#????????????}}: see \"status\"" >&2
		fi
	fi

	if [ -z "$(state installed)" ]; then
		# First run: the boot firmware is the one flashed with this image
		echo "$sum" > "${STATE_DIR}/installed"
		echo "recorded the capsule of the image as the installed one"
		return 0
	fi
	if [ "$(state installed)" = "$sum" ]; then
		echo "the capsule of the image is installed already"
		return 0
	fi
	if [ "$(state failed)" = "$sum" ]; then
		echo "the firmware refused this capsule before: not trying again"
		return 0
	fi
	if [ "$(state staged)" = "$sum" ]; then
		echo "the capsule is waiting for the next reboot"
		return 0
	fi
	# Not while an update is being tried, or after it was rolled back: the
	# deployment that is running may not be the one that stays
	if command -v fw_printenv >/dev/null 2>&1; then
		flags="$(fw_printenv upgrade_available rollback 2>/dev/null | tr '\n' ' ')"
		case "$flags" in
		*upgrade_available=1*|*rollback=1*)
			echo "the update is not confirmed ($flags): not installing the capsule yet"
			return 0 ;;
		esac
	fi
	install_capsule "$cap" || return 1
	echo "$sum" > "${STATE_DIR}/staged"
	echo "$boot" > "${STATE_DIR}/staged-boot"
}

case "$1" in
status) status ;;
install) install_capsule "$2" ;;
auto) auto "$2" ;;
*) sed -n '5,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
