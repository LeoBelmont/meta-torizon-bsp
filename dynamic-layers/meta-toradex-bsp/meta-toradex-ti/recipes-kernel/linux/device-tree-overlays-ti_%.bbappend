# meta-toradex-ti's COMPATIBLE_MACHINE:upstream = "(^$)" is meant to step
# aside once a TI machine actually switches to a mainline kernel, but it's
# keyed off the *distro*-level "upstream" override (set unconditionally by
# any torizon-upstream[-rt] DISTRO for every MACHINE), not the per-machine
# "upstream" MACHINEOVERRIDES tag that only appears when TDX_BSP_VARIANT
# resolves to tdx-upstream-mainline. No TI machine (verdin-am62,
# verdin-am62p, aquila-am69) sets TDX_BSP_VARIANT:upstream, so this recipe
# is wrongly excluded on torizon-upstream builds even though the kernel is
# still the downstream one, leaving virtual/dtb with no provider.
# TODO: Remove once meta-toradex-ti fixes COMPATIBLE_MACHINE:upstream to key off
# MACHINEOVERRIDES instead of DISTROOVERRIDES.
COMPATIBLE_MACHINE:upstream = "k3"
