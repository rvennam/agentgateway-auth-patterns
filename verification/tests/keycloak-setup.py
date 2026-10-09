#!/usr/bin/env python3
"""Bootstrap Keycloak realms 'authtest' and 'upstream' via admin REST (port-forward on 18080)."""
import json, os, urllib.request, urllib.parse, sys
KC = "http://localhost:18080/keycloak"
def req(method, url, data=None, tok=None, form=False):
    body = None; hdr = {}
    if data is not None:
        body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
        hdr["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
    if tok: hdr["Authorization"] = "Bearer " + tok
    r = urllib.request.Request(url, data=body, method=method, headers=hdr)
    try:
        with urllib.request.urlopen(r) as resp:
            raw = resp.read(); return resp.status, (json.loads(raw) if raw.strip().startswith(b"[") or raw.strip().startswith(b"{") else raw.decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]
st, t = req("POST", f"{KC}/realms/master/protocol/openid-connect/token", {"username":"admin","password":os.environ.get("KC_ADMIN_PW","authtest-Adm1n-9f3c7b"),"grant_type":"password","client_id":"admin-cli"}, form=True)
TOK = t["access_token"]
A = lambda m, p, d=None: req(m, f"{KC}/admin/realms{p}", d, TOK)
def mk_realm(r):
    print("realm", r, A("POST", "", {"realm": r, "enabled": True, "sslRequired": "none", "accessTokenLifespan": 3600})[0])
    st, comps = A("GET", f"/{r}/components?type=org.keycloak.services.clientregistration.policy.ClientRegistrationPolicy")
    for c in comps:
        if c["providerId"] == "trusted-hosts" or (c.get("subType") == "anonymous" and c["providerId"] in ("allowed-client-templates","consent-required","scope","protocol-mappers")):
            A("DELETE", f"/{r}/components/{c['id']}")
    print("  relaxed anonymous DCR policies")
    mappers = [
      {"name":"aud","protocol":"openid-connect","protocolMapper":"oidc-audience-mapper","config":{"included.custom.audience":"authtest-mcp","access.token.claim":"true"}},
      {"name":"tier","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"user.attribute":"tier","claim.name":"tier","jsonType.label":"String","access.token.claim":"true","id.token.claim":"true"}},
      {"name":"role","protocol":"openid-connect","protocolMapper":"oidc-usermodel-attribute-mapper","config":{"user.attribute":"role","claim.name":"role","jsonType.label":"String","access.token.claim":"true","id.token.claim":"true"}},
      {"name":"may_act","protocol":"openid-connect","protocolMapper":"oidc-hardcoded-claim-mapper","config":{"claim.name":"may_act","claim.value":"{\"sub\":\"system:serviceaccount:authtest:agent-runtime\"}","jsonType.label":"JSON","access.token.claim":"true","id.token.claim":"true"}},
    ]
    print("  scope", A("POST", f"/{r}/client-scopes", {"name":"authtest","protocol":"openid-connect","attributes":{"include.in.token.scope":"true"},"protocolMappers":mappers})[0])
    st, scopes = A("GET", f"/{r}/client-scopes"); sid = [s["id"] for s in scopes if s["name"]=="authtest"][0]
    print("  default scope", A("PUT", f"/{r}/default-default-client-scopes/{sid}")[0])
    st, up = A("GET", f"/{r}/users/profile"); up["unmanagedAttributePolicy"] = "ENABLED"; print("  user profile", A("PUT", f"/{r}/users/profile", up)[0])
    print("  client agw", A("POST", f"/{r}/clients", {"clientId":"agw","enabled":True,"publicClient":False,"secret":"agw-secret","directAccessGrantsEnabled":True,"standardFlowEnabled":True,"serviceAccountsEnabled":True,"redirectUris":["*"],"webOrigins":["*"]})[0])
    for n, tier, role in (("alice","paid","admin"),("bob","free","analyst")):
        print("  user", n, A("POST", f"/{r}/users", {"username":n,"email":f"{n}@example.com","emailVerified":True,"firstName":n,"lastName":"Test","enabled":True,"requiredActions":[],"attributes":{"tier":[tier],"role":[role]},"credentials":[{"type":"password","value":f"{n}-pw","temporary":False}]})[0])
for r in ("authtest", "upstream"): mk_realm(r)
