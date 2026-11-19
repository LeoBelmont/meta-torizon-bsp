# Torizon OS signed images on NVIDIA Jetson, for both the standard and the RT
# kernel.

# The kernel options composefs needs. The Jetson kernel does not include
# linux-torizon.inc, which adds them for the other kernels.
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../../recipes-kernel/linux/files:"
SRC_URI:append:cfs-support = " file://composefs.cfg"
SRC_URI:append:cfs-signed = " file://composefs-fsverity.cfg"

# UEFI Secure Boot (torizon-signed, see tegra-torizon-signed.bbclass):
# module signing with TEGRA_MODSIGN_KEY, rejecting unsigned modules, kernel
# lockdown in integrity mode (TEGRA_SECBOOT_LOCKDOWN), and efivarfs for the
# initramfs.
FILESEXTRAPATHS:prepend:tegra-signed := "${THISDIR}/linux-noble-nvidia-tegra:"

SRC_URI:append:tegra-signed = " \
    file://tegra-signed-modsign.cfg \
    file://tegra-signed-efivarfs.cfg \
    ${@'file://tegra-signed-lockdown.cfg' if d.getVar('TEGRA_SECBOOT_LOCKDOWN') == '1' else ''} \
"

# The kernel image is signed with db on its own too: it is inside the UKI and
# inside the Android boot images, and the UEFI firmware starts it like any
# other signed EFI application, with whatever load options it is given.
# Without this, "initrd=" and "rdinit=" in those options choose the first
# user space that runs, on a device with UEFI Secure Boot enabled. So the
# kernel only takes the command line of its configuration (CMDLINE_FORCE,
# set in do_configure below), and the patch makes its EFI stub ignore
# "initrd=" then. The initramfs of the UKI and of the Android boot images
# does not come from the command line and still loads.
SRC_URI:append:tegra-signed = " \
    file://0001-efi-libstub-do-not-load-initrd-from-an-untrusted-command-line.patch \
"

# Strip the debug information from the modules when they are installed,
# before they are signed: packaging leaves signed modules as they are, as
# stripping them later would drop the signature.
EXTRA_OEMAKE:append:tegra-signed = " INSTALL_MOD_STRIP=1"

TEGRA_MODSIGN_KEY ??= ""
TEGRA_SECBOOT_LOCKDOWN ??= "1"

do_configure[file-checksums] += "${@'${TEGRA_MODSIGN_KEY}:True' if 'tegra-signed' in d.getVar('OVERRIDES').split(':') else ''}"

# CONFIG_MODULE_SIG_KEY is relative to the build directory
do_configure:prepend:tegra-signed() {
    if [ ! -f "${TEGRA_MODSIGN_KEY}" ]; then
        bbfatal "Kernel module signing key not found: ${TEGRA_MODSIGN_KEY}"
    fi
    install -m 0600 "${TEGRA_MODSIGN_KEY}" ${B}/modsign_key.pem
}

# TEGRA_SECBOOT_KERNEL_CMDLINE is the command line of the UKI too
# (tegra-torizon-signed.bbclass). TEGRA_SECBOOT_FORCE_CMDLINE = "0" leaves
# the kernel taking its command line from the boot loader, for debugging.
TEGRA_SECBOOT_KERNEL_CMDLINE ??= ""
TEGRA_SECBOOT_FORCE_CMDLINE ??= "1"

do_configure:append:tegra-signed() {
    if [ "${TEGRA_SECBOOT_FORCE_CMDLINE}" = "1" ]; then
        if [ -z "${TEGRA_SECBOOT_KERNEL_CMDLINE}" ]; then
            bbfatal "TEGRA_SECBOOT_KERNEL_CMDLINE is empty: no kernel command line to build in"
        fi
        ${S}/scripts/config --file ${B}/.config \
            --set-str CMDLINE "${TEGRA_SECBOOT_KERNEL_CMDLINE}" \
            --disable CMDLINE_FROM_BOOTLOADER \
            --enable CMDLINE_FORCE
        ${KERNEL_CONFIG_COMMAND}
        if ! grep -q '^CONFIG_CMDLINE_FORCE=y' ${B}/.config; then
            bbfatal "CONFIG_CMDLINE_FORCE is not set in the kernel configuration"
        fi
    fi
}

# Out-of-tree modules (e.g. nvidia-kernel-oot) build against
# STAGING_KERNEL_BUILDDIR, so the key must be there to sign them too.
do_shared_workdir:append:tegra-signed() {
    install -m 0600 ${B}/modsign_key.pem ${STAGING_KERNEL_BUILDDIR}/modsign_key.pem
}
