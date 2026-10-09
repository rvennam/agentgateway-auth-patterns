#!/bin/bash
TEST_NAME=05-tls; . "$(dirname "$0")/lib.sh"
C=$S/certs
# README inbound mTLS shape: listeners[].tls.frontendValidation (Gateway API v1.5 moved this to spec.tls.frontend)
out=$(kubectl apply --dry-run=server -f - 2>&1 <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: authtest-gw, namespace: authtest}
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 8080
      allowedRoutes: {namespaces: {from: Same}}
    - name: https
      protocol: HTTPS
      port: 8443
      allowedRoutes: {namespaces: {from: Same}}
      tls:
        mode: Terminate
        certificateRefs: [{kind: Secret, name: gw-tls}]
        frontendValidation:
          caCertificateRefs: [{kind: ConfigMap, name: client-ca}]
Y
); log "README listeners[].tls.frontendValidation (server dry-run): $(echo "$out" | head -c 250)"
# Current shape: spec.tls.frontend.perPort
kubectl apply -f - <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: authtest-gw, namespace: authtest}
spec:
  gatewayClassName: enterprise-agentgateway
  tls:
    frontend:
      perPort:
        - port: 8443
          tls:
            validation:
              mode: AllowValidOnly
              caCertificateRefs: [{group: "", kind: ConfigMap, name: client-ca}]
  listeners:
    - name: http
      protocol: HTTP
      port: 8080
      allowedRoutes: {namespaces: {from: Same}}
    - name: https
      protocol: HTTPS
      port: 8443
      allowedRoutes: {namespaces: {from: Same}}
      tls:
        mode: Terminate
        certificateRefs: [{kind: Secret, name: gw-tls}]
Y
kubectl apply -n authtest -f - <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-https-plain}
spec:
  parentRefs: [{name: authtest-gw, sectionName: https}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /plain}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{name: httpbin, port: 8080}]
Y
for i in $(seq 1 20); do kubectl get svc authtest-gw -n authtest -o jsonpath='{.spec.ports[*].port}' | grep -q 8443 && break; sleep 3; done; settle 15
log "gateway listeners status: $(kubectl get gateway authtest-gw -n authtest -o json | jq -c '[.status.listeners[] | {name, conds: [.conditions[] | select(.status!="True") | .type]}]')"
HGW=https://$GW_IP:8443
expect "mTLS: no client cert -> TLS failure (curl exit)" 000 --cacert $C/ca.crt $HGW/plain/get
expect "mTLS: valid client cert -> 200" 200 --cacert $C/ca.crt --cert $C/client.crt --key $C/client.key $HGW/plain/get
openssl req -new -newkey rsa:2048 -nodes -keyout $C/badclient.key -out $C/badclient.csr -subj "/CN=bad" 2>/dev/null; openssl x509 -req -days 5 -CA $C/other-ca.crt -CAkey $C/other-ca.key -set_serial 9 -in $C/badclient.csr -out $C/badclient.crt 2>/dev/null
expect "mTLS: client cert from untrusted CA -> failure" 000 --cacert $C/ca.crt --cert $C/badclient.crt --key $C/badclient.key $HGW/plain/get
log "-- backend sees with mTLS: $(curl -s --cacert $C/ca.crt --cert $C/client.crt --key $C/client.key $HGW/plain/headers | jq -c '.headers | with_entries(select(.key|test("forward|client|cert|ssl";"i")))')"
expect "http:8080 listener unaffected -> 200" 200 $GW/plain/get
# ---- BackendTLS: README inline shape (backend.tls.hostname) vs schema
kubectl apply -n authtest -f - <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-tlsbackend}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /tlsbackend}}]
      backendRefs: [{name: tlsbackend, port: 8443}]
Y
settle 4; expect "no BackendTLS: gateway speaks plaintext to TLS backend -> 5xx" 502 $GW/tlsbackend/x
out=$(kubectl apply -n authtest -f - 2>&1 <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: backend-tls-inline}
spec:
  targetRefs: [{group: "", kind: Service, name: tlsbackend}]
  backend:
    tls:
      hostname: api.upstream.example.com
Y
); log "README backend.tls.hostname: $(echo "$out" | head -c 200)"
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: backend-tls-inline}
spec:
  targetRefs: [{group: "", kind: Service, name: tlsbackend}]
  backend:
    tls:
      caCertificateRefs: [{kind: ConfigMap, name: backend-ca}]
      sni: tlsbackend.authtest.svc.cluster.local
Y
wait_policy agentgatewaypolicy backend-tls-inline; settle
expect "inline backend.tls + correct CA -> 200" 200 $GW/tlsbackend/x
log "-- tls backend saw: $(curl -s $GW/tlsbackend/x)"
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: backend-tls-inline}
spec:
  targetRefs: [{group: "", kind: Service, name: tlsbackend}]
  backend:
    tls:
      caCertificateRefs: [{kind: ConfigMap, name: other-ca}]
Y
settle 6; expect "inline backend.tls + WRONG CA -> 5xx" 502 $GW/tlsbackend/x
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: backend-tls-inline}
spec:
  targetRefs: [{group: "", kind: Service, name: tlsbackend}]
  backend:
    tls:
      insecureSkipVerify: All
Y
settle 6; expect "inline backend.tls insecureSkipVerify: All -> 200" 200 $GW/tlsbackend/x
kubectl delete agentgatewaypolicy backend-tls-inline -n authtest >/dev/null; settle 5
# Gateway API standard BackendTLSPolicy (README shape)
kubectl apply -n authtest -f - <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata: {name: my-backend-tls}
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: tlsbackend
  validation:
    hostname: tlsbackend.authtest.svc.cluster.local
    caCertificateRefs:
      - kind: ConfigMap
        name: backend-ca
        group: ""
Y
settle 8; log "BackendTLSPolicy status: $(kubectl get backendtlspolicy my-backend-tls -n authtest -o jsonpath='{.status.ancestors[*].conditions[*].type}={.status.ancestors[*].conditions[*].status}')"
expect "BackendTLSPolicy (Gateway API std) + correct CA -> 200" 200 $GW/tlsbackend/x
kubectl delete backendtlspolicy my-backend-tls -n authtest >/dev/null
summary
