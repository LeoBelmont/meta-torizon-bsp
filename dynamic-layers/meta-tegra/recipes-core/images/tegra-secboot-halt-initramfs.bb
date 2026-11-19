DESCRIPTION = "initramfs for the kernel partition of signed Torizon OS images: it does not boot"
LICENSE = "MIT"

# See tegra-secboot-halt-init: the image in the kernel partition must not
# boot the root filesystem without verifying it, as tegra-minimal-initramfs
# does. Modeled on that recipe.
PACKAGE_INSTALL = "tegra-secboot-halt-init busybox"

IMAGE_FEATURES = ""
IMAGE_LINGUAS = ""

COPY_LIC_MANIFEST = "0"
COPY_LIC_DIRS = "0"

COMPATIBLE_MACHINE = "(tegra)"

KERNELDEPMODDEPEND = ""

IMAGE_ROOTFS_SIZE = "8192"
IMAGE_ROOTFS_EXTRA_SPACE = "0"
IMAGE_NAME_SUFFIX = ""

FORCE_RO_REMOVE ?= "1"

inherit core-image

IMAGE_FSTYPES = "${INITRAMFS_FSTYPES}"

SSTATE_SKIP_CREATION:task-image-complete = "0"
SSTATE_SKIP_CREATION:task-image-qa = "0"
do_image_complete[vardepsexclude] += "rm_work_rootfs"
IMAGE_POSTPROCESS_COMMAND = ""

inherit nopackages

python sstate_report_unihash() {
    report_unihash = getattr(bb.parse.siggen, 'report_unihash', None)

    if report_unihash:
        ss = sstate_state_fromvars(d)
        if ss['task'] in ['image_complete','image_qa']:
            os.environ['PSEUDO_DISABLED'] = '1'
        report_unihash(os.getcwd(), ss['task'], d)
}
