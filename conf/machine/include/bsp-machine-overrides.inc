# Machine / SoC-family distro-config overrides shared by Torizon distro
# families.
IMX_DEFAULT_BSP = "nxp"
IMX_DEFAULT_BSP:upstream = "mainline"

IMAGE_BOOT_FILES_REMOVE:append:apalis-imx8 = " hdmitxfw.bin dpfw.bin"
IMAGE_CLASSES:append = " torizon-image-machine"

DISTRO_FEATURES_REMOVE:remove:verdin-imx95 = "vulkan"
DISTRO_FEATURES_REMOVE:remove:toradex-smarc-imx95 = "vulkan"
DISTRO_FEATURES_REMOVE:append:imx-generic-bsp = " opengl"

# No need for x11 even for native
DISTRO_FEATURES_NATIVE:remove:imx-generic-bsp = "x11"
DISTRO_FEATURES_NATIVESDK:remove:imx-generic-bsp = "x11"

TOS_SECBOOT_REQUIRED_BOOTARGS_DEFAULT:qemuarm64 ?= ""

# Cross machines / BSPs
## Drop IMX BSP that is not needed
MACHINE_EXTRA_RRECOMMENDS:remove:imx = "imx-alsa-plugins"

# Compatibility with Toradex BSP layers
BBMASK += " \
    /meta-freescale/recipes-graphics/cairo \
"

# Load Torizon-only BSP metadata after torizon.inc selects its distro family.
require ${@'bsp-machine-overrides-torizon.inc' if 'torizon-distro' in d.getVar('DISTROOVERRIDES').split(':') else ''}

# Common Torizon currently has no family-specific BSP overrides. Add a conditional require for bsp-machine-overrides-common-torizon.inc when needed.
# require ${@'bsp-machine-overrides-common-torizon.inc' if 'common-torizon-distro' in d.getVar('DISTROOVERRIDES').split(':') else ''}
