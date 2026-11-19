# torizon-signed with TEGRA_SECBOOT_KERNEL_DTB = "1": put the devicetrees in
# the OSTree commit, each with a detached signature (<file>.sig) made with
# the db key, the way tegra_uefi_split_sign of meta-tegra makes one.
# L4TLauncher loads the devicetree of the deployment and verifies that
# signature when UEFI Secure Boot is enabled.
#
# With a UKI, meta-updater does not install the devicetrees itself.
TEGRA_SECBOOT_KERNEL_DTB ??= "0"

do_install:append:tegra-signed() {
    if [ "${TEGRA_SECBOOT_KERNEL_DTB}" = "1" ]; then
        if [ -z "${OSTREE_DEVICETREE}" ]; then
            bbfatal "TEGRA_SECBOOT_KERNEL_DTB is set, but OSTREE_DEVICETREE is empty"
        fi
        signed_dtb_dir=${D}${KERNEL_BUILD_ROOT}$(cat ${DEPLOY_DIR_IMAGE}/kernel-abiversion)/dtb
        install -d $signed_dtb_dir
        for dts_file in ${OSTREE_DEVICETREE}; do
            dtb=$(basename $dts_file)
            install -m 0644 ${DEPLOY_DIR_IMAGE}/$dtb $signed_dtb_dir/$dtb
            openssl cms -sign -signer "${TEGRA_UEFI_DB_CERT}" -inkey "${TEGRA_UEFI_DB_KEY}" \
                -binary -in $signed_dtb_dir/$dtb -outform der -out $signed_dtb_dir/$dtb.sig
            if [ ! -s $signed_dtb_dir/$dtb.sig ]; then
                bbfatal "No signature was created for $dtb"
            fi
        done
    fi
}

SIGNED_DTB_ENABLED = "${@'1' if 'tegra-signed' in (d.getVar('OVERRIDES') or '').split(':') and d.getVar('TEGRA_SECBOOT_KERNEL_DTB') == '1' else ''}"
do_install[depends] += "${@'openssl-native:do_populate_sysroot' if d.getVar('SIGNED_DTB_ENABLED') else ''}"
do_install[file-checksums] += "${@'${TEGRA_UEFI_DB_KEY}:True ${TEGRA_UEFI_DB_CERT}:True' if d.getVar('SIGNED_DTB_ENABLED') else ''}"
