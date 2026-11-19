#!/bin/bash
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT
#
# Flash one NVIDIA Jetson in recovery mode with a tegraflash package of a
# torizon-signed image, and say whether it worked:
#
#   tegra-secboot-flash.sh [--keydir DIR] [--usb-instance INSTANCE]
#                          [--work-dir DIR] [--log-dir DIR] PACKAGE
#
# PACKAGE is the .tegraflash-tar.zst file, or the directory it was unpacked
# into. A file is unpacked into a new directory under --work-dir (default:
# the current directory), and its root filesystem image is checked.
#
# --keydir DIR          check the package against this key set first, with
#                       tegra-secboot-verify-package.py, and do not flash a
#                       package that fails
# --usb-instance INST   the USB port of the device (for instance 1-4.2), when
#                       more than one Jetson is in recovery mode on the host
# --log-dir DIR         where the log of the run goes (default: the package
#                       directory)
#
# The exit status is 0 only when the device reported that it was flashed.
#
# To flash several devices at once, run one instance per device, each with
# its --usb-instance and with the packed PACKAGE, so that each gets its own
# unpacked copy: initrd-flash writes to the directory it runs in.
#
# initrd-flash releases the USB storage that the device exports with
# "udisksctl power-off". On a host without udisks2 this script puts a
# stand-in for that command on the PATH, which disables the USB port of the
# device for a few seconds instead.
#
# Needs root (run it with sudo), zstd and tar for a packed package, and what
# initrd-flash itself needs. See docs/README-nvidia-secure-boot.md.

set -o pipefail

here="$(dirname "$(readlink -f "$0")")"
keydir=""
usb_instance=""
work_dir="$PWD"
log_dir=""

die() { echo "tegra-secboot-flash: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
	--keydir|--usb-instance|--work-dir|--log-dir)
		[ $# -ge 2 ] || die "$1 needs a value"
		case "$1" in
		--keydir) keydir="$2" ;;
		--usb-instance) usb_instance="$2" ;;
		--work-dir) work_dir="$2" ;;
		--log-dir) log_dir="$2" ;;
		esac
		shift 2 ;;
	-h|--help) sed -n '5,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	-*) die "unknown option $1" ;;
	*) break ;;
	esac
done
[ $# -eq 1 ] || die "give one package (see --help)"
package="$1"
[ -e "$package" ] || die "$package: not found"
[ "$(id -u)" = "0" ] || die "run as root (sudo)"

# Check the signatures first: on the packed file when there is one
if [ -n "$keydir" ]; then
	echo "== Checking the package against the key set in $keydir"
	python3 "$here/tegra-secboot-verify-package.py" "$package" "$keydir" || die "the package failed the check: not flashing it"
fi

if [ -d "$package" ]; then
	flash_dir="$(readlink -f "$package")"
else
	mkdir -p "$work_dir" || die "cannot create $work_dir"
	flash_dir="$(mktemp -d "$(readlink -f "$work_dir")/tegraflash.XXXXXX")" || die "cannot create a directory in $work_dir"
	echo "== Unpacking $package into $flash_dir"
	tar --zstd -xf "$package" -C "$flash_dir" || die "cannot unpack $package"
fi
[ -x "$flash_dir/initrd-flash" ] || die "no initrd-flash in $flash_dir: not a tegraflash package?"

# A truncated root filesystem image flashes fine and then does not boot
rootfs="$(sed -n 's/^ROOTFS_IMAGE="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$flash_dir/.env.initrd-flash" 2>/dev/null)"
if [ -n "$rootfs" ] && [ -e "$flash_dir/$rootfs" ]; then
	e2fsck="$(command -v e2fsck || echo /sbin/e2fsck)"
	echo "== Checking $rootfs"
	"$e2fsck" -fn "$flash_dir/$rootfs" > /dev/null 2>&1 || die "$rootfs is damaged (e2fsck): unpack the package again"
fi

# The stand-in for "udisksctl power-off -b DEVICE" disables the USB port
# that DEVICE is on for a few seconds: the Jetson sees the disconnect and
# exports the next thing, and when the port is enabled again the host looks
# at what is connected then. Without that, a host can miss the next export
# when it comes quickly: seen behind a USB 3 hub, both when the device was
# only detached (the "remove" attribute) and with the unbind and bind that
# initrd-flash falls back to. The "remove" attribute is the fallback here
# for kernels without the "disable" attribute of USB ports.
#
# It only acts on a device with the USB ID of the Linux gadget that the
# flashing image is, and only on the port that device is on.
#
# It only touches the storage that the flashing image of a Jetson exports.
# For the other udisksctl commands it fails, and initrd-flash then mounts
# and unmounts by itself.
standin=""
cleanup() { [ -z "$standin" ] || rm -rf "$standin"; }
trap cleanup EXIT
if ! command -v udisksctl > /dev/null 2>&1; then
	echo "== No udisksctl on this host: using a stand-in to release the USB storage"
	standin="$(mktemp -d)" || die "cannot create a temporary directory"
	cat > "$standin/udisksctl" <<'EOF'
#!/bin/sh
[ "$1" = "power-off" ] || exit 1
dev=""
while [ $# -gt 0 ]; do
	case "$1" in
	-b) dev="$2"; shift ;;
	esac
	shift
done
[ -b "$dev" ] || exit 1
usbdev="$(readlink -f "/sys/block/$(basename "$dev")/device" | tr / '\n' | grep -E '^[0-9]+-[0-9.]+$' | tail -n 1)"
[ -n "$usbdev" ] || exit 1
sysdev="/sys/bus/usb/devices/$usbdev"
# Only the mass storage gadget of the flashing image
[ "$(cat "$sysdev/idVendor" 2>/dev/null):$(cat "$sysdev/idProduct" 2>/dev/null)" = "1d6b:0104" ] || exit 1
sync
port="$(readlink -f "$sysdev/port" 2>/dev/null)"
if [ -n "$port" ] && [ -e "$port/disable" ]; then
	# A USB 3 port and the USB 2 port of the same socket are peers: disable
	# both, or the device comes back on the USB 2 one, four times slower
	peer="$(readlink -f "$port/peer" 2>/dev/null)"
	[ -n "$peer" ] && [ -e "$peer/disable" ] || peer=""
	echo 1 > "$port/disable" || exit 1
	[ -z "$peer" ] || echo 1 > "$peer/disable"
	# The flashing image looks at the state of its USB port once a second
	sleep 3
	# The faster port first, so that the device connects there
	first="$port"; second="$peer"
	if [ -n "$peer" ] && [ "$(cat "$peer/../../speed" 2>/dev/null || echo 0)" -gt "$(cat "$port/../../speed" 2>/dev/null || echo 0)" ]; then
		first="$peer"; second="$port"
	fi
	echo 0 > "$first/disable"
	if [ -n "$second" ]; then
		sleep 1
		echo 0 > "$second/disable"
	fi
else
	echo 1 > "$sysdev/remove"
fi
EOF
	chmod 755 "$standin/udisksctl"
	PATH="$standin:$PATH"
	export PATH
fi

[ -n "$log_dir" ] || log_dir="$flash_dir"
mkdir -p "$log_dir" || die "cannot create $log_dir"
log="$(readlink -f "$log_dir")/tegra-secboot-flash-$(date +%Y%m%d-%H%M%S)${usb_instance:+-$usb_instance}.log"

echo "== Flashing from $flash_dir, log in $log"
cd "$flash_dir" || die "cannot enter $flash_dir"
./initrd-flash ${usb_instance:+--usb-instance "$usb_instance"} 2>&1 | tee "$log"
rc=${PIPESTATUS[0]}

if [ "$rc" = "0" ] && grep -q "^Final status: SUCCESS" "$log"; then
	echo "RESULT: flashed${usb_instance:+ the device on USB $usb_instance}"
	exit 0
fi
echo "RESULT: FAILED${usb_instance:+ for the device on USB $usb_instance} (initrd-flash exit status $rc): see $log" >&2
exit 1
