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
| OP-TEE trusted applications | OP-TEE | trusted application signing key |
| Firmware update capsules | UEFI firmware | capsule certificates |

The kernel runs in lockdown integrity mode.

The kernel image is also signed with db on its own: meta-tegra signs it, and it is inside the UKI and inside the Android boot images of the kernel partition and of the flashing tool. The UEFI firmware starts it like any signed EFI application, with whatever load options it is given. So the kernel of a signed build only takes the command line built into it (`CONFIG_CMDLINE_FORCE`, the same command line as the UKI), and its EFI stub is patched to ignore `initrd=` in the load options then. Started on its own, it has no initramfs and waits for a root device it has no driver for. `TEGRA_SECBOOT_FORCE_CMDLINE = "0"` turns this off for debugging.

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

This creates:

| Directory | Keys | Used for |
| :-------- | :--- | :------- |
| `uefi/` | `PK`, `KEK`, `db` (`.key` and `.crt`) | UEFI Secure Boot. The build signs with `db.key`; the three certificates are enrolled in the firmware. |
| `modsign/` | `modsign_key.pem` | Signing the kernel modules. |
| `optee/` | `ta_sign_key.pem` | Signing the OP-TEE trusted applications. OP-TEE is built with its public part. |
| `capsule/` | `root`, `sub` (`.key` and `.crt`), `signer.pem` | Signing the firmware update capsules. The firmware is built with `root.crt`, and the build signs with `signer.pem`. |
| `bootchain/` | `pkc.pem`, `sbk.key` | Only with `--bootchain`: signing and encrypting the Tegra boot chain. They only take effect once fused. |

The script keeps the keys that a directory has already and creates the missing ones, so run it again on an existing key directory when a newer version of the layer needs more keys. The build stops when a key is missing.

The build does not use `capsule/root.key` and `capsule/sub.key`: keep them offline.

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
- enables composefs in signed mode;
- builds OP-TEE with the trusted application key of the key set (`TEGRA_OPTEE_TA_SIGN_KEY`), instead of the default OP-TEE key, whose private part is in the OP-TEE sources;
- builds the UEFI firmware with the capsule root certificate of the key set, instead of the EDK2 test certificate that meta-tegra builds in.

Keep the key directory. Once the keys are enrolled, the device only boots images signed with them.

A full flash erases the whole QSPI flash, UEFI variables included, so the device comes back in setup mode and enrolls the keys of the package just flashed at its next boot. NVIDIA documents that Secure Boot enabled at flashing time, as here, cannot be disabled unless the device is flashed again.

UEFI Secure Boot does not protect the flashing path. `initrd-flash` boots its image over USB with a minimal firmware that does not enforce Secure Boot (its kernel logs "Secure boot disabled"), so on a device whose boot chain keys are not fused, any package can be flashed, signed or not, and the flash removes the enrolled keys. Tested on an Orin Nano: an unsigned package flashed over a device with enrolled keys, which then booted with Secure Boot off. Only the fused boot chain keys restrict what the recovery mode accepts.

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

`tegra-secboot-check` runs these checks and the rest of the chain (the UKI boot, lockdown, module signatures, composefs), and reports the state of the services that depend on the NVIDIA hardware. Signed images have it installed:

```
# tegra-secboot-check
```

On an image built before it was packaged, copy `scripts/tools/tegra-secboot-check.sh` to the device and run it with `sh` as root.

Its exit status is 1 when a Secure Boot check fails.

OP-TEE trusted applications
---------------------------

OP-TEE only loads trusted applications signed with `optee/ta_sign_key.pem`. The ones that meta-tegra builds are signed with it by the build. Build other trusted applications with the same `TA_SIGN_KEY`. Torizon OS installs none by default.

`TEGRA_SECBOOT_TEST_TA = "1"` installs NVIDIA's sample trusted application (`hwkey-agent`) and its client (`nvhwkey-app`), to test on a device that OP-TEE loads a trusted application signed with the key. It is for test images, and has not been built or run yet.

When the owner of the trusted applications signs them elsewhere and keeps the private key, set `TEGRA_OPTEE_TA_PUBLIC_KEY` to the public key (PEM). OP-TEE then verifies trusted applications with that key, and the ones this build signs with `optee/ta_sign_key.pem` do not load.

Firmware update capsules
------------------------

`bitbake tegra-uefi-capsules` builds `tegra-bl.cap`, the capsule that updates the boot chain, signed with `capsule/signer.pem`. The UEFI firmware of a signed build only accepts capsules that chain to `capsule/root.crt`. The firmware a device runs decides which certificate is trusted: a device flashed before this change still trusts the EDK2 test certificate until its firmware is replaced.

The firmware selects the images of a capsule for the board it runs on, which it reads from the `TegraPlatformSpec` and `TegraPlatformCompatSpec` variables. meta-tegra's `setup-nv-boot-control` service sets them at boot; Torizon OS leaves it out of unsigned images, and signed images install it. Without the variables the firmware refuses every capsule, with the last attempt status 0x1807.

Torizon OS does not deliver capsules with its updates yet. To install one on a device, as root:

```
# tegra-secboot-capsule install /path/to/tegra-bl.cap
# reboot
# tegra-secboot-capsule status
```

`install` copies the capsule to the EFI system partition and sets `OsIndications`, as the "manually trigger the capsule update" procedure of NVIDIA's [Bootloader update](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/Bootloader/UpdateAndRedundancy.html) documentation does. After the reboot, `status` shows "Capsule update status: 1" and the other boot chain as the current one. `TEGRA_SECBOOT_CAPSULE_IN_IMAGE = "1"` puts the capsule of the build in the image, in `/usr/share/tegra-uefi-capsules`, where `install` takes it from when no file is given: an update of the operating system then brings the capsule, and installing it stays a separate step. A boot firmware update is not undone when the operating system rolls back.

Changing the enrolled keys
--------------------------

The KEK, `db` and `dbx` of a device can be changed with signed updates, the way NVIDIA documents it: the updates travel in a firmware update capsule, and the firmware applies them when it installs the capsule.

1. Create the signed updates with `sign-efi-sig-list` of efitools: a KEK update is signed with the PK, a `db` or `dbx` update with the KEK.
2. Put them in `<keydir>/uefi/update/` as `KEK_<n>.auth`, `db_<n>.auth` and `dbx_<n>.auth`.
3. Build the capsule: `bitbake tegra-uefi-capsules`. The build writes `UefiUpdateSecurityKeys.dtbo` and meta-tegra adds it to the capsule.

Revoking a boot image means adding its hash, or the certificate that signed it, to `dbx`.

The build writes the same overlay as `gen_uefi_keys_dts.sh` of the L4T kit, byte for byte, for the same inputs. No key update has been applied on a device yet.

Production devices
------------------

`TEGRA_SECBOOT_UEFI_MENU = "0"` builds the UEFI firmware without its setup menu, boot menu, shell and network boot (HTTP, PXE), and with no boot delay. Leave it at its default while developing: the menu shows the Secure Boot state.

Two more settings are for production devices, and are also on by default: `TEGRA_SECBOOT_SERIAL_CONSOLE = "0"` takes the serial console off the kernel command line and disables the login on it (the boot firmware still prints there), and `TEGRA_SECBOOT_SSH = "0"` keeps the SSH server from starting. Signed images set `kernel.kptr_restrict = 2`.

The firmware of the development kits is already configured (`CONFIG_SECURITY_DISABLE_PHYSICAL_PRESENCE_POST_SECUREBOOT`) to refuse changes to the Secure Boot state and keys from the menu once Secure Boot is enabled.

Boot chain signing and fusing
-----------------------------

UEFI Secure Boot alone does not protect the boot chain before UEFI: on a device without fused keys, anyone with access to the recovery port can flash another UEFI firmware. Fusing the PKC key (and optionally the SBK key) closes that, and is **irreversible**: a device fused with a key only boots images signed with it, and a mistake bricks it.

1. Fuse the keys following NVIDIA's [Secure Boot](https://docs.nvidia.com/jetson/archives/r39.2.1/DeveloperGuide/SD/Security/SecureBoot.html) documentation (`odmfuse.sh` of the L4T kit). Test the procedure on a device you can afford to lose first.
2. Build with the boot chain signed: `TEGRA_SECBOOT_BOOTCHAIN = "1"` (and `TEGRA_SECBOOT_BOOTCHAIN_SBK = "1"` if the SBK is fused). meta-tegra then signs the boot chain (`TEGRA_SIGNING_ARGS`) in the flash package and in the bootloader update payloads.

Key sets
--------

A key set is one directory, as created by `tegra-secboot-genkeys.sh`: use a separate one for development, for test units, and for production, and select it with `TEGRA_SECBOOT_KEYDIR` (and `CFS_SIGN_KEYDIR` for the composefs keys). A device enrolled with one set only boots images signed with that set; what it can be reflashed with is decided by the fused boot chain keys, not by the enrolled ones. Production keys are created and kept by whoever owns the product; the development keys this script creates are for engineering units only.

Test status
-----------

Verified on the built images, and by booting the signed image in QEMU (`virt` machine, UEFI firmware with the image's PK, KEK and db enrolled):

- the firmware boots the signed UKI, and refuses a UKI with one bit changed and an unsigned kernel;
- with Secure Boot, a kernel command line passed to the UKI is ignored;
- the kernel is locked down, loads the signed modules and refuses an unsigned one;
- the initramfs takes the deployment from the `TorizonBootArgs` variable, and stops when the variable is missing or does not name an OSTree boot link;
- composefs mounts the deployment in `signed` mode, refuses a replaced composefs image, and fs-verity reports a block changed behind the filesystem;
- the system reaches the login prompt, and `ostree admin status` shows the booted deployment;
- an update: a second signed commit deployed with `ostree admin deploy` boots with its own UKI, `uEnv.txt` keeps `uki=1` and lists the previous deployment as the second entry, and that one still boots afterwards. The update client and L4TLauncher were not part of this test.

`tegra-uefi-capsules` builds the capsule with the firmware and OP-TEE of the image. Its signature has the signing and intermediate certificates of the key set, and verifies with the EDK2 capsule tool against the root certificate of the key set, not against the EDK2 test certificate. The built firmware holds that root certificate and no longer the test one, and the built OP-TEE holds the trusted application key of the key set. `TEGRA_SECBOOT_UEFI_MENU` was checked with the configuration tool of the firmware, not built.

Verified on a Jetson Orin Nano Developer Kit with NVMe (2026-11-19, signed image built from c5cd803, development keys, boot chain keys not fused):

- the NVIDIA firmware enrolls PK, KEK and db from the flash package at the first boot, and Secure Boot is enforced from that boot on;
- L4TLauncher boots the signed UKI in the Torizon boot mode, on the first boot and after a reboot, and `tegra-secboot-check.sh` passes;
- the kernel command line is the one of the UKI: the arguments the firmware appends on an unsigned image (`bl_prof_dataptr`, `bl_prof_ro_ptr`) are not there;
- a boot image with one byte changed is refused ("Access Denied"), and L4TLauncher does not fall back to the kernel partition. The firmware then goes on to its other boot options (HTTP and PXE boot), which `TEGRA_SECBOOT_UEFI_MENU = "0"` removes;
- the boot image has fs-verity enabled, so it cannot be changed in place, only replaced;
- an unsigned module is refused, and a file changed behind the filesystem gives an I/O error ("FILE CORRUPTED");
- `nvpmodel`, `nvfancontrol`, the GPU modules and device nodes, and `/dev/tee0` are there with lockdown. Lockdown refuses the debugfs writes of `nvpower.sh` (host1x load monitoring and one clock rate), which are then not applied;
- a device with enrolled keys is reflashed with the signed package, and with the unsigned one (see "Build").

Also verified on that Jetson, with the image built from b55ddf9 deployed as an update over the first one and then flashed:

- an update: the new commit, deployed with `ostree admin deploy` and with `upgrade_available` set, is booted by L4TLauncher, and the flag is cleared after the boot;
- a failed update: with the boot image of the pending deployment changed, L4TLauncher refuses it and resets three times, then sets the rollback flag ("The boot counter has expired, setting the rollback flag") and boots the other deployment;
- the kernel built with the forced command line boots, in the UKI and in the flashing image. The flashing image is then quiet on the serial console;
- OP-TEE loads the sample trusted application signed with the key of the key set (`TEGRA_SECBOOT_TEST_TA`), and refuses a copy of it with one byte changed;
- a capsule: refused with status 0x1807 while the platform spec variables are not set; with them, `tegra-secboot-capsule install` and a reboot write the other boot chain, the device boots from it with Secure Boot still enabled, and a capsule with one byte changed is refused.

Still to be verified on a Jetson: the update client (the updates above were deployed by hand), the firmware built with `TEGRA_SECBOOT_UEFI_MENU = "0"`, the serial console and SSH settings, `setup-nv-boot-control` in the image (the variables were set by hand for the capsule test), L4TLauncher ignoring other boot modes, the signed kernel started on its own after the forced command line, and everything that needs the boot chain keys fused.

Limitations and open points
---------------------------

- **Flashing is not restricted without fused boot chain keys**: see "Build". Disabling the recovery path for production devices needs the fuses.
- **Other boot options after a failed boot**: when L4TLauncher refuses the boot image, the firmware tries its remaining boot options (network boot, and the shell if it is built in). Secure Boot still checks what they load. `TEGRA_SECBOOT_UEFI_MENU = "0"` leaves them out of the firmware.
- **Kernel arguments from the firmware**: with a UKI, the arguments the UEFI firmware appends are dropped, as the command line is fixed. On the Orin Nano these are `video=efifb:off`, which `KERNEL_ARGS` has already, the boot profiler and debug data pointers (`bl_prof_dataptr`, `bl_prof_ro_ptr`, `bl_debug_data`), and the `KernelCommandLine` variable of the setup menu. Confirmed on an Orin Nano: `bl_prof_dataptr` and `bl_prof_ro_ptr` are on the command line of an unsigned image and not on that of a signed one.
- **Lockdown**: integrity mode blocks e.g. `/dev/mem`, unsigned kexec and debugfs. On an Orin Nano this stops the debugfs writes of `nvpower.sh`; `nvpmodel` and `nvfancontrol` work. Check the other NVIDIA tools in use (`jetson_clocks`, ...).
- **UEFI setup menu and shell**: they are part of the firmware unless `TEGRA_SECBOOT_UEFI_MENU = "0"`, which has been checked against the firmware configuration but not built or booted yet. Whether the menu really refuses to turn Secure Boot off once it is enabled is to be confirmed on hardware.
- **Capsules**: Torizon OS updates do not deliver or install them: see "Firmware update capsules". A capsule has been installed on an Orin Nano, with the platform spec variables set by hand; `setup-nv-boot-control` in the image is not tested yet.
- **The kernel started on its own**: before the forced command line (see "Chain of trust"), the signed kernel image started from the UEFI shell with `initrd=` and `rdinit=` of an attacker's choice gave a root shell with Secure Boot enabled; this was reproduced in QEMU with the image of 2026-11-19. The kernel with the fix is built and boots on an Orin Nano; the test itself is still to be repeated on that image. With Secure Boot, L4TLauncher still starts any image signed with db that `uEnv.txt` points to, not only a UKI.
- **Boot mode of L4TLauncher**: the `L4TDefaultBootMode` variable can be written from the running system, and `bootmode=bootimg` in the load options selects the kernel partition too, which can be rewritten with any Android boot image signed with db; the flashing image is one. With Secure Boot enabled, L4TLauncher now uses the Torizon boot mode whatever they say (`0003-L4TLauncher-only-use-the-Torizon-boot-mode-with-Secu.patch`). Not built or tested yet.
- **Found by review of the L4TLauncher change, not fixed yet**: `uki=1` applies to both entries of `uEnv.txt`, so with Secure Boot off a rollback from the first UKI deployment to a deployment without one does not boot; a failure to set `TorizonBootArgs` is only logged; an EKB with the UEFI payload encryption key makes L4TLauncher try to decrypt the UKI, which then does not load.
- **Rollback of a failed update**: when the UKI of a new deployment does not load, L4TLauncher resets instead of falling back to the kernel partition, so that the boot counting of the Torizon boot mode rolls back. Confirmed on an Orin Nano (see "Test status").
- **Kernel options for composefs**: added for the Jetson kernel by this change (`composefs.cfg`, `composefs-fsverity.cfg`); composefs has not run on Jetson before.
- **Image size**: signed images use composefs, for which the resize helper is off, so the root filesystem image has the size of the whole partition (about 28 GiB, sparse).
- **UEFI key updates**: the build puts signed KEK, `db` and `dbx` updates in the capsule (see "Changing the enrolled keys"), but none has been applied on a device, and Torizon OS updates do not deliver capsules.
- **Unsigned staging drivers**: the Ubuntu based kernel does not sign the staging drivers that are not in its `debian/signature-inclusion` list, so they cannot be loaded (`meson-vdec` in the current image). The build accepts unsigned modules only there (`TEGRA_MODSIGN_UNSIGNED_OK`) and stops on any other.
- **The module signing key in the build**: `modsign_key.pem`, with the private key, is copied to the kernel build directories and ends up in their sstate. `kernel-devsrc` does not package it. Keep the build directory and the sstate cache of production builds private.
- Only the Jetson Orin Nano is covered. Thor (T264) uses other boot chain keys.
