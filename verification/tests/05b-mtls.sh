#!/bin/bash
TEST_NAME=05b-mtls; . "$(dirname "$0")/lib.sh"
C=$S/certs
kubectl apply -f - <<'Y'
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata: {name: authtest-gw, namespace: authtest}
spec:
  gatewayClassName: enterprise-agentgateway
  tls:
    frontend:
      default:
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
for i in $(seq 1 30); do kubectl get svc authtest-gw -n authtest -o jsonpath='{.spec.ports[*].port}' | grep -q 8443 && break; sleep 3; done; settle 20
log "gateway listeners: $(kubectl get gateway authtest-gw -n authtest -o json | jq -c '[.status.listeners[] | {name, bad: [.conditions[] | select(.status!="True") | .type]}]')"
HGW=https://$GW_IP:8443
expect "mTLS: no client cert -> handshake failure" 000 --cacert $C/ca.crt $HGW/plain/get
expect "mTLS: valid client cert -> 200" 200 --cacert $C/ca.crt --cert $C/client.crt --key $C/client.key $HGW/plain/get
expect "mTLS: untrusted-CA client cert -> failure" 000 --cacert $C/ca.crt --cert $C/badclient.crt --key $C/badclient.key $HGW/plain/get
log "-- backend sees with mTLS: $(curl -s --cacert $C/ca.crt --cert $C/client.crt --key $C/client.key $HGW/plain/headers | jq -c '.headers | with_entries(select(.key|test("forward|client|cert|ssl";"i")))')"
log "-- server cert presented: $(echo | openssl s_client -connect $GW_IP:8443 -cert $C/client.crt -key $C/client.key 2>/dev/null | openssl x509 -noout -subject 2>/dev/null)"
expect "http:8080 unaffected -> 200" 200 $GW/plain/get
# AllowInsecureFallback mode
kubectl patch gateway authtest-gw -n authtest --type=merge -p '{"spec":{"tls":{"frontend":{"default":{"validation":{"mode":"AllowInsecureFallback","caCertificateRefs":[{"group":"","kind":"ConfigMap","name":"client-ca"}]}}}}}}' >/dev/null; settle 10
expect "AllowInsecureFallback: no client cert -> 200" 200 --cacert $C/ca.crt $HGW/plain/get
expect "AllowInsecureFallback: valid client cert -> 200" 200 --cacert $C/ca.crt --cert $C/client.crt --key $C/client.key $HGW/plain/get
# BackendTLS with system roots (no caCertificateRefs) to a public HTTPS host via AgentgatewayBackend
kubectl apply -n authtest -f - <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: httpbin-org}
spec:
  static: {host: httpbin.org, port: 443}
  policies:
    tls: {}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-httpbin-org}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  hostnames: []
  rules:
    - matches: [{path: {type: PathPrefix, value: /ext}}]
      filters:
        - {type: URLRewrite, urlRewrite: {hostname: httpbin.org, path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}
      backendRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-org}]
Y
settle 8
expect "BackendTLS system roots (tls: {}) to httpbin.org -> 200" 200 $GW/ext/get
log "-- httpbin.org saw url: $(curl -s $GW/ext/get | jq -r .url)"
summary
