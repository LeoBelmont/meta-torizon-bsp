# torizon-signed: OP-TEE verifies the trusted applications with the public
# part of TEGRA_OPTEE_TA_SIGN_KEY, which meta-tegra passes as TA_SIGN_KEY.
# With TEGRA_OPTEE_TA_PUBLIC_KEY, it verifies them with that public key
# instead, for trusted applications that are signed elsewhere.
TEGRA_OPTEE_TA_PUBLIC_KEY ??= ""
EXTRA_OEMAKE:append:tegra-signed = "${@' TA_PUBLIC_KEY=' + d.getVar('TEGRA_OPTEE_TA_PUBLIC_KEY') if d.getVar('TEGRA_OPTEE_TA_PUBLIC_KEY') else ''}"
TORIZON_OPTEE_CHECKSUMS = ""
TORIZON_OPTEE_CHECKSUMS:tegra-signed = "${@d.getVar('TEGRA_OPTEE_TA_PUBLIC_KEY') + ':True' if d.getVar('TEGRA_OPTEE_TA_PUBLIC_KEY') else ''}"
do_compile[file-checksums] += "${TORIZON_OPTEE_CHECKSUMS}"
