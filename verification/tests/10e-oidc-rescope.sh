#!/bin/bash
TEST_NAME=10e-oidc-rescope; . "$(dirname "$0")/lib.sh"
KC_ISS=$GW/keycloak/realms/authtest
kubectl delete enterpriseagentgatewaypolicy oidc-pre oidc-post oidc-and-exchange -n authtest >/dev/null 2>&1
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
            accessTokenHeader: x-user-access-token
          session:
            failOnFetchFailure: true
            redis:
              cookieName: keycloak-session
              options:
                host: ext-cache-enterprise-agentgateway.agentgateway-system.svc.cluster.local:6379
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: oidc-login}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-oidc}]
  traffic:
    entExtAuth:
      authConfigRef: {name: corporate-sso}
      backendRef: {name: ext-auth-service-enterprise-agentgateway, namespace: agentgateway-system, port: 8083}
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: rescope-user-token}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-oidc}]
  backend:
    auth:
      oauthTokenExchange:
        backendRef: {group: agentgateway.dev, kind: AgentgatewayBackend, name: sts, port: 7777}
        path: /oauth2/token
        grantType: TokenExchange
        subjectToken:
          source: {header: {name: x-user-access-token}}
          tokenType: Jwt
        audiences: [my-agent]
        requestedTokenType: Jwt
        location:
          header: {name: Authorization, prefix: "Bearer "}
Y
sleep 10
login() { local JAR=$(mktemp); rm -f $JAR; local LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -c $JAR $GW/oidc/headers); local LOGIN=$(curl -s -c $JAR -b $JAR -L "$LOC"); local ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g'); local CB=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw); curl -s -D - -o /dev/null -c $JAR -b $JAR "$CB" | grep -i '^set-cookie' | sed -E 's/^[Ss]et-[Cc]ookie: ([^;]*);.*/\1/' | paste -sd';' -; }
COOK=$(login); code=$(curl -s -o /tmp/rs.body -w '%{http_code}' -H "Cookie: $COOK" $GW/oidc/headers); B=$(cat /tmp/rs.body)
log "after OIDC login: http=$code headers=$(echo "$B" | jq -c '.headers|keys' 2>/dev/null)"
OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' 2>/dev/null | sed 's/^Bearer //')
if [ "$code" = 200 ] && [ -n "$OUT" ] && jwtclaims "$OUT" | jq -r .iss | grep -q 7777; then PASS=$((PASS+1)); log "PASS gateway-mediated OIDC + exchange (accessTokenHeader -> oauthTokenExchange): backend sees STS token; claims=$(jwtclaims $OUT | jq -c .)"; else FAIL=$((FAIL+1)); log "FAIL: $(echo "$B" | head -c 300)"; fi
log "-- user access token also forwarded? x-user-access-token present: $(echo "$B" | jq -r '.headers | has("X-User-Access-Token")')"
summary
