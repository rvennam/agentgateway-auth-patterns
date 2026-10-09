#!/bin/bash
TEST_NAME=10d-oidc-exchange; . "$(dirname "$0")/lib.sh"
KC_ISS=$GW/keycloak/realms/authtest
kubectl apply -n authtest -f - <<Y >/dev/null
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
            accessTokenHeader: authorization
          session:
            failOnFetchFailure: true
            redis:
              cookieName: keycloak-session
              options:
                host: ext-cache-enterprise-agentgateway.agentgateway-system.svc.cluster.local:6379
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
  backend:
    tokenExchange:
      mode: ExchangeOnly
Y
sleep 10
login() { local JAR=$(mktemp); rm -f $JAR; local LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -c $JAR $GW/oidc/headers); local LOGIN=$(curl -s -c $JAR -b $JAR -L "$LOC"); local ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g'); local CB=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw); curl -s -D - -o /dev/null -c $JAR -b $JAR "$CB" | grep -i '^set-cookie' | sed -E 's/^[Ss]et-[Cc]ookie: ([^;]*);.*/\1/' | paste -sd';' -; }
COOK=$(login); B=$(curl -s -H "Cookie: $COOK" $GW/oidc/headers); code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOK" $GW/oidc/headers)
log "accessTokenHeader=authorization, no jwtAuthentication: http=$code Authorization iss=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //' | xargs -I{} sh -c 'python3 -c "import sys,base64,json;t=sys.argv[1].split(\".\")[1];print(json.loads(base64.urlsafe_b64decode(t+\"=\"*(-len(t)%4)))[\"iss\"])" {}' 2>/dev/null)"
# add jwtAuthentication so the proxy has validated Claims to exchange
kubectl apply -n authtest -f - <<Y >/dev/null
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: oidc-and-exchange}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-oidc}]
  traffic:
    entExtAuth:
      authConfigRef: {name: corporate-sso}
      backendRef: {name: ext-auth-service-enterprise-agentgateway, namespace: agentgateway-system, port: 8083}
    jwtAuthentication:
      mode: Optional
      providers:
        - issuer: "$KC_ISS"
          audiences: [authtest-mcp]
          jwks: {remote: {url: "$KC_ISS/protocol/openid-connect/certs"}}
  backend:
    tokenExchange:
      mode: ExchangeOnly
Y
sleep 10; B=$(curl -s -H "Cookie: $COOK" $GW/oidc/headers); code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOK" $GW/oidc/headers); OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //')
log "with jwtAuthentication(Optional) + ExchangeOnly: http=$code body=$(echo "$B" | head -c 200 | tr '\n' ' ')"
if [ "$code" = 200 ] && [ -n "$OUT" ] && jwtclaims "$OUT" | jq -r .iss | grep -q 7777; then PASS=$((PASS+1)); log "PASS OIDC login -> IdP access token -> STS exchange; backend sees STS token: $(jwtclaims $OUT | jq -c .)"; else FAIL=$((FAIL+1)); log "FAIL (iss=$( [ -n "$OUT" ] && jwtclaims $OUT | jq -r .iss))"; fi
log "-- proxy log: $(kubectl logs -n authtest deploy/authtest-gw --since=1m 2>/dev/null | grep 'r-oidc' | grep -iE 'error|exchange' | tail -2 | cut -c1-300)"
summary
