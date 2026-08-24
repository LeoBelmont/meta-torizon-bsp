#!/usr/bin/env python3
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT

import argparse
import logging
import re
import subprocess
from pathlib import Path


logger = logging.getLogger(__name__)

# Recipes and SRCREV variables that this script is allowed to update.
SRCREV_FILES = {
    ("aktualizr-torizon", "SRCREV"):
        "meta-torizon/recipes-sota/aktualizr-torizon/aktualizr-torizon_git.bb",
    ("linux-toradex-imx", "SRCREV_torizon-meta"):
        "meta-torizon-bsp/recipes-kernel/linux/linux-toradex-kmeta.inc",
    ("rac", "SRCREV_rac"):
        "meta-torizon/recipes-sota/rac/rac_git.bb",
    ("rac", "SRCREV_tough"):
        "meta-torizon/recipes-sota/rac/rac_git.bb",
    ("tzn-mqtt", "SRCREV"):
        "meta-torizon/recipes-sota/tzn-mqtt/tzn-mqtt_git.bb",
}


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description="Update pinned SRCREVs from buildhistory")
    parser.add_argument(
        "build_dir", nargs="?", type=Path, default=Path.cwd(),
        help="build directory containing buildhistory (default: current directory)",
    )
    parser.add_argument("-n", "--dry-run", action="store_true", help="show changes without writing")
    return parser.parse_args(argv)


def parse_srcrevs(output):
    # Parse buildhistory-collect-srcrevs output into {(PN, variable): hash}.
    matches = re.findall(
        r'^(SRCREV(?:_[^: ]+)?):pn-([^ ]+)\s*=\s*"([^"]+)"$',
        output,
        re.MULTILINE,
    )
    return {(pn, var): rev for var, pn, rev in matches}


def replace_srcrev(recipe, var, rev):
    pattern = rf'^({re.escape(var)}\s*=\s*")[^"]+(".*)$'
    updated, count = re.subn(pattern, rf'\g<1>{rev}\2', recipe, count=1, flags=re.MULTILINE)
    if not count:
        raise RuntimeError(f"{var} assignment not found")
    return updated


def update_file(path, var, rev, dry_run=False):
    old = path.read_text()
    new = replace_srcrev(old, var, rev)
    if old == new:
        return
    logger.info("%s %s", "would update" if dry_run else "updating", path)
    if not dry_run:
        path.write_text(new)


def main(argv=None):
    args = parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")

    root = Path(__file__).resolve().parents[4]
    collector = root / "layers/openembedded-core/scripts/buildhistory-collect-srcrevs"
    output = subprocess.check_output(
        [collector, "-p", args.build_dir / "buildhistory"], text=True
    )
    srcrevs = parse_srcrevs(output)

    for key, filename in SRCREV_FILES.items():
        if key in srcrevs:
            update_file(
                root / "layers" / filename,
                key[1],
                srcrevs[key],
                args.dry_run,
            )


if __name__ == "__main__":
    main()
