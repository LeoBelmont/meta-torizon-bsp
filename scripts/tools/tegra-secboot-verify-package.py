#!/usr/bin/env python3
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT
"""Check, on the build or flashing host, that a tegraflash package of a
torizon-signed image for NVIDIA Jetson is signed with a given key set,
before it is flashed.

  tegra-secboot-verify-package.py [--capsule FILE] PACKAGE KEYDIR

PACKAGE is the .tegraflash-tar.zst file or the directory it was unpacked
into. KEYDIR is a key directory in the layout of tegra-secboot-genkeys.sh;
only its public parts are needed (uefi/*.crt, capsule/root.crt, the OP-TEE
key as optee/ta_sign_key.pem or optee/ta_sign_key.pub.pem, and for a package
with a signed boot chain bootchain/pkc.pem or bootchain/pkc.pub.pem).

PASS/FAIL lines are the checks, and the exit status is 1 when one fails.
SKIP lines are checks that could not be made, with the reason. Needs
sbverify (sbsigntool), debugfs (e2fsprogs), openssl, and zstd and tar for a
packed package.

See docs/README-nvidia-secure-boot.md.
"""

import argparse
import gzip
import hashlib
import os
import re
import shutil
import ssl
import struct
import subprocess
import sys
import tempfile

EFI_CERT_X509_GUID = bytes.fromhex('a159c0a5e494a74a87b5ab155c2bf072')
MODULE_SIG_MARKER = b'~Module signature appended~\n'
HALT_MESSAGE = b'does not boot a signed image'

# Signed boot chain files of T234 (Orin), as the flashing tools of L4T R39.2.1
# write them. NVIDIA does not document this layout: the offsets were read off
# signed files, and the check fails on a file that is laid out otherwise.
# An image has a header of NVDA_HEADER bytes: an RSASSA-PSS signature (SHA-512,
# least significant byte first, like the modulus of its key) over the part of
# the header from NVDA_SIGNED on, which holds the SHA-512 digests of what
# follows the header. That is one payload of the length at NVDA_LENGTH, or,
# when that is 0, the parts of the table at NVDA_PARTS.
NVDA_HEADER = 0x2000
NVDA_SIGNATURE = 0x90
NVDA_KEY = 0xba0
NVDA_SIGNED = 0xfc0
NVDA_LENGTH = 0x1ee4
NVDA_PARTS = 0x1400
NVDA_PART_SIZE = 0xa0      # length at 4, offset in 512 byte sectors at 0x18, digest at 0x60
# The table for the boot ROM (BR BCT): signature over its part from BCT_SIGNED on
BCT_SIZE = 0x2000
BCT_KEY = 0x44
BCT_SIGNATURE = 0x204
BCT_SIGNED = 0x1200

fails = 0


def report(kind, text):
    print('%-5s %s' % (kind, text))


def ok(text):
    report('PASS', text)


def fail(text):
    global fails
    fails += 1
    report('FAIL', text)


def skip(text):
    report('SKIP', text)


def info(text):
    report('INFO', text)


def run(args, **kwargs):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def have(tool):
    return shutil.which(tool) is not None or any(
        os.access(os.path.join(d, tool), os.X_OK) for d in ('/sbin', '/usr/sbin'))


def tool_path(tool):
    found = shutil.which(tool)
    if found:
        return found
    for d in ('/sbin', '/usr/sbin'):
        if os.access(os.path.join(d, tool), os.X_OK):
            return os.path.join(d, tool)
    return tool


def cert_der(path):
    with open(path) as f:
        return ssl.PEM_cert_to_DER_cert(f.read())


def fdt_props(blob):
    """The properties of a devicetree blob, as {'/node/path/prop': bytes}."""
    magic, _total, off_struct, off_strings = struct.unpack_from('>4I', blob, 0)
    if magic != 0xd00dfeed:
        raise ValueError('not a devicetree blob')
    props, path, pos = {}, [], off_struct
    while True:
        token, = struct.unpack_from('>I', blob, pos)
        pos += 4
        if token == 1:  # FDT_BEGIN_NODE
            end = blob.index(b'\0', pos)
            path.append(blob[pos:end].decode())
            pos = (end + 4) & ~3
        elif token == 2:  # FDT_END_NODE
            path.pop()
        elif token == 3:  # FDT_PROP
            length, nameoff = struct.unpack_from('>2I', blob, pos)
            pos += 8
            end = blob.index(b'\0', off_strings + nameoff)
            name = blob[off_strings + nameoff:end].decode()
            props['/'.join(path) + '/' + name] = blob[pos:pos + length]
            pos = (pos + length + 3) & ~3
        elif token == 4:  # FDT_NOP
            continue
        else:  # FDT_END
            return props


def esl_certs(data):
    """The X.509 certificates (DER) of an EFI signature list."""
    certs, pos = [], 0
    while pos + 28 <= len(data):
        sig_type = data[pos:pos + 16]
        list_size, header_size, sig_size = struct.unpack_from('<3I', data, pos + 16)
        if list_size < 28 or pos + list_size > len(data):
            raise ValueError('malformed EFI signature list')
        if sig_type == EFI_CERT_X509_GUID:
            first = pos + 28 + header_size
            for off in range(first, pos + list_size, sig_size):
                certs.append(data[off + 16:off + sig_size])
        pos += list_size
    return certs


def fat_read(image, path):
    """Read a file from a FAT16 or FAT32 image by its 8.3 path."""
    with open(image, 'rb') as f:
        img = f.read()
    bps, spc, reserved, nfats, root_entries, total16 = struct.unpack_from('<HBHBHH', img, 11)
    fatsz16, = struct.unpack_from('<H', img, 22)
    total32, fatsz32 = struct.unpack_from('<I', img, 32)[0], struct.unpack_from('<I', img, 36)[0]
    fatsz = fatsz16 or fatsz32
    total = total16 or total32
    root_sectors = (root_entries * 32 + bps - 1) // bps
    first_data = reserved + nfats * fatsz + root_sectors
    clusters = (total - first_data) // spc
    fat32 = clusters >= 65525
    if clusters < 4085:
        raise ValueError('FAT12 is not supported')
    fat = reserved * bps

    def next_cluster(c):
        if fat32:
            return struct.unpack_from('<I', img, fat + c * 4)[0] & 0x0fffffff
        return struct.unpack_from('<H', img, fat + c * 2)[0]

    def chain(c):
        data = b''
        end = 0x0ffffff8 if fat32 else 0xfff8
        while 2 <= c < end:
            start = (first_data + (c - 2) * spc) * bps
            data += img[start:start + spc * bps]
            c = next_cluster(c)
        return data

    if fat32:
        directory = chain(struct.unpack_from('<I', img, 44)[0])
    else:
        start = (reserved + nfats * fatsz) * bps
        directory = img[start:start + root_entries * 32]
    parts = [p for p in path.upper().split('/') if p]
    for depth, part in enumerate(parts):
        base, _, ext = part.partition('.')
        want = base.ljust(8).encode() + ext.ljust(3).encode()
        for off in range(0, len(directory), 32):
            entry = directory[off:off + 32]
            if entry[0] == 0:
                break
            if entry[0] == 0xe5 or entry[11] == 0x0f:
                continue
            if entry[:11] == want:
                cluster = (struct.unpack_from('<H', entry, 20)[0] << 16) | struct.unpack_from('<H', entry, 26)[0]
                size, = struct.unpack_from('<I', entry, 28)
                data = chain(cluster)
                if depth == len(parts) - 1:
                    return data[:size]
                directory = data
                break
        else:
            raise FileNotFoundError(path)
    raise FileNotFoundError(path)


def pe_sections(data):
    """The sections of a PE file, as {name: bytes}."""
    pe, = struct.unpack_from('<I', data, 0x3c)
    if data[pe:pe + 4] != b'PE\0\0':
        raise ValueError('not a PE file')
    count, = struct.unpack_from('<H', data, pe + 6)
    opt_size, = struct.unpack_from('<H', data, pe + 20)
    table = pe + 24 + opt_size
    sections = {}
    for i in range(count):
        entry = data[table + i * 40:table + i * 40 + 40]
        name = entry[:8].rstrip(b'\0').decode('latin-1')
        vsize, _vaddr, rsize, roff = struct.unpack_from('<4I', entry, 8)
        sections[name] = data[roff:roff + min(vsize, rsize)]
    return sections


def bootimg_ramdisk(data):
    """The ramdisk of an Android boot image (header version 0)."""
    if data[:8] != b'ANDROID!':
        raise ValueError('not an Android boot image')
    ksize, _kaddr, rsize = struct.unpack_from('<3I', data, 8)
    page, = struct.unpack_from('<I', data, 36)
    off = page + (ksize + page - 1) // page * page
    return data[off:off + rsize]


class Package:
    def __init__(self, path):
        self.tmp = None
        if os.path.isdir(path):
            self.dir = path
            self.archive = None
        else:
            self.tmp = tempfile.mkdtemp(prefix='tegra-secboot-verify.')
            self.dir = self.tmp
            self.archive = path
        self.env = {}

    def fetch(self, *names):
        """Make the named files available in self.dir, and say which are."""
        missing = [n for n in names if not os.path.exists(os.path.join(self.dir, n))]
        if missing and self.archive:
            zstd = subprocess.Popen(['zstd', '-dc', self.archive], stdout=subprocess.PIPE,
                                    stderr=subprocess.DEVNULL)
            # The names come from the package: "--" keeps tar from taking
            # one as an option. tar fails for a name that is not there.
            subprocess.run(['tar', '-x', '-C', self.dir, '--'] + missing, stdin=zstd.stdout,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            zstd.stdout.close()
            if zstd.wait() not in (0, -13):
                sys.exit('%s: cannot be read as a zstd archive' % self.archive)
        return [n for n in names if os.path.exists(os.path.join(self.dir, n))]

    def fetch_matching(self, *patterns):
        """Make the files that match the patterns available in self.dir. The
        patterns are shell patterns of this script, and match in every
        directory of the package."""
        if not self.archive:
            return
        zstd = subprocess.Popen(['zstd', '-dc', self.archive], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        subprocess.run(['tar', '-x', '-C', self.dir, '--wildcards', '--'] + list(patterns), stdin=zstd.stdout,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        zstd.stdout.close()
        if zstd.wait() not in (0, -13):
            sys.exit('%s: cannot be read as a zstd archive' % self.archive)

    def path(self, name):
        return os.path.join(self.dir, name)

    def read_env(self):
        if self.fetch('.env.initrd-flash'):
            with open(self.path('.env.initrd-flash')) as f:
                for line in f:
                    m = re.match(r'^(\w+)="?([^"\n]*)"?$', line)
                    if m:
                        self.env[m.group(1)] = m.group(2)

    def cleanup(self):
        if self.tmp:
            shutil.rmtree(self.tmp, ignore_errors=True)


def check_key_overlay(pkg, keydir):
    name = 'UefiDefaultSecurityKeys.dtbo'
    if not pkg.fetch(name):
        fail('no %s in the package: the firmware would not enroll any key' % name)
        return
    with open(pkg.path(name), 'rb') as f:
        props = fdt_props(f.read())

    def prop(var):
        for key, value in props.items():
            if key.endswith('/%s/data' % var):
                return value
        return None

    if prop('EnrollDefaultSecurityKeys') == b'\x01':
        ok('the key overlay asks the firmware to enroll the keys')
    else:
        fail('the key overlay does not set EnrollDefaultSecurityKeys')
    for var, cert in (('PKDefault', 'PK.crt'), ('KEKDefault', 'KEK.crt'), ('dbDefault', 'db.crt')):
        want = cert_der(os.path.join(keydir, 'uefi', cert))
        data = prop(var)
        try:
            certs = esl_certs(data) if data else []
        except ValueError as e:
            fail('%s in the key overlay: %s' % (var, e))
            continue
        if certs == [want]:
            ok('%s in the key overlay is uefi/%s of the key set' % (var, cert))
        elif want in certs:
            fail('%s in the key overlay has uefi/%s and %d other certificate(s)' % (var, cert, len(certs) - 1))
        else:
            fail('%s in the key overlay is not uefi/%s of the key set' % (var, cert))


def sbverify(path, cert):
    r = run([tool_path('sbverify'), '--cert', cert, path])
    return r.returncode == 0


def check_launcher(pkg, keydir, tmp):
    if not pkg.fetch('esp.img'):
        fail('no esp.img in the package')
        return
    try:
        data = fat_read(pkg.path('esp.img'), 'EFI/BOOT/BOOTAA64.EFI')
    except (FileNotFoundError, ValueError, struct.error) as e:
        fail('cannot read EFI/BOOT/BOOTAA64.EFI from esp.img: %s' % e)
        return
    launcher = os.path.join(tmp, 'BOOTAA64.EFI')
    with open(launcher, 'wb') as f:
        f.write(data)
    if sbverify(launcher, os.path.join(keydir, 'uefi', 'db.crt')):
        ok('the boot loader (L4TLauncher) is signed with db')
    else:
        fail('the boot loader (L4TLauncher) is not signed with db of the key set')
    if 'TorizonBootArgs'.encode('utf-16-le') in data:
        ok('the boot loader has the Torizon UKI boot')
    else:
        fail('the boot loader does not have the Torizon UKI boot')


def debugfs(image, command):
    return run([tool_path('debugfs'), '-R', command, image])


def check_rootfs(pkg, keydir, tmp, unsigned_ok):
    name = pkg.env.get('ROOTFS_IMAGE')
    if not name or not pkg.fetch(name):
        fail('no root filesystem image (%s) in the package' % (name or 'ROOTFS_IMAGE not set'))
        return
    image = pkg.path(name)
    uenv = debugfs(image, 'cat /boot/loader/uEnv.txt').stdout.decode('latin-1')
    m = re.search(r'^kernel_image=(\S+)', uenv, re.M)
    if not m:
        fail('no kernel_image in /boot/loader/uEnv.txt of the root filesystem')
        return
    if re.search(r'^uki=1$', uenv, re.M):
        ok('uEnv.txt selects the UKI boot (uki=1)')
    else:
        fail('uEnv.txt does not have uki=1')
    uki = os.path.join(tmp, 'uki.efi')
    debugfs(image, 'dump %s %s' % (m.group(1), uki))
    if not os.path.exists(uki) or os.path.getsize(uki) == 0:
        fail('cannot read the boot image %s from the root filesystem' % m.group(1))
        return
    if sbverify(uki, os.path.join(keydir, 'uefi', 'db.crt')):
        ok('the boot image is signed with db')
    else:
        fail('the boot image is not signed with db of the key set')
    with open(uki, 'rb') as f:
        try:
            sections = pe_sections(f.read())
        except (ValueError, struct.error):
            sections = {}
    if all(s in sections for s in ('.linux', '.initrd', '.cmdline')):
        ok('the boot image is a UKI, with kernel, initramfs and command line')
        cmdline = sections['.cmdline'].rstrip(b'\0\n').decode('latin-1')
        info('command line of the UKI: %s' % cmdline)
        secver = sections.get('.tznsv', b'0').rstrip(b'\0\n').decode('latin-1')
        info('security version of the UKI (anti-rollback limit): %s' % (secver or '0'))
        if 'ostree=' in cmdline:
            fail('the command line of the UKI has an ostree= argument')
    else:
        fail('the boot image is not a UKI (sections: %s)' % ' '.join(sorted(sections)))

    # Devicetrees of the deployment (TEGRA_SECBOOT_KERNEL_DTB)
    m = re.search(r'^fdtdir=(\S+)', uenv, re.M)
    if not m:
        info('no devicetree in the deployment: the kernel gets the one of the boot chain')
    else:
        dtbdir = os.path.join(tmp, 'dtb')
        os.mkdir(dtbdir)
        debugfs(image, 'rdump %s %s' % (m.group(1), dtbdir))
        dtbs = []
        for root, _dirs, files in os.walk(dtbdir):
            dtbs += [os.path.join(root, f) for f in files if f.endswith('.dtb')]
        if not dtbs:
            fail('uEnv.txt names a devicetree directory, %s, with no devicetree in it' % m.group(1))
        db = os.path.join(keydir, 'uefi', 'db.crt')
        for dtb in sorted(dtbs):
            name = os.path.basename(dtb)
            if not os.path.exists(dtb + '.sig'):
                fail('the devicetree %s has no signature (%s.sig)' % (name, name))
                continue
            r = run(['openssl', 'cms', '-verify', '-binary', '-inform', 'DER', '-in', dtb + '.sig',
                     '-content', dtb, '-CAfile', db, '-purpose', 'any', '-out', os.devnull])
            if r.returncode == 0:
                ok('the devicetree %s is signed with db' % name)
            else:
                fail('the signature of the devicetree %s does not verify with db of the key set' % name)

    # Kernel modules of the deployment
    deploy = '/ostree/deploy/torizon/deploy'
    listing = debugfs(image, 'ls -p %s' % deploy).stdout.decode('latin-1')
    names = [l.split('/')[5] for l in listing.splitlines() if l.count('/') >= 6]
    deployments = [n for n in names if re.match(r'^[0-9a-f]{64}\.\d+$', n)]
    if not deployments:
        skip('kernel modules: no deployment found in the root filesystem')
        return
    moddir = os.path.join(tmp, 'modules')
    os.mkdir(moddir)
    debugfs(image, 'rdump %s/%s/usr/lib/modules %s' % (deploy, deployments[0], moddir))
    total, unsigned, accepted = 0, [], []
    for root, _dirs, files in os.walk(moddir):
        for fn in files:
            if not fn.endswith('.ko'):
                continue
            total += 1
            path = os.path.join(root, fn)
            with open(path, 'rb') as f:
                f.seek(max(0, os.path.getsize(path) - len(MODULE_SIG_MARKER)))
                signed = f.read() == MODULE_SIG_MARKER
            if not signed:
                rel = os.path.relpath(path, moddir).split(os.sep, 2)[-1]
                (accepted if any(rel.startswith(p) for p in unsigned_ok) else unsigned).append(rel)
    if total == 0:
        skip('kernel modules: none found in the deployment')
    elif unsigned:
        fail('%d of %d kernel modules have no signature, for example %s' % (len(unsigned), total, unsigned[0]))
    else:
        ok('%d kernel modules are signed%s' % (total - len(accepted),
           ', %d unsigned ones are in an accepted directory' % len(accepted) if accepted else ''))


def check_kernel_partition(pkg):
    name = pkg.env.get('LNXFILE')
    if not name or not pkg.fetch(name):
        fail('no kernel partition image (%s) in the package' % (name or 'LNXFILE not set'))
        return
    with open(pkg.path(name), 'rb') as f:
        try:
            ramdisk = bootimg_ramdisk(f.read())
            content = gzip.decompress(ramdisk)
        except (ValueError, OSError, struct.error) as e:
            fail('cannot read the initramfs of the kernel partition image: %s' % e)
            return
    if HALT_MESSAGE in content:
        ok('the kernel partition has the image that only stops')
    else:
        fail('the kernel partition does not have the image that only stops: it may boot an unverified system')


def rsa_modulus(path):
    for extra in ([], ['-pubin']):
        r = run(['openssl', 'rsa', '-in', path, '-noout', '-modulus'] + extra)
        m = re.search(r'Modulus=([0-9A-Fa-f]+)', r.stdout.decode())
        if m:
            return bytes.fromhex(m.group(1))
    return None


def pss_verify(modulus, signature, message):
    """Verify an RSASSA-PSS signature made with SHA-512 and MGF1 with SHA-512,
    with a salt of any length and the exponent 65537. modulus and signature
    are big endian."""
    n = int.from_bytes(modulus, 'big')
    s = int.from_bytes(signature, 'big')
    if len(signature) != len(modulus) or s >= n:
        return False
    bits = n.bit_length() - 1
    size = (bits + 7) // 8
    em = pow(s, 65537, n).to_bytes(len(modulus), 'big')
    if any(em[:len(modulus) - size]) or em[-1] != 0xbc or size < 64 + 2:
        return False
    em = em[-size:]
    masked, digest = em[:size - 65], em[size - 65:-1]
    mask = b''
    counter = 0
    while len(mask) < len(masked):
        mask += hashlib.sha512(digest + counter.to_bytes(4, 'big')).digest()
        counter += 1
    db = bytearray(a ^ b for a, b in zip(masked, mask))
    db[0] &= 0xff >> (8 * size - bits)
    start = db.find(b'\x01')
    if start < 0 or any(db[:start]):
        return False
    salt = bytes(db[start + 1:])
    return hashlib.sha512(b'\0' * 8 + hashlib.sha512(message).digest() + salt).digest() == digest


def nvda_check(data, pos, modulus, whole_file):
    """What is wrong with the signed boot chain image at pos of data, or
    None when its signature and payload digests verify with the key."""
    key = modulus[::-1]
    if data[pos:pos + 4] != b'NVDA' or len(data) < pos + NVDA_HEADER:
        return 'not a signed image (no NVDA header)'
    if data[pos + NVDA_KEY:pos + NVDA_KEY + len(key)] != key:
        return 'signed with another key, or not signed'
    signed = data[pos + NVDA_SIGNED:pos + NVDA_HEADER]
    signature = data[pos + NVDA_SIGNATURE:pos + NVDA_SIGNATURE + len(key)][::-1]
    if not pss_verify(modulus, signature, signed):
        return 'the signature of the header does not verify'
    length, = struct.unpack_from('<I', data, pos + NVDA_LENGTH)
    parts = []
    if length:
        parts.append((NVDA_HEADER, length, None))
        if whole_file and pos + NVDA_HEADER + length != len(data):
            return 'the signed length is not the length of the file'
    else:
        for i in range((NVDA_LENGTH - NVDA_PARTS) // NVDA_PART_SIZE):
            entry = pos + NVDA_PARTS + i * NVDA_PART_SIZE
            part_length, = struct.unpack_from('<I', data, entry + 4)
            sectors, = struct.unpack_from('<I', data, entry + 0x18)
            if not part_length:
                break
            parts.append((sectors * 512, part_length, data[entry + 0x60:entry + 0xa0]))
    if not parts:
        return 'the header names no payload'
    for offset, part_length, want in parts:
        if offset < NVDA_HEADER or pos + offset + part_length > len(data):
            return 'the payload is cut short'
        digest = hashlib.sha512(data[pos + offset:pos + offset + part_length]).digest()
        if (digest != want) if want else (digest not in signed):
            return 'the payload does not have the digest in the signed header'
    return None


def bct_check(data, pos, modulus):
    """The same for a table for the boot ROM (BR BCT)."""
    key = modulus[::-1]
    if data[pos:pos + 4] != b'BCTB' or len(data) < pos + BCT_SIZE:
        return 'not a table for the boot ROM (no BCTB header)'
    if data[pos + BCT_KEY:pos + BCT_KEY + len(key)] != key:
        return 'signed with another key, or not signed'
    signature = data[pos + BCT_SIGNATURE:pos + BCT_SIGNATURE + len(key)][::-1]
    if not pss_verify(modulus, signature, data[pos + BCT_SIGNED:pos + BCT_SIZE]):
        return 'the signature does not verify'
    return None


def bootchain_key(keydir):
    for name in ('pkc.pem', 'pkc.pub.pem'):
        path = os.path.join(keydir, 'bootchain', name)
        if os.path.exists(path):
            return name, rsa_modulus(path)
    return None, None


def check_bootchain(pkg, keydir):
    """The boot chain before UEFI, when the package was signed at build time
    (TEGRA_SECBOOT_BOOTCHAIN). Returns the modulus of the key when it was."""
    pkg.fetch_matching('.presigning-vars', '*_sigheader*.signed', '*.bct')
    if not os.path.exists(pkg.path('.presigning-vars')):
        info('the boot chain is not signed in this package: it is for devices without fused boot chain keys')
        return None
    if pkg.env.get('CHIPID', '0x23') != '0x23':
        skip('boot chain: the check only knows the signed files of T234 (Orin)')
        return None
    name, modulus = bootchain_key(keydir)
    if not name:
        skip('boot chain: signed in this package, but no bootchain/pkc.pem or bootchain/pkc.pub.pem in the key directory')
        return None
    if not modulus or len(modulus) != 384:
        skip('boot chain: bootchain/%s is not an RSA-3072 key that openssl can read' % name)
        return None
    images, tables, bad = 0, 0, []
    for root, _dirs, files in os.walk(pkg.dir):
        for fn in sorted(files):
            image = '_sigheader' in fn and fn.endswith('.signed')
            if not image and not fn.endswith('.bct'):
                continue
            with open(os.path.join(root, fn), 'rb') as f:
                data = f.read()
            if image:
                images += 1
                error = nvda_check(data, 0, modulus, True)
            elif data[:4] == b'BCTB':
                tables += 1
                error = bct_check(data, 0, modulus)
            else:
                continue
            if error:
                bad.append('%s: %s' % (os.path.relpath(os.path.join(root, fn), pkg.dir), error))
    if not images or not tables:
        fail('the package says its boot chain is signed, but has %d signed images and %d tables for the boot ROM'
             % (images, tables))
    elif bad:
        fail('%d of the %d files of the boot chain do not verify with bootchain/%s, for example %s'
             % (len(bad), images + tables, name, bad[0]))
    else:
        ok('the boot chain is signed with bootchain/%s: %d images and %d tables for the boot ROM '
           '(signatures and payload digests)' % (name, images, tables))
    info('a device only checks the signatures of the boot chain once the hash of that key is fused')
    return modulus


def check_capsule_bootchain(capsule, modulus):
    """The boot chain images inside a capsule: they are stored as they are."""
    with open(capsule, 'rb') as f:
        data = f.read()
    images, tables, other, bad = 0, 0, 0, []
    for m in re.finditer(b'NVDA', data):
        pos = m.start()
        # The name of the image is in the header twice, or once for the
        # image with several parts: tells a header from the same four letters
        # elsewhere
        tag = data[pos + NVDA_PARTS:pos + NVDA_PARTS + 4]
        if not re.fullmatch(b'[A-Z0-9]{4}', tag) or \
           data[pos + NVDA_LENGTH - 4:pos + NVDA_LENGTH] not in (tag, b'\0\0\0\0'):
            continue
        error = nvda_check(data, pos, modulus, False)
        if error is None:
            images += 1
        elif error.startswith('signed with another key'):
            other += 1
        else:
            bad.append('%s at 0x%x: %s' % (tag.decode(), pos, error))
    for m in re.finditer(b'BCTB', data):
        if bct_check(data, m.start(), modulus) is None:
            tables += 1
    if bad:
        fail('%d boot chain image(s) in the capsule do not verify with the boot chain key, for example %s'
             % (len(bad), bad[0]))
    elif other:
        fail('%d of the %d boot chain images in the capsule are not signed with the boot chain key'
             % (other, images + other))
    elif not images or not tables:
        fail('no boot chain signed with the boot chain key in the capsule (%d images, %d tables for the boot ROM)'
             % (images, tables))
    else:
        ok('the boot chain in the capsule is signed with the boot chain key: %d images and %d tables for '
           'the boot ROM' % (images, tables))


def check_optee(pkg, keydir):
    key = None
    for name in ('ta_sign_key.pem', 'ta_sign_key.pub.pem'):
        if os.path.exists(os.path.join(keydir, 'optee', name)):
            key = os.path.join(keydir, 'optee', name)
            break
    names = [n for n in os.listdir(pkg.dir) if re.match(r'^tos.*\.img$', n)] or ['tos-optee_t234.img']
    if not pkg.fetch(names[0]):
        skip('OP-TEE: no %s in the package' % names[0])
        return
    if not key:
        skip('OP-TEE: no optee/ta_sign_key.pem or optee/ta_sign_key.pub.pem in the key directory')
        return
    modulus = rsa_modulus(key)
    if not modulus:
        skip('OP-TEE: cannot read the key %s' % key)
        return
    with open(pkg.path(names[0]), 'rb') as f:
        image = f.read()
    if modulus in image:
        ok('OP-TEE has the trusted application key of the key set')
    else:
        fail('OP-TEE does not have the trusted application key of the key set')


def check_capsule(capsule, keydir, tmp):
    with open(capsule, 'rb') as f:
        data = f.read(65536)
    certs = None
    for m in re.finditer(b'\x30\x82', data):
        length, = struct.unpack_from('>H', data, m.start() + 2)
        der = data[m.start():m.start() + 4 + length]
        r = run(['openssl', 'pkcs7', '-inform', 'DER', '-print_certs'], input=der)
        found = re.findall(b'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', r.stdout, re.S)
        if r.returncode == 0 and found:
            certs = found
            break
    if not certs:
        fail('no signature found in the capsule')
        return
    chain = os.path.join(tmp, 'capsule-chain.pem')
    signer = os.path.join(tmp, 'capsule-signer.pem')
    with open(chain, 'wb') as f:
        f.write(b'\n'.join(certs) + b'\n')
    with open(signer, 'wb') as f:
        f.write(certs[0] + b'\n')
    root = os.path.join(keydir, 'capsule', 'root.crt')
    r = run(['openssl', 'verify', '-CAfile', root, '-untrusted', chain, signer])
    if r.returncode == 0:
        ok('the signing certificate of the capsule chains to capsule/root.crt')
    else:
        fail('the signing certificate of the capsule does not chain to capsule/root.crt of the key set')
    info('this checks the certificates of the capsule, not its signature: the firmware does that')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('package', help='.tegraflash-tar.zst file, or the directory it was unpacked into')
    parser.add_argument('keydir', help='key directory (public parts are enough)')
    parser.add_argument('--capsule', help='also check this capsule (tegra-bl.cap)')
    parser.add_argument('--unsigned-ok', action='append', default=None, metavar='DIR',
                        help='module directory, relative to the kernel version, where unsigned modules '
                             'are accepted (default: kernel/drivers/staging/)')
    args = parser.parse_args()
    unsigned_ok = args.unsigned_ok or ['kernel/drivers/staging/']

    for cert in ('PK.crt', 'KEK.crt', 'db.crt'):
        if not os.path.exists(os.path.join(args.keydir, 'uefi', cert)):
            sys.exit('%s: no uefi/%s' % (args.keydir, cert))
    missing = [t for t in ('sbverify', 'debugfs', 'openssl') if not have(t)]
    if missing:
        sys.exit('missing tool(s): %s' % ' '.join(missing))
    if not os.path.exists(args.package):
        sys.exit('%s: not found' % args.package)

    pkg = Package(args.package)
    tmp = tempfile.mkdtemp(prefix='tegra-secboot-verify.work.')
    try:
        pkg.read_env()
        info('package: %s, machine %s' % (args.package, pkg.env.get('MACHINE', 'unknown')))
        info('key set: db certificate sha256 %s' % hashlib.sha256(
            cert_der(os.path.join(args.keydir, 'uefi', 'db.crt'))).hexdigest()[:16])
        check_key_overlay(pkg, args.keydir)
        check_launcher(pkg, args.keydir, tmp)
        check_rootfs(pkg, args.keydir, tmp, unsigned_ok)
        check_kernel_partition(pkg)
        check_optee(pkg, args.keydir)
        bootchain = check_bootchain(pkg, args.keydir)
        if args.capsule:
            if os.path.exists(os.path.join(args.keydir, 'capsule', 'root.crt')):
                check_capsule(args.capsule, args.keydir, tmp)
            else:
                skip('capsule: no capsule/root.crt in the key directory')
            if bootchain:
                check_capsule_bootchain(args.capsule, bootchain)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        pkg.cleanup()

    print()
    if fails:
        print('%d check(s) FAILED: do not flash this package as a signed image of this key set.' % fails)
        return 1
    print('The package is signed with this key set.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
