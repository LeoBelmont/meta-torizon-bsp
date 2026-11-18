FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# 0002 boots signed UKIs in the Torizon boot mode: with UEFI Secure Boot
# enabled (torizon-signed), or with "uki=1" in uEnv.txt. Without either,
# the Torizon boot is unchanged.
SRC_URI += "\
    file://0001-Implement-support-for-the-Torizon-boot.patch;patchdir=../edk2-nvidia \
    file://0002-L4TLauncher-boot-signed-UKIs-in-the-Torizon-boot-mode.patch;patchdir=../edk2-nvidia \
"
