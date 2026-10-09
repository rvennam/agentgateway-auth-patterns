#!/bin/bash
TEST_NAME=07b-mcp-auth0; . "$(dirname "$0")/lib.sh"
ISS="https://$AUTH0_DOMAIN/"
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: mcp-everything-auth0}
spec:
  mcp:
    targets:
      - name: everything
        static: {host: mcp-everything.authtest.svc.cluster.local, port: 8080, path: /mcp, protocol: StreamableHTTP}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-mcp-auth0}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches:
        - {path: {type: PathPrefix, value: /mcp-auth0}}
        - {path: {type: PathPrefix, value: /.well-known/oauth-protected-resource/mcp-auth0}}
        - {path: {type: PathPrefix, value: /.well-known/oauth-authorization-server/mcp-auth0}}
      backendRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: mcp-everything-auth0}]
Y
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: mcp-oauth-auth0}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-mcp-auth0}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "$ISS"
          audiences: ["$AUTH0_AUDIENCE"]
          jwks: {remote: {url: "https://$AUTH0_DOMAIN/.well-known/jwks.json"}}
      mcp:
        provider: Auth0
        resourceMetadata:
          resource: "$GW/mcp-auth0"
          scopesSupported: [openid, profile, offline_access]
Y
wait_policy agentgatewaypolicy mcp-oauth-auth0; settle
MCPINIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"authtest","version":"1"}}}'
H=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream')
expect "auth0: no token -> 401" 401 -X POST $GW/mcp-auth0 "${H[@]}" -d "$MCPINIT"
log "-- protected-resource: $(curl -s $GW/.well-known/oauth-protected-resource/mcp-auth0 | jq -c .)"
ASM=$(curl -s $GW/.well-known/oauth-authorization-server/mcp-auth0); log "-- AS metadata: $(echo "$ASM" | jq -c '{issuer, authorization_endpoint, token_endpoint, registration_endpoint, jwks_uri}' | head -c 600)"
AT=$(curl -s -X POST "https://$AUTH0_DOMAIN/oauth/token" -H 'content-type: application/json' -d "{\"client_id\":\"$AUTH0_CLIENT_ID\",\"client_secret\":\"$AUTH0_CLIENT_SECRET\",\"audience\":\"$AUTH0_AUDIENCE\",\"grant_type\":\"client_credentials\"}" | jq -r .access_token)
expect "auth0: client-credentials JWT -> 200" 200 -X POST $GW/mcp-auth0 "${H[@]}" -H "Authorization: Bearer $AT" -d "$MCPINIT"
expect "auth0: keycloak token -> 401" 401 -X POST $GW/mcp-auth0 "${H[@]}" -H "Authorization: Bearer $(curl -s -X POST $GW/keycloak/realms/authtest/protocol/openid-connect/token -d client_id=agw -d client_secret=agw-secret -d grant_type=password -d username=alice -d password=alice-pw | jq -r .access_token)" -d "$MCPINIT"
# DCR through the gateway's Auth0 adapter (Auth0 /oidc/register is open if the tenant enables it)
REG=$(echo "$ASM" | jq -r .registration_endpoint); DCR=$(curl -s -X POST "$REG" -H 'content-type: application/json' -d '{"client_name":"authtest-auth0-probe","redirect_uris":["http://localhost:6274/oauth/callback"]}'); log "-- DCR via adapter ($REG): $(echo "$DCR" | jq -c '{client_id: (.client_id|tostring|.[0:8]), error, error_description, message}' 2>/dev/null | head -c 300)"
summary
