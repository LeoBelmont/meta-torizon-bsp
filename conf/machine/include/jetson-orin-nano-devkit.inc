require tegra-torizon.inc

IMAGE_INSTALL:append:tegra = " nvidia-torizon-runtime nvidia-drm-loadconf"

IMAGE_INSTALL:remove:pn-torizon-minimal = " nvidia-torizon-runtime"
