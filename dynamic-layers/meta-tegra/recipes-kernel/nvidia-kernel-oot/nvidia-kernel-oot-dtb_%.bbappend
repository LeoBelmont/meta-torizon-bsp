do_deploy:append() {
    for dtb in ${KERNEL_DEVICETREE}; do
        dtbf="${DEPLOYDIR}/devicetree/$dtb"
        if [ ! -f "$dtbf" ]; then
            bbfatal "Not found: $dtbf"
        fi
    done
    install -m 0644 ${DEPLOYDIR}/devicetree/*.dtb ${DEPLOYDIR}/
}
