#!/bin/bash
TEST_NAME=04-jwt; . "$(dirname "$0")/lib.sh"
KC_ISS=$GW/keycloak/realms/authtest
kctoken() { curl -s -X POST $KC_ISS/protocol/openid-connect/token -d client_id=agw -d client_secret=agw-secret -d grant_type=password -d "username=$1" -d "password=$1-pw" -d scope=openid | jq -r .access_token; }
ALICE=$(kctoken alice); BOB=$(kctoken bob); log "alice claims: $(jwtclaims $ALICE | jq -c '{iss,aud,sub,tier,role}')"
# README shape: remote JWKS via backendRef Service + jwksPath (+ cacheDuration)
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: jwt-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-jwt}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "$KC_ISS"
          audiences: ["authtest-mcp"]
          jwks:
            remote:
              jwksPath: "/keycloak/realms/authtest/protocol/openid-connect/certs"
              cacheDuration: "5m"
              backendRef: {kind: Service, name: keycloak, namespace: authtest, port: 8080}
Y
wait_policy agentgatewaypolicy jwt-auth; settle
expect "remote JWKS: no token -> 401" 401 $GW/jwt/get
expect "remote JWKS: garbage -> 401" 401 -H 'Authorization: Bearer abc.def.ghi' $GW/jwt/get
expect "remote JWKS: keycloak alice -> 200" 200 -H "Authorization: Bearer $ALICE" $GW/jwt/get
LOCAL=$(mint '{"sub":"alice"}'); expect "remote JWKS: other issuer -> 401" 401 -H "Authorization: Bearer $LOCAL" $GW/jwt/get
log "-- backend sees (Authorization stripped by default?): $(curl -s -H "Authorization: Bearer $ALICE" $GW/jwt/headers | jq -c '.headers | with_entries(select(.key|test("auth";"i")))')"
# README inline JWKS multi-provider + CEL authorization
JWKS=$(cat $S/keys/jwks.json)
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: jwt-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-jwt}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://authtest.example
          audiences: [authtest]
          jwks:
            inline: '$JWKS'
        - issuer: "$KC_ISS"
          audiences: ["authtest-mcp"]
          jwks:
            remote:
              jwksPath: "/keycloak/realms/authtest/protocol/openid-connect/certs"
              backendRef: {kind: Service, name: keycloak, namespace: authtest, port: 8080}
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - jwt.sub == "agent-service"
          - jwt.role == "admin"
Y
wait_policy agentgatewaypolicy jwt-auth; settle
expect "inline provider: local sub=agent-service -> 200" 200 -H "Authorization: Bearer $(mint '{"sub":"agent-service"}')" $GW/jwt/get
expect "inline provider: local sub=someone (CEL deny) -> 403" 403 -H "Authorization: Bearer $(mint '{"sub":"someone"}')" $GW/jwt/get
expect "inline provider: wrong aud -> 401" 401 -H "Authorization: Bearer $(mint '{"sub":"agent-service","aud":"other"}')" $GW/jwt/get
expect "inline provider: expired -> 401" 401 -H "Authorization: Bearer $(mint '{"sub":"agent-service"}' -100)" $GW/jwt/get
expect "2nd provider: keycloak alice role=admin -> 200" 200 -H "Authorization: Bearer $ALICE" $GW/jwt/get
expect "2nd provider: keycloak bob role=analyst -> 403" 403 -H "Authorization: Bearer $BOB" $GW/jwt/get
# modes
for m in Optional Permissive; do
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: jwt-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-jwt}]
  traffic:
    jwtAuthentication:
      mode: $m
      providers:
        - issuer: https://authtest.example
          audiences: [authtest]
          jwks: {inline: '$JWKS'}
Y
settle 5
expect "$m: no token" 200 $GW/jwt/get
expect "$m: bad token" $([ $m = Optional ] && echo 401 || echo 200) -H 'Authorization: Bearer abc.def.ghi' $GW/jwt/get
expect "$m: good token" 200 -H "Authorization: Bearer $(mint '{"sub":"x"}')" $GW/jwt/get
done
# jwks.remote.url form (schema has url alongside backendRef) -- via gateway-reachable public URL
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata: {name: jwt-auth}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-jwt}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "$KC_ISS"
          audiences: ["authtest-mcp"]
          jwks:
            remote:
              url: "$KC_ISS/protocol/openid-connect/certs"
Y
settle 6; log "jwks.remote.url status: $(kubectl get agentgatewaypolicy jwt-auth -n authtest -o jsonpath='{.status.ancestors[*].conditions[*].message}' | head -c 200)"
expect "jwks.remote.url: keycloak alice -> 200" 200 -H "Authorization: Bearer $ALICE" $GW/jwt/get
summary
