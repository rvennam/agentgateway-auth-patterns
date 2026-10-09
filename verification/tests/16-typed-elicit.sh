#!/bin/bash
TEST_NAME=16-typed-elicit; . "$(dirname "$0")/lib.sh"
UP_ISS=$GW/keycloak/realms/upstream
# typed interactive + proxy-native solo token exchange lookup
kubectl apply -n authtest -f - <<Y >/dev/null
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: jira-interactive}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-elicit}]
  backend:
    entElicitation:
      interactive:
        oauth:
          clientId: agw
          clientSecretRef: {name: jira-oauth-app, key: client_secret}
          scopes: [openid, profile]
          redirectUri: http://localhost:8090/age/elicitations
          authorizeUrl: $UP_ISS/protocol/openid-connect/auth
          accessTokenUrl: $UP_ISS/protocol/openid-connect/token
    entTokenExchange:
      solo:
        elicitation: {}
Y
settle 8; log "policy: $(kubectl get enterpriseagentgatewaypolicy jira-interactive -n authtest -o jsonpath='{.status.ancestors[*].conditions[*].message}' | head -c 200)"
R=$(curl -s -o /tmp/el.body -w '%{http_code}' -H "Authorization: Bearer $(mint '{"sub":"alice"}')" $GW/elicit/headers); log "entElicitation.interactive + entTokenExchange.solo.elicitation: http=$R body=$(head -c 300 /tmp/el.body)"
if { [ "$R" = 500 ] || [ "$R" = 400 ]; } && grep -q '"url"' /tmp/el.body; then PASS=$((PASS+1)); log "PASS typed interactive elicitation PENDING url (http $R)"; else FAIL=$((FAIL+1)); log "FAIL"; fi
# brokered dual (static client) + solo lookup -> upstream token injected into MCP server request
kubectl apply -n authtest -f - <<Y >/dev/null
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
            clientId: agw
            clientSecretRef: {name: upstream-client-secret, key: client_secret}
            scopes: [openid, profile]
            authorizeUrl: $UP_ISS/protocol/openid-connect/auth
            accessTokenUrl: $UP_ISS/protocol/openid-connect/token
    entTokenExchange:
      solo:
        elicitation: {}
Y
settle 8; log "dual policy: $(kubectl get enterpriseagentgatewaypolicy mcp-dual-elicit -n authtest -o jsonpath='{.status.ancestors[*].conditions[*].message}' | head -c 200)"
ASM=$(curl -s $GW/.well-known/oauth-authorization-server/mcp-dual); AUTHZ=$(echo "$ASM" | jq -r .authorization_endpoint); TOKEN_EP=$(echo "$ASM" | jq -r .token_endpoint)
VER=$(openssl rand -base64 48 | tr -d '=+/' | cut -c1-64); CH=$(printf '%s' "$VER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='); JAR=$(mktemp); rm -f $JAR
IDP=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' "$AUTHZ?client_id=agw&response_type=code&redirect_uri=http%3A%2F%2Flocalhost%3A6274%2Foauth%2Fcallback&scope=openid&code_challenge=$CH&code_challenge_method=S256&state=xyz&resource=$GW%2Fmcp-dual")
LOGIN=$(curl -s -c $JAR -b $JAR -L "$IDP"); ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g')
NEXT=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw)
for i in 1 2 3 4 5 6; do R=$(curl -s -c $JAR -b $JAR -o /tmp/dual.body -w '%{http_code} %{redirect_url} %{url_effective}' "$NEXT"); C=${R%% *}; rest=${R#* }; N=${rest%% *}; EFF=${rest#* }; log "-- hop$i: $C ${N:0:90}"
  echo "$N" | grep -q 'localhost:6274' && break
  if [ "$C" = 200 ]; then
    if grep -q 'decision' /tmp/dual.body; then ST=$(grep -oE 'name="state"[^>]*value="[^"]*"' /tmp/dual.body | sed 's/.*value="//;s/"$//'); NEXT=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$EFF" --data-urlencode "state=$ST" -d decision=allow); log "-- consent allow -> ${NEXT:0:90}"; continue
    elif grep -q 'login-actions/authenticate' /tmp/dual.body; then ACTION=$(grep -oE 'action="[^"]+"' /tmp/dual.body | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g'); NEXT=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw); log "-- upstream login -> ${NEXT:0:90}"; continue; fi; break; fi; [ -z "$N" ] && break; NEXT=$N; done
CODE=$(echo "$N" | sed -n 's/.*[?&]code=\([^&]*\).*/\1/p'); AT=$(curl -s -X POST "$TOKEN_EP" -d grant_type=authorization_code -d client_id=agw -d "code=$CODE" -d code_verifier=$VER --data-urlencode redirect_uri=http://localhost:6274/oauth/callback | jq -r .access_token)
H=(-H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -H "Authorization: Bearer $AT")
RESP=$(curl -s -D /tmp/init.h -X POST $GW/mcp-dual "${H[@]}" -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'); SID=$(grep -i '^mcp-session-id' /tmp/init.h | awk '{print $2}' | tr -d '\r'); log "-- initialize: $(grep HTTP /tmp/init.h | tr -d '\r') $(echo "$RESP" | head -c 150)"
CALL=$(curl -s -X POST $GW/mcp-dual "${H[@]}" -H "mcp-session-id: $SID" -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"headers","arguments":{}}}'); TXT=$(echo "$CALL" | grep '^data:' | head -1 | sed 's/^data: //' | jq -r '.result.content[0].text' 2>/dev/null); log "-- MCP server saw: ${TXT:0:200}"
UPT=$(echo "$TXT" | jq -r '.Authorization // .authorization // empty' 2>/dev/null | sed 's/^Bearer //')
if [ -n "$UPT" ] && [ "$UPT" != "$AT" ]; then PASS=$((PASS+1)); log "PASS dual OAuth: upstream token injected; iss=$(jwtclaims $UPT | jq -r .iss) user=$(jwtclaims $UPT | jq -r .preferred_username) azp=$(jwtclaims $UPT | jq -r .azp)"; else FAIL=$((FAIL+1)); log "FAIL no upstream token: $(echo "$CALL" | head -c 300)"; fi
log "-- proxy log: $(kubectl logs -n authtest deploy/authtest-gw --since=2m 2>/dev/null | grep -iE 'exchange|elicit' | grep -iE 'error|warn' | tail -3 | cut -c1-300)"
summary
