#!/usr/bin/env python3
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT
"""Write the fuse configuration file (fuse.xml) for an NVIDIA Jetson Orin
from a key directory of tegra-secboot-genkeys.sh --bootchain.

  tegra-secboot-fuse-config.py --boot-security-info VALUE [options] KEYDIR

This script only writes a file. It does not talk to a device and burns
nothing: NVIDIA's fskp_fuseburn.py turns the file into a fuse blob and
burns it, as docs/README-nvidia-secure-boot.md describes. Burning fuses
cannot be undone, and a device with a wrong public key hash never boots
again. Read the file this script writes, and try it with a blob made with
--test, before a blob made with --burn exists.

The public key hashes are computed here (SHA-512 of the RSA-3072 modulus,
least significant byte first) and, with --tegraflash-dir, compared with what
NVIDIA's tegrasign_v3.py from an unpacked tegraflash package computes. The
script stops when the two differ.

BootSecurityInfo has no default: its value depends on the module, and NVIDIA
states that newer Orin modules come with some of its bits burned already.
Take it from NVIDIA's fuse specification and Secure Boot guide for the
module. Documented there: bits 2..0 are 1 for an RSA-3072 key, and bit 3
enables the encryption with the SBK. This script checks those two against
the keys and options, and passes the other bits on as given.
"""

import argparse
import hashlib
import os
import re
import subprocess
import sys


def die(text):
    sys.exit('tegra-secboot-fuse-config: ' + text)


def rsa_modulus(path):
    r = subprocess.run(['openssl', 'rsa', '-in', path, '-noout', '-modulus'],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    m = re.search(r'Modulus=([0-9A-Fa-f]+)', r.stdout.decode())
    if r.returncode != 0 or not m:
        die('%s is not an RSA private key that openssl can read' % path)
    return bytes.fromhex(m.group(1))


def pkc_hash(path):
    """PublicKeyHash fuse value of an RSA-3072 PKC key."""
    modulus = rsa_modulus(path)
    if len(modulus) != 384:
        die('%s is an RSA key of %d bits: Orin needs RSA-3072 for this script' % (path, len(modulus) * 8))
    return hashlib.sha512(modulus[::-1]).hexdigest()


def tegrasign_hash(tegraflash_dir, key, workdir):
    """The same hash, from NVIDIA's tool of a tegraflash package."""
    tool = os.path.join(tegraflash_dir, 'tegrasign_v3.py')
    if not os.path.exists(tool):
        die('no tegrasign_v3.py in %s' % tegraflash_dir)
    out_hash = os.path.join(workdir, 'pkc.hash')
    r = subprocess.run([sys.executable, tool, '--pubkeyhash', os.path.join(workdir, 'pkc.pubkey'),
                        out_hash, '--key', os.path.abspath(key)],
                       cwd=tegraflash_dir, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if r.returncode != 0 or not os.path.exists(out_hash):
        die('tegrasign_v3.py failed for %s:\n%s' % (key, r.stdout.decode(errors='replace')[-600:]))
    with open(out_hash, 'rb') as f:
        return f.read().hex()


def fuse_key(path, nbytes):
    """A key file as NVIDIA documents it: hexadecimal, big endian, as one
    number or as 32-bit words, with or without 0x."""
    with open(path) as f:
        text = f.read()
    digits = ''.join(w[2:] if w.lower().startswith('0x') else w for w in text.split())
    if not re.fullmatch(r'[0-9A-Fa-f]+', digits) or len(digits) != 2 * nbytes:
        die('%s is not a key of %d bytes in hexadecimal' % (path, nbytes))
    if len(set(digits.lower())) < 4:
        die('%s does not look like a random key' % path)
    return digits.lower()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('keydir', help='key directory with bootchain/ (tegra-secboot-genkeys.sh --bootchain)')
    parser.add_argument('--boot-security-info', required=True, metavar='VALUE',
                        help='value of the BootSecurityInfo fuse, for instance 0x1; see above')
    parser.add_argument('--sbk', action='store_true',
                        help='fuse bootchain/sbk.key (SecureBootKey): the boot chain is then encrypted too')
    parser.add_argument('--oem-k1', action='store_true',
                        help='fuse bootchain/oem_k1.key (OemK1), the key of the EKB. The image must then be '
                             'built with an EKB made with it, or the device does not boot')
    parser.add_argument('--oem-k2', action='store_true', help='fuse bootchain/oem_k2.key (OemK2)')
    parser.add_argument('--disable-jtag', action='store_true', help='fuse ArmJtagDisable: no JTAG debugging any more')
    parser.add_argument('--security-mode', action='store_true',
                        help='fuse SecurityMode: the device then only boots a boot chain signed with a fused '
                             'key. Without it the other fuses are burned but not enforced')
    parser.add_argument('--extra-fuse', action='append', default=[], metavar='NAME:SIZE:VALUE',
                        help='another fuse to add as given, for instance OptInEnable:4:0x1 (may be repeated)')
    parser.add_argument('--tegraflash-dir', metavar='DIR',
                        help='unpacked tegraflash package: compare the hashes with its tegrasign_v3.py')
    parser.add_argument('-o', '--output', metavar='FILE', help='write to FILE instead of standard output')
    args = parser.parse_args()

    boot = os.path.join(args.keydir, 'bootchain')
    if not os.path.exists(os.path.join(boot, 'pkc.pem')):
        die('no bootchain/pkc.pem in %s: create the keys with tegra-secboot-genkeys.sh --bootchain' % args.keydir)

    try:
        bsi = int(args.boot_security_info, 0)
    except ValueError:
        die('--boot-security-info %s is not a number' % args.boot_security_info)
    if not 0 < bsi <= 0xffffffff:
        die('--boot-security-info must be between 0x1 and 0xffffffff')
    if bsi & 0x7 != 0x1:
        die('bits 2..0 of BootSecurityInfo are %d: they must be 1, for the RSA-3072 keys of the key directory' % (bsi & 0x7))
    if bool(bsi & 0x8) != args.sbk:
        die('bit 3 of BootSecurityInfo (encryption with the SBK) is %d, but --sbk is %s: they must agree'
            % ((bsi >> 3) & 1, 'given' if args.sbk else 'not given'))

    fuses = []
    summary = []
    seen = {}
    for name, fuse in (('pkc.pem', 'PublicKeyHash'), ('pkc1.pem', 'PkcPubkeyHash1'), ('pkc2.pem', 'PkcPubkeyHash2')):
        path = os.path.join(boot, name)
        if not os.path.exists(path):
            continue
        value = pkc_hash(path)
        if args.tegraflash_dir:
            import tempfile
            with tempfile.TemporaryDirectory() as tmp:
                other = tegrasign_hash(args.tegraflash_dir, path, tmp)
            if other != value:
                die('the hash of %s differs from the one tegrasign_v3.py computes:\n  here:      %s\n  tegrasign: %s'
                    % (name, value, other))
        if value in seen:
            die('%s and %s are the same key' % (name, seen[value]))
        seen[value] = name
        fuses.append((fuse, 64, '0x' + value))
        summary.append('%-15s bootchain/%s, hash %s...%s' % (fuse, name, value[:12], value[-8:]))
    if len(seen) < 3:
        summary.append('NOTE            only %d PKC key(s): NVIDIA recommends to fuse three, as they can only be '
                       'fused once' % len(seen))

    for wanted, name, fuse in ((args.sbk, 'sbk.key', 'SecureBootKey'), (args.oem_k1, 'oem_k1.key', 'OemK1'),
                               (args.oem_k2, 'oem_k2.key', 'OemK2')):
        if not wanted:
            continue
        path = os.path.join(boot, name)
        if not os.path.exists(path):
            die('no bootchain/%s in %s' % (name, args.keydir))
        fuses.append((fuse, 32, '0x' + fuse_key(path, 32)))
        summary.append('%-15s bootchain/%s (value not shown)' % (fuse, name))

    names = {f[0] for f in fuses} | {'BootSecurityInfo', 'SecurityMode', 'ArmJtagDisable'}
    for extra in args.extra_fuse:
        m = re.fullmatch(r'([A-Za-z][A-Za-z0-9]*):(\d+):(0[xX][0-9A-Fa-f]+)', extra)
        if not m:
            die('--extra-fuse %s is not NAME:SIZE:VALUE with a hexadecimal value' % extra)
        if m.group(1) in names:
            die('--extra-fuse %s: this script writes %s itself' % (extra, m.group(1)))
        names.add(m.group(1))
        fuses.append((m.group(1), int(m.group(2)), m.group(3)))
        summary.append('%-15s %s, as given' % (m.group(1), m.group(3)))

    if args.disable_jtag:
        fuses.append(('ArmJtagDisable', 4, '0x1'))
        summary.append('ArmJtagDisable  0x1: JTAG is disabled for good')
    fuses.append(('BootSecurityInfo', 4, '0x%x' % bsi))
    summary.append('BootSecurityInfo 0x%x: RSA-3072%s' % (bsi, ', encryption with the SBK' if args.sbk else ''))
    if args.security_mode:
        fuses.append(('SecurityMode', 4, '0x1'))
        summary.append('SecurityMode    0x1: only a boot chain signed with a fused key boots')
    else:
        summary.append('NOTE            SecurityMode is not in this file: Secure Boot is not enforced by it')

    lines = ['<genericfuse MagicId="0x45535546" version="1.0.0">',
             ' <!-- Written by tegra-secboot-fuse-config.py. Burning fuses cannot be undone. -->']
    lines += [' <fuse name="%s" size="%d" value="%s"/>' % f for f in fuses]
    lines.append('</genericfuse>')
    text = '\n'.join(lines) + '\n'

    if args.output:
        fd = os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(text)
    else:
        sys.stdout.write(text)

    err = sys.stderr
    print('Fuses in %s:' % (args.output or 'the output'), file=err)
    for line in summary:
        print('  ' + line, file=err)
    if args.tegraflash_dir:
        print('The public key hashes agree with tegrasign_v3.py of %s.' % args.tegraflash_dir, file=err)
    else:
        print('The public key hashes were not compared with tegrasign_v3.py: give --tegraflash-dir.', file=err)
    if args.sbk or args.oem_k1 or args.oem_k2:
        print('The file holds secret keys: keep it like the key directory.', file=err)
    print('Nothing was sent to a device. Make a fuse blob with --test first (fskp_fuseburn.py of the L4T kit).',
          file=err)
    return 0


if __name__ == '__main__':
    sys.exit(main())
