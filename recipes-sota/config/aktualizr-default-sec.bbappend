FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append:imx-generic-bsp = " \
                                   file://fuse_actions-in.sh \
                                "

RDEPENDS:${PN}:remove:genericx86-64 = "u-boot-fw-utils"
RDEPENDS:${PN}:remove:intel-x86-common = "u-boot-fw-utils"
DEPENDS:imx-generic-bsp = "jq-native"

BL_UPDATE_SUPPORT:intel-x86-common ?= "0"

do_install:append:imx-generic-bsp () {
    sed -e 's/@@MACHINE@@/${MACHINE}/' \
        ${UNPACKDIR}/fuse_actions-in.sh > ${UNPACKDIR}/fuse_actions.sh
    install -d ${D}${bindir}
    install -m 0744 ${UNPACKDIR}/fuse_actions.sh ${D}${bindir}/fuse_actions.sh

    local machine="${MACHINE}"
    cat ${D}${libdir}/sota/secondaries.json |\
        jq '.["torizon-generic"] +=
             [{"partial_verifying": false,
               "ecu_hardware_id": "'"$machine"'-fuses",
               "full_client_dir": "/var/sota/storage/fuse",
               "ecu_private_key": "sec.private",
               "ecu_public_key": "sec.public",
               "firmware_path": "/var/sota/storage/fuse/fuse.yml",
               "target_name_path": "/var/sota/storage/fuse/target_name",
               "metadata_path": "/var/sota/storage/fuse/metadata",
               "action_handler_path": "/usr/bin/fuse_actions.sh"}]' \
        > ${UNPACKDIR}/temp.json

    install -m 0644 ${UNPACKDIR}/temp.json ${D}${libdir}/sota/secondaries.json
}

FILES:${PN}:append:imx-generic-bsp = " \
                                ${bindir}/fuse_actions.sh \
                                "
FILES:${PN}:remove:intel-x86-common = "\
    ${bindir}/bl_actions.sh \
    ${bindir}/common_actions.sh \
"
