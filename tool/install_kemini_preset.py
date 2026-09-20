#!/usr/bin/env python3
"""Install the user-supplied, local-only preset without changing its bytes."""
import argparse
import hashlib
from pathlib import Path


EXPECTED_SHA256 = "3d394088a2b4c19a6d819a9cfba7bfacb372296a626c1192eaa6cab62c383968"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    args = parser.parse_args()
    payload = args.source.read_bytes()
    if hashlib.sha256(payload).hexdigest() != EXPECTED_SHA256:
        parser.error("This is not the verified Kemini Dramatron v3.1 source file.")
    destination = Path(__file__).resolve().parents[1] / "assets/presets/kemini_dramatron_v3_1.json"
    if destination.exists() and destination.read_bytes() != payload:
        parser.error("Destination contains a different preset; preserve it before replacing it.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_bytes(payload)
    print(f"Installed verified preset: {destination}")
    print("Runtime enable/disable choices are applied separately; source bytes are unchanged.")


if __name__ == "__main__":
    main()
