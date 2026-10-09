#!/bin/bash
TEST_NAME=05c-mtls-strict; . "$(dirname "$0")/lib.sh"
C=$S/certs; HGW=https://$GW_IP:8443
kubectl patch gateway authtest-gw -n authtest --type=merge -p '{"spec":{"tls":{"frontend":{"default":{"validation":{"mode":"AllowValidOnly","caCertificateRefs":[{"group":"","kind":"ConfigMap","name":"client-ca"}]}}}}}}' >/dev/null; settle 15
for i in 1 2 3; do curl -s -o /dev/null --cacert $C/ca.crt --cert $C/client.crt --key $C/client.key $HGW/plain/get && break; sleep 5; done
expect "strict mTLS: valid client cert -> 200" 200 --cacert $C/ca.crt --cert $C/client.crt --key $C/client.key $HGW/plain/get
log "-- no cert curl error: $(curl -s --cacert $C/ca.crt $HGW/plain/get 2>&1 | head -c 150)"
expect "strict mTLS: no client cert -> fail" 000 --cacert $C/ca.crt $HGW/plain/get
expect "strict mTLS: untrusted CA client cert -> fail" 000 --cacert $C/ca.crt --cert $C/badclient.crt --key $C/badclient.key $HGW/plain/get
log "-- backend headers with mTLS: $(curl -s --cacert $C/ca.crt --cert $C/client.crt --key $C/client.key $HGW/plain/headers | jq -c '.headers | keys')"
summary
