#!/bin/bash
TEST_NAME=15-sts-uri-elicit; . "$(dirname "$0")/lib.sh"
kubectl patch enterpriseagentgatewayparameters agentgateway-config -n agentgateway-system --type=json -p='[{"op":"replace","path":"/spec/env/0/value","value":"http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/elicitations/oauth2/token"}]' >/dev/null
log "STS_URI now: $(kubectl get enterpriseagentgatewayparameters agentgateway-config -n agentgateway-system -o jsonpath='{.spec.env[0].value}')"
sleep 5; kubectl rollout status deploy/authtest-gw -n authtest --timeout=180s >/dev/null; settle 20
U=$(mint '{"sub":"alice","scope":"mcp:invoke","may_act":{"sub":"system:serviceaccount:authtest:agent-runtime"}}')
# regression: inline ExchangeOnly on /xchg (policy xchg-jwt + xchg-backend?)
kubectl apply -n authtest -f - <<'Y' >/dev/null
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: xchg-backend}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-sts}]
  backend:
    tokenExchange: {mode: ExchangeOnly}
Y
settle 8; B=$(curl -s -H "Authorization: Bearer $U" $GW/xchg/headers); OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //')
if [ -n "$OUT" ] && [ "$OUT" != "$U" ]; then PASS=$((PASS+1)); log "PASS ExchangeOnly still works with /elicitations/oauth2/token STS_URI (iss=$(jwtclaims $OUT | jq -r .iss))"; else FAIL=$((FAIL+1)); log "FAIL ExchangeOnly regression: $(echo "$B" | head -c 200)"; fi
# interactive elicitation legacy (policy jira-elicit-only exists)
R=$(curl -s -o /tmp/el.body -w '%{http_code}' -H "Authorization: Bearer $(mint '{"sub":"alice"}')" $GW/elicit/headers); log "legacy ElicitationOnly: http=$R body=$(head -c 300 /tmp/el.body)"
if [ "$R" = 500 ] && grep -q '"url"' /tmp/el.body; then PASS=$((PASS+1)); log "PASS interactive elicitation PENDING url returned"; else FAIL=$((FAIL+1)); log "FAIL expected 500+url"; fi
# typed interactive
kubectl delete enterpriseagentgatewaypolicy jira-elicit-only -n authtest >/dev/null 2>&1
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
          authorizeUrl: $GW/keycloak/realms/upstream/protocol/openid-connect/auth
          accessTokenUrl: $GW/keycloak/realms/upstream/protocol/openid-connect/token
Y
settle 8; R=$(curl -s -o /tmp/el.body -w '%{http_code}' -H "Authorization: Bearer $(mint '{"sub":"alice"}')" $GW/elicit/headers); log "entElicitation.interactive: http=$R body=$(head -c 300 /tmp/el.body)"
if [ "$R" = 500 ] && grep -q '"url"' /tmp/el.body; then PASS=$((PASS+1)); log "PASS typed interactive elicitation PENDING url returned"; else FAIL=$((FAIL+1)); log "FAIL expected 500+url"; fi
log "-- proxy log: $(kubectl logs -n authtest deploy/authtest-gw --since=2m 2>/dev/null | grep -iE 'elicit|exchange|7777' | grep -v 'route=authtest/r-oauth-issuer' | tail -3 | cut -c1-300)"
summary
