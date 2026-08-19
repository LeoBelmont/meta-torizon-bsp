FILESEXTRAPATHS:prepend := "${THISDIR}/${BPN}:"

SRC_URI:append:genericx86-64 = " file://0001-rules-whitelist-hd-devices.patch"
