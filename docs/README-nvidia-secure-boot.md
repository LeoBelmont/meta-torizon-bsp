Secure Boot on NVIDIA Jetson
============================

> [!WARNING]
> Draft: validated in QEMU up to the login prompt (see "Test status"), not yet on a Jetson. Do not fuse production devices with it.

Torizon OS enables Secure Boot on Jetson the same way as on the Toradex SoMs, with the `torizon-signed` class. On Jetson, the class uses UEFI Secure Boot with a signed Unified Kernel Image (UKI), like the x86 support, and composefs to verify the root filesystem.

Chain of trust
--------------

| Stage | Verified by | Key |
| :---- | :---------- | :-- |
| Tegra boot chain (MB1, MB2, UEFI firmware...) | BootROM, once the keys are fused | PKC (and SBK) |
| UEFI Secure Boot keys | enrolled from `UefiDefaultSecurityKeys.dtbo` at the first boot, while the firmware is in setup mode | PK, KEK, db |
| L4TLauncher (`BOOTAA64.efi`) | UEFI firmware | db |
| UKI: kernel, initramfs, kernel command line | UEFI firmware, through `LoadImage()` in L4TLauncher | db |
| Devicetree | part of the boot chain: the UEFI firmware image carries it, and the UKI boots with the firmware's devicetree | PKC |
| OSTree deployment (root filesystem) | composefs in the initramfs (`cfs-signed`) | composefs keys |
| Kernel modules | kernel (`CONFIG_MODULE_SIG_FORCE`) | module signing key |

The kernel runs in lockdown integrity mode.

`uEnv.txt` is not signed: OSTree writes it on the device at every deployment. With Secure Boot, L4TLauncher only takes from it which UKI to boot, and the initramfs only takes which OSTree deployment to mount (`ostree=`), which composefs then verifies. A rollback picks another signed UKI and deployment the same way.

When the Torizon boot fails, L4TLauncher does not fall back to the kernel partition as it does on unsigned images, and while an update is being tried it resets instead, so that the boot counter runs out and the previous deployment is booted. The kernel partition itself gets an image that only prints a message and stops (`tegra-secboot-halt-initramfs`), instead of the meta-tegra one, which boots the root filesystem without verifying it.

composefs verifies the root filesystem in two ways. The composefs image of the deployment must have the fs-verity digest recorded in the signed OSTree commit, or the deployment is not mounted and the boot stops. The content of the files is verified by fs-verity when it is read: a block changed behind the filesystem gives an I/O error instead of the changed data, so such a system may still boot, without the affected files.

The devicetree is only verified on fused devices: without the boot chain keys fused, nothing checks the UEFI firmware image that carries it.

Keys
----

Create a key set with:

```
$ meta-torizon-bsp/scripts/tools/tegra-secboot-genkeys.sh <keydir>
```

This creates the UEFI keys (`uefi/`) and the kernel module signing key (`modsign/`). With `--bootchain`, it also creates the boot chain keys (`bootchain/pkc.pem` and `bootchain/sbk.key`), which only take effect once fused.

The composefs keys are generated at build time by default (`CFS_GENERATE_KEYS`), as on the other machines.

Build
-----

Add to `conf/local.conf`:

```
INHERIT += "torizon-signed"
TEGRA_SECBOOT_KEYDIR = "/path/to/keydir"
```

This makes `torizon-signed` inherit `tegra-torizon-signed` (meta-torizon-bsp) instead of `tdx-signed` (meta-toradex-security). The build:

- signs L4TLauncher and the kernel with db (meta-tegra, `TEGRA_UEFI_DB_KEY`/`TEGRA_UEFI_DB_CERT`), and flashes `UefiDefaultSecurityKeys.dtbo` with the PK, KEK and db certificates;
- builds a UKI with the kernel, the initramfs and the kernel command line (`OSTREE_KERNEL_ARGS`), signed with db, and puts it in the OSTree commit as the kernel;
- adds `uki=1` to `uEnv.txt`, so L4TLauncher boots the UKI before the keys are enrolled too;
- signs the kernel modules and the out-of-tree ones (`nvidia-kernel-oot`), and builds the kernel with lockdown;
- enables composefs in signed mode.

Keep the key directory. Once the keys are enrolled, the device only boots images signed with them, and that includes the flashing image that `initrd-flash` boots over USB: L4TLauncher verifies it when Secure Boot is enabled. So a device with enrolled keys is reflashed with a package signed with the same keys.

A full flash erases the whole QSPI flash, UEFI variables included, so the device comes back in setup mode and enrolls the keys of the package just flashed at its next boot. To flash an unsigned image, or one signed with other keys, first turn Secure Boot off in the UEFI setup menu (ESC at boot on the serial console, then Device Manager, Secure Boot Configuration), or rewrite the QSPI flash with NVIDIA's `flash.sh`.

The UEFI firmware only creates the default key variables when they do not exist. An update of the firmware alone (e.g. a capsule) therefore does not change the enrolled keys.

Flash the `.tegraflash-tar.zst` package with `initrd-flash` as described in [README-nvidia.md](README-nvidia.md). At the first boot, the UEFI firmware enrolls the keys and enables Secure Boot. Check on the device:

```
# od -An -tx1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c
 06 00 00 00 01
# cat /sys/kernel/security/lockdown
none [integrity] confidentiality
# cat /run/ostree/cmdline-extra
ostree=/ostree/boot.1/torizon/<checksum>/0
```

The last byte of `SecureBoot` is `01` with Secure Boot enabled.

Boot chain signing and fusing
-----------------------------

UEFI Secure Boot alone does not protect the boot chain before UEFI: on a device without fused keys, anyone with access to the recovery port can flash another UEFI firmware. Fusing the PKC key (and optionally the SBK key) closes that, and is **irreversible**: a device fused with a key only boots images signed with it, and a mistake bricks it.

1. Fuse the keys following NVIDIA's [Secure Boot](https://docs.nvidia.com/jetson/archives/r38.2/DeveloperGuide/SD/Security/SecureBoot.html) documentation (`odmfuse.sh` of the L4T kit). Test the procedure on a device you can afford to lose first.
2. Build with the boot chain signed: `TEGRA_SECBOOT_BOOTCHAIN = "1"` (and `TEGRA_SECBOOT_BOOTCHAIN_SBK = "1"` if the SBK is fused). meta-tegra then signs the boot chain (`TEGRA_SIGNING_ARGS`) in the flash package and in the bootloader update payloads.

Key sets
--------

A key set is one directory, as created by `tegra-secboot-genkeys.sh`: use a separate one for development, for test units, and for production, and select it with `TEGRA_SECBOOT_KEYDIR` (and `CFS_SIGN_KEYDIR` for the composefs keys). A device enrolled with one set only boots, and is only reflashed with, images signed with that set. Production keys are created and kept by whoever owns the product; the development keys this script creates are for engineering units only.

Test status
-----------

Verified on the built images, and by booting the signed image in QEMU (`virt` machine, UEFI firmware with the image's PK, KEK and db enrolled):

- the firmware boots the signed UKI, and refuses a UKI with one bit changed and an unsigned kernel;
- with Secure Boot, a kernel command line passed to the UKI is ignored;
- the kernel is locked down, loads the signed modules and refuses an unsigned one;
- the initramfs takes the deployment from the `TorizonBootArgs` variable, and stops when the variable is missing or does not name an OSTree boot link;
- composefs mounts the deployment in `signed` mode, refuses a replaced composefs image, and fs-verity reports a block changed behind the filesystem;
- the system reaches the login prompt, and `ostree admin status` shows the booted deployment.

Still to be verified on a Jetson: the enrollment of the keys by the NVIDIA firmware, L4TLauncher booting the UKI (and not falling back), the NVIDIA drivers and tools with lockdown, updates and rollback, and reflashing with Secure Boot enabled.

Limitations and open points
---------------------------

- **Not validated on a Jetson**, in particular:
  - the L4TLauncher change (`0002-L4TLauncher-boot-signed-UKIs-in-the-Torizon-boot-mode.patch`) builds, but has not booted yet;
  - `UefiDefaultSecurityKeys.dts` is written from what the firmware reads (`NvSecureBootProvisionDxe` and `DefaultVariableDxe` in edk2-nvidia), not yet compared with the output of `gen_uefi_keys_dts.sh` of the L4T kit.
- **Kernel arguments from the firmware**: with a UKI, the arguments the UEFI firmware appends are dropped, as the command line is fixed. On the Orin Nano these are `video=efifb:off`, which `KERNEL_ARGS` has already, the boot profiler and debug data pointers (`bl_prof_dataptr`, `bl_prof_ro_ptr`, `bl_debug_data`), and the `KernelCommandLine` variable of the setup menu. Compare `/proc/cmdline` with an unsigned image to confirm.
- **Lockdown**: integrity mode blocks e.g. `/dev/mem`, unsigned kexec and parts of debugfs. Check the NVIDIA tools in use (`nvpmodel`, `jetson_clocks`, ...).
- **UEFI setup menu and shell**: they are part of the firmware and not disabled yet. From the setup menu, Secure Boot can be turned off by someone with access to the console.
- **Other db-signed images**: with Secure Boot, L4TLauncher boots any image signed with db that `uEnv.txt` points to, not only a UKI. meta-tegra also signs the plain kernel with db; it gets no initramfs and no command line from `uEnv.txt`, so it should stop without a root filesystem: to be confirmed on hardware.
- **Rollback of a failed update**: when the UKI of a new deployment does not load, L4TLauncher resets instead of falling back to the kernel partition, so that the boot counting of the Torizon boot mode rolls back. To be confirmed on hardware.
- **Kernel options for composefs**: added for the Jetson kernel by this change (`composefs.cfg`, `composefs-fsverity.cfg`); composefs has not run on Jetson before.
- **Image size**: signed images use composefs, for which the resize helper is off, so the root filesystem image has the size of the whole partition (about 28 GiB, sparse).
- **UEFI key updates over the air** (db/dbx), as the x86 support does with Torizon subsystem updates, are not supported yet.
- **Unsigned staging drivers**: the Ubuntu based kernel does not sign the staging drivers that are not in its `debian/signature-inclusion` list, so they cannot be loaded (`meson-vdec` in the current image). The build accepts unsigned modules only there (`TEGRA_MODSIGN_UNSIGNED_OK`) and stops on any other.
- **The module signing key in the build**: `modsign_key.pem`, with the private key, is copied to the kernel build directories and ends up in their sstate. `kernel-devsrc` does not package it. Keep the build directory and the sstate cache of production builds private.
- Only the Jetson Orin Nano is covered. Thor (T264) uses other boot chain keys.
