SUMMARY = "Prebuilt ConnectTech Rudi-NX (Orin NX / NGX010) kernel device tree"
DESCRIPTION = "Supplies the prebuilt ConnectTech NGX010 carrier device tree \
(and CTI overlay) as virtual/dtb, since the .dts source is not shipped and \
cannot be built from the OOT kernel tree. One-shot build: installed straight \
from the layer's files/ dir."
LICENSE = "CLOSED"

PROVIDES = "virtual/dtb"
COMPATIBLE_MACHINE = "rudi-nx"

inherit deploy

# Capture the recipe dir at parse time so it survives into the task shell.
CTI_FILES := "${THISDIR}/files"

CTI_KDTB = "tegra234-orin-nx-cti-NGX010.dtb"
CTI_OVERLAY = "tegra234-orin-nx-cti-overlay.dtbo"

do_fetch[noexec] = "1"
do_unpack[noexec] = "1"
do_patch[noexec] = "1"
do_configure[noexec] = "1"
do_compile[noexec] = "1"

# Install into the rootfs boot dir; SYSROOT_DIRS stages it so the image's
# do_image_tegraflash_tar finds it in recipe-sysroot/boot/devicetree.
do_install() {
    install -d ${D}/boot/devicetree
    install -m 0644 ${CTI_FILES}/${CTI_KDTB}    ${D}/boot/devicetree/
    install -m 0644 ${CTI_FILES}/${CTI_OVERLAY} ${D}/boot/devicetree/
}
SYSROOT_DIRS += "/boot"
FILES:${PN} = "/boot/devicetree"

do_deploy() {
    install -d ${DEPLOYDIR}/devicetree
    install -m 0644 ${CTI_FILES}/${CTI_KDTB}    ${DEPLOYDIR}/devicetree/
    install -m 0644 ${CTI_FILES}/${CTI_OVERLAY} ${DEPLOYDIR}/devicetree/
    # Flat copies in the deploy image root: the flash step looks for the dtb and
    # overlays there (DEPLOY_DIR_IMAGE), and ostree-kernel-initramfs pulls the
    # dtb basename from there too.
    install -m 0644 ${CTI_FILES}/${CTI_KDTB}    ${DEPLOYDIR}/
    install -m 0644 ${CTI_FILES}/${CTI_OVERLAY} ${DEPLOYDIR}/
}
addtask deploy before do_build after do_install
