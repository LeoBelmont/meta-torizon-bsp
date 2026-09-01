# Inject ConnectTech Rudi-NX (Orin NX / NGX010) carrier files into the
# tegraflash staging. meta-tegra only stages NVIDIA's bootloader files, so the
# CTI carrier BCT/pinmux/DTB (referenced by the TEGRA_FLASHVAR_* and DTB_FILE
# values set in conf/machine/rudi-nx.conf) must be added here. One-shot build:
# installed straight from the layer's files/ dir (no SRC_URI/unpack), since the
# CTI files carry no CTI-specific includes and stand alone.

# Capture the bbappend dir at parse time so it survives into the task shell.
CTI_FILES := "${THISDIR}/files"

do_install:append:rudi-nx() {
    install -m 0644 ${CTI_FILES}/tegra234-cti-orin-nx-rudi-mb1-bct-pinmux.dtsi ${D}${datadir}/tegraflash/
    install -m 0644 ${CTI_FILES}/tegra234-cti-orin-nx-mb2-bct-misc.dts         ${D}${datadir}/tegraflash/
    install -m 0644 ${CTI_FILES}/tegra234-cti-orin-nx-mb2-bct-scr.dts          ${D}${datadir}/tegraflash/
    install -m 0644 ${CTI_FILES}/tegra234-cti-orin-nx-mb1-bct-gpioint.dts      ${D}${datadir}/tegraflash/
    install -m 0644 ${CTI_FILES}/tegra234-orin-nx-cti-NGX010.dtb               ${D}${datadir}/tegraflash/
    install -m 0644 ${CTI_FILES}/tegra234-orin-nx-cti-overlay.dtbo             ${D}${datadir}/tegraflash/
}
