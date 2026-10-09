#!/usr/bin/env python3
"""mint.py: generate (once) an RSA key + JWKS, and mint JWTs.  usage: mint.py '<json-claims>' [ttl_seconds]"""
import json, base64, time, sys, os, jwt
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives import serialization
D = os.path.dirname(os.path.abspath(__file__))
pem = os.path.join(D, "authtest.pem")
if not os.path.exists(pem):
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    open(pem, "wb").write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
    pub = key.public_key().public_numbers()
    b64 = lambda n, l: base64.urlsafe_b64encode(n.to_bytes(l, 'big')).rstrip(b'=').decode()
    json.dump({"keys": [{"kty": "RSA", "kid": "authtest", "use": "sig", "alg": "RS256", "n": b64(pub.n, 256), "e": b64(pub.e, 3)}]}, open(os.path.join(D, "jwks.json"), "w"))
priv = open(pem).read()
claims = json.loads(sys.argv[1]) if len(sys.argv) > 1 else {}
ttl = int(sys.argv[2]) if len(sys.argv) > 2 else 3600
now = int(time.time())
base = {"iss": "https://authtest.example", "aud": "authtest", "iat": now, "exp": now + ttl}
print(jwt.encode({**base, **claims}, priv, algorithm="RS256", headers={"kid": "authtest"}))
