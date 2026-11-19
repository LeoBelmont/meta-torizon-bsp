SUMMARY = "Device side tools of torizon-signed images on NVIDIA Jetson"
DESCRIPTION = "Installs two scripts of scripts/tools of this layer. \
tegra-secboot-check checks UEFI Secure Boot, the UKI boot, the kernel \
lockdown and the composefs root on the running device. \
tegra-secboot-capsule installs a boot firmware update capsule and shows \
the result of the last one."
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(tegra)"

# The scripts are kept with the other tools of the layer, to be copied to a
# device that does not have this package
FILESEXTRAPATHS:prepend := "${THISDIR}/../../../../scripts/tools:"
SRC_URI = "\
    file://tegra-secboot-check.sh \
    file://tegra-secboot-capsule.sh \
"

S = "${UNPACKDIR}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -D -m 0755 ${UNPACKDIR}/tegra-secboot-check.sh ${D}${sbindir}/tegra-secboot-check
    install -D -m 0755 ${UNPACKDIR}/tegra-secboot-capsule.sh ${D}${sbindir}/tegra-secboot-capsule
}
