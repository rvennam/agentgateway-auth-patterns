#!/bin/bash
TEST_NAME=09-inline-exchange; . "$(dirname "$0")/lib.sh"
JWKS=$(cat $S/keys/jwks.json)
kubectl apply -n authtest -f - <<'Y'
apiVersion: v1
kind: Service
metadata: {name: httpbin-xchg}
spec:
  selector: {app: httpbin}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-xchg}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /xchg}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{name: httpbin-xchg, port: 8080}]
Y
# README "OBO Impersonation" shape: EnterpriseAgentgatewayPolicy on HTTPRoute with traffic.jwtAuthentication + backend.tokenExchange ExchangeOnly
kubectl apply -n authtest -f - <<Y
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: obo-impersonation}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-xchg}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://authtest.example
          audiences: [authtest]
          jwks: {inline: '$JWKS'}
  backend:
    tokenExchange:
      mode: ExchangeOnly
Y
wait_policy enterpriseagentgatewaypolicy obo-impersonation; settle 6
log "policy status: $(kubectl get enterpriseagentgatewaypolicy obo-impersonation -n authtest -o jsonpath='{.status.ancestors[*].conditions[*].message}')"
U=$(mint '{"sub":"alice","role":"admin","scope":"mcp:invoke","may_act":{"sub":"system:serviceaccount:authtest:agent-runtime"}}')
expect "inline ExchangeOnly (HTTPRoute target): no token -> 401" 401 $GW/xchg/get
B=$(curl -s -H "Authorization: Bearer $U" $GW/xchg/headers); code=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $U" $GW/xchg/headers)
OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //')
if [ -n "$OUT" ] && [ "$OUT" != "$U" ]; then PASS=$((PASS+1)); log "PASS inline exchange: backend got STS-issued token; claims=$(jwtclaims $OUT | jq -c .)"; else FAIL=$((FAIL+1)); log "FAIL inline exchange: http=$code body=$(echo "$B" | head -c 300)"; fi
log "-- proxy log tail (token exchange): $(kubectl logs -n authtest deploy/authtest-gw --since=2m 2>/dev/null | grep -iE 'exchange|sts' | tail -3 | cut -c1-300)"
# Same with the leidos-style target: AgentgatewayBackend
kubectl delete enterpriseagentgatewaypolicy obo-impersonation -n authtest >/dev/null
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: httpbin-sts}
spec:
  static: {host: httpbin.authtest.svc.cluster.local, port: 8080}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-xchg}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /xchg}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-sts}]
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: xchg-jwt}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-xchg}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://authtest.example
          audiences: [authtest]
          jwks: {inline: '$JWKS'}
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: xchg-backend}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-sts}]
  backend:
    tokenExchange:
      mode: ExchangeOnly
Y
wait_policy enterpriseagentgatewaypolicy xchg-backend; settle 6
B=$(curl -s -H "Authorization: Bearer $U" $GW/xchg/headers); OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //')
if [ -n "$OUT" ] && [ "$OUT" != "$U" ]; then PASS=$((PASS+1)); log "PASS inline exchange (Backend target): claims=$(jwtclaims $OUT | jq -c .)"; else FAIL=$((FAIL+1)); log "FAIL inline exchange (Backend target): $(echo "$B" | head -c 300)"; fi
# OSS backend.auth.oauthTokenExchange against the STS with actorToken from a header (delegation inline)
kubectl delete enterpriseagentgatewaypolicy xchg-backend -n authtest >/dev/null
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: sts}
spec:
  static: {host: enterprise-agentgateway.agentgateway-system.svc.cluster.local, port: 7777}
---
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
        actorToken:
          source: {header: {name: x-actor-token}}
          mayAct: Required
        audiences: [mcp-tool-server]
Y
settle 8; log "oss oauthTokenExchange status: $(kubectl get agentgatewaypolicy xchg-oss -n authtest -o jsonpath='{.status.ancestors[*].conditions[*].message}' | head -c 300)"
A1=$(kubectl create token agent-runtime -n authtest --duration=1h)
B=$(curl -s -H "Authorization: Bearer $U" -H "x-user-token: Bearer $U" -H "x-actor-token: $A1" $GW/xchg/headers); OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //')
if [ -n "$OUT" ] && [ "$OUT" != "$U" ]; then PASS=$((PASS+1)); log "PASS OSS oauthTokenExchange w/ actor: claims=$(jwtclaims $OUT | jq -c '{iss,sub,aud,act,may_act}')"; else FAIL=$((FAIL+1)); log "FAIL OSS oauthTokenExchange: $(echo "$B" | head -c 300)"; fi
summary
