# Machine / SoC-family configuration specific to the Torizon distro family.
MACHINE_FIRMWARE:append:imx-generic-bsp = " \
    linux-firmware-rtl8723 \
    linux-firmware-rtl8821 \
    linux-firmware-rtl8822 \
"

# Configure the "kernel command-line protection" for Torizon OS (relevant when
# the tdx-signed class is in use).
TDX_SECBOOT_REQUIRED_BOOTARGS:imx-generic-bsp:tdx-signed = "${TOS_SECBOOT_REQUIRED_BOOTARGS}"
TDX_SECBOOT_REQUIRED_BOOTARGS:apalis-imx6:tdx-signed = "enable_wait_mode=off vmalloc=400M ${TOS_SECBOOT_REQUIRED_BOOTARGS}"
TDX_SECBOOT_REQUIRED_BOOTARGS:colibri-imx6:tdx-signed = "enable_wait_mode=off galcore.contiguousSize=50331648 ${TOS_SECBOOT_REQUIRED_BOOTARGS}"
TDX_SECBOOT_REQUIRED_BOOTARGS:colibri-imx6ull-emmc:tdx-signed = "user_debug=30 ${TOS_SECBOOT_REQUIRED_BOOTARGS}"
TDX_SECBOOT_REQUIRED_BOOTARGS:apalis-imx8:tdx-signed = "pci=nomsi ${TOS_SECBOOT_REQUIRED_BOOTARGS}"
TDX_SECBOOT_REQUIRED_BOOTARGS:verdin-am62:tdx-signed = ""
TDX_SECBOOT_REQUIRED_BOOTARGS:qemuarm64:tdx-signed = ""

# Compatibility with Toradex BSP layers
BBMASK += " \
    /meta-toradex-bsp-common/recipes-core/systemd/systemd_%.bbappend \
"
