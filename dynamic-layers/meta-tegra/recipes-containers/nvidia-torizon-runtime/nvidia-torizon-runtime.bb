SUMMARY = "On-demand NVIDIA container runtime for Docker"
DESCRIPTION = "Host-side OCI runtime registered as Docker's \"nvidia\" runtime. \
It replaces nvidia-container-toolkit in the OS image: on the first GPU \
container it pulls and starts the nvidia-l4t-driver container for this OS's \
L4T release, which exposes the L4T userspace libraries and the NVIDIA \
container toolkit to the host only while it runs, and delegates to the \
toolkit's runtime from there."

LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

COMPATIBLE_MACHINE = "(tegra)"

SRC_URI = " \
    file://nvidia-torizon-runtime.in \
    file://nvidia-l4t-driver-ctl.in \
    file://nvidia-l4t-driver-reconcile.service \
"

S = "${UNPACKDIR}"

inherit l4t_version systemd

# Repository of the nvidia-l4t-driver container images (built from the
# nvidia-l4t-driver project, one per L4T release), e.g.
# "registry.example.com/torizon/nvidia-l4t-driver". The tag is the L4T version
# of this build (meta-tegra's L4T_VERSION), so it follows meta-tegra updates:
# push an image with that tag for every L4T release the OS is built with.
NVIDIA_L4T_DRIVER_REPO ??= "lbornia/nvidia-l4t-driver"
NVIDIA_L4T_DRIVER_TAG ??= "${L4T_VERSION}"
NVIDIA_L4T_DRIVER_IMAGE ??= "${@'${NVIDIA_L4T_DRIVER_REPO}:${NVIDIA_L4T_DRIVER_TAG}' if d.getVar('NVIDIA_L4T_DRIVER_REPO') else ''}"

# Optionally ship the driver container image in the OS, e.g. for devices
# without internet access: the runtime then loads it from
# ${datadir}/nvidia-l4t-driver/nvidia-l4t-driver-${NVIDIA_L4T_DRIVER_TAG}.tar
# instead of downloading it (named after the tag, so that the runtime never
# loads an archive of another L4T release). Set the URI of
# a `docker save` archive of ${NVIDIA_L4T_DRIVER_IMAGE} (its layers are
# already compressed), e.g. made with
#   docker save lbornia/nvidia-l4t-driver:39.2.1 -o nvidia-l4t-driver-39.2.1.tar
# and its sha256 (not needed for file:// URIs). Since it is part of the OS, an
# OS update (online or offline, e.g. Lockbox) brings the driver container
# matching its L4T release along. Adds about 330 MB to the OS image.
NVIDIA_L4T_DRIVER_BUNDLE_URI ??= ""
NVIDIA_L4T_DRIVER_BUNDLE_SHA256 ??= ""
BUNDLE_FILE = "nvidia-l4t-driver-${NVIDIA_L4T_DRIVER_TAG}.bundle"
SRC_URI += "${@'${NVIDIA_L4T_DRIVER_BUNDLE_URI};name=bundle;downloadfilename=${BUNDLE_FILE};unpack=0' if d.getVar('NVIDIA_L4T_DRIVER_BUNDLE_URI') else ''}"
SRC_URI[bundle.sha256sum] = "${NVIDIA_L4T_DRIVER_BUNDLE_SHA256}"

do_configure[noexec] = "1"
do_compile[noexec] = "1"

do_install() {
    if [ -z "${NVIDIA_L4T_DRIVER_IMAGE}" ]; then
        bbwarn "NVIDIA_L4T_DRIVER_REPO is not set: GPU containers will fail until the driver container is started by other means"
    fi
    if [ -n "${NVIDIA_L4T_DRIVER_BUNDLE_URI}" ]; then
        install -D -m 0644 ${DL_DIR}/${BUNDLE_FILE} \
            ${D}${datadir}/nvidia-l4t-driver/nvidia-l4t-driver-${NVIDIA_L4T_DRIVER_TAG}.tar
    fi
    install -D -m 0755 ${S}/nvidia-torizon-runtime.in ${D}${bindir}/nvidia-torizon-runtime
    install -d ${D}${sbindir}
    sed -e 's|@NVIDIA_L4T_DRIVER_IMAGE@|${NVIDIA_L4T_DRIVER_IMAGE}|g' \
        ${S}/nvidia-l4t-driver-ctl.in > ${D}${sbindir}/nvidia-l4t-driver-ctl
    chmod 0755 ${D}${sbindir}/nvidia-l4t-driver-ctl
    install -D -m 0644 ${S}/nvidia-l4t-driver-reconcile.service \
        ${D}${systemd_system_unitdir}/nvidia-l4t-driver-reconcile.service
}

SYSTEMD_SERVICE:${PN} = "nvidia-l4t-driver-reconcile.service"

# nvidia-l4t-driver-ctl and the runtime rely on flock, logger, umount,
# timeout and stty. /etc/nv_tegra_release is no longer used by the runtime
# (GPU containers get the driver container's copy) but host tools use it to
# identify the L4T release, and nvidia-container-toolkit used to pull it in.
RDEPENDS:${PN} = " \
    coreutils \
    nv-tegra-release \
    util-linux-flock \
    util-linux-logger \
    util-linux-umount \
"

# the bundled driver container image, if any, comes along with the runtime
PACKAGES =+ "${PN}-bundle"
FILES:${PN}-bundle = "${datadir}/nvidia-l4t-driver"
ALLOW_EMPTY:${PN}-bundle = "1"
RDEPENDS:${PN} += "${@'${PN}-bundle' if d.getVar('NVIDIA_L4T_DRIVER_BUNDLE_URI') else ''}"

PACKAGE_ARCH:tegra = "${TEGRA_PKGARCH}"
