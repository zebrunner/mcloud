#!/usr/bin/env python3
"""The pin of the certificate of stf-proxy for the enrollment of the nodes (README.md#nodes).

Prints base64 of the SHA-256 of the public key (the DER SubjectPublicKeyInfo) of the first certificate of a PEM file,
the pin of `curl --pinnedpubkey 'sha256//<pin>'` of mcloud-agent. ./zebrunner.sh node-invite uses it without openssl.
"""

import base64
import hashlib
import re
import sys


def element(der: bytes, pos: int) -> tuple[int, int]:
    """The start of the content and the end of the DER element at a position."""
    length = der[pos + 1]
    start = pos + 2
    if length & 0x80:
        size = length & 0x7F
        length = int.from_bytes(der[start : start + size], "big")
        start += size
    end = start + length
    if end > len(der):
        raise ValueError("a cut DER element")
    return start, end


def public_key_info(der: bytes) -> bytes:
    """The DER SubjectPublicKeyInfo of an X.509 certificate (RFC 5280, section 4.1)."""
    certificate, _ = element(der, 0)
    pos, _ = element(der, certificate)
    # the version is optional ([0]), then the serial number, the signature, the issuer, the validity and the subject
    if der[pos] == 0xA0:
        pos = element(der, pos)[1]
    for _ in range(5):
        pos = element(der, pos)[1]
    if der[pos] != 0x30:
        raise ValueError("no SubjectPublicKeyInfo")
    return der[pos : element(der, pos)[1]]


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <certificate.pem>", file=sys.stderr)
        return 2
    with open(sys.argv[1]) as file:
        match = re.search(r"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", file.read(), re.S)
    if not match:
        print("No PEM certificate", file=sys.stderr)
        return 1
    try:
        spki = public_key_info(base64.b64decode("".join(match.group(1).split())))
    except (ValueError, IndexError) as error:
        print(f"Not a certificate: {error}", file=sys.stderr)
        return 1
    print(base64.b64encode(hashlib.sha256(spki).digest()).decode())
    return 0


if __name__ == "__main__":
    sys.exit(main())
