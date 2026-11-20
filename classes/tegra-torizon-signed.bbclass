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
# The kernel is built with the same command line and takes no other
# (CONFIG_CMDLINE_FORCE, see linux-noble-nvidia-tegra%.bbappend): its image
# is signed with db on its own, and must not be usable with other arguments.
TEGRA_SECBOOT_KERNEL_CMDLINE ?= "${OSTREE_KERNEL_ARGS}"
TEGRA_SECBOOT_FORCE_CMDLINE ?= "1"
UKI_CMDLINE = "${TEGRA_SECBOOT_KERNEL_CMDLINE}"
# Anti-rollback limit: the security version of the image, a whole number in
# the ".tznsv" section of the UKI. L4TLauncher refuses a UKI with a lower
# version than the highest one that was booted and confirmed on the device.
# Raise it, by hand, in the release that must not be undone: the releases
# before it then no longer boot on a device that confirmed it, not even as
# the rollback of a later update. Leave it alone otherwise.
TEGRA_SECBOOT_SECURITY_VERSION ?= "0"
UKIFY_CMD:append = " --section=.tznsv:${TEGRA_SECBOOT_SECURITY_VERSION}"
UKI_DEVICETREE = ""
UKI_SB_KEY = "${TEGRA_UEFI_DB_KEY}"
UKI_SB_CERT = "${TEGRA_UEFI_DB_CERT}"
# The UKI carries no devicetree. By default the kernel gets the one of the
# boot chain, which is only verified on a device with the boot chain keys
# fused, and which an update of the operating system does not change.
# Set to "1" to boot with the devicetree of the deployment instead: the
# build puts the devicetrees in the OSTree commit with a signature made with
# the db key (ostree-kernel-initramfs_%.bbappend), and L4TLauncher verifies
# it. The boot stops when the devicetree does not verify.
TEGRA_SECBOOT_KERNEL_DTB ?= "0"
# As an override: torizon.bbclass is inherited after this class and sets it
OSTREE_DEPLOY_DEVICETREE:tegra-signed = "${TEGRA_SECBOOT_KERNEL_DTB}"

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

# The UEFI firmware selects the images of a capsule for the board, which it
# reads from the TegraPlatformSpec and TegraPlatformCompatSpec variables.
# meta-tegra sets them at boot with setup-nv-boot-control, which Torizon OS
# leaves out of tegra-redundant-boot-base. Without them the firmware refuses
# every capsule (last attempt status 0x1807).
IMAGE_INSTALL:append = " setup-nv-boot-control-service util-linux-lsblk"

# Set to "1" to put the capsule of the build in the image, for
# tegra-secboot-capsule to install on the device, for instance after an
# update of the operating system. Nothing installs it automatically.
TEGRA_SECBOOT_CAPSULE_IN_IMAGE ?= "0"
TEGRA_UEFI_CAPSULE_INSTALL_DIR ?= "${datadir}/tegra-uefi-capsules"
IMAGE_INSTALL:append = "${@' tegra-uefi-capsules' if d.getVar('TEGRA_SECBOOT_CAPSULE_IN_IMAGE') == '1' else ''}"
# Set to "1" to have the device install that capsule: a timer runs
# "tegra-secboot-capsule auto", which hands the capsule to the firmware when
# a confirmed update brought another one than the one installed. It is then
# installed at the next reboot. This puts the capsule in the image too.
TEGRA_SECBOOT_CAPSULE_AUTO ?= "0"
IMAGE_INSTALL:append = "${@' tegra-secboot-check-capsule-auto' if d.getVar('TEGRA_SECBOOT_CAPSULE_AUTO') == '1' else ''}"

# Set to "0" to build the UEFI firmware without its setup menu, boot menu,
# shell and network boot, for production devices.
TEGRA_SECBOOT_UEFI_MENU ?= "1"

# Set to "0" for production devices: no kernel console and no login on the
# serial console. The boot firmware still prints there.
TEGRA_SECBOOT_SERIAL_CONSOLE ?= "1"
# Set to "0" for production devices: the SSH server is not started.
TEGRA_SECBOOT_SSH ?= "1"

def tegra_secboot_serial_ttys(d):
    return [c.split(';')[1] for c in (d.getVar('SERIAL_CONSOLES') or '').split() if ';' in c]

def tegra_secboot_serial_console_args(d):
    if d.getVar('TEGRA_SECBOOT_SERIAL_CONSOLE') != '0':
        return ''
    return ' '.join('console=%s,%s' % (c.split(';')[1], c.split(';')[0])
                    for c in (d.getVar('SERIAL_CONSOLES') or '').split() if ';' in c)

# KERNEL_ARGS is part of the command line of the UKI and of the kernel
KERNEL_ARGS:remove = "${@tegra_secboot_serial_console_args(d)}"

tegra_signed_interfaces() {
    # Only the images with systemd: not the initramfs images
    [ -d ${IMAGE_ROOTFS}${systemd_system_unitdir} ] || return 0
    install -d ${IMAGE_ROOTFS}${sysconfdir}/systemd/system
    if [ "${TEGRA_SECBOOT_SERIAL_CONSOLE}" = "0" ]; then
        for tty in ${@' '.join(tegra_secboot_serial_ttys(d))}; do
            ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/serial-getty@$tty.service
        done
    fi
    if [ "${TEGRA_SECBOOT_SSH}" = "0" ]; then
        for unit in sshd.socket sshd.service sshd@.service; do
            ln -sf /dev/null ${IMAGE_ROOTFS}${sysconfdir}/systemd/system/$unit
        done
    fi
    # Do not show kernel addresses, also not to root
    install -d ${IMAGE_ROOTFS}${nonarch_libdir}/sysctl.d
    echo "kernel.kptr_restrict = 2" > ${IMAGE_ROOTFS}${nonarch_libdir}/sysctl.d/60-tegra-secboot.conf
}
ROOTFS_POSTPROCESS_COMMAND:append = " tegra_signed_interfaces"

# tegra-secboot-check and tegra-secboot-capsule, to check on the device
# that it booted as intended and to install capsules
IMAGE_INSTALL:append = " tegra-secboot-check"

# Set to "1" to install NVIDIA's sample trusted application (hwkey-agent)
# and its client, nvhwkey-app: a trusted application signed with
# TEGRA_OPTEE_TA_SIGN_KEY to test that OP-TEE loads it. For test images.
TEGRA_SECBOOT_TEST_TA ?= "0"
IMAGE_INSTALL:append = "${@' optee-nvsamples-hwkey-agent' if d.getVar('TEGRA_SECBOOT_TEST_TA') == '1' else ''}"

# For test images: a health check that fails for the deployment whose checksum
# is written to /var/lib/tegra-secboot/fail-health-check, to test the rollback
# of an update that boots and is then found unhealthy
TEGRA_SECBOOT_TEST_HEALTH_CHECK ?= "0"
IMAGE_INSTALL:append = "${@' tegra-secboot-check-test-health-check' if d.getVar('TEGRA_SECBOOT_TEST_HEALTH_CHECK') == '1' else ''}"

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

# The EKB (encrypted key blob) that OP-TEE reads its keys from. Set to "1"
# for devices with the OemK1 key fused: meta-tegra then builds the EKB with
# that key, and puts the key that authenticates the UEFI variables and the
# disk encryption key of the key set in it. Off by default: a device without
# OemK1 fused cannot read such an EKB, and one with it fused cannot read the
# EKB of the L4T kit that is used otherwise.
TEGRA_SECBOOT_EKB ?= "0"
TEGRA_EKB_OEM_K1 = "${@'${TEGRA_SECBOOT_KEYDIR}/bootchain/oem_k1.key' if d.getVar('TEGRA_SECBOOT_EKB') == '1' else ''}"
TEGRA_EKB_AUTH = "${@'${TEGRA_SECBOOT_KEYDIR}/bootchain/ekb_auth.key' if d.getVar('TEGRA_SECBOOT_EKB') == '1' else ''}"
TEGRA_EKB_SYM2 = "${@'${TEGRA_SECBOOT_KEYDIR}/bootchain/ekb_sym2.key' if d.getVar('TEGRA_SECBOOT_EKB') == '1' else ''}"

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
    # The keys for fused devices, when the build is told to use them
    for var in ('TEGRA_SIGNING_PKC', 'TEGRA_SIGNING_SBK', 'TEGRA_EKB_OEM_K1', 'TEGRA_EKB_AUTH', 'TEGRA_EKB_SYM2'):
        if d.getVar(var):
            keys.append(d.getVar(var))
    secver = d.getVar('TEGRA_SECBOOT_SECURITY_VERSION') or ''
    if not secver.isdigit() or int(secver) > 0xffffffff:
        bb.fatal("torizon-signed: TEGRA_SECBOOT_SECURITY_VERSION must be a whole number "
                 "from 0 to 4294967295, not '%s'" % secver)
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
