#!/bin/bash
TEST_NAME=03-extauth; . "$(dirname "$0")/lib.sh"
# README HTTP shape verbatim: path: "/check" (schema says path is a CEL expression)
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: ext-auth-http}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-extauth-http}]
  traffic:
    extAuth:
      backendRef: {kind: Service, name: http-ext-authz, port: 80}
      failureMode: FailClosed
      http:
        path: "/check"
        allowedResponseHeaders: [Authorization]
Y
settle 6
log "README path:\"/check\" status: $(kubectl get agentgatewaypolicy ext-auth-http -n authtest -o jsonpath='{.status.conditions[*].message}' | head -c 300)"
expect "README http shape: no token" 403 $GW/extauth-http/get
expect "README http shape: with x-ext-token" 200 -H 'x-ext-token: letmein' $GW/extauth-http/get
# corrected CEL string literal
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: ext-auth-http}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-extauth-http}]
  traffic:
    extAuth:
      backendRef: {kind: Service, name: http-ext-authz, port: 80}
      failureMode: FailClosed
      http:
        path: '"/check"'
        allowedRequestHeaders: [x-ext-token]
        allowedResponseHeaders: [Authorization, x-ext-user]
Y
wait_policy agentgatewaypolicy ext-auth-http; settle
expect "http CEL path: no token -> 403" 403 $GW/extauth-http/get
expect "http CEL path: Authorization: Bearer letmein -> 200" 200 -H 'Authorization: Bearer letmein' $GW/extauth-http/get
expect "http CEL path: x-ext-token (allowedRequestHeaders) -> 200" 200 -H 'x-ext-token: letmein' $GW/extauth-http/get
log "-- backend sees injected headers: $(curl -s -H 'x-ext-token: letmein' $GW/extauth-http/headers | jq -c '.headers | with_entries(select(.key|test("auth|ext";"i")))')"
# gRPC README shape: grpc.context (schema has contextExtensions)
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: ext-auth-grpc}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-extauth-grpc}]
  traffic:
    extAuth:
      backendRef: {kind: Service, name: grpc-ext-authz, port: 4444}
      failureMode: FailClosed
      grpc:
        context:
          environment: prod
Y
log "README grpc.context apply rc=$? ; status: $(kubectl get agentgatewaypolicy ext-auth-grpc -n authtest -o jsonpath='{.status.conditions[*].message}' 2>/dev/null | head -c 200)"
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: ext-auth-grpc}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-extauth-grpc}]
  traffic:
    extAuth:
      backendRef: {kind: Service, name: grpc-ext-authz, port: 4444}
      failureMode: FailClosed
      grpc:
        contextExtensions:
          environment: prod
Y
wait_policy agentgatewaypolicy ext-auth-grpc; settle
expect "grpc: no header -> 403" 403 $GW/extauth-grpc/get
expect "grpc: x-ext-authz: allow -> 200" 200 -H 'x-ext-authz: allow' $GW/extauth-grpc/get
expect "grpc: x-ext-authz: deny -> 403" 403 -H 'x-ext-authz: deny' $GW/extauth-grpc/get
log "-- backend sees: $(curl -s -H 'x-ext-authz: allow' $GW/extauth-grpc/headers | jq -c '.headers | with_entries(select(.key|test("ext";"i")))')"
summary
