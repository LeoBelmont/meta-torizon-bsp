FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"

SRC_URI:append:genericx86-64 = " file://0001-rules-whitelist-hd-devices.patch"

# With the kernel cmdline's "quiet" dropped (lec-mtk-i1200-ufs.inc) to keep
# full boot-time console output, lower console_loglevel back down via
# sysctl.d once systemd-sysctl runs early in boot, to suppress kernel
# messages after boot on the console/login shell - without touching the
# boot cmdline itself. The messages remain visible via dmesg.
SRC_URI:append:lec-mtk1200 = " file://99-printk-console.conf"

do_install:append:lec-mtk1200() {
    install -Dm 0644 ${UNPACKDIR}/99-printk-console.conf ${D}${sysconfdir}/sysctl.d/99-printk-console.conf
}
