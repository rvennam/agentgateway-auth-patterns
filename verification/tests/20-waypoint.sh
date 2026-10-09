#!/bin/bash
TEST_NAME=20-waypoint; . "$(dirname "$0")/lib.sh"
NS=authtest-mesh
for i in $(seq 1 30); do kubectl get pods -n $NS --no-headers 2>/dev/null | grep -qvE '1/1 +Running' || break; sleep 4; done
log "pods: $(kubectl get pods -n $NS --no-headers | awk '{print $1":"$2}' | paste -sd' ' -)"
X() { kubectl exec -n $NS deploy/$1 -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$2"; }
XB() { kubectl exec -n $NS deploy/$1 -- curl -s --max-time 10 "$2"; }
URL=http://inventory-mcp.$NS.svc.cluster.local/headers
log "baseline (no waypoint): customer=$(X customer-agent $URL) rogue=$(X rogue-agent $URL)"
kubectl label svc inventory-mcp -n $NS istio.io/use-waypoint=agw-waypoint --overwrite >/dev/null; settle 8
log "via waypoint: customer=$(X customer-agent $URL) rogue=$(X rogue-agent $URL)"
log "-- waypoint log: $(kubectl logs -n $NS -l gateway.networking.k8s.io/gateway-name=agw-waypoint --tail=2 2>/dev/null | grep -oE 'source\.identity=[^ ]+|src.identity=[^ ]+|http.status=[0-9]+' | paste -sd' ' - | head -c 200)"
# Pattern W1: identity-based authorization via SPIFFE (CEL on source.identity)
kubectl apply -n $NS -f - <<'Y' >/dev/null
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: waypoint-authz}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: agw-waypoint}]
  traffic:
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - 'source.identity.namespace == "authtest-mesh" && source.identity.serviceAccount == "customer-agent"'
Y
settle 8
c=$(X customer-agent $URL); r=$(X rogue-agent $URL); log "authz: customer=$c rogue=$r"
[ "$c" = 200 ] && [ "$r" = 403 ] && { PASS=$((PASS+1)); log "PASS W1 SPIFFE identity authz (allow customer-agent, deny rogue-agent)"; } || { FAIL=$((FAIL+1)); log "FAIL W1"; }
# Pattern W2: propagate workload identity to the backend as headers (CEL transformation)
kubectl apply -n $NS -f - <<'Y' >/dev/null
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: waypoint-identity-headers}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: Gateway, name: agw-waypoint}]
  traffic:
    transformation:
      request:
        set:
          - name: x-caller-spiffe
            value: 'source.identity.trustDomain + "/ns/" + source.identity.namespace + "/sa/" + source.identity.serviceAccount'
          - name: x-caller-sa
            value: source.identity.serviceAccount
Y
settle 8
B=$(XB customer-agent $URL); log "-- backend headers: $(echo "$B" | jq -c '.headers | with_entries(select(.key|test("caller";"i")))')"
echo "$B" | grep -q 'sa/customer-agent' && { PASS=$((PASS+1)); log "PASS W2 caller SPIFFE identity propagated as header"; } || { FAIL=$((FAIL+1)); log "FAIL W2"; }
# Pattern W3: LLM egress through waypoint: ServiceEntry + AgentgatewayBackend with API key injection; agents send no key
kubectl create secret generic openai-secret -n $NS --from-literal=Authorization="Bearer $OPENAI_API_KEY" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n $NS -f - <<'Y' >/dev/null
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: myllm
  labels: {istio.io/use-waypoint: agw-waypoint}
spec:
  hosts: [myllm.com]
  location: MESH_EXTERNAL
  ports: [{number: 80, name: http, protocol: HTTP}]
  resolution: STATIC
  endpoints: [{address: 1.1.1.1}]
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: openai}
spec:
  ai:
    provider:
      openai: {model: gpt-4o-mini}
  policies:
    auth:
      secretRef: {name: openai-secret}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: llm-routes}
spec:
  parentRefs: [{group: networking.istio.io, kind: ServiceEntry, name: myllm}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /openai}}]
      backendRefs: [{name: openai, group: agentgateway.dev, kind: AgentgatewayBackend}]
Y
settle 12
BODY='{"model":"gpt-4o-mini","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":5}'
R=$(kubectl exec -n $NS deploy/customer-agent -- curl -s --max-time 30 -o /tmp/llm.json -w '%{http_code}' http://myllm.com/openai/v1/chat/completions -H 'content-type: application/json' -d "$BODY"); OUT=$(kubectl exec -n $NS deploy/customer-agent -- cat /tmp/llm.json | jq -r '.choices[0].message.content // .error.message' 2>/dev/null)
log "customer-agent -> OpenAI via waypoint (no key in pod): http=$R content=$OUT"
[ "$R" = 200 ] && { PASS=$((PASS+1)); log "PASS W3 LLM egress with waypoint-injected API key"; } || { FAIL=$((FAIL+1)); log "FAIL W3"; }
R2=$(kubectl exec -n $NS deploy/rogue-agent -- curl -s --max-time 30 -o /dev/null -w '%{http_code}' http://myllm.com/openai/v1/chat/completions -H 'content-type: application/json' -d "$BODY"); log "rogue-agent -> OpenAI via waypoint: http=$R2"
[ "$R2" = 403 ] && { PASS=$((PASS+1)); log "PASS W3 rogue agent blocked by identity authz before egress"; } || { FAIL=$((FAIL+1)); log "FAIL W3 rogue"; }
log "-- waypoint access log (llm): $(kubectl logs -n $NS -l gateway.networking.k8s.io/gateway-name=agw-waypoint --tail=20 2>/dev/null | grep -i 'gen_ai' | tail -1 | grep -oE 'source.identity[^ ]*|gen_ai\.[a-z._]+=[^ ]+' | paste -sd' ' - | head -c 300)"
summary
