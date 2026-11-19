FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

# 0002 boots signed UKIs in the Torizon boot mode: with UEFI Secure Boot
# enabled (torizon-signed), or with "uki=1" in uEnv.txt. Without either,
# the Torizon boot is unchanged.
SRC_URI += "\
    file://0001-Implement-support-for-the-Torizon-boot.patch;patchdir=../edk2-nvidia \
    file://0002-L4TLauncher-boot-signed-UKIs-in-the-Torizon-boot-mode.patch;patchdir=../edk2-nvidia \
"

# torizon-signed: the firmware authenticates the update capsules with the
# root certificate of the key set, instead of the EDK2 test certificate that
# meta-tegra builds in, whose private key is public.
SRC_URI:append:tegra-signed = " file://torizon-fmp-certificates.cfg"

# TEGRA_SECBOOT_UEFI_MENU = "0" leaves the setup menu, the boot menu and the
# shell out of the firmware, for production devices.
SRC_URI:append:tegra-signed = "${@'' if d.getVar('TEGRA_SECBOOT_UEFI_MENU') != '0' else ' file://torizon-no-menu.cfg'}"

# The include file that torizon-fmp-certificates.cfg names, in the format
# BinToPcd.py --xdr writes: the length of the certificate (DER) as 32 bits
# big endian, then the certificate, padded to a multiple of 4 bytes. The
# directory is in PACKAGES_PATH, where the platform description looks for it.
# Written before do_compile: do_configure empties the build directory after
# its own prefuncs have run.
python torizon_fmp_certificates() {
    import ssl

    with open(d.getVar('UEFI_CAPSULE_TRUSTED_PUBLIC_CERT')) as f:
        der = ssl.PEM_cert_to_DER_cert(f.read())
    xdr = len(der).to_bytes(4, 'big') + der + bytes(-len(der) % 4)
    outdir = d.expand('${B}/nvidia-config/Tegra/${EDK2_PLATFORM}')
    os.makedirs(outdir, exist_ok=True)
    with open(os.path.join(outdir, 'TorizonFmpCertificates.inc'), 'w') as f:
        f.write('  gFmpDevicePkgTokenSpaceGuid.PcdFmpDevicePkcs7CertBufferXdr|{%s}\n'
                % ', '.join('0x%02X' % b for b in xdr))
}
TORIZON_FMP_PREFUNCS = ""
TORIZON_FMP_PREFUNCS:tegra-signed = "torizon_fmp_certificates"
do_compile[prefuncs] += "${TORIZON_FMP_PREFUNCS}"
TORIZON_FMP_CHECKSUMS = ""
TORIZON_FMP_CHECKSUMS:tegra-signed = "${UEFI_CAPSULE_TRUSTED_PUBLIC_CERT}:True"
do_compile[file-checksums] += "${TORIZON_FMP_CHECKSUMS}"
