#!/bin/bash
TEST_NAME=14-interactive-elicit; . "$(dirname "$0")/lib.sh"
JWKS=$(cat $S/keys/jwks.json); UP_ISS=$GW/keycloak/realms/upstream
kubectl apply -n authtest -f - <<Y
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: httpbin-elicit}
spec:
  static: {host: httpbin.authtest.svc.cluster.local, port: 8080}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata: {name: r-elicit}
spec:
  parentRefs: [{name: authtest-gw, sectionName: http}]
  rules:
    - matches: [{path: {type: PathPrefix, value: /elicit}}]
      filters: [{type: URLRewrite, urlRewrite: {path: {type: ReplacePrefixMatch, replacePrefixMatch: /}}}]
      backendRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-elicit}]
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: elicit-jwt}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-elicit}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: https://authtest.example
          audiences: [authtest]
          jwks: {inline: '$JWKS'}
---
# README "Elicitation" shape: Secret type extauth.solo.io/oauth with client-id/client-secret + ElicitationOnly + elicitation.clientName/secretName
apiVersion: v1
kind: Secret
metadata: {name: jira-oauth-app}
type: extauth.solo.io/oauth
stringData:
  client-id: agw
  client-secret: agw-secret
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: jira-elicit-only}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-elicit}]
  backend:
    tokenExchange:
      mode: ElicitationOnly
      elicitation: {clientName: jira, secretName: jira-oauth-app}
Y
wait_policy enterpriseagentgatewaypolicy jira-elicit-only; settle 8
U=$(mint '{"sub":"alice"}')
R=$(curl -s -o /tmp/el.body -w '%{http_code}' -H "Authorization: Bearer $U" $GW/elicit/headers); log "README legacy secret (client-id/client-secret keys): http=$R body=$(head -c 300 /tmp/el.body)"
# legacy opaque secret format expected by the STS: client_id, client_secret, authorize_url, access_token_url, scopes
kubectl apply -n authtest -f - <<Y
apiVersion: v1
kind: Secret
metadata: {name: jira-oauth-app}
type: Opaque
stringData:
  app_id: jira
  client_id: agw
  client_secret: agw-secret
  authorize_url: $UP_ISS/protocol/openid-connect/auth
  access_token_url: $UP_ISS/protocol/openid-connect/token
  scopes: "openid profile"
Y
settle 6
R=$(curl -s -o /tmp/el.body -w '%{http_code}' -H "Authorization: Bearer $U" $GW/elicit/headers); log "legacy opaque secret format: http=$R body=$(head -c 400 /tmp/el.body)"
if [ "$R" = 500 ] && grep -q '"url"' /tmp/el.body; then PASS=$((PASS+1)); log "PASS interactive elicitation returns PENDING url (HTTP 500 + {url})"; else FAIL=$((FAIL+1)); log "FAIL expected 500+url"; fi
# Typed entElicitation.interactive
kubectl delete enterpriseagentgatewaypolicy jira-elicit-only -n authtest >/dev/null
kubectl apply -n authtest -f - <<Y
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: jira-interactive}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: httpbin-elicit}]
  backend:
    entElicitation:
      interactive:
        oauth:
          clientId: agw
          clientSecretRef: {name: jira-oauth-app, key: client_secret}
          scopes: [openid, profile]
          redirectUri: http://localhost:8090/age/elicitations
          authorizeUrl: $UP_ISS/protocol/openid-connect/auth
          accessTokenUrl: $UP_ISS/protocol/openid-connect/token
Y
wait_policy enterpriseagentgatewaypolicy jira-interactive; settle 8
R=$(curl -s -o /tmp/el.body -w '%{http_code}' -H "Authorization: Bearer $U" $GW/elicit/headers); log "entElicitation.interactive: http=$R body=$(head -c 400 /tmp/el.body)"
if [ "$R" = 500 ] && grep -q '"url"' /tmp/el.body; then PASS=$((PASS+1)); log "PASS typed interactive elicitation returns PENDING url"; else FAIL=$((FAIL+1)); log "FAIL expected 500+url"; fi
log "-- STS elicitation list (k8s api token): $(curl -s -H "Authorization: Bearer $(kubectl create token agent-runtime -n authtest --duration=5m)" http://localhost:17777/elicitations 2>/dev/null | head -c 300)"
summary
