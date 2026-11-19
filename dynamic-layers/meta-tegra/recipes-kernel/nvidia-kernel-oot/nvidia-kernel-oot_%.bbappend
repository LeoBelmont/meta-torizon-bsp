# Signed images (torizon-signed): the modules are signed when they are
# installed, with the key the kernel recipe puts in STAGING_KERNEL_BUILDDIR.
# Strip their debug information before that, as packaging leaves signed
# modules as they are.
EXTRA_OEMAKE:append:tegra-signed = " INSTALL_MOD_STRIP=1"
