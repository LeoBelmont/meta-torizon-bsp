# Architecture & Migration

Torizon OS build metadata is organized in two cooperating Yocto layers:
`meta-torizon` and `meta-torizon-bsp`. This document describes their current
responsibilities, how their metadata is composed, and how to migrate an older
build to this architecture.

## Layer responsibilities

`meta-torizon` owns the board-independent definition of Torizon OS, while
`meta-torizon-bsp` adapts that definition to machines, SoCs, and vendor BSPs.
This is a responsibility boundary rather than strict recipe isolation: BitBake
combines metadata from every enabled layer, and both layers may extend the same
recipe.

| Concern | `meta-torizon` primary responsibility | `meta-torizon-bsp` primary responsibility |
| :-- | :-- | :-- |
| Distro configuration | Distro definitions, common policy, features, and distro overrides under `conf/distro/` | Machine- and distro-specific BSP override fragments under `conf/machine/include/`, loaded by the distro configuration |
| OS policy and composition | Board-independent classes such as `torizon.bbclass`, image-type classes, signing, and OTA helpers | Board-coupled classes such as `toradex-kernel-{config,localversion}.bbclass` and `torizon-image-machine.bbclass` |
| Images and initramfs | Base image recipes and common image composition | Machine-specific image and initramfs appends, kernel modules, firmware, and boot artifacts |
| OTA / SOTA | Common update recipes, clients, and configuration | Machine- and vendor-specific update appends, bootloader integration, and secondary configuration |
| Containers and OS userland | Common runtime policy and recipes for containers, networking, system services, and utilities | Machine- or SoC-specific appends to shared recipes where hardware behavior affects the runtime |
| Hardware integration | Interfaces and policy consumed by supported machines | Machine configuration, vendor `dynamic-layers/`, bootloader and kernel metadata, and vendor tools |
| Build support | Image targets consumed by the build | `setup-environment`, build templates, WIC layouts, and machine-specific build guides |

> **Rule of thumb:** If it decides *what Torizon OS is*, it's in
> **`meta-torizon`**. If it adapts a *board/BSP* to boot Torizon, it's in
> **`meta-torizon-bsp`**. A few items that look like distro but are board-coupled
> (WIC layouts, the kernel-version helper classes, the Synaptics tool, and the
> vendor guides) deliberately live in the BSP layer.

## How they fit together in a build

The layers have distinct responsibilities, but their metadata is intentionally
composed during parsing:

| Relationship | Mechanism | Effect |
| :-- | :-- | :-- |
| Declared layer dependency | `LAYERDEPENDS_meta-torizon-bsp = "meta-torizon"` | The BSP layer requires the distro collection to be present. `meta-torizon` in turn declares its dependencies on `sota` and `virtualization-layer`. |
| Torizon distro dependency on the BSP layer | `torizon.inc` and `common-torizon.inc` both use `require conf/machine/include/bsp-machine-overrides.inc` | Selecting either Torizon distro creates a hard parse-time dependency on the BSP-owned include. Parsing fails if BitBake cannot resolve it through `BBPATH`; the dispatcher can then load distro-specific BSP overrides. |
| Shared recipe extension | Both layers provide matching `.bbappend` files for recipes such as `base-files`, `systemd`, `networkmanager`, and `initramfs-framework` | BitBake applies all matching appends. The distro layer contributes OS policy, while the BSP layer adds machine, SoC, or vendor-specific behavior to the same recipe. |
| BSP extension of distro recipes | The BSP layer appends recipes defined in `meta-torizon`, including `aktualizr-default-sec` and `initramfs-ostree-torizon-image` | Board-specific OTA and initramfs behavior is added without moving ownership of the base recipe out of the distro layer. |
| Vendor BSP integration | `BBFILES_DYNAMIC` in `meta-torizon-bsp` | Vendor-specific recipes and appends are activated only when the corresponding vendor layer collection is available. |

The collections retain separate priorities: `meta-torizon` uses `90`, and
`meta-torizon-bsp` uses `91`.

## Migrating from `meta-toradex-torizon`

In an existing build that uses the former combined layer, replace its single
`meta-toradex-torizon` entry with both current layers:

1. **Clone two repos instead of one.** Wherever you cloned `meta-toradex-torizon`,
   clone both `meta-torizon` and `meta-torizon-bsp`. See
   [Building Torizon OS](../README.md#building-torizon-os) for the full commands.
   Note that `setup-environment` now lives in **`meta-torizon-bsp/scripts`**.
2. **List both layers in `conf/bblayers.conf`**, replacing the single
   `meta-toradex-torizon` entry.
3. **Update collection-name references** — this is the breaking change. Anything
   that referenced `meta-toradex-torizon` (`bblayers.conf`, `bitbake-layers
   add-layer`, `LAYERDEPENDS`/`LAYERRECOMMENDS` in downstream layers, CI configs,
   TorizonCore Builder) must now point to **`meta-torizon`** and/or
   **`meta-torizon-bsp`**.
4. **Or just use the manifest.** The `toradex-manifest` (`repo init … && repo
   sync`) already fetches both layers in the correct layout.
