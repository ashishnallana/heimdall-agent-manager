"""Regenerate the TEST-ONLY RS256 signing key used to mint ID tokens in tests.

The private exponent in oidc_rs256_signing.json is a throwaway key that exists
only so tests can sign tokens with dynamic claims (nonce, aud, exp). It is never
trusted outside the test fixtures (tests serve its public half as the JWKS).

Usage: python3 generate_oidc_signing_fixture.py [path-to-openssl]
"""
import base64
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def field(text, name):
    m = re.search(name + r":\s*\n((?:\s+[0-9a-f:]+\n)+)", text)
    return bytes.fromhex(re.sub(r"[\s:]", "", m.group(1))).lstrip(b"\x00")


openssl = sys.argv[1] if len(sys.argv) > 1 else "openssl"
with tempfile.TemporaryDirectory() as directory:
    key = Path(directory) / "test-signing.pem"
    subprocess.run([openssl, "genpkey", "-algorithm", "RSA", "-pkeyopt",
                    "rsa_keygen_bits:2048", "-out", str(key)], check=True, capture_output=True)
    text = subprocess.check_output([openssl, "rsa", "-in", str(key), "-text", "-noout"]).decode()
    n, d = field(text, "modulus"), field(text, "privateExponent")
    fixture = {"kid": "test-signing-rs256", "n": b64(n), "e": "AQAB", "d": b64(d)}
    Path(__file__).with_name("oidc_rs256_signing.json").write_text(json.dumps(fixture, indent=2) + "\n")
print("Generated TEST-ONLY signing key fixture")
