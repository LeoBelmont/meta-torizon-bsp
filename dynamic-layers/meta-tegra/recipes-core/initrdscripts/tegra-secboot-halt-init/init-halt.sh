#!/bin/sh
# init of the image in the kernel partition of signed Torizon OS images.
#
# Signed images only boot through the signed UKI of an OSTree deployment,
# which verifies the root filesystem. L4TLauncher can still be told to boot
# the kernel partition (bootmode=bootimg), so the image there must not boot
# the root filesystem, nor offer a shell: say so and stop.
PATH=/sbin:/bin:/usr/sbin:/usr/bin
mount -t proc proc -o nosuid,nodev,noexec /proc
mount -t devtmpfs none -o nosuid /dev
mount -t sysfs sysfs -o nosuid,nodev,noexec /sys

while true; do
    echo "Torizon OS: the kernel partition does not boot a signed image." > /dev/console
    echo "Boot through the Torizon boot mode of the UEFI boot loader. System halted." > /dev/console
    sleep 60
done
