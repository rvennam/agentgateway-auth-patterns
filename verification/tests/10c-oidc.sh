#!/bin/bash
TEST_NAME=10c-oidc; . "$(dirname "$0")/lib.sh"
kubectl apply -n authtest -f - <<'Y' >/dev/null
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
settle 8
JAR=$(mktemp); rm -f $JAR
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' -c $JAR $GW/oidc/headers)
LOGIN=$(curl -s -c $JAR -b $JAR -L "$LOC"); ACTION=$(echo "$LOGIN" | grep -oE 'action="[^"]+"' | head -1 | sed 's/action="//;s/"$//' | sed 's/&amp;/\&/g')
CB=$(curl -s -c $JAR -b $JAR -o /dev/null -w '%{redirect_url}' -X POST "$ACTION" --data-urlencode username=alice --data-urlencode password=alice-pw)
curl -s -D /tmp/cb.h -o /dev/null -c $JAR -b $JAR "$CB"
COOK=$(grep -i '^set-cookie' /tmp/cb.h | sed -E 's/^[Ss]et-[Cc]ookie: ([^;]*);.*/\1/' | paste -sd';' -); log "callback: $(grep HTTP /tmp/cb.h | tr -d '\r'); cookies: $(echo "$COOK" | tr ';' '\n' | cut -d= -f1 | paste -sd, -)"
sleep 1; code=$(curl -s -o /tmp/replay.body -w '%{http_code}' -H "Cookie: $COOK" $GW/oidc/headers); log "replay with Cookie header: $code"
log "-- ext-auth log around replay: $(kubectl logs -n agentgateway-system deploy/ext-auth-service-enterprise-agentgateway --since=40s 2>/dev/null | grep -viE 'jwks|not used for signing|incomingMetadata' | tail -4 | cut -c1-250)"
if [ "$code" = 200 ]; then PASS=$((PASS+1)); log "PASS OIDC session replay -> 200; backend headers: $(jq -c '.headers|keys' /tmp/replay.body)"; else FAIL=$((FAIL+1)); fi
# try over the HTTPS listener (Secure cookie semantics) with mTLS client cert
summary
