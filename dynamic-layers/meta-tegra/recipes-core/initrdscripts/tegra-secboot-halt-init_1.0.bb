DESCRIPTION = "initramfs init that refuses to boot, for the kernel partition of signed images"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

SRC_URI = "file://init-halt.sh"

S = "${UNPACKDIR}"

COMPATIBLE_MACHINE = "(tegra)"

do_install() {
    install -m 0755 ${UNPACKDIR}/init-halt.sh ${D}/init
    install -m 0555 -d ${D}/proc ${D}/sys
    install -m 0755 -d ${D}/dev
    mknod -m 622 ${D}/dev/console c 5 1
}

FILES:${PN} = "/"
