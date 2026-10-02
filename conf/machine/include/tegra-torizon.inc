TEGRA_ESSENTIAL_EXTRA_RDEPENDS:remove = " \
  l4t-launcher-extlinux \
"

OSTREE_KERNEL_ARGS:append = " ${KERNEL_ARGS} root=/dev/${TNSPEC_BOOTDEV} rootfstype=ext4 rootwait"

IMAGE_TEGRAFLASH_KERNEL = "${DEPLOY_DIR_IMAGE}/tegra-minimal-initramfs-${MACHINE}.cboot"
IMAGE_TEGRAFLASH_FS_TYPE:tegra = "ota-ext4"

# Don't gate flashing on the module's board SKU. The default expects one SKU per
# machine (e.g. orin-nano = 0005, DevKit w/ SD), but the same image must flash
# across pin-compatible SKUs of the same module (e.g. 0003 Orin Nano production,
# 0004 4GB, 0005 devkit). Empty = skip the SKU check in the flash helper.
TEGRA_FLASH_CHECK_BOARDSKU = ""

BBMASK += "meta-tegra/external/sota/recipes-bsp/uefi/edk2-firmware-tegra_%.bbappend"

do_image_tegraflash_tar[depends] += " tegra-minimal-initramfs:do_image_complete"

MACHINE_EXTRA_RDEPENDS:remove = " tegra-redundant-boot"

# meta-tegra uses A/B layout, we don't want it here.
HAS_REDUNDANT_PARTITION_LAYOUT_EXTERNAL = "0"

PREFERRED_PROVIDER_u-boot-fw-utils = "u-boot-fw-utils-tegra-emul"
PREFERRED_RPROVIDER_u-boot-fw-utils = "u-boot-fw-utils-tegra-emul"
