#!/bin/bash
TEST_NAME=13-dryrun; . "$(dirname "$0")/lib.sh"
try() { local d="$1"; shift; out=$(kubectl apply --dry-run=server -n authtest -f - 2>&1); if echo "$out" | grep -qiE 'error|invalid|unknown field'; then log "SCHEMA-FAIL $d :: $(echo "$out" | grep -iE 'error|invalid|unknown' | head -1 | cut -c1-260)"; else log "SCHEMA-OK   $d"; fi; }
try "README: Gateway-mediated Variant B (backend.tokenExchange.entra)" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-entra}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-plain}]
  backend:
    tokenExchange:
      mode: ExchangeOnly
      entra:
        clientId: 00000000-0000-0000-0000-000000000000
        clientSecretRef: {name: entra-client-secret}
        tenantId: 11111111-1111-1111-1111-111111111111
        scope: "https://graph.microsoft.com/.default"
Y
try "Current: backend.entTokenExchange.entra" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-entra2}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-plain}]
  backend:
    entTokenExchange:
      entra:
        tenantId: 11111111-1111-1111-1111-111111111111
        clientAuth: {clientId: 00000000-0000-0000-0000-000000000000, clientSecretRef: {name: entra-client-secret}}
        scopes: ["https://graph.microsoft.com/.default"]
        backendRef: {group: agentgateway.dev, kind: AgentgatewayBackend, name: entra-login, port: 443}
Y
try "README: Gateway-Brokered DCR Auth0 policy (mcp.authentication on AgentgatewayBackend target)" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-mcp-auth-eager}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: mcp-everything}]
  backend:
    mcp:
      authentication:
        mode: Strict
        issuer: https://your-tenant.auth0.com/
        audiences: [https://your-api/]
        jwks:
          backendRef: {name: idp-jwks, kind: AgentgatewayBackend, group: agentgateway.dev}
          jwksPath: .well-known/jwks.json
        resourceMetadata:
          agentgateway.dev/issuer-proxy: http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth-issuer
          authorizationServers: [https://gateway.example.com/mcp]
          resource: https://gateway.example.com/mcp
Y
try "README: Double OAuth (tokenExchange.elicitation clientName+secretName)" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-double}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-plain}]
  traffic:
    entExtAuth:
      authConfigRef: {name: corporate-sso}
      backendRef: {name: ext-auth-service-enterprise-agentgateway, namespace: agentgateway-system, port: 8083}
  backend:
    tokenExchange:
      elicitation: {clientName: github, secretName: github-oauth-app}
Y
try "README: Eager Upstream Variant 1 (ElicitationOnly + elicitation.secretName on AgentgatewayBackend)" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-eager}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: mcp-everything}]
  backend:
    tokenExchange:
      mode: ElicitationOnly
      elicitation: {secretName: github-token-exchange}
Y
try "README: Eager Upstream MCP backend wiring (AgentgatewayBackend policies.tls + policies.mcp.authentication)" <<'Y'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata: {name: dry-github}
spec:
  mcp:
    targets:
      - name: mcp-target
        static: {host: api.githubcopilot.com, port: 443}
  policies:
    tls: {}
    mcp:
      authentication:
        mode: Strict
        issuer: https://sts.windows.net/tenant/
        audiences: [api://client]
        jwks:
          backendRef: {name: entra-jwks, kind: AgentgatewayBackend, group: agentgateway.dev}
          jwksPath: tenant/discovery/v2.0/keys
        resourceMetadata:
          agentgateway.dev/issuer-proxy: http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth-issuer
          authorizationServers: [https://gateway.example.com/mcp/github]
          resource: https://gateway.example.com/mcp/github
          scopesSupported: [api://client/agentgateway]
Y
try "README: Elicitation (ElicitationOnly + clientName/secretName on HTTPRoute)" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-elicit}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-plain}]
  backend:
    tokenExchange:
      mode: ElicitationOnly
      elicitation: {clientName: jira, secretName: jira-oauth-app}
Y
try "Current: entElicitation.interactive" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-interactive}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: mcp-everything}]
  backend:
    entElicitation:
      interactive:
        oauth:
          clientId: abc
          clientSecretRef: {name: jira-oauth-app, key: client-secret}
          scopes: [read:jira-work]
          redirectUri: http://localhost:8090/age/elicitations
          authorizeUrl: https://auth.atlassian.com/authorize
          accessTokenUrl: https://auth.atlassian.com/oauth/token
Y
try "Current: entElicitation.brokered.chainedAuth (DCR via baseUrl)" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-brokered}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: mcp-everything}]
  backend:
    entElicitation:
      brokered:
        mcpResourcePath: /mcp/gitlab
        chainedAuth:
          oauth:
            baseUrl: https://gitlab.com
            scopes: [mcp]
Y
try "README: Eager Upstream Helm-era STS_URI env on EnterpriseAgentgatewayParameters" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayParameters
metadata: {name: dry-params}
spec:
  env:
    - {name: STS_URI, value: http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token}
    - {name: STS_AUTH_TOKEN, value: /var/run/secrets/xds-tokens/xds-token}
Y
try "README: OBO Delegation policy (jwtAuthentication + tokenExchange ExchangeOnly on HTTPRoute)" <<'Y'
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: dry-obo}
spec:
  targetRefs: [{group: gateway.networking.k8s.io, kind: HTTPRoute, name: r-plain}]
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "https://idp.example.com"
          audiences: ["agent-gateway"]
          jwks:
            remote:
              jwksPath: "/.well-known/jwks.json"
              backendRef: { kind: Service, name: idp, namespace: idp-system, port: 443 }
  backend:
    tokenExchange:
      mode: ExchangeOnly
Y
try "README: standalone-binary jwks.url inside K8s mcpAuthentication (not applicable) - skip" <<'Y'
apiVersion: v1
kind: ConfigMap
metadata: {name: dry-noop}
Y
summary
