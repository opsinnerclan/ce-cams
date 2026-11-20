#!/usr/bin/env python3
"""
ce_cams_patch_fork.py - put your own license public key into an nx_open checkout, in place of
Network Optix's three built-in keys, so the client you build accepts only licenses signed with
your matching private key.

  python ce_cams_patch_fork.py --public-key license_public.pem PATH_TO_NX_OPEN

PATH_TO_NX_OPEN is the root of your nx_open checkout. The public key is the PEM file whose private
half your license issuer (e.g. CE Cams Cloud, or your own tool) signs licenses with. This script
only reads the PUBLIC key; it never needs, generates or touches a private key.

Safe to run again: if the fork already carries your key it does nothing. The original file is
kept alongside as license.cpp.orig.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# The file in nx_open that carries Network Optix's license public keys.
LICENSE_CPP = Path("vms/libs/nx_vms_common/src/licensing/license.cpp")


def c_string_literal(pem: str, indent: str = "    ") -> str:
    lines = pem.strip().splitlines()
    return "\n".join(f'{indent}"{line}\\n"' for line in lines[:-1]) + f'\n{indent}"{lines[-1]}"'


def patch_fork(nx_open_root: Path, public_key_file: Path) -> int:
    if not public_key_file.is_file():
        print(f"Public key not found: {public_key_file}")
        return 1
    target = nx_open_root / LICENSE_CPP
    if not target.is_file():
        print(f"Not found: {target}\nGive the root folder of your nx_open checkout.")
        return 1
    source = target.read_text(encoding="utf-8")
    pub = public_key_file.read_text()
    literal = c_string_literal(pub)
    pattern = re.compile(
        r'(static constexpr const char\* (nxRSAPublicKey\d?) = )((?:\s*"[^"]*")+)(;)')
    found = pattern.findall(source)
    if len(found) != 3:
        print(f"Expected 3 public keys in {target}, found {len(found)}. Is this a 6.x checkout?")
        return 1
    if all(pub.strip().splitlines()[1] in m[2] for m in found):
        print("Your fork already uses your public key.")
        return 0
    backup = target.with_suffix(".cpp.orig")
    if not backup.exists():
        backup.write_text(source, encoding="utf-8")
    # One key pair of yours replaces all three of Network Optix's, so only licenses you sign
    # are valid in this client.
    patched = pattern.sub(lambda m: f"{m.group(1)}\n{literal}{m.group(4)}", source)
    target.write_text(patched, encoding="utf-8")
    print(f"Patched {target}")
    print(f"  Network Optix's 3 license keys -> your public key (original in {backup.name})")
    print("Rebuild the client. Licenses you sign will then be valid in it, and only in it.")
    return 0


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--public-key", required=True, metavar="FILE",
                   help="your license public key (PEM)")
    p.add_argument("path", help="root folder of your nx_open checkout")
    args = p.parse_args()
    return patch_fork(Path(args.path), Path(args.public_key))


if __name__ == "__main__":
    sys.exit(main())
