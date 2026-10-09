#!/bin/bash
TEST_NAME=09b-oss-exchange; . "$(dirname "$0")/lib.sh"
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: xchg-oss}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-sts}]
  backend:
    auth:
      oauthTokenExchange:
        backendRef: {group: agentgateway.dev, kind: AgentgatewayBackend, name: sts, port: 7777}
        path: /oauth2/token
        subjectToken:
          source: {header: {name: x-user-token, prefix: "Bearer "}}
          tokenType: Jwt
        actorToken:
          source: {header: {name: x-actor-token}}
          tokenType: Jwt
          mayAct: Required
        audiences: [mcp-tool-server]
Y
wait_policy agentgatewaypolicy xchg-oss; settle 6
U=$(mint '{"sub":"alice","scope":"mcp:invoke","may_act":{"sub":"system:serviceaccount:authtest:agent-runtime"}}'); A1=$(kubectl create token agent-runtime -n authtest --duration=1h)
B=$(curl -s -H "Authorization: Bearer $U" -H "x-user-token: Bearer $U" -H "x-actor-token: $A1" $GW/xchg/headers); OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //')
if [ -n "$OUT" ] && [ "$OUT" != "$U" ]; then PASS=$((PASS+1)); log "PASS OSS backend.auth.oauthTokenExchange delegation inline: claims=$(jwtclaims $OUT | jq -c '{iss,sub,aud,act: .act.sub,scope}')"; else FAIL=$((FAIL+1)); log "FAIL: $(echo "$B" | head -c 300)"; fi
A2=$(kubectl create token agent-two -n authtest --duration=1h); expect "OSS exchange: actor not in may_act -> error" 403 -H "Authorization: Bearer $U" -H "x-user-token: Bearer $U" -H "x-actor-token: $A2" $GW/xchg/headers
log "-- actual status for may_act mismatch: $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $U" -H "x-user-token: Bearer $U" -H "x-actor-token: $A2" $GW/xchg/headers) $(curl -s -H "Authorization: Bearer $U" -H "x-user-token: Bearer $U" -H "x-actor-token: $A2" $GW/xchg/headers | head -c 150)"
kubectl delete agentgatewaypolicy xchg-oss -n authtest >/dev/null
summary
