#!/bin/bash
TEST_NAME=12-brokered-dual; . "$(dirname "$0")/lib.sh"
KC_ISS=$GW/keycloak/realms/authtest; UP_ISS=$GW/keycloak/realms/upstream
mk() { # $1 variant yaml for chainedAuth.oauth
kubectl apply -n authtest -f - <<Y
apiVersion: v1
kind: Secret
metadata: {name: upstream-client-secret}
stringData: {client_secret: agw-secret}
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata: {name: mcp-dual}
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
        audiences: [authtest-mcp]
        jwks:
          backendRef: {group: agentgateway.dev, kind: AgentgatewayBackend, name: keycloak-jwks}
          jwksPath: /keycloak/realms/authtest/protocol/openid-connect/certs
        resourceMetadata:
          agentgateway.dev/issuer-proxy: "http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth-issuer"
          resource: "$GW/mcp-dual"
          authorizationServers: ["$GW/mcp-dual"]
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: mcp-dual-elicit}
spec:
  targetRefs: [{group: enterpriseagentgateway.solo.io, kind: EnterpriseAgentgatewayBackend, name: mcp-dual}]
  backend:
    entElicitation:
      brokered:
        mcpResourcePath: /mcp-dual
        chainedAuth:
          oauth:
$1
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-mcp-dual}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches:
        - {path: {type: PathPrefix, value: /mcp-dual}}
        - {path: {type: PathPrefix, value: /.well-known/oauth-protected-resource/mcp-dual}}
        - {path: {type: PathPrefix, value: /.well-known/oauth-authorization-server/mcp-dual}}
      backendRefs: [{group: enterpriseagentgateway.solo.io, kind: EnterpriseAgentgatewayBackend, name: mcp-dual}]
Y
}
flow() { # $1 label
  ASM=$(curl -s $GW/.well-known/oauth-authorization-server/mcp-dual); AUTHZ=$(echo "$ASM" | jq -r .authorization_endpoint); TOKEN_EP=$(echo "$ASM" | jq -r .token_endpoint)
  VER=$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-64); CH=$(printf '%s' "$VER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  JAR=$(mktemp); rm -f $JAR
  IDP=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' "$AUTHZ?client_id=agw&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A6274%2Foauth%2Fcallback&scope=openid&code_challenge=$CH&code_challenge_method=S256&state=xyz&resource=$GW%2Fmcp-dual")
  log "-- [$1] /authorize -> ${IDP:0:100}"
  LOGIN=$(curl -s -c $JAR -b $JAR -L "$IDP"); ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g')
  NEXT=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw)
  for i in 1 2 3 4 5 6 7 8; do
    R=$(curl -s -c $JAR -b $JAR -o /tmp/dual.body -w '%{http_code} %{redirect_url} %{url_effective}' "$NEXT"); C=${R%% *}; rest=${R#* }; N=${rest%% *}; EFF=${rest#* }
    log "-- [$1] hop$i: $C ${N:0:110}"
    if echo "$N" | grep -q 'localhost:6274'; then break; fi
    if [ "$C" = 200 ]; then
      if grep -qi 'consent\|allow' /tmp/dual.body && grep -q '<form' /tmp/dual.body; then
        FA=$(grep -oE '<form[^>]*action="[^"]*"' /tmp/dual.body | head -1 | sed 's/.*action="//;s/"$//'); FA=${FA:-$EFF}; case "$FA" in /*) FA="$GW$FA";; esac
        FIELDS=$(grep -oE '<input[^>]*type="hidden"[^>]*>' /tmp/dual.body | sed -E 's/.*name="([^"]*)".*value="([^"]*)".*/\1=\2/' | paste -sd'&' -)
        BTN=$(grep -oE '<button[^>]*name="[^"]*"[^>]*value="[^"]*"' /tmp/dual.body | head -3 | sed -E 's/.*name="([^"]*)".*value="([^"]*)".*/\1=\2/' | tr '\n' ' ')
        log "-- [$1] consent page: action=$FA hidden=[${FIELDS:0:80}] buttons=[$BTN]"
        ALLOW=$(echo "$BTN" | tr ' ' '\n' | grep -iE 'allow|approve|accept|yes' | head -1); ALLOW=${ALLOW:-$(echo "$BTN" | tr ' ' '\n' | head -1)}
        NEXT=$(curl -s -c $JAR -b $JAR -o /tmp/dual2.body -w '%{redirect_url}' -X POST "$FA" -d "$FIELDS&$ALLOW"); log "-- [$1] consent POST -> ${NEXT:0:110}"; [ -z "$NEXT" ] && { log "-- consent POST body: $(head -c 200 /tmp/dual2.body)"; break; }
        continue
      elif grep -q 'login-actions/authenticate' /tmp/dual.body; then
        ACTION=$(grep -oE 'action="[^"]+"' /tmp/dual.body | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g')
        NEXT=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw); log "-- [$1] upstream login POST -> ${NEXT:0:110}"; continue
      else log "-- [$1] 200 page: $(grep -oE '<title>[^<]*' /tmp/dual.body | head -1) $(head -c 150 /tmp/dual.body | tr '\n' ' ')"; break; fi
    fi
    [ -z "$N" ] && { log "-- [$1] stopped: $(head -c 200 /tmp/dual.body | tr '\n' ' ')"; break; }; NEXT=$N
  done
  CODE=$(echo "$N" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p')
  TOK=$(curl -s -X POST "$TOKEN_EP" -d grant_type=authorization_code -d client_id=agw -d "code=$CODE" -d code_verifier=$VER --data-urlencode redirect_uri=http://localhost:6274/oauth/callback); AT=$(echo "$TOK" | jq -r .access_token)
  if [ -n "$AT" ] && [ "$AT" != null ]; then PASS=$((PASS+1)); log "PASS [$1] dual-OAuth flow completed; downstream token iss=$(jwtclaims $AT | jq -r .iss)"; else FAIL=$((FAIL+1)); log "FAIL [$1] token: $(echo "$TOK" | head -c 200)"; return; fi
  H=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "Authorization: Bearer $AT")
  SID=$(curl -s -D - -o /dev/null -X POST $GW/mcp-dual "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' | grep -i '^mcp-session-id' | awk '{print $2}' | tr -d '\r')
  log "-- [$1] mcp session: ${SID:0:12}..."
  CALL=$(curl -s -X POST $GW/mcp-dual "${H[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"headers","arguments":{}}}')
  UPAUTH=$(echo "$CALL" | sed 's/^data: //' | jq -r '.result.content[0].text' 2>/dev/null | jq -r '.Authorization // .authorization // empty' 2>/dev/null); UPT=${UPAUTH#Bearer }
  if [ -n "$UPT" ] && [ "$UPT" != "$AT" ]; then PASS=$((PASS+1)); log "PASS [$1] upstream MCP server received UPSTREAM token: iss=$(jwtclaims $UPT | jq -r .iss) sub=$(jwtclaims $UPT | jq -r .preferred_username) azp=$(jwtclaims $UPT | jq -r .azp)"; else FAIL=$((FAIL+1)); log "FAIL [$1] upstream header: $(echo "$CALL" | head -c 300)"; fi
}
# Variant 1: static pre-registered upstream OAuth app (clientId/secret)
mk "            clientId: agw
            clientSecretRef: {name: upstream-client-secret, key: client_secret}
            scopes: [openid, profile]
            authorizeUrl: $UP_ISS/protocol/openid-connect/auth
            accessTokenUrl: $UP_ISS/protocol/openid-connect/token"
settle 10; log "policy status: $(kubectl get enterpriseagentgatewaypolicy mcp-dual-elicit -n authtest -o jsonpath='{.status.ancestors[*].conditions[*].message}' | head -c 200)"
expect "dual: no token -> 401" 401 -X POST $GW/mcp-dual -H 'content-type: application/json' -d '{}'
flow "static-client"
# Variant 2: DCR against the upstream provider (baseUrl discovery)
mk "            baseUrl: $UP_ISS
            scopes: [openid, profile]
            clientName: authtest-gateway"
settle 10; log "policy status (DCR variant): $(kubectl get enterpriseagentgatewaypolicy mcp-dual-elicit -n authtest -o jsonpath='{.status.ancestors[*].conditions[*].message}' | head -c 200)"
flow "dcr-baseUrl"
log "-- controller issuer log tail: $(kubectl logs -n agentgateway-system deploy/enterprise-agentgateway --since=3m 2>/dev/null | grep -iE 'upstream|elicit|consent|register' | grep -iE 'error|warn|fail' | tail -3 | cut -c1-250)"
summary
