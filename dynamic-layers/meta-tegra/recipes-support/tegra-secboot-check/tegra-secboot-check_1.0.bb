SUMMARY = "Check that a torizon-signed image booted with Secure Boot on NVIDIA Jetson"
DESCRIPTION = "Installs scripts/tools/tegra-secboot-check.sh of this layer as \
tegra-secboot-check: it checks UEFI Secure Boot, the UKI boot, the kernel \
lockdown and the composefs root on the running device."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(tegra)"

# The script is kept with the other tools of the layer, to be copied to a
# device that does not have this package
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../../scripts/tools:"
SRC_URI = "file://tegra-secboot-check.sh"

S = "${UNPACKDIR}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -D -m 0755 ${UNPACKDIR}/tegra-secboot-check.sh ${D}${sbindir}/tegra-secboot-check
}
