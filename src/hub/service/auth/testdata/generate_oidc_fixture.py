"""Regenerate public RS256 fixtures; the temporary signing key is discarded.

Usage: python3 generate_oidc_fixture.py [path-to-openssl]
No network or production credentials are used.
"""
import base64
import json
from pathlib import Path
import subprocess
import sys
import tempfile


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def compact(value):
    return json.dumps(value, separators=(",", ":")).encode()


openssl = sys.argv[1] if len(sys.argv) > 1 else "openssl"
with tempfile.TemporaryDirectory() as directory:
    key = Path(directory) / "fixture.pem"
    subprocess.run([openssl, "genpkey", "-algorithm", "RSA", "-pkeyopt",
                    "rsa_keygen_bits:2048", "-out", str(key)], check=True, capture_output=True)
    modulus = subprocess.check_output(
        [openssl, "rsa", "-in", str(key), "-modulus", "-noout"]
    ).decode().strip().split("=")[1]
    jwks = {"keys": [{"kty": "RSA", "kid": "test-rs256", "alg": "RS256", "use": "sig",
                      "n": b64(bytes.fromhex(modulus)), "e": "AQAB"}]}
    claims = {"iss": "https://auth.mundus.in/application/o/heimdall-native/",
              "aud": ["heimdall-native", "heimdall-api"], "sub": "subject-1",
              "exp": 1792407600, "scope": "openid profile heimdall.api"}
    changes = {"valid": {}, "short": {"exp": 1792404010},
               "audience_string": {"aud": "heimdall-api"},
               "wrong_issuer": {"iss": "https://evil.example/"},
               "wrong_audience": {"aud": ["heimdall-native"]},
               "wrong_scope": {"scope": "openid heimdall.api.evil"},
               "expired": {"exp": 1792404000}, "future": {"nbf": 1792404001},
               "empty_sub": {"sub": ""}, "second_subject": {"sub": "subject-2"}}
    tokens = {}

    def sign(header, body):
        message = (b64(compact(header)) + "." + b64(compact(body))).encode()
        signature = subprocess.run([openssl, "dgst", "-sha256", "-sign", str(key)],
                                   input=message, check=True, capture_output=True).stdout
        return message.decode() + "." + b64(signature)

    for name, change in changes.items():
        tokens[name] = sign({"alg": "RS256", "kid": "test-rs256"}, claims | change)
    for name, header in {
        "wrong_alg": {"alg": "HS256", "kid": "test-rs256"},
        "critical": {"alg": "RS256", "kid": "test-rs256", "crit": ["extension"]},
        "unknown_kid": {"alg": "RS256", "kid": "missing"},
    }.items():
        tokens[name] = sign(header, claims)
    Path(__file__).with_name("oidc_rs256.json").write_text(
        json.dumps({"jwks": json.dumps(jwks, separators=(",", ":")), "tokens": tokens}, indent=2) + "\n"
    )
print("Generated public-key/token fixtures; temporary signing key removed")
