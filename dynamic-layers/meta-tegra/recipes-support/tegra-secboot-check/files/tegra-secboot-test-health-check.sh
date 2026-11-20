#!/bin/sh
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT
#
# Test images only (TEGRA_SECBOOT_TEST_HEALTH_CHECK = "1"): fail the health
# check of the deployment whose checksum is in
# /var/lib/tegra-secboot/fail-health-check, to test the rollback of an update
# that boots and is then found unhealthy. Without that file, or for another
# deployment, the check passes.

marker=/var/lib/tegra-secboot/fail-health-check
[ -e "$marker" ] || exit 0

booted="$(ostree admin status 2>/dev/null | sed -n 's/^\* [^ ]* \([0-9a-f]\{64\}\)\..*/\1/p')"
if [ -n "$booted" ] && grep -q "$booted" "$marker"; then
	echo "tegra-secboot test: failing the health check of $booted, as $marker asks"
	exit 1
fi
exit 0
