# Machine-specific initramfs additions moved from the distro.
# Additional firmware needed for splash screen on DisplayPort with Aquila AM69
PACKAGE_INSTALL:append:aquila-am69 = " cadence-mhdp-fw "
