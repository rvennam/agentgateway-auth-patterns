#!/bin/bash
TEST_NAME=10-oidc-extauth; . "$(dirname "$0")/lib.sh"
KC_ISS=$GW/keycloak/realms/authtest
kubectl apply -n authtest -f - <<Y
apiVersion: v1
kind: Service
metadata: {name: httpbin-oidc}
spec:
  selector: {app: httpbin}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-oidc}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /oidc}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{name: httpbin-oidc, port: 8080}]
---
apiVersion: v1
kind: Secret
metadata: {name: idp-client-secret}
type: extauth.solo.io/oauth
stringData:
  client-secret: agw-secret
---
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata: {name: corporate-sso}
spec:
  configs:
    - oauth2:
        oidcAuthorizationCode:
          appUrl: "$GW"
          callbackPath: /oidc/callback
          clientId: agw
          clientSecretRef: {name: idp-client-secret, namespace: authtest}
          issuerUrl: "$KC_ISS/"
          scopes: [openid, profile, email]
          headers:
            idTokenHeader: jwt
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: oidc-and-exchange}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-oidc}]
  traffic:
    entExtAuth:
      authConfigRef: {name: corporate-sso}
      backendRef: {name: ext-auth-service-enterprise-agentgateway, namespace: agentgateway-system, port: 8083}
Y
wait_policy enterpriseagentgatewaypolicy oidc-and-exchange; settle 8
log "authconfig status: $(kubectl get authconfig corporate-sso -n authtest -o jsonpath='{.status}' | head -c 200)"
JAR=$(mktemp); rm -f $JAR
code=$(curl -s -o /dev/null -w '%{http_code}' -c $JAR $GW/oidc/headers); LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -c $JAR $GW/oidc/headers)
if [ "$code" = 302 ] && echo "$LOC" | grep -q 'openid-connect/auth'; then PASS=$((PASS+1)); log "PASS unauthenticated -> 302 to Keycloak authorize (${LOC:0:90}...)"; else FAIL=$((FAIL+1)); log "FAIL expected 302 to IdP, got $code $LOC"; fi
LOGIN=$(curl -s -c $JAR -b $JAR -L "$LOC"); ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g')
CB=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw); log "-- IdP redirects to callback: ${CB:0:70}... "
FIN=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{http_code} %{redirect_url}' "$CB"); log "-- callback response: $FIN"
B=$(curl -s -b $JAR $GW/oidc/headers); code=$(curl -s -o /dev/null -w '%{http_code}' -b $JAR $GW/oidc/headers)
if [ "$code" = 200 ]; then PASS=$((PASS+1)); log "PASS session cookie -> 200; backend headers: $(echo "$B" | jq -c '.headers | keys')"; else FAIL=$((FAIL+1)); log "FAIL after login got $code: $(echo "$B" | head -c 200)"; fi
IDT=$(echo "$B" | jq -r '.headers.Jwt[0] // .headers.jwt[0] // empty'); [ -n "$IDT" ] && log "-- idTokenHeader jwt claims: $(jwtclaims $IDT | jq -c '{iss,aud,sub,preferred_username,azp}')"
log "-- Authorization header at backend: $(echo "$B" | jq -c '.headers.Authorization')"
# Add ExchangeOnly: gateway exchanges the IdP token for an STS token (README Gateway-Mediated OIDC + Token Exchange, Variant A)
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: httpbin-oidc-be}
spec:
  static: {host: httpbin.authtest.svc.cluster.local, port: 8080}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-oidc}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /oidc}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-oidc-be}]
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: oidc-exchange-backend}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-oidc-be}]
  backend:
    tokenExchange:
      mode: ExchangeOnly
Y
wait_policy enterpriseagentgatewaypolicy oidc-exchange-backend; settle 8
B=$(curl -s -b $JAR $GW/oidc/headers); code=$(curl -s -o /dev/null -w '%{http_code}' -b $JAR $GW/oidc/headers); OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //')
if [ "$code" = 200 ] && [ -n "$OUT" ]; then PASS=$((PASS+1)); log "PASS OIDC + ExchangeOnly: backend Authorization is STS token; claims=$(jwtclaims $OUT | jq -c .)"; else FAIL=$((FAIL+1)); log "FAIL OIDC+exchange http=$code body=$(echo "$B" | head -c 300)"; fi
# README variant: same policy carries BOTH entExtAuth (traffic) and tokenExchange (backend) on the Gateway/route target
kubectl delete enterpriseagentgatewaypolicy oidc-and-exchange oidc-exchange-backend -n authtest >/dev/null
kubectl apply -n authtest -f - <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: oidc-and-exchange}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-oidc}]
  traffic:
    entExtAuth:
      authConfigRef: {name: corporate-sso}
      backendRef: {name: ext-auth-service-enterprise-agentgateway, namespace: agentgateway-system, port: 8083}
  backend:
    tokenExchange:
      mode: ExchangeOnly
Y
wait_policy enterpriseagentgatewaypolicy oidc-and-exchange; settle 8
B=$(curl -s -b $JAR $GW/oidc/headers); code=$(curl -s -o /dev/null -w '%{http_code}' -b $JAR $GW/oidc/headers); OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //')
if [ "$code" = 200 ] && [ -n "$OUT" ]; then PASS=$((PASS+1)); log "PASS README single-policy (entExtAuth + tokenExchange on HTTPRoute): STS claims=$(jwtclaims $OUT | jq -c '{iss,sub,aud,scope,act}')"; else FAIL=$((FAIL+1)); log "FAIL README single-policy: http=$code $(echo "$B" | head -c 300)"; fi
summary
