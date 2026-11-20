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
    file://tegra-secboot-capsule-auto.service \
    file://tegra-secboot-capsule-auto.timer \
    file://tegra-secboot-test-health-check.sh \
"

inherit systemd

# ${PN}-capsule-auto: the timer that runs "tegra-secboot-capsule auto", to
# install the capsule of the image when an update brought another one
PACKAGES =+ "${PN}-capsule-auto"
SYSTEMD_PACKAGES = "${PN}-capsule-auto"
SYSTEMD_SERVICE:${PN}-capsule-auto = "tegra-secboot-capsule-auto.timer"
FILES:${PN}-capsule-auto = "\
    ${systemd_system_unitdir}/tegra-secboot-capsule-auto.service \
    ${systemd_system_unitdir}/tegra-secboot-capsule-auto.timer \
"
RDEPENDS:${PN}-capsule-auto = "${PN} tegra-uefi-capsules"

# ${PN}-test-health-check: for test images, a health check that fails for the
# deployment named in a file, to test the rollback of an unhealthy update
PACKAGES =+ "${PN}-test-health-check"
FILES:${PN}-test-health-check = "${sysconfdir}/greenboot/check/required.d/90-tegra-secboot-test.sh"
RDEPENDS:${PN}-test-health-check = "greenboot"

S = "${UNPACKDIR}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    install -D -m 0755 ${UNPACKDIR}/tegra-secboot-check.sh ${D}${sbindir}/tegra-secboot-check
    install -D -m 0755 ${UNPACKDIR}/tegra-secboot-capsule.sh ${D}${sbindir}/tegra-secboot-capsule
    install -D -m 0644 ${UNPACKDIR}/tegra-secboot-capsule-auto.service ${D}${systemd_system_unitdir}/tegra-secboot-capsule-auto.service
    install -D -m 0644 ${UNPACKDIR}/tegra-secboot-capsule-auto.timer ${D}${systemd_system_unitdir}/tegra-secboot-capsule-auto.timer
    install -D -m 0755 ${UNPACKDIR}/tegra-secboot-test-health-check.sh ${D}${sysconfdir}/greenboot/check/required.d/90-tegra-secboot-test.sh
}
