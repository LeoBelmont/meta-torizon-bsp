require tegra-torizon.inc

# Ship both 8GB Orin Nano super DTBs so one image boots either module variant:
# orin-nano.inc bakes only the devkit module (p3767-0005); add the RAM-module
# (p3767-0003) DTB alongside it. UEFI/L4TLauncher selects the matching one from
# the module EEPROM at boot. Pairs with TEGRA_FLASH_CHECK_BOARDSKU="" in
# tegra-torizon.inc, which lets either module get past the flash SKU gate.
KERNEL_DEVICETREE:append = " tegra234-p3768-0000+p3767-0003-nv-super.dtb"
