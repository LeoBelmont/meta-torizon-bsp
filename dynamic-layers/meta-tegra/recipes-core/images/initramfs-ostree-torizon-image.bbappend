PACKAGE_INSTALL:append = " \
    tegra-firmware-xusb \
    kernel-module-nvme \
"

PACKAGE_INSTALL:append:tegra234 = " \
    kernel-module-pcie-tegra194 \
    kernel-module-phy-tegra194-p2u \
    kernel-module-tegra-xudc \
    kernel-module-ucsi-ccg \
"

PACKAGE_INSTALL:append:tegra264 = " \
    nv-kernel-module-pcie-tegra264 \
    nv-kernel-module-ufs-tegra \
"
