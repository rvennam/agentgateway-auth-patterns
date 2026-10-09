#!/bin/bash
TEST_NAME=02-basic; . "$(dirname "$0")/lib.sh"
A=$(htpasswd -nbm alice 'p4ssword'); B=$(htpasswd -nbB bob 'hunter2')
log "htpasswd lines: $A | $B"
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: basic-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-basic}]
  traffic:
    basicAuthentication:
      mode: Strict
      realm: agentgateway
      users:
        - "$A"
        - "$B"
Y
wait_policy agentgatewaypolicy basic-auth; settle
expect "inline users: no creds -> 401" 401 $GW/basic/get
log "WWW-Authenticate: $(curl -s -D - -o /dev/null $GW/basic/get | grep -i www-auth | tr -d '\r')"
expect "inline users: alice (apr1/MD5) -> 200" 200 -u alice:p4ssword $GW/basic/get
expect "inline users: bob (bcrypt) -> 200" 200 -u bob:hunter2 $GW/basic/get
expect "inline users: wrong pw -> 401" 401 -u alice:wrong $GW/basic/get
log "-- backend sees: $(curl -s -u alice:p4ssword $GW/basic/headers | jq -c '.headers | with_entries(select(.key|test("auth|user";"i")))')"
# README secretRef shape: key 'htpasswd' (schema default key is .htaccess)
kubectl apply -n authtest -f - <<Y
apiVersion: v1
kind: Secret
metadata: {name: basic-auth-htpasswd}
type: Opaque
stringData:
  htpasswd: |
    $A
    $B
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: basic-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-basic}]
  traffic:
    basicAuthentication:
      mode: Strict
      realm: agentgateway
      secretRef: {name: basic-auth-htpasswd}
Y
settle 6
log "policy status (README secret key 'htpasswd'): $(kubectl get agentgatewaypolicy basic-auth -n authtest -o jsonpath='{.status.conditions[*].message}' | head -c 300)"
expect "README secretRef (key htpasswd, no secretRef.key): alice" 200 -u alice:p4ssword $GW/basic/get
# corrected: secretRef.key
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: basic-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-basic}]
  traffic:
    basicAuthentication:
      mode: Strict
      realm: agentgateway
      secretRef: {name: basic-auth-htpasswd, key: htpasswd}
Y
wait_policy agentgatewaypolicy basic-auth; settle
expect "secretRef.key=htpasswd: alice -> 200" 200 -u alice:p4ssword $GW/basic/get
expect "secretRef.key=htpasswd: bad -> 401" 401 -u alice:bad $GW/basic/get
summary
