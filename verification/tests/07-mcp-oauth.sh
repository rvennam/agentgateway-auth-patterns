#!/bin/bash
TEST_NAME=07-mcp-oauth; . "$(dirname "$0")/lib.sh"
KC_ISS=$GW/keycloak/realms/authtest
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: mcp-everything}
spec:
  mcp:
    targets:
      - name: everything
        static: {host: mcp-everything.authtest.svc.cluster.local, port: 8080, path: /mcp, protocol: StreamableHTTP}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-mcp}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches:
        - {path: {type: PathPrefix, value: /mcp}}
        - {path: {type: PathPrefix, value: /.well-known/oauth-protected-resource/mcp}}
        - {path: {type: PathPrefix, value: /.well-known/oauth-authorization-server/mcp}}
      backendRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: mcp-everything}]
Y
settle 5
MCPINIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"authtest","version":"1"}}}'
mcp() { curl -s -o /tmp/authtest.body -w '%{http_code}' --max-time 20 -X POST $GW/mcp -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' "$@" -d "$MCPINIT"; }
expect "no policy: MCP initialize -> 200" 200 -X POST $GW/mcp -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d "$MCPINIT"
# README OSS shape: backend.mcpAuthentication + provider: {keycloak: {}}
out=$(kubectl apply -n authtest -f - 2>&1 <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: mcp-oauth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-mcp}]
  backend:
    mcpAuthentication:
      mode: Strict
      issuer: "$KC_ISS"
      audiences: ["authtest-mcp"]
      jwks: {url: "$KC_ISS/protocol/openid-connect/certs"}
      provider: {keycloak: {}}
      resourceMetadata:
        resource: "$GW/mcp"
        scopesSupported: [openid, profile, offline_access]
        bearerMethodsSupported: [header]
Y
); log "README backend.mcpAuthentication: $(echo "$out" | head -c 220)"
# Deprecated-but-present shape: backend.mcp.authentication, provider enum string, targeting the Backend
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: mcp-oauth}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: mcp-everything}]
  backend:
    mcp:
      authentication:
        mode: Strict
        issuer: "$KC_ISS"
        audiences: ["authtest-mcp"]
        jwks: {url: "$KC_ISS/protocol/openid-connect/certs"}
        provider: Keycloak
        resourceMetadata:
          resource: "$GW/mcp"
          scopesSupported: [openid, profile, offline_access]
          bearerMethodsSupported: [header]
Y
wait_policy agentgatewaypolicy mcp-oauth; settle
run_flow() {
  expect "$1: MCP initialize w/o token -> 401" 401 -X POST $GW/mcp -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d "$MCPINIT"
  log "-- 401 WWW-Authenticate: $(curl -s -D - -o /dev/null -X POST $GW/mcp -H 'content-type: application/json' -d "$MCPINIT" | grep -i www-auth | tr -d '\r' | head -c 300)"
  PRM=$(curl -s $GW/.well-known/oauth-protected-resource/mcp); log "-- protected-resource: $(echo "$PRM" | jq -c . | head -c 400)"
  ASM=$(curl -s $GW/.well-known/oauth-authorization-server/mcp); log "-- auth-server metadata: $(echo "$ASM" | jq -c '{issuer, authorization_endpoint, token_endpoint, registration_endpoint, code_challenge_methods_supported}' | head -c 500)"
  REG=$(echo "$ASM" | jq -r .registration_endpoint)
  DCR=$(curl -s -X POST "$REG" -H 'content-type: application/json' -d '{"client_name":"authtest-mcp-client","redirect_uris":["http://localhost:6274/oauth/callback"],"grant_types":["authorization_code"],"response_types":["code"],"token_endpoint_auth_method":"none"}')
  CID=$(echo "$DCR" | jq -r .client_id); log "-- DCR at $REG -> client_id=$CID $(echo "$DCR" | jq -c '{client_name, token_endpoint_auth_method, error, error_description}' | head -c 200)"
  if [ -n "$CID" ] && [ "$CID" != null ]; then PASS=$((PASS+1)); log "PASS DCR returned client_id"; else FAIL=$((FAIL+1)); log "FAIL DCR"; fi
  # Authorization code + PKCE flow against the DCR client, driving Keycloak's login form with curl
  AUTHZ=$(echo "$ASM" | jq -r .authorization_endpoint); TOKEN_EP=$(echo "$ASM" | jq -r .token_endpoint)
  VER=$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-64); CH=$(printf '%s' "$VER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  JAR=$(mktemp); rm -f $JAR
  LOGIN=$(curl -s -c $JAR -b $JAR -L "$AUTHZ?client_id=$CID&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A6274%2Foauth%2Fcallback&scope=openid&code_challenge=$CH&code_challenge_method=S256&state=xyz&resource=$GW%2Fmcp")
  ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g')
  log "-- login form action: ${ACTION:0:80}..."
  LOC=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw)
  CODE=$(echo "$LOC" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p'); log "-- redirect: ${LOC:0:60}... code_len=${#CODE}"
  TOK=$(curl -s -X POST "$TOKEN_EP" -d grant_type=authorization_code -d "client_id=$CID" -d "code=$CODE" -d code_verifier=$VER --data-urlencode redirect_uri=http://localhost:6274/oauth/callback)
  AT=$(echo "$TOK" | jq -r .access_token); log "-- token resp: $(echo "$TOK" | jq -c '{token_type, scope, error, error_description}')"
  if [ -n "$AT" ] && [ "$AT" != null ]; then PASS=$((PASS+1)); log "PASS auth-code+PKCE via DCR client got access_token; claims=$(jwtclaims $AT | jq -c '{iss,aud,azp,sub,preferred_username}')"; else FAIL=$((FAIL+1)); log "FAIL no access token"; fi
  expect "$1: MCP initialize with DCR-client token -> 200" 200 -X POST $GW/mcp -H "Authorization: Bearer $AT" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d "$MCPINIT"
  expect "$1: MCP initialize with wrong-aud local token -> 401" 401 -X POST $GW/mcp -H "Authorization: Bearer $(mint '{"sub":"x"}')" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d "$MCPINIT"
  TL=$(curl -s -X POST $GW/mcp -H "Authorization: Bearer $AT" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | grep '^data:' | head -1 | sed 's/^data: //'); log "-- tools/list (first): $(echo "$TL" | jq -c '[.result.tools[].name] | .[0:6]' 2>/dev/null)"
}
run_flow "backend.mcp.authentication"
# Current route-level shape: traffic.jwtAuthentication.mcp
kubectl delete agentgatewaypolicy mcp-oauth -n authtest >/dev/null
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: mcp-oauth-route}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-mcp}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "$KC_ISS"
          audiences: ["authtest-mcp"]
          jwks: {remote: {url: "$KC_ISS/protocol/openid-connect/certs"}}
      mcp:
        provider: Keycloak
        resourceMetadata:
          resource: "$GW/mcp"
          scopesSupported: [openid, profile, offline_access]
          bearerMethodsSupported: [header]
Y
wait_policy agentgatewaypolicy mcp-oauth-route; settle
run_flow "traffic.jwtAuthentication.mcp"
summary
