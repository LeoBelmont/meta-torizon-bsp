#!/bin/sh
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT
#
# Check, on a running NVIDIA Jetson, that a torizon-signed image booted the
# way docs/README-nvidia-secure-boot.md describes: UEFI Secure Boot enabled,
# the signed UKI booted, the kernel locked down, the root filesystem
# verified by composefs. Copy it to the device and run it as root:
#
#   $ scp tegra-secboot-check.sh torizon@<device>:/tmp/
#   $ ssh -t torizon@<device> sudo sh /tmp/tegra-secboot-check.sh
#
# PASS/FAIL lines are the Secure Boot checks, and the exit status is 1 when
# one fails. WARN lines are about the rest of the system (services, NVIDIA
# tools) and INFO lines are for the test report.

EFIVARS=/sys/firmware/efi/efivars
EFI_GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
EFI_IMAGE_SECURITY=d719b2cb-3d3a-4596-a3bc-dad00e67656f
TORIZON_GUID=42dcf640-982c-443e-a0af-f6eb12f881f5
LOADER_GUID=4a67b082-0a4c-41cf-b6c7-440b29bb8c4f

fails=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; fails=$((fails + 1)); }
warn() { echo "WARN  $*"; }
info() { echo "INFO  $*"; }
skip() { echo "SKIP  $*"; }
section() { echo; echo "== $*"; }

# efi_byte NAME GUID: the first byte of the value of a variable
efi_byte() {
	[ -e "${EFIVARS}/$1-$2" ] || return 1
	od -An -tu1 -j4 -N1 "${EFIVARS}/$1-$2" 2>/dev/null | tr -d ' \n'
}
# efi_string NAME GUID: a UCS-2 string variable, as text
efi_string() {
	[ -e "${EFIVARS}/$1-$2" ] || return 1
	dd if="${EFIVARS}/$1-$2" bs=1 skip=4 2>/dev/null | tr -d '\000\r\n'
}

root=1
if [ "$(id -u)" != "0" ]; then
	root=0
	echo "Not running as root: some checks are skipped."
fi

if [ ! -d "${EFIVARS}" ] || [ -z "$(ls "${EFIVARS}" 2>/dev/null)" ]; then
	mount -t efivarfs efivarfs "${EFIVARS}" 2>/dev/null
fi

section "UEFI Secure Boot"
v="$(efi_byte SecureBoot ${EFI_GLOBAL})"
if [ "$v" = "1" ]; then pass "Secure Boot is enabled"; else fail "Secure Boot is not enabled (SecureBoot=${v:-missing})"; fi
v="$(efi_byte SetupMode ${EFI_GLOBAL})"
if [ "$v" = "0" ]; then pass "the firmware is in user mode"; else fail "the firmware is in setup mode: no keys enrolled (SetupMode=${v:-missing})"; fi
for var in PK-${EFI_GLOBAL} KEK-${EFI_GLOBAL} db-${EFI_IMAGE_SECURITY}; do
	if [ -s "${EFIVARS}/${var}" ]; then
		pass "${var%%-*} is enrolled ($(($(wc -c < "${EFIVARS}/${var}") - 4)) bytes)"
	else
		fail "${var%%-*} is not enrolled"
	fi
done

section "Boot path"
v="$(efi_string StubInfo ${LOADER_GUID})"
if [ -n "$v" ]; then pass "booted through a UKI ($v)"; else fail "not booted through a UKI: no StubInfo variable"; fi
bootargs="$(efi_string TorizonBootArgs ${TORIZON_GUID})"
want=""
for arg in ${bootargs}; do
	case "$arg" in ostree=*) want="$arg" ;; esac
done
if [ -n "$want" ]; then
	pass "L4TLauncher passed the deployment: $want"
else
	fail "no ostree= argument in the TorizonBootArgs variable"
fi
got="$(cat /run/ostree/cmdline-extra 2>/dev/null)"
if [ -n "$want" ] && [ "$got" = "$want" ]; then
	pass "the initramfs took the deployment from the variable"
else
	fail "/run/ostree/cmdline-extra is '${got}', expected '${want}'"
fi
case " $(cat /proc/cmdline) " in
*" ostree="*) fail "ostree= is on the kernel command line: not the command line of the UKI" ;;
*) pass "the kernel command line has no ostree= argument" ;;
esac
info "kernel command line: $(cat /proc/cmdline)"
if ostree admin status 2>/dev/null | grep -q '^\* '; then
	pass "booted deployment: $(ostree admin status | sed -n 's/^\* //p')"
else
	fail "ostree admin status shows no booted deployment"
fi

section "Kernel"
v="$(cat /sys/kernel/security/lockdown 2>/dev/null)"
case "$v" in
*"[integrity]"*|*"[confidentiality]"*) pass "lockdown: $v" ;;
*) fail "the kernel is not locked down (${v:-no lockdown support})" ;;
esac
v="$(cat /sys/module/module/parameters/sig_enforce 2>/dev/null)"
if [ "$v" = "Y" ]; then pass "unsigned modules are rejected (sig_enforce)"; else fail "module signatures are not enforced (sig_enforce=${v:-missing})"; fi
v="$(cat /proc/sys/kernel/tainted 2>/dev/null)"
if [ $(( ${v:-0} & 8192 )) -eq 0 ]; then pass "no unsigned module was loaded (tainted=$v)"; else fail "an unsigned module was loaded (tainted=$v)"; fi
info "$(grep -c . /proc/modules) modules loaded, kernel $(uname -r)"

section "Root filesystem"
v="$(sed -n 's/^\([^ ]*\) \/ \([^ ]*\) \([^ ]*\) .*/\1 \2 \3/p' /proc/mounts | tail -n 1)"
case "$v" in
"composefs overlay "*verity=require*) pass "the root is a composefs mount with verity=require" ;;
*) fail "the root is not a verified composefs mount: $v" ;;
esac
if [ "$root" = "1" ]; then
	if touch /usr/.tegra-secboot-check 2>/dev/null; then
		rm -f /usr/.tegra-secboot-check
		fail "/usr is writable"
	else
		pass "/usr is read-only"
	fi
	# The composefs image of the booted deployment: "* <os> <checksum>.<serial>"
	cfs="$(ostree admin status 2>/dev/null | sed -n 's|^\* \([^ ]*\) \([^ ]*\).*|/sysroot/ostree/deploy/\1/deploy/\2/.ostree.cfs|p')"
	[ -e "$cfs" ] || cfs=""
	if ! command -v fsverity >/dev/null 2>&1; then
		skip "no fsverity tool to measure the composefs image"
	elif [ -n "$cfs" ] && v="$(fsverity measure "$cfs" 2>/dev/null)"; then
		pass "fs-verity is enabled on the composefs image (${v%% *})"
	else
		fail "fs-verity is not enabled on the composefs image (${cfs:-not found})"
	fi
else
	skip "/usr read-only and fs-verity checks need root"
fi

section "System"
v="$(systemctl is-system-running 2>/dev/null)"
if [ "$v" = "running" ]; then pass "systemd state: running"; else warn "systemd state: $v"; fi
systemctl --failed --no-legend --plain 2>/dev/null | while read -r unit rest; do
	[ -n "$unit" ] && echo "WARN  failed unit: $unit"
done
for unit in docker.service aktualizr-torizon.service tee-supplicant.service nvpmodel.service nvfancontrol.service; do
	v="$(systemctl is-active "$unit" 2>/dev/null)"
	case "$v" in
	active) info "$unit: active" ;;
	*) warn "$unit: ${v:-unknown}" ;;
	esac
done
if [ -e /dev/tee0 ]; then info "OP-TEE device: /dev/tee0"; else warn "no OP-TEE device (/dev/tee0)"; fi
if [ "$root" = "1" ]; then
	if command -v nvpmodel >/dev/null 2>&1; then
		if v="$(nvpmodel -q 2>&1)"; then info "nvpmodel: $(echo "$v" | tr '\n' ' ')"; else warn "nvpmodel -q failed: $(echo "$v" | tail -n 1)"; fi
	fi
	dmesg 2>/dev/null | sed -n 's/.*Lockdown: \(.*\) is restricted.*/\1/p' | sort | uniq -c | while read -r count what; do
		echo "INFO  blocked by lockdown, $count time(s): $what"
	done
	v="$(dmesg 2>/dev/null | grep -c -i -E 'module verification failed|Loading of unsigned module')"
	if [ "$v" = "0" ]; then info "no module signature errors in the kernel log"; else warn "$v module signature message(s) in the kernel log"; fi
fi
if command -v fw_printenv >/dev/null 2>&1; then
	info "update state: $(fw_printenv upgrade_available bootcount rollback 2>/dev/null | tr '\n' ' ')"
fi

echo
if [ "$fails" = "0" ]; then
	echo "Secure Boot checks passed."
else
	echo "$fails Secure Boot check(s) FAILED."
fi
[ "$fails" = "0" ]
