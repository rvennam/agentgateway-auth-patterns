#!/bin/bash
TEST_NAME=06-upstream; . "$(dirname "$0")/lib.sh"
JWKS=$(cat $S/keys/jwks.json)
jwtpol() { # jwtpol <policy-name> <route> [extra-yaml-under-traffic]
cat <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: $1, namespace: authtest}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: $2}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://authtest.example
          audiences: [authtest]
          jwks: {inline: '$JWKS'}
$3
Y
}
# ---- Passthrough
jwtpol jwt-passthrough r-passthrough | kubectl apply -f - >/dev/null
settle 5
T=$(mint '{"sub":"alice","tier":"paid"}')
log "-- JWT auth alone, backend Authorization: $(curl -s -H "Authorization: Bearer $T" $GW/passthrough/headers | jq -c '.headers.Authorization')"
# README shape targets Service; the route r-passthrough -> httpbin Service (shared by other routes!) so use a dedicated Service alias
kubectl apply -n authtest -f - <<'Y'
apiVersion: v1
kind: Service
metadata: {name: httpbin-pt}
spec:
  selector: {app: httpbin}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-passthrough}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /passthrough}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{name: httpbin-pt, port: 8080}]
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: backend-passthrough}
spec:
  targetRefs: [{group: "", kind: Service, name: httpbin-pt}]
  backend:
    auth:
      passthrough: {}
Y
wait_policy agentgatewaypolicy backend-passthrough; settle
expect_body "passthrough: original JWT reaches backend" "Bearer $T" -H "Authorization: Bearer $T" $GW/passthrough/headers
expect "passthrough: no token still 401 at gateway" 401 $GW/passthrough/get
# ---- Static secret injection (README: Secret key 'Authorization')
jwtpol jwt-static r-static | kubectl apply -f - >/dev/null
kubectl apply -n authtest -f - <<'Y'
apiVersion: v1
kind: Service
metadata: {name: httpbin-static}
spec:
  selector: {app: httpbin}
  ports: [{port: 8080, targetPort: 8080}]
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-static}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /static}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{name: httpbin-static, port: 8080}]
---
apiVersion: v1
kind: Secret
metadata: {name: github-auth}
type: Opaque
stringData:
  Authorization: "Bearer ghp_SHARED_UPSTREAM_TOKEN"
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: static-inject}
spec:
  targetRefs: [{group: "", kind: Service, name: httpbin-static}]
  backend:
    auth:
      secretRef: {name: github-auth}
Y
wait_policy agentgatewaypolicy static-inject; settle
expect_body "static secretRef: backend gets shared token" 'Bearer ghp_SHARED_UPSTREAM_TOKEN' -H "Authorization: Bearer $T" $GW/static/headers
expect_body "static secretRef: user JWT NOT forwarded" '^((?!authtest).)*$' -H "Authorization: Bearer $T" $GW/static/headers
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: static-inject}
spec:
  targetRefs: [{group: "", kind: Service, name: httpbin-static}]
  backend:
    auth:
      key: "Bearer sk-INLINE-KEY"
Y
settle 6
expect_body "static inline key: backend gets inline key" 'Bearer sk-INLINE-KEY' -H "Authorization: Bearer $T" $GW/static/headers
# secretRef with custom key + location header x-api-key
kubectl apply -n authtest -f - <<'Y'
apiVersion: v1
kind: Secret
metadata: {name: upstream-apikey}
stringData:
  apikey: "k-upstream-123"
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: static-inject}
spec:
  targetRefs: [{group: "", kind: Service, name: httpbin-static}]
  backend:
    auth:
      secretRef: {name: upstream-apikey, key: apikey}
      location:
        header: {name: x-api-key}
Y
settle 6
expect_body "static secretRef.key + location x-api-key" '"X-Api-Key":\["k-upstream-123"\]' -H "Authorization: Bearer $T" $GW/static/headers
# ---- Claim-based mapping (README: transformation.request.set[].expression ; schema: value)
out=$(jwtpol claim-map r-claim '    transformation:
      request:
        set:
          - name: Authorization
            expression: |
              "Bearer " + (jwt.tier == "paid" ? "PAID-KEY" : "FREE-KEY")' | kubectl apply -f - 2>&1); log "README set[].expression: $(echo "$out" | head -c 200)"
jwtpol claim-map r-claim '    transformation:
      request:
        set:
          - name: Authorization
            value: |
              "Bearer " + (jwt.tier == "paid" ? "PAID-KEY" : jwt.tier == "internal" ? "INTERNAL-KEY" : "FREE-KEY")' | kubectl apply -f - >/dev/null
wait_policy agentgatewaypolicy claim-map; settle
expect_body "claim map: tier=paid -> PAID-KEY" 'Bearer PAID-KEY' -H "Authorization: Bearer $(mint '{"sub":"alice","tier":"paid"}')" $GW/claim/headers
expect_body "claim map: tier=free -> FREE-KEY" 'Bearer FREE-KEY' -H "Authorization: Bearer $(mint '{"sub":"bob","tier":"free"}')" $GW/claim/headers
expect_body "claim map: tier=internal -> INTERNAL-KEY" 'Bearer INTERNAL-KEY' -H "Authorization: Bearer $(mint '{"sub":"ci","tier":"internal"}')" $GW/claim/headers
expect "claim map: no tier claim -> ?" 200 -H "Authorization: Bearer $(mint '{"sub":"x"}')" $GW/claim/headers
log "-- no tier claim result: $(curl -s -H "Authorization: Bearer $(mint '{"sub":"x"}')" $GW/claim/headers | jq -c '.headers.Authorization')"
summary
