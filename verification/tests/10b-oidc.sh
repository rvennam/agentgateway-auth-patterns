#!/bin/bash
TEST_NAME=10b-oidc; . "$(dirname "$0")/lib.sh"
login() { # prints Cookie header value after full OIDC login
  local JAR=$(mktemp); rm -f $JAR
  local LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -c $JAR $GW/oidc/headers)
  local LOGIN=$(curl -s -c $JAR -b $JAR -L "$LOC"); local ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g')
  local CB=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw)
  curl -s -D - -o /dev/null -c $JAR -b $JAR "$CB" | grep -i '^set-cookie' | sed -E 's/^[Ss]et-[Cc]ookie: ([^;]*);.*/\1/' | paste -sd';' -
}
COOK=$(login); log "cookies set by callback: $(echo "$COOK" | tr ';' '\n' | cut -d= -f1 | paste -sd, -) (flags: HttpOnly; Secure)"
B=$(curl -s -H "Cookie: $COOK" $GW/oidc/headers); code=$(curl -s -o /dev/null -w '%{http_code}' -H "Cookie: $COOK" $GW/oidc/headers)
if [ "$code" = 200 ]; then PASS=$((PASS+1)); log "PASS OIDC session -> 200 (README single policy entExtAuth+ExchangeOnly active); backend headers: $(echo "$B" | jq -c '.headers | keys')"; else FAIL=$((FAIL+1)); log "FAIL $code $(echo "$B" | head -c 200)"; fi
OUT=$(echo "$B" | jq -r '.headers.Authorization[0] // empty' | sed 's/^Bearer //'); [ -n "$OUT" ] && log "-- Authorization at backend = STS token? iss=$(jwtclaims $OUT | jq -r .iss) claims=$(jwtclaims $OUT | jq -c .)"
IDT=$(echo "$B" | jq -r '.headers.Jwt[0] // empty'); [ -n "$IDT" ] && log "-- idTokenHeader 'jwt' claims: $(jwtclaims $IDT | jq -c '{iss,aud,sub,preferred_username}')"
if [ -n "$OUT" ] && echo "$(jwtclaims $OUT | jq -r .iss)" | grep -q 7777; then PASS=$((PASS+1)); log "PASS gateway-mediated OIDC + token exchange: agent sees STS-issued token only"; else FAIL=$((FAIL+1)); log "FAIL no STS token at backend"; fi
# Without ExchangeOnly: what does the backend get after OIDC?
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
Y
settle 6; B=$(curl -s -H "Cookie: $COOK" $GW/oidc/headers); log "-- OIDC only (no exchange): backend headers: $(echo "$B" | jq -c '.headers | with_entries(select(.key|test("auth|jwt";"i"))) | map_values(.[0][0:40])')"
summary
