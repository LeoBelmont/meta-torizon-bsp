# UEFI Secure Boot for NVIDIA Jetson machines
#
# Inherited by torizon-signed (meta-torizon) on Jetson machines, so it is
# enabled like on the Toradex SoMs, with INHERIT += "torizon-signed".
#
# Chain of trust:
#
#   Tegra boot chain       signed with the PKC key (and encrypted with the SBK
#                          key) fused in the SoC (TEGRA_SECBOOT_BOOTCHAIN)
#   UEFI firmware          enrolls the PK, KEK and db keys at the first boot
#   L4TLauncher            signed with db; its Torizon boot mode boots the UKI
#                          of the deployment chosen in uEnv.txt, with no
#                          fallback to the kernel partition
#   UKI                    kernel, initramfs and command line, signed with db
#   OSTree deployment      verified by composefs (cfs-signed, which
#                          torizon-signed inherits) against the commit
#                          signature
#   kernel modules         signed, and unsigned ones rejected
#   trusted applications   OP-TEE only loads the ones signed with the key of
#                          the key set
#   firmware updates       capsules authenticated with the certificates of
#                          the key set
#
# See docs/README-nvidia-secure-boot.md.

DISTROOVERRIDES .= ":ostree-uki:tegra-signed"

# Key directory, see scripts/tools/tegra-secboot-genkeys.sh for the layout
TEGRA_SECBOOT_KEYDIR ?= "${TOPDIR}/keys/tegra"

# UEFI Secure Boot keys: PK.crt, KEK.crt and db.crt with db.key. With
# TEGRA_UEFI_DB_KEY and TEGRA_UEFI_DB_CERT set, meta-tegra signs L4TLauncher
# and the kernel, and flashes UefiDefaultSecurityKeys.dtbo, from which the
# UEFI firmware enrolls the keys (see tegra-uefi-keys-dtb.bbappend).
TEGRA_UEFI_KEYDIR ?= "${TEGRA_SECBOOT_KEYDIR}/uefi"
TEGRA_UEFI_DB_KEY = "${TEGRA_UEFI_KEYDIR}/db.key"
TEGRA_UEFI_DB_CERT = "${TEGRA_UEFI_KEYDIR}/db.crt"

# Unified Kernel Image with the kernel, the initramfs and the command line,
# signed with db. meta-updater puts it in the OSTree commit as the kernel
# (vmlinuz). The devicetree is the one of the boot chain, as L4TLauncher
# ignores the uEnv.txt one for a UKI: do not deploy any.
IMAGE_CLASSES:append = " uki"
# Only the Torizon OS images get a UKI, not the other images of the build
IMAGE_CLASSES:remove:pn-tegra-minimal-initramfs = "uki"
IMAGE_CLASSES:remove:pn-tegra-initrd-flash-initramfs = "uki"
IMAGE_CLASSES:remove:pn-tegra-espimage = "uki"
IMAGE_CLASSES:remove:pn-tegra-secboot-halt-initramfs = "uki"
# ukify signs with sbsign: a task depending on a do_populate_sysroot gets it
# in its recipe sysroot (staging.bbclass), as the meta-tegra signing tasks do
do_uki[depends] += "sbsigntool-native:do_populate_sysroot"
# One UKI per image: do_uki writes it straight to DEPLOY_DIR_IMAGE
UKI_FILENAME = "${IMAGE_BASENAME}-${MACHINE}.efi"
UKI_CMDLINE = "${OSTREE_KERNEL_ARGS}"
UKI_DEVICETREE = ""
UKI_SB_KEY = "${TEGRA_UEFI_DB_KEY}"
UKI_SB_CERT = "${TEGRA_UEFI_DB_CERT}"
# As an override: torizon.bbclass is inherited after this class and sets it
OSTREE_DEPLOY_DEVICETREE:tegra-signed = "0"

# The kernel partition, which L4TLauncher boots when told to
# (bootmode=bootimg), gets an image that stops instead of the meta-tegra
# one: that one boots the root filesystem without verifying it, and has a
# shell on failure.
IMAGE_TEGRAFLASH_KERNEL:tegra-signed = "${DEPLOY_DIR_IMAGE}/tegra-secboot-halt-initramfs-${MACHINE}.cboot"
do_image_tegraflash_tar[depends] += "tegra-secboot-halt-initramfs:do_image_complete"

# Key for signing the kernel modules: a PEM file with the private key and
# the certificate. The kernel embeds the certificate and, with
# CONFIG_MODULE_SIG_FORCE, rejects unsigned modules, out-of-tree ones too.
TEGRA_MODSIGN_KEY ?= "${TEGRA_SECBOOT_KEYDIR}/modsign/modsign_key.pem"

# Fail the build when an image has a module without a signature, which the
# kernel would refuse to load. The Ubuntu based kernel leaves the staging
# drivers that are not in its debian/signature-inclusion list unsigned on
# purpose: TEGRA_MODSIGN_UNSIGNED_OK lists the directories, relative to the
# modules directory of the kernel, where unsigned modules are accepted.
TEGRA_MODSIGN_UNSIGNED_OK ?= "kernel/drivers/staging/"

tegra_signed_check_modules() {
    unsigned=""
    for ko in $(find ${IMAGE_ROOTFS}${nonarch_base_libdir}/modules -name '*.ko' 2>/dev/null); do
        if tail -c 28 "$ko" | grep -aq 'Module signature appended'; then
            continue
        fi
        rel="${ko#${IMAGE_ROOTFS}${nonarch_base_libdir}/modules/*/}"
        accepted=""
        for dir in ${TEGRA_MODSIGN_UNSIGNED_OK}; do
            case "$rel" in
                "$dir"*) accepted="1" ;;
            esac
        done
        if [ -n "$accepted" ]; then
            bbnote "Unsigned module accepted (TEGRA_MODSIGN_UNSIGNED_OK): $rel"
        else
            unsigned="$unsigned $rel"
        fi
    done
    if [ -n "$unsigned" ]; then
        bbfatal "Kernel modules without a signature, which the kernel would refuse to load:$unsigned"
    fi
}
ROOTFS_POSTPROCESS_COMMAND:append = " tegra_signed_check_modules"

# OP-TEE is built with the public part of this key, and only loads trusted
# applications signed with it. Without it, OP-TEE trusts its default key,
# whose private part is in the OP-TEE sources.
TEGRA_OPTEE_TA_SIGN_KEY ?= "${TEGRA_SECBOOT_KEYDIR}/optee/ta_sign_key.pem"
# Set to a public key (PEM) to make OP-TEE verify the trusted applications
# with it instead: for an owner who signs them elsewhere and keeps the
# private key. Trusted applications signed by this build then do not load.
TEGRA_OPTEE_TA_PUBLIC_KEY ?= ""

# Firmware update capsules (tegra-uefi-capsules): signed with signer.pem,
# which sub.crt and root.crt certify. The UEFI firmware authenticates them
# with root.crt (see edk2-firmware-tegra_%.bbappend), instead of the EDK2
# test certificates that meta-tegra uses, whose private keys are public.
TEGRA_UEFI_CAPSULE_KEYDIR ?= "${TEGRA_SECBOOT_KEYDIR}/capsule"
UEFI_CAPSULE_SIGNER_PRIVATE_CERT ?= "${TEGRA_UEFI_CAPSULE_KEYDIR}/signer.pem"
UEFI_CAPSULE_OTHER_PUBLIC_CERT ?= "${TEGRA_UEFI_CAPSULE_KEYDIR}/sub.crt"
UEFI_CAPSULE_TRUSTED_PUBLIC_CERT ?= "${TEGRA_UEFI_CAPSULE_KEYDIR}/root.crt"
# The capsule carries the image of the kernel partition
TEGRA_UEFI_CAPSULE_SIGNING_EXTRA_DEPS:append = " tegra-secboot-halt-initramfs:do_image_complete"

# Set to "0" to build the UEFI firmware without its setup menu, boot menu
# and shell, for production devices.
TEGRA_SECBOOT_UEFI_MENU ?= "1"

# tegra-secboot-check, to check on the device that it booted as intended
IMAGE_INSTALL:append = " tegra-secboot-check"

# Kernel lockdown in integrity mode. Set to "0" if it gets in the way of
# NVIDIA tools that need /dev/mem or debugfs, while that is investigated.
TEGRA_SECBOOT_LOCKDOWN ?= "1"

# Tegra boot chain signing, for devices with the PKC (and optionally SBK)
# keys fused. Off by default: a device without fused keys boots unsigned
# boot chain images, and fusing is irreversible (see the README).
TEGRA_SECBOOT_BOOTCHAIN ?= "0"
TEGRA_SECBOOT_BOOTCHAIN_SBK ?= "0"
TEGRA_SIGNING_PKC = "${@'${TEGRA_SECBOOT_KEYDIR}/bootchain/pkc.pem' if d.getVar('TEGRA_SECBOOT_BOOTCHAIN') == '1' else ''}"
TEGRA_SIGNING_SBK = "${@'${TEGRA_SECBOOT_KEYDIR}/bootchain/sbk.key' if d.getVar('TEGRA_SECBOOT_BOOTCHAIN') == '1' and d.getVar('TEGRA_SECBOOT_BOOTCHAIN_SBK') == '1' else ''}"

python tegra_torizon_signed_check_keys() {
    import os

    keys = [
        d.getVar('TEGRA_UEFI_DB_KEY'),
        d.getVar('TEGRA_UEFI_DB_CERT'),
        os.path.join(d.getVar('TEGRA_UEFI_KEYDIR'), 'PK.crt'),
        os.path.join(d.getVar('TEGRA_UEFI_KEYDIR'), 'KEK.crt'),
        d.getVar('TEGRA_MODSIGN_KEY'),
        d.getVar('TEGRA_OPTEE_TA_SIGN_KEY'),
        d.getVar('UEFI_CAPSULE_SIGNER_PRIVATE_CERT'),
        d.getVar('UEFI_CAPSULE_OTHER_PUBLIC_CERT'),
        d.getVar('UEFI_CAPSULE_TRUSTED_PUBLIC_CERT'),
    ]
    if d.getVar('TEGRA_OPTEE_TA_PUBLIC_KEY'):
        keys.append(d.getVar('TEGRA_OPTEE_TA_PUBLIC_KEY'))
    missing = [k for k in keys if not os.path.exists(k)]
    if missing:
        bb.fatal("torizon-signed: missing Jetson Secure Boot keys: %s. Create them "
                 "with meta-torizon-bsp/scripts/tools/tegra-secboot-genkeys.sh, which "
                 "keeps the keys a key directory has already, or set "
                 "TEGRA_SECBOOT_KEYDIR (see docs/README-nvidia-secure-boot.md)."
                 % ' '.join(missing))
}

addhandler tegra_torizon_signed_check_keys
tegra_torizon_signed_check_keys[eventmask] = "bb.event.SanityCheck"
