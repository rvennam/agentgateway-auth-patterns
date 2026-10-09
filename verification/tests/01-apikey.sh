#!/bin/bash
TEST_NAME=01-apikey; . "$(dirname "$0")/lib.sh"
kubectl apply -n authtest -f - <<'Y'
apiVersion: v1
kind: Secret
metadata:
  name: api-keys
  labels: {purpose: api-key}
stringData:
  alice-laptop: |
    { "key": "k-alice-7f0a3c91", "metadata": { "user": "alice@example.com", "team": "platform", "tier": "paid" } }
  ci-prod-pipeline: |
    { "key": "k-ci-prod-abc123", "metadata": { "service": "github-actions", "tier": "internal" } }
  bob-cli: "k-bob-456"
---
# README shape, verbatim fields (mode + secretSelector)
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: api-key-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-apikey}]
  traffic:
    apiKeyAuthentication:
      mode: Strict
      secretSelector:
        matchLabels: {purpose: api-key}
Y
wait_policy agentgatewaypolicy api-key-auth; settle
expect "no key -> 401" 401 $GW/apikey/get
expect "bad key (Bearer) -> 401" 401 -H 'Authorization: Bearer nope' $GW/apikey/get
expect "README diagram: x-api-key header (default location is Authorization Bearer) " 401 -H 'x-api-key: k-alice-7f0a3c91' $GW/apikey/get
expect "JSON-form key via Authorization Bearer -> 200" 200 -H 'Authorization: Bearer k-alice-7f0a3c91' $GW/apikey/get
expect "bare-string key via Authorization Bearer -> 200" 200 -H 'Authorization: Bearer k-bob-456' $GW/apikey/get
log "-- headers seen by backend with alice key:"; curl -s -H 'Authorization: Bearer k-alice-7f0a3c91' $GW/apikey/headers | jq -c '.headers | with_entries(select(.key|test("auth|user|api|key";"i")))' | tee -a "$RESULTS"
# location override + CEL authz on metadata
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: api-key-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-apikey}]
  traffic:
    apiKeyAuthentication:
      mode: Strict
      secretSelector:
        matchLabels: {purpose: api-key}
      location:
        header: {name: x-api-key}
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - 'apiKey.tier == "paid"'
Y
wait_policy agentgatewaypolicy api-key-auth; settle
expect "x-api-key alice (tier=paid) -> 200" 200 -H 'x-api-key: k-alice-7f0a3c91' $GW/apikey/get
expect "x-api-key ci (tier=internal) -> 403 by CEL" 403 -H 'x-api-key: k-ci-prod-abc123' $GW/apikey/get
expect "x-api-key bob (no metadata) -> 403 by CEL" 403 -H 'x-api-key: k-bob-456' $GW/apikey/get
expect "Bearer alice when location=x-api-key -> 401" 401 -H 'Authorization: Bearer k-alice-7f0a3c91' $GW/apikey/get
# secretRef form
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: api-key-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-apikey}]
  traffic:
    apiKeyAuthentication:
      mode: Optional
      secretRef: {name: api-keys}
Y
wait_policy agentgatewaypolicy api-key-auth; settle
expect "secretRef + Optional: no key -> 200" 200 $GW/apikey/get
expect "secretRef + Optional: bad key -> 401" 401 -H 'Authorization: Bearer nope' $GW/apikey/get
expect "secretRef + Optional: good key -> 200" 200 -H 'Authorization: Bearer k-bob-456' $GW/apikey/get
summary
