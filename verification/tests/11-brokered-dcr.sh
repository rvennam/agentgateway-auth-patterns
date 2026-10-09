#!/bin/bash
TEST_NAME=11-brokered-dcr; . "$(dirname "$0")/lib.sh"
KC_ISS=$GW/keycloak/realms/authtest
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: oauth-issuer-backend}
spec:
  static: {host: enterprise-agentgateway.agentgateway-system.svc.cluster.local, port: 7777}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-oauth-issuer}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /oauth-issuer}}]
      backendRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: oauth-issuer-backend}]
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: keycloak-jwks}
spec:
  static: {host: keycloak.authtest.svc.cluster.local, port: 8080}
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata: {name: mcp-brokered}
spec:
  mcp:
    targets:
      - name: echo
        static: {host: mcp-echo.authtest.svc.cluster.local, port: 8080, path: /mcp, protocol: StreamableHTTP}
  policies:
    mcp:
      authentication:
        mode: Strict
        issuer: "$KC_ISS"
        audiences: [agw]
        jwks:
          backendRef: {group: agentgateway.dev, kind: AgentgatewayBackend, name: keycloak-jwks}
          jwksPath: /keycloak/realms/authtest/protocol/openid-connect/certs
          cacheDuration: 5m
        resourceMetadata:
          agentgateway.dev/issuer-proxy: "http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth-issuer"
          resource: "$GW/mcp-brokered"
          authorizationServers: ["$GW/mcp-brokered"]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-mcp-brokered}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches:
        - {path: {type: PathPrefix, value: /mcp-brokered}}
        - {path: {type: PathPrefix, value: /.well-known/oauth-protected-resource/mcp-brokered}}
        - {path: {type: PathPrefix, value: /.well-known/oauth-authorization-server/mcp-brokered}}
      backendRefs: [{group: enterpriseagentgateway.solo.io, kind: EnterpriseAgentgatewayBackend, name: mcp-brokered}]
Y
settle 10
log "backend status: $(kubectl get enterpriseagentgatewaybackend mcp-brokered -n authtest -o jsonpath='{.status.conditions[*].message}' | head -c 200)"
MCPINIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"authtest","version":"1"}}}'
H=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream')
expect "brokered: no token -> 401" 401 -X POST $GW/mcp-brokered "${H[@]}" -d "$MCPINIT"
log "-- issuer metadata direct: $(curl -s $GW/oauth-issuer/.well-known/oauth-authorization-server | jq -c '{issuer, authorization_endpoint, token_endpoint, registration_endpoint}' | head -c 400)"
PRM=$(curl -s $GW/.well-known/oauth-protected-resource/mcp-brokered); log "-- protected-resource: $(echo "$PRM" | jq -c .)"
ASM=$(curl -s $GW/.well-known/oauth-authorization-server/mcp-brokered); log "-- AS metadata (should point at gateway /oauth-issuer): $(echo "$ASM" | jq -c '{issuer, authorization_endpoint, token_endpoint, registration_endpoint}' | head -c 500)"
REG=$(echo "$ASM" | jq -r .registration_endpoint)
if echo "$REG" | grep -q '/oauth-issuer/'; then PASS=$((PASS+1)); log "PASS registration_endpoint rewritten to gateway issuer"; else FAIL=$((FAIL+1)); log "FAIL registration_endpoint=$REG"; fi
DCR=$(curl -s -X POST "$REG" -H 'content-type: application/json' -d '{"client_name":"inspector","redirect_uris":["http://localhost:6274/oauth/callback"],"grant_types":["authorization_code"],"response_types":["code"],"token_endpoint_auth_method":"none"}')
CID=$(echo "$DCR" | jq -r .client_id); log "-- gateway-brokered DCR -> $(echo "$DCR" | jq -c '{client_id, client_secret: (.client_secret|tostring|.[0:4]), error, error_description}')"
if [ "$CID" = agw ]; then PASS=$((PASS+1)); log "PASS /register returned the pre-registered client_id (agw)"; else FAIL=$((FAIL+1)); log "FAIL unexpected client_id $CID"; fi
DCR2=$(curl -s -X POST "$REG" -H 'content-type: application/json' -d '{"client_name":"evil","redirect_uris":["http://evil.example/cb"]}'); log "-- DCR with unlisted redirect_uri: $(echo "$DCR2" | jq -c '{client_id, error}')"
# auth code + PKCE through the gateway issuer, logging in at Keycloak
AUTHZ=$(echo "$ASM" | jq -r .authorization_endpoint); TOKEN_EP=$(echo "$ASM" | jq -r .token_endpoint)
VER=$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-64); CH=$(printf '%s' "$VER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
JAR=$(mktemp); rm -f $JAR
L1=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{http_code} %{redirect_url}' "$AUTHZ?client_id=$CID&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A6274%2Foauth%2Fcallback&scope=openid&code_challenge=$CH&code_challenge_method=S256&state=xyz&resource=$GW%2Fmcp-brokered"); log "-- issuer /authorize: ${L1:0:120}"
IDP=$(echo "$L1" | cut -d' ' -f2); LOGIN=$(curl -s -c $JAR -b $JAR -L "$IDP"); ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g')
CB=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw); log "-- keycloak -> ${CB:0:90}"
# follow the downstream callback chain until redirected to localhost:6274
NEXT=$CB; for i in 1 2 3 4; do R=$(curl -s -c $JAR -b $JAR -o /tmp/br.body -w '%{http_code} %{redirect_url}' "$NEXT"); C=${R%% *}; N=${R#* }; log "-- hop$i: $C ${N:0:100}"; if echo "$N" | grep -q 'localhost:6274'; then break; fi; if [ "$C" = 200 ]; then log "-- 200 page snippet: $(grep -oE '<form[^>]*>|<title>[^<]*' /tmp/br.body | head -3 | tr '\n' ' ')"; break; fi; [ -z "$N" ] && break; NEXT=$N; done
CODE=$(echo "$N" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
TOK=$(curl -s -X POST "$TOKEN_EP" -d grant_type=authorization_code -d "client_id=$CID" -d "code=$CODE" -d code_verifier=$VER --data-urlencode redirect_uri=http://localhost:6274/oauth/callback); AT=$(echo "$TOK" | jq -r .access_token)
log "-- token: $(echo "$TOK" | jq -c '{token_type, expires_in, error, error_description}')"
if [ -n "$AT" ] && [ "$AT" != null ]; then PASS=$((PASS+1)); log "PASS gateway-issuer auth-code flow -> token; claims=$(jwtclaims $AT | jq -c '{iss,aud,azp,sub,preferred_username}')"; else FAIL=$((FAIL+1)); log "FAIL no token"; fi
expect "brokered: MCP initialize with issued token -> 200" 200 -X POST $GW/mcp-brokered "${H[@]}" -H "Authorization: Bearer $AT" -d "$MCPINIT"
CALL=$(curl -s -X POST $GW/mcp-brokered "${H[@]}" -H "Authorization: Bearer $AT" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"headers","arguments":{}}}'); log "-- upstream MCP server saw headers: $(echo "$CALL" | sed 's/^data: //' | jq -r '.result.content[0].text' 2>/dev/null | head -c 300)"
summary
