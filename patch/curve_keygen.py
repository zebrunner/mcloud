#!/usr/bin/env python3
"""A CURVE key pair for the ZeroMQ security of STF (zebrunner/stf ZEBRUNNER.md#zeromq).

Prints `public=<key>` and `secret=<key>`, the keys are 64 hex characters, the same as `stf curve-keygen`: a new pair, or
with `-` the pair of the secret key read from stdin (not an argument: the arguments of a process are visible to every
user). X25519 of RFC 7748 in pure Python: the hosts of mcloud and mcloud-agent have Python, not always the cryptography
package or an openssl with X25519 (the LibreSSL of macOS).
Synced from zebrunner/mcloud-conventions (shared/patch/), change it there.
"""

import os
import re
import sys

P = 2**255 - 19
A24 = 121665


def x25519_base(secret: bytes) -> bytes:
    """The public key of a secret key: the scalar multiplication of the base point 9 (RFC 7748, section 5)."""
    k = bytearray(secret)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    scalar = int.from_bytes(k, "little")
    x1 = 9
    x2, z2, x3, z3 = 1, 0, x1, 1
    swap = 0
    for t in reversed(range(255)):
        bit = (scalar >> t) & 1
        swap ^= bit
        if swap:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b = (x2 + z2) % P, (x2 - z2) % P
        aa, bb = a * a % P, b * b % P
        e = (aa - bb) % P
        c, d = (x3 + z3) % P, (x3 - z3) % P
        da, cb = d * a % P, c * b % P
        x3 = (da + cb) ** 2 % P
        z3 = x1 * (da - cb) ** 2 % P
        x2 = aa * bb % P
        z2 = e * (aa + A24 * e) % P
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")


def main() -> int:
    if len(sys.argv) > 2 or (len(sys.argv) == 2 and sys.argv[1] != "-"):
        print(f"usage: {sys.argv[0]} [-]  (-: the secret key from stdin)", file=sys.stderr)
        return 2
    if len(sys.argv) == 2:
        key = sys.stdin.read().strip()
        if not re.fullmatch(r"[0-9a-fA-F]{64}", key):
            print("The secret key must be 64 hex characters", file=sys.stderr)
            return 1
        secret = bytes.fromhex(key)
    else:
        secret = os.urandom(32)
    print(f"public={x25519_base(secret).hex()}")
    print(f"secret={secret.hex()}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
