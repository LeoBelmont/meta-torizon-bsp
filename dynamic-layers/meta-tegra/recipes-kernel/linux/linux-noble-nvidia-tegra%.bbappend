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

# Out-of-tree modules (e.g. nvidia-kernel-oot) build against
# STAGING_KERNEL_BUILDDIR, so the key must be there to sign them too.
do_shared_workdir:append:tegra-signed() {
    install -m 0600 ${B}/modsign_key.pem ${STAGING_KERNEL_BUILDDIR}/modsign_key.pem
}
