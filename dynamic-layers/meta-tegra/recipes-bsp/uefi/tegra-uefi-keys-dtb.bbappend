# UEFI Secure Boot (torizon-signed): create UefiDefaultSecurityKeys.dts from
# the PK, KEK and db certificates in TEGRA_UEFI_KEYDIR (tegra-torizon-signed),
# as gen_uefi_keys_dts.sh of the L4T kit does. With EnrollDefaultSecurityKeys
# set, the UEFI firmware (NvSecureBootProvisionDxe) enrolls these keys at the
# first boot, while still in setup mode, which enables UEFI Secure Boot.

# Owner of the signature list entries; any GUID, identifying who added them
TEGRA_UEFI_KEYS_OWNER_GUID ?= "16064d27-8ac4-4f04-a216-b3a1211c2aea"

TEGRA_UEFI_KEYS_CERTS = "PK KEK db"

python tegra_uefi_keys_gen() {
    import os
    import ssl
    import struct
    import uuid

    keydir = d.getVar('TEGRA_UEFI_KEYDIR')
    unpackdir = d.getVar('UNPACKDIR')
    owner = uuid.UUID(d.getVar('TEGRA_UEFI_KEYS_OWNER_GUID'))
    # EFI_CERT_X509_GUID
    x509_type = uuid.UUID('a5c059a1-94e4-4aa7-87b5-ab155c2bf072')

    entries = ''
    for name in d.getVar('TEGRA_UEFI_KEYS_CERTS').split():
        crt = os.path.join(keydir, name + '.crt')
        if not os.path.exists(crt):
            bb.fatal('UEFI Secure Boot certificate not found: %s' % crt)
        with open(crt) as f:
            der = ssl.PEM_cert_to_DER_cert(f.read())

        # EFI_SIGNATURE_LIST with a single EFI_SIGNATURE_DATA (owner + cert)
        sig_size = 16 + len(der)
        esl = x509_type.bytes_le + struct.pack('<III', 28 + sig_size, 0, sig_size) + owner.bytes_le + der
        with open(os.path.join(unpackdir, name + '.esl'), 'wb') as f:
            f.write(esl)

        entries += '''
                            %sDefault {
                                data = /incbin/("%s.esl");
                                non-volatile;
                            };''' % (name, name)

    dts = '''/dts-v1/;
/plugin/;
/ {
    overlay-name = "UEFI default security keys";
    fragment@0 {
        target-path = "/";
        board_config {
            sw-modules = "uefi";
        };
        __overlay__ {
            firmware {
                uefi {
                    variables {
                        gNVIDIAPublicVariableGuid {
                            EnrollDefaultSecurityKeys {
                                data = [01];
                                non-volatile;
                            };
                        };
                        gEfiGlobalVariableGuid {%s
                        };
                    };
                };
            };
        };
    };
};
''' % entries
    with open(os.path.join(unpackdir, 'UefiDefaultSecurityKeys.dts'), 'w') as f:
        f.write(dts)
}

do_configure[prefuncs] += "${@'tegra_uefi_keys_gen' if 'tegra-signed' in d.getVar('OVERRIDES').split(':') else ''}"
do_configure[file-checksums] += "${@' '.join('%s/%s.crt:True' % (d.getVar('TEGRA_UEFI_KEYDIR'), c) for c in d.getVar('TEGRA_UEFI_KEYS_CERTS').split()) if 'tegra-signed' in d.getVar('OVERRIDES').split(':') else ''}"
do_configure[vardeps] += "TEGRA_UEFI_KEYS_OWNER_GUID"
