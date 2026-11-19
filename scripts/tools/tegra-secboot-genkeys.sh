#!/bin/sh
# Copyright (c) 2026 Toradex AG
# SPDX-License-Identifier: MIT
#
# Create the keys for UEFI Secure Boot on NVIDIA Jetson (torizon-signed), in
# the layout tegra-torizon-signed.bbclass expects in TEGRA_SECBOOT_KEYDIR:
#
#   uefi/PK.{key,crt} uefi/KEK.{key,crt} uefi/db.{key,crt}
#                            UEFI Secure Boot keys; db signs L4TLauncher and
#                            the UKI, PK and KEK are enrolled with it
#   modsign/modsign_key.pem  kernel module signing key and certificate
#   optee/ta_sign_key.pem    OP-TEE trusted application signing key
#   capsule/root.{key,crt} capsule/sub.{key,crt} capsule/signer.pem
#                            certificate chain for the firmware update
#                            capsules: the firmware trusts root.crt, and the
#                            build signs with signer.pem (certificate and key)
#   bootchain/pkc.pem        with --bootchain: Tegra boot chain signing key,
#   bootchain/pkc1.pem         and two more, to fuse their hashes too
#   bootchain/pkc2.pem
#   bootchain/sbk.key        with --bootchain: Tegra boot chain encryption key
#   bootchain/oem_k1.key     with --bootchain: fuse keys OemK1 (the key of the
#   bootchain/oem_k2.key       EKB) and OemK2
#   bootchain/ekb_auth.key   with --bootchain: keys inside the EKB, for the UEFI
#   bootchain/ekb_sym2.key     variable authentication and the disk encryption
#
# Keys that exist are kept: run it again on a key directory to add the keys
# that a newer version of the layer needs.
#
# The boot chain keys only take effect once fused in the SoC, which is
# irreversible: see docs/README-nvidia-secure-boot.md before fusing.
#
# The build does not need capsule/root.key and capsule/sub.key: keep them
# offline. Keep production keys off the build machine where possible, and
# never commit them to a repository.

set -eu

usage() {
	echo "usage: $0 [--bootchain] [--cn PREFIX] KEYDIR" >&2
	exit 1
}

bootchain=0
cn="Torizon"
while [ $# -gt 1 ]; do
	case "$1" in
	--bootchain) bootchain=1 ;;
	--cn) shift; cn="$1" ;;
	*) usage ;;
	esac
	shift
done
[ $# -eq 1 ] || usage
keydir="$1"

umask 077
mkdir -p "${keydir}/uefi" "${keydir}/modsign" "${keydir}/optee" "${keydir}/capsule"

created=""
# missing FILE: true when FILE has to be created
missing() {
	if [ -e "${keydir}/$1" ]; then
		echo "Keeping ${keydir}/$1"
		return 1
	fi
	created="${created} $1"
}

for name in PK KEK db; do
	if missing "uefi/${name}.key"; then
		openssl req -new -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
			-subj "/CN=${cn} UEFI ${name}/" \
			-keyout "${keydir}/uefi/${name}.key" -out "${keydir}/uefi/${name}.crt" 2>/dev/null
	fi
done

if missing "modsign/modsign_key.pem"; then
	# Extensions as in the kernel's certs/default_x509.genkey
	cat > "${keydir}/modsign/x509.genkey" <<EOF
[ req ]
default_bits = 4096
distinguished_name = req_distinguished_name
prompt = no
string_mask = utf8only
x509_extensions = myexts

[ req_distinguished_name ]
CN = ${cn} kernel module signing key

[ myexts ]
basicConstraints=critical,CA:FALSE
keyUsage=digitalSignature
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
	openssl req -new -x509 -nodes -utf8 -sha256 -days 7300 -batch \
		-config "${keydir}/modsign/x509.genkey" -outform PEM \
		-keyout "${keydir}/modsign/modsign_key.pem" -out "${keydir}/modsign/modsign_key.crt" 2>/dev/null
	cat "${keydir}/modsign/modsign_key.crt" >> "${keydir}/modsign/modsign_key.pem"
fi

if missing "optee/ta_sign_key.pem"; then
	# RSA-2048, as the default key of OP-TEE that it replaces
	openssl genrsa -out "${keydir}/optee/ta_sign_key.pem" 2048 2>/dev/null
fi

# Root, intermediate and signing certificates, with the extensions of the
# EDK2 test certificates (BaseTools/Source/Python/Pkcs7Sign/Readme.md)
if missing "capsule/signer.pem"; then
	# Not over a part of an earlier chain: a root that devices trust already
	# must not be replaced by a new one
	for f in root.key root.crt sub.key sub.crt; do
		if [ -e "${keydir}/capsule/$f" ]; then
			echo "${keydir}/capsule has $f but no signer.pem: not creating a new capsule key chain over it." >&2
			echo "Restore signer.pem, or move the capsule directory away to create a new chain." >&2
			exit 1
		fi
	done
	c="${keydir}/capsule"
	cat > "${c}/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_distinguished_name
prompt = no

[ req_distinguished_name ]
CN = ${cn} capsule root

[ v3_ca ]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:true
keyUsage = critical,digitalSignature,cRLSign,keyCertSign

[ usr_cert ]
basicConstraints = CA:FALSE
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
keyUsage = critical,nonRepudiation,digitalSignature,keyEncipherment
EOF
	# With its own configuration: the root must be a CA whatever the
	# default configuration of openssl says
	openssl req -new -x509 -newkey rsa:3072 -sha256 -days 7300 -nodes \
		-config "${c}/openssl.cnf" -extensions v3_ca \
		-keyout "${c}/root.key" -out "${c}/root.crt" 2>/dev/null
	openssl req -new -newkey rsa:3072 -sha256 -nodes \
		-subj "/CN=${cn} capsule intermediate/" \
		-keyout "${c}/sub.key" -out "${c}/sub.csr" 2>/dev/null
	openssl x509 -req -in "${c}/sub.csr" -sha256 -days 7300 \
		-CA "${c}/root.crt" -CAkey "${c}/root.key" -CAcreateserial \
		-extfile "${c}/openssl.cnf" -extensions v3_ca -out "${c}/sub.crt" 2>/dev/null
	openssl req -new -newkey rsa:3072 -sha256 -nodes \
		-subj "/CN=${cn} capsule signing/" \
		-keyout "${c}/signer.key" -out "${c}/signer.csr" 2>/dev/null
	openssl x509 -req -in "${c}/signer.csr" -sha256 -days 7300 \
		-CA "${c}/sub.crt" -CAkey "${c}/sub.key" -CAcreateserial \
		-extfile "${c}/openssl.cnf" -extensions usr_cert -out "${c}/signer.crt" 2>/dev/null
	if ! openssl verify -CAfile "${c}/root.crt" -untrusted "${c}/sub.crt" "${c}/signer.crt" >/dev/null 2>&1; then
		echo "The capsule certificates do not form a valid chain, see ${c}" >&2
		exit 1
	fi
	cat "${c}/signer.crt" "${c}/signer.key" > "${c}/signer.pem"
	rm -f "${c}/sub.csr" "${c}/signer.csr" "${c}/signer.key" "${c}/signer.crt"
fi

if [ "${bootchain}" = "1" ]; then
	mkdir -p "${keydir}/bootchain"
	# Orin (T234) accepts RSA-3072 PKC keys. Three of them: the hashes of
	# the PKC keys can only be fused once, and with three fused, a key can
	# be revoked later. The build signs with pkc.pem.
	for name in pkc pkc1 pkc2; do
		if missing "bootchain/${name}.pem"; then
			openssl genrsa -out "${keydir}/bootchain/${name}.pem" 3072 2>/dev/null
		fi
	done
	if missing "bootchain/sbk.key"; then
		# SBK: 256 bits, as eight 32-bit words in hexadecimal
		printf '%s\n' "$(od -An -tx4 -N32 /dev/urandom | tr -s ' \n' ' ' | \
			sed -e 's/^ //' -e 's/ $//' -e 's/\([0-9a-f]\{8\}\)/0x\1/g')" > "${keydir}/bootchain/sbk.key"
	fi
	# OemK1 and OemK2, the fuse keys for the EKB and other uses: 256 bits,
	# as one hexadecimal number, the form that gen_ekb.py reads. And the
	# keys that go into the EKB: the one that authenticates the UEFI
	# variables (128 bits) and the disk encryption key (256 bits).
	for name in oem_k1 oem_k2 ekb_sym2; do
		if missing "bootchain/${name}.key"; then
			od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "${keydir}/bootchain/${name}.key"
			echo >> "${keydir}/bootchain/${name}.key"
		fi
	done
	if missing "bootchain/ekb_auth.key"; then
		od -An -tx1 -N16 /dev/urandom | tr -d ' \n' > "${keydir}/bootchain/ekb_auth.key"
		echo >> "${keydir}/bootchain/ekb_auth.key"
	fi
	chmod 600 "${keydir}"/bootchain/*.key "${keydir}"/bootchain/*.pem
fi

if [ -z "${created}" ]; then
	echo "No key was missing in ${keydir}."
	exit 0
fi
echo "Created in ${keydir}:${created}"
echo "Set in local.conf:"
echo "  INHERIT += \"torizon-signed\""
echo "  TEGRA_SECBOOT_KEYDIR = \"$(cd "${keydir}" && pwd)\""
