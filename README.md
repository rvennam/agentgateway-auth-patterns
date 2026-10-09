# Agent Gateway Auth Patterns

A practical guide to the authentication patterns supported by agentgateway. Each pattern is tagged with the **minimum tier** required (**OSS** or **Enterprise**), with a "when to use," a YAML snippet, and a diagram.

> **Why an AI gateway needs its own auth patterns.** Christian Posta's [Can You Use an API Gateway as an MCP Gateway?](https://blog.christianposta.com/can-you-use-an-api-gateway-for-mcp/) frames the gap well: traditional API gateways were built for stateless REST where every request carries its own context in HTTP headers and URL. MCP — the protocol AI tooling is converging on — uses persistent sessions, JSON-RPC bodies, server-initiated SSE callbacks, and multiplexes many backends behind one endpoint. None of that maps cleanly onto an API-gateway feature matrix, and the auth patterns reflect that: dynamic client registration, multi-stage OAuth (downstream + upstream), token exchange with agent-actor claims, and on-demand consent elicitation are all new territory.

> Related reading from Christian Posta: [API Keys Are a Bad Idea for Enterprise LLM, Agent, and MCP Access](https://blog.christianposta.com/api-keys-are-a-bad-idea-for-enterprise-llm-agent-and-mcp-access/) · [Explaining OAuth Delegation, 'On Behalf Of', and Agent Identity for AI Agents](https://blog.christianposta.com/explaining-on-behalf-of-for-ai-agents/) · [Enterprise MCP SSO With Microsoft Entra and Agentgateway](https://blog.christianposta.com/enterprise-mcp-sso-with-microsoft-entra-and-agentgateway/) · [Connecting SaaS MCP Servers to Enterprise With Agentgateway](https://blog.christianposta.com/connecting-saas-mcp-servers-to-enterprise-with-agentgateway/) · [MCP Authorization Patterns for Upstream API Calls](https://blog.christianposta.com/mcp-authorization-patterns-upstream-api-calls/) · [Enterprise Challenges With MCP Adoption](https://blog.christianposta.com/enterprise-challenges-with-mcp-adoption/)

> **Documentation:** [docs.solo.io/agentgateway/latest](https://docs.solo.io/agentgateway/latest/) · [Enterprise API](https://docs.solo.io/agentgateway/latest/reference/api/solo/) · [OSS API](https://docs.solo.io/agentgateway/latest/reference/api/api/) · [Helm Values](https://docs.solo.io/agentgateway/latest/reference/helm/agentgateway/)

> **Verified on a live cluster (2026-10-08):** every YAML in this guide was applied to Solo Enterprise for agentgateway **v2026.9.3** (enterprise-agentgateway Helm chart, Gateway API v1.5.0 standard, Solo Istio 1.31 ambient for the waypoint patterns) and exercised end to end with Keycloak as the IdP. Where the API changed since the guide was first written, the YAML below is the shape that works today and a **"Tested"** note calls out what was observed. Patterns that need credentials we did not have (Okta, Microsoft Entra, GitHub OAuth apps) were validated against the installed CRD schema only and are marked as such.

---

## Tier Legend

| Tag | Meaning |
|---|---|
| **[OSS]** | Configurable using only the OSS `agentgateway.dev` API surface — works on the standalone OSS Rust binary and on Solo Enterprise clusters. The capability ships in the open-source data plane. |
| **[Enterprise]** | Requires **Solo Enterprise for agentgateway**. Depends on one or more enterprise-only components: the `EnterpriseAgentgatewayPolicy` / `AuthConfig` CRDs (`enterpriseagentgateway.solo.io`, `extauth.solo.io`), the Enterprise external auth service, the built-in **STS** (Security Token Service), or the **Solo Enterprise UI**. |

---

## Table of Contents

- [Architecture at a Glance](#architecture-at-a-glance)
- [Quick Selection Guide](#quick-selection-guide)
- [At a Glance: All Patterns](#at-a-glance-all-patterns)
- [Inbound Authentication](#inbound-authentication)
  - [API Key Auth](#api-key-auth-oss) — [OSS]
  - [Basic Auth (RFC 7617)](#basic-auth-rfc-7617-oss) — [OSS]
  - [BYO External Auth (gRPC ext_authz)](#byo-external-auth-grpc-ext_authz-oss) — [OSS]
  - [Standard OIDC / JWT Authentication](#standard-oidc--jwt-authentication-oss) — [OSS]
  - [Mutual TLS (mTLS)](#frontendtls-mtls--backendtls-oss) — [OSS]
  - [MCP OAuth with Dynamic Client Registration](#mcp-oauth-with-dynamic-client-registration-oss) — [OSS]
  - [MCP OAuth — Gateway-Brokered DCR for Auth0 / Okta](#mcp-oauth--gateway-brokered-dcr-for-auth0--okta-enterprise) — [Enterprise]
- [Token Exchange](#token-exchange)
  - [Gateway-Mediated OIDC + Token Exchange](#gateway-mediated-oidc--token-exchange-enterprise) — [Enterprise]
  - [OBO Delegation (Dual Identity)](#obo-delegation-dual-identity-enterprise) — [Enterprise]
  - [OBO Impersonation (Token Swap)](#obo-impersonation-token-swap-enterprise) — [Enterprise]
  - [Double OAuth Flow (OIDC + Elicitation)](#double-oauth-flow-oidc--elicitation-enterprise) — [Enterprise]
  - [Eager Upstream OAuth (Gateway as OAuth Issuer)](#eager-upstream-oauth-gateway-as-oauth-issuer-enterprise) — [Enterprise]
- [Upstream / Backend Auth](#upstream--backend-auth)
  - [Passthrough Token](#passthrough-token-oss) — [OSS]
  - [Static Secret Injection (Shared Credential)](#static-secret-injection-shared-credential-oss) — [OSS]
  - [Claim-Based Token Mapping](#claim-based-token-mapping-oss) — [OSS]
- [Credential Gathering](#credential-gathering)
  - [Elicitation](#elicitation-enterprise) — [Enterprise]
- [East-West: agentgateway as an Istio Ambient Waypoint](#east-west-agentgateway-as-an-istio-ambient-waypoint)
  - [Mesh Identity Authorization (SPIFFE, no tokens)](#mesh-identity-authorization-spiffe-no-tokens-enterprise) — [Enterprise]
  - [LLM Egress with Waypoint-Injected Credentials](#llm-egress-with-waypoint-injected-credentials-enterprise) — [Enterprise]
- [Decision Flowchart](#decision-flowchart)
- [Glossary](#glossary)

---

## Architecture at a Glance

agentgateway brokers identity in **two directions** — *inbound* (who's calling) and *outbound* (how to reach the destination). These diagrams are the mental model; the pattern sections below give the exact config.

### The two directions

```mermaid
flowchart LR
  B[Browsers] & M[MCP Clients] & A[Agents / Apps] -->|inbound| AGW["AgentGateway"]
  AGW -->|outbound| LLM[LLMs] & MCP[MCP Servers] & UP[Agents / APIs]
```

### New clients, no way to register them — real DCR vs. gateway-brokered DCR

AI clients (Claude Code, Cursor, VS Code) are each their own OAuth client, and the IdPs most enterprises run (Okta, Entra) don't allow open Dynamic Client Registration. Two ways to bridge that:

**Build a custom authorization server** — real DCR, unique client IDs, per-client revocation, but you build and run it:

```mermaid
flowchart LR
  C1[Claude Code] & C2[Cursor] & C3[VS Code] -->|"/register -> unique client_id"| AS["Custom Auth Server<br/>(e.g. auth-mcp)"]
  AS <-->|"broker login (per-user)"| IDP{{No-DCR IdP<br/>Okta / Entra}}
  AS -->|"own JWT (iss: AS)"| MCP[MCP Servers]
```

**Let agentgateway broker DCR** — one shared client ID, IdP token passed through, no per-client revocation, but nothing to build:

```mermaid
flowchart LR
  C1[Claude Code] & C2[Cursor] & C3[VS Code] -->|"/register -> ONE shared client_id"| AGW["AgentGateway<br/>(gateway-brokered DCR)"]
  AGW <-->|"broker login (per-user)"| IDP{{No-DCR IdP<br/>Okta / Entra}}
  AGW -->|"IdP JWT (passthrough)"| MCP[MCP Servers]
```

Either way, only the **registration** is shared — every user still logs in at the IdP as themselves, so per-user identity is preserved.

> **See it all working together:** [rvennam/agent-mesh-demo](https://github.com/rvennam/agent-mesh-demo) runs the ingress login + token rescoping, agent delegation chains (RFC 8693 with nested `act`), per-tool MCP authorization on workload *and* user identity, LLM budgets, and prompt guards on one Solo Istio ambient mesh with agentgateway as the waypoint. The [east-west section](#east-west-agentgateway-as-an-istio-ambient-waypoint) below covers the mesh-side identity patterns.

### Agents act on your behalf — token exchange (RFC 8693)

Don't hand a multi-hop agent your broad IdP token. The gateway swaps it for a fresh, scoped, short-lived one before any agent sees it — **impersonation** keeps just the user (`sub`), **delegation** adds an `act` claim naming the acting agent.

```mermaid
flowchart LR
  U[User] -->|"broad IdP JWT<br/>sub: alice - groups: eng, mcp-users, gcp-admin - exp: 1h"| AGW["AgentGateway"]
  AGW <-->|mint scoped token| STS{{Gateway STS}}
  AGW -->|"scoped JWT<br/>sub: alice - act: agent1 - groups: mcp-users - exp: 1m"| A1[Agent 1] --> A2[Agent 2]
```

### Agents call third-party APIs as you — elicitation

One inbound login, many upstreams — each with its **own** OAuth identity domain. The gateway gathers a per-user token for each provider (eager at connect, or lazy on first use) and injects it.

```mermaid
flowchart LR
  ENTRA{{Microsoft Entra}}

  C1[Claude Code]
  C2[Cursor]
  C3[VS Code]
  C1 & C2 & C3 -->|MCP| AGW["AgentGateway<br/>(OAuth issuer · gateway-brokered DCR)"]

  ENTRA <-->|"inbound login<br/>one IdP for all clients"| AGW

  AGW ==>|elicit| SF[Snowflake MCP]
  AGW ==>|elicit| ATL[Atlassian MCP]
  AGW ==>|elicit| GL[GitLab MCP]

  SF <-->|"upstream OAuth"| SFIDP{{Snowflake OAuth}}
  ATL <-->|"upstream OAuth"| ATLIDP{{Atlassian OAuth}}
  GL <-->|"upstream OAuth"| GLIDP{{GitLab OAuth}}
```

---

## Quick Selection Guide

Pick the **first** pattern that matches your scenario:

| If you need to… | Use this pattern | Tier |
|---|---|---|
| Let machine clients (CI, scripts) authenticate with a long-lived secret | [API Key Auth](#api-key-auth-oss) | OSS |
| Authenticate humans/services with username + password | [Basic Auth](#basic-auth-rfc-7617-oss) | OSS |
| Validate end-user JWTs from an existing IdP (Okta, Auth0, Keycloak, Entra) | [Standard OIDC / JWT](#standard-oidc--jwt-authentication-oss) | OSS |
| Authenticate clients with X.509 certificates (no app-layer credentials) | [Mutual TLS](#frontendtls-mtls--backendtls-oss) | OSS |
| Plug in a custom auth service (existing IAM, MFA, fraud checks) | [BYO External Auth](#byo-external-auth-grpc-ext_authz-oss) | OSS |
| Onboard MCP clients (Claude Code, VS Code) to Keycloak or another IdP that supports open DCR | [MCP OAuth + DCR](#mcp-oauth-with-dynamic-client-registration-oss) | OSS |
| Onboard MCP clients to Auth0 or Okta (DCR is gated behind their management APIs) | [MCP OAuth — Gateway-Brokered DCR](#mcp-oauth--gateway-brokered-dcr-for-auth0--okta-enterprise) | Enterprise |
| Replace the IdP token with a gateway-issued token before reaching agents | [Gateway-Mediated OIDC + Token Exchange](#gateway-mediated-oidc--token-exchange-enterprise) | Enterprise |
| Carry **both** user and agent identity to downstream services | [OBO Delegation](#obo-delegation-dual-identity-enterprise) | Enterprise |
| Carry the user's identity only, replacing the IdP token | [OBO Impersonation](#obo-impersonation-token-swap-enterprise) | Enterprise |
| Have one user complete OAuth flows for two different APIs in sequence | [Double OAuth Flow](#double-oauth-flow-oidc--elicitation-enterprise) | Enterprise |
| One SSO login → multiple upstream APIs (GitHub/GitLab/Atlassian), no Solo UI prompts | [Eager Upstream OAuth](#eager-upstream-oauth-gateway-as-oauth-issuer-enterprise) | Enterprise |
| Forward the client's original `Authorization` header to the backend | [Passthrough Token](#passthrough-token-oss) | OSS |
| Inject a single shared API key for all users into upstream calls | [Static Secret Injection](#static-secret-injection-shared-credential-oss) | OSS |
| Inject a different upstream key per user, team, or tier | [Claim-Based Token Mapping](#claim-based-token-mapping-oss) | OSS |
| Prompt users to authorize a third-party API on demand | [Elicitation](#elicitation-enterprise) | Enterprise |
| Authorize agent-to-MCP / agent-to-agent calls **inside the mesh** by workload identity, with no tokens or keys in the agent | [Mesh Identity Authorization](#mesh-identity-authorization-spiffe-no-tokens-enterprise) | Enterprise |
| Let in-mesh agents call LLM providers with **no API key in the pod**; the waypoint injects it per provider | [LLM Egress with Waypoint-Injected Credentials](#llm-egress-with-waypoint-injected-credentials-enterprise) | Enterprise |

---

## At a Glance: All Patterns

| Pattern | Tier | Direction | Identity carried downstream | Best for |
|---|---|---|---|---|
| API Key Auth | OSS | Inbound | Secret-name → `x-user-id` | Service accounts, CI/CD |
| Basic Auth | OSS | Inbound | Username | Internal tools, low-friction APIs |
| BYO External Auth | OSS | Inbound | Whatever your service returns | Custom auth, MFA, legacy IAM |
| Standard OIDC / JWT | OSS | Inbound | JWT claims (`sub`, `email`, …) | End-user APIs behind an IdP |
| Mutual TLS | OSS | Inbound + outbound | Client cert SAN/CN | Service-to-service, zero-trust |
| MCP OAuth + DCR | OSS | Inbound | OAuth identity | MCP clients onboarding to open-DCR IdPs (Keycloak) |
| MCP OAuth — Gateway-Brokered DCR | Enterprise | Inbound | OAuth identity | MCP clients onboarding to Auth0 / Okta (admin-gated DCR) |
| Gateway-Mediated OIDC + Token Exchange | Enterprise | Token exchange | Gateway-issued JWT (`sub` + `act`) | Decoupling agents from the IdP |
| OBO Delegation | Enterprise | Token exchange | Gateway-issued JWT (`sub` + `act`) | Auditable user-on-behalf-of-agent |
| OBO Impersonation | Enterprise | Token exchange | Gateway-issued JWT (`sub` only) | Hiding IdP tokens from agents |
| Double OAuth Flow | Enterprise | Token exchange | Downstream JWT + upstream token | Agents calling 3rd-party APIs as user |
| Eager Upstream OAuth | Enterprise | Token exchange | Upstream provider token | Single SSO → many third-party APIs |
| Passthrough Token | OSS | Outbound | Original client token | Federated identity, opaque tokens |
| Static Secret Injection | OSS | Outbound | Shared credential | One backend key, many users |
| Claim-Based Token Mapping | OSS | Outbound | Per-claim mapped credential | Tiered access, per-team API keys |
| Elicitation | Enterprise | Outbound | Per-user upstream OAuth token | On-demand 3rd-party authorization |
| Mesh Identity Authorization (waypoint) | Enterprise | East-west | Caller SPIFFE ID (`source.identity.*`), optionally as headers | Agent → MCP / agent → agent inside an ambient mesh |
| LLM Egress with Waypoint-Injected Credentials | Enterprise | East-west → egress | Provider API key (never in the agent pod) | In-mesh agents calling OpenAI / Anthropic / Bedrock |

---

# Inbound Authentication

Patterns that authenticate the client calling the gateway.

---

## API Key Auth `[OSS]`

> **When to use:** Machine clients (CI jobs, scripts, internal services) that need a stable, long-lived credential. Avoid for end-user traffic — keys leak, don't expire, and can't carry rich identity claims.

Clients authenticate with a static API key stored in a Kubernetes Secret. The `apiKeyAuthentication` policy validates the key inline in the data plane via `secretRef` (one Secret), `secretSelector` (label-matched Secrets), or `configMapSelector` (ConfigMaps, hashed keys only). Per-key metadata flows through to CEL authorization rules as `apiKey.<field>`.

> **Heads up:** there is no inline-keys mode in the current API — keys must live in a Kubernetes Secret (or a ConfigMap holding `keyHash` entries). Each top-level `stringData` entry in the Secret is one key. Use the JSON-object form to attach metadata (or to store a `sha256:<hex>` `keyHash` instead of the raw key); use the bare-string form for keys without metadata.

> **Where the key is read from:** by default the gateway reads the key from `Authorization: Bearer <key>`, **not** from `x-api-key`. To accept a custom header, set `location.header.name` (see the policy below). The key is consumed by the gateway and is not forwarded to the backend, and no `x-user-id` header is added — use the metadata in CEL (`apiKey.tier`, `apiKey.user`) or a `transformation` if the backend needs identity.

**Modes:** `Strict` (require a valid key) or `Optional` (validate if present, allow if not).

> **Tested (v2026.9.3):** `secretSelector`, `secretRef`, JSON and bare-string keys, `Optional` mode, `location.header` override, and CEL on `apiKey.tier` all behave as documented below.

**Trade-offs:** Simple to roll out. No native expiry — pair with rate limiting and audit logging. **Do not use for end-user (human) traffic** — see [API Keys Are a Bad Idea for Enterprise LLM, Agent, and MCP Access (Christian Posta)](https://blog.christianposta.com/api-keys-are-a-bad-idea-for-enterprise-llm-agent-and-mcp-access/) — keys prove possession, not legitimacy, and broad-permission keys held by an autonomous agent will eventually be misused.

### YAML — Secret with per-key metadata

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: api-keys
  namespace: agentgateway-system
  labels:
    purpose: api-key
stringData:
  # JSON-object form — key + arbitrary metadata
  alice-laptop: |
    { "key": "k-7f0a3c91-...",
      "metadata": {
        "user": "alice@example.com",
        "team": "platform",
        "tier": "paid"
      } }
  ci-prod-pipeline: |
    { "key": "k-ci-prod-abc123",
      "metadata": {
        "service": "github-actions",
        "tier": "internal"
      } }
  # Bare-string form — no metadata
  bob-cli: "k-bob-456"
```

### YAML — Policy (`secretRef` or `secretSelector`)

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: api-key-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  traffic:
    apiKeyAuthentication:
      mode: Strict             # Strict | Optional
      # Either secretRef (one Secret) OR secretSelector (label-matched Secrets):
      secretSelector:
        matchLabels:
          purpose: api-key
      # secretRef:
      #   name: api-keys
      # Default location is "Authorization: Bearer <key>". To read x-api-key instead:
      location:
        header:
          name: x-api-key
    # Optional: authorize on per-key metadata
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - 'apiKey.tier == "paid"'
```

> **Docs:** [API Key Auth](https://docs.solo.io/agentgateway/latest/security/extauth/apikey/)
> **API:** [APIKeyAuthentication (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#apikeyauthentication) · [APIKeyAuthentication (Enterprise)](https://docs.solo.io/agentgateway/latest/reference/api/solo/#apikeyauthentication)

```mermaid
sequenceDiagram
    actor Client
    participant GW as Agent Gateway
    participant Backend
    Client->>GW: Request + Authorization: Bearer <key> (or x-api-key via location.header)
    GW->>GW: Look up key in labeled K8s Secret(s); metadata -> apiKey.* for CEL
    alt key valid
        GW->>Backend: Forward (key stripped; identity via CEL/transformation)
        Backend-->>GW: Response
        GW-->>Client: Response
    else key invalid
        GW-->>Client: 401 Unauthorized
    end
```


---

## Basic Auth (RFC 7617) `[OSS]`

> **When to use:** Internal tools and low-stakes APIs where you already have htpasswd-style credentials. Not recommended for production end-user traffic — credentials travel on every request and can't be revoked individually without a re-deploy. No path to MFA.

Clients send `Authorization: Basic <base64(user:pass)>`. The gateway validates against hashed credentials generated by `htpasswd` (APR1/MD5, bcrypt, crypt, and SHA-1 are supported). Storage is mutually exclusive: a `users` list of htpasswd lines **or** a `secretRef` to a Kubernetes Secret holding an htpasswd file.

**Modes:** `Strict` (require credentials) or `Optional` (validate if present).

> **Tested (v2026.9.3):** inline `users` with both `$apr1$` and `$2y$` (bcrypt) hashes work; failed auth returns `401` with `WWW-Authenticate: Basic realm="agentgateway"`. For `secretRef`, the gateway reads the Secret key **`.htaccess`** by default — a Secret with a key named `htpasswd` fails with `invalid credentials` unless you also set `secretRef.key: htpasswd`. The username is not forwarded to the backend.

### YAML — inline `users` list

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: basic-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  traffic:
    basicAuthentication:
      mode: Strict        # Strict | Optional
      realm: agentgateway
      # Each entry is one htpasswd line.
      # Generate with: htpasswd -nbm alice 'p4ssword'
      users:
        - "alice:$apr1$dCv...redacted..."
        - "bob:$apr1$Hke...redacted..."
```

### YAML — `secretRef` to an htpasswd file

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: basic-auth-htpasswd
  namespace: agentgateway-system
type: Opaque
stringData:
  # Default key the gateway reads is ".htaccess"; use secretRef.key to override.
  .htaccess: |
    alice:$apr1$dCv...redacted...
    bob:$2y$05$Hke...redacted...
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: basic-auth
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  traffic:
    basicAuthentication:
      mode: Strict
      realm: agentgateway
      secretRef:
        name: basic-auth-htpasswd
        # key: htpasswd     # only if your Secret uses a key other than .htaccess
```

> **Docs:** [Basic Auth](https://docs.solo.io/agentgateway/latest/security/extauth/basic/)
> **API:** [BasicAuthentication (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#basicauthentication) · [BasicAuthentication (Enterprise)](https://docs.solo.io/agentgateway/latest/reference/api/solo/#basicauthentication)

```mermaid
sequenceDiagram
    actor Client
    participant GW as Agent Gateway
    participant Backend
    Client->>GW: Request + Authorization: Basic base64(user:pass)
    GW->>GW: Decode + verify against APR1-hashed credentials
    alt credentials valid
        GW->>Backend: Forward request
        Backend-->>GW: Response
        GW-->>Client: Response
    else credentials invalid
        GW-->>Client: 401 + WWW-Authenticate: Basic realm
    end
```


---

## BYO External Auth (gRPC ext_authz) `[OSS]`

> **When to use:** You already have an authentication service (legacy IAM, MFA gateway, fraud-detection) and want the gateway to delegate decisions instead of duplicating logic. Also fits scenarios needing custom auth logic the built-in patterns don't cover.

Delegate auth to your own service via the Envoy `ext_authz` protocol (gRPC or HTTP). The gateway sends a `CheckRequest` for each request; your service returns allow/deny plus optional headers to inject. Maximum flexibility, at the cost of one network hop per request.

> The OSS `extAuth` field calls your service directly. The Enterprise `entExtAuth` field uses an `AuthConfig` reference, which is what enables OAuth/OIDC, JWT-with-introspection, OPA, and other Solo Enterprise extauth modes.

### YAML — OSS (HTTP ext_authz)

The gateway calls a service over HTTP and copies selected headers from the auth response into the upstream request:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: ext-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  traffic:
    extAuth:
      backendRef:
        kind: Service
        name: my-auth-service
        port: 80
      failureMode: FailClosed   # FailClosed | FailOpen
      http:
        # `path` is a CEL *expression*, so a fixed path needs quotes inside the string.
        # A bare "/check" is an invalid expression and fails closed with 403.
        path: '"/check"'
        # Defaults to [Authorization] when unset. Setting it REPLACES the default,
        # so list Authorization again if your auth service needs it.
        allowedRequestHeaders:
          - Authorization
          - x-ext-token
        allowedResponseHeaders:
          - Authorization       # headers copied from the auth response into the request
          - x-ext-user
```

### YAML — OSS (gRPC ext_authz)

```yaml
spec:
  traffic:
    extAuth:
      backendRef:
        kind: Service           # Service must advertise appProtocol: kubernetes.io/h2c
        name: my-grpc-auth-service
        port: 9001
      failureMode: FailClosed
      grpc:
        contextExtensions:      # static context fields sent in CheckRequest (not `context`)
          environment: prod
```

> **Tested (v2026.9.3):** both modes work. Gotchas that bit the original YAML: `http.path` is CEL (`'"/check"'`), `allowedRequestHeaders` overrides the default `Authorization` passthrough, and the gRPC field is `contextExtensions` (`grpc.context` is rejected as an unknown field). Headers returned by the auth service (for example `Authorization: Bearer <minted>` or `x-ext-user`) show up on the backend request when listed in `allowedResponseHeaders`.

> **Docs:** [BYO Ext Auth Service](https://docs.solo.io/agentgateway/latest/security/extauth/byo-ext-auth-service/)
> **API:** [ExtAuth (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#extauth) · [EnterpriseAgentgatewayExtAuth](https://docs.solo.io/agentgateway/latest/reference/api/solo/#enterpriseagentgatewayextauth)

```mermaid
sequenceDiagram
    actor Client
    participant GW as Agent Gateway
    participant ExtAuth as Your Auth Service
    participant Backend
    Client->>GW: Request
    GW->>ExtAuth: CheckRequest (gRPC ext_authz or HTTP)
    alt ExtAuth allows
        ExtAuth-->>GW: ALLOW + headers to inject
        GW->>Backend: Forward request (+ injected headers)
        Backend-->>GW: Response
        GW-->>Client: Response
    else ExtAuth denies
        ExtAuth-->>GW: DENY
        GW-->>Client: 403
    end
```


---

## Standard OIDC / JWT Authentication `[OSS]`

> **When to use:** End-user APIs where users authenticate at an existing IdP (Okta, Auth0, Keycloak, Entra ID) and present a JWT bearer token. Default modern choice for human-driven traffic.

The client obtains a JWT from an external OIDC provider (e.g., via Authorization Code Flow) and presents it as a bearer token. The gateway validates the JWT signature against the provider's JWKS endpoint, plus issuer and audience claims. The gateway does **not** participate in the OIDC redirect flow itself — it only validates tokens.

**Three ways to handle the OIDC redirect**, mapped to the three patterns in this guide:

| Who runs the OIDC redirect | Tier | Pattern |
|---|---|---|
| The CLIENT (browser app, CLI with PKCE, MCP client) | OSS | **This pattern** — gateway just validates the JWT the client brings |
| YOUR ext-auth service (custom or off-the-shelf) | OSS | [BYO External Auth](#byo-external-auth-grpc-ext_authz-oss) — gateway delegates via `extAuth` |
| The Enterprise ext-auth service (built-in OIDC + token exchange) | Enterprise | [Gateway-Mediated OIDC + Token Exchange](#gateway-mediated-oidc--token-exchange-enterprise) |

**Modes:** `Strict` (require valid JWT), `Optional` (validate if present), `Permissive` (never reject).

> **Tested (v2026.9.3):** both YAMLs below work as written against Keycloak (remote JWKS via `backendRef` + `jwksPath`, and `jwks.remote.url` as a shortcut) and a locally minted inline JWKS; multi-provider, `audiences`, `exp`, and CEL `authorization` on `jwt.*` all enforce as expected. Two things to know: the validated JWT is **stripped** from the request by default (set `preserveToken: true` or use [Passthrough](#passthrough-token-oss) to forward it), and `jwtAuthentication.mcp` is now where MCP OAuth metadata handling lives (see [MCP OAuth + DCR](#mcp-oauth-with-dynamic-client-registration-oss)).

### YAML — OSS (remote JWKS, Keycloak)

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: jwt-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: my-route
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "https://keycloak.example.com/realms/agents"
          audiences: ["my-ai-application"]
          jwks:
            remote:
              jwksPath: "/realms/agents/protocol/openid-connect/certs"
              cacheDuration: "5m"
              backendRef:
                kind: Service
                name: keycloak
                namespace: keycloak
                port: 8080
```

### YAML — OSS (inline JWKS, multi-provider)

Pulled from a live cluster — useful for tests and air-gapped setups:

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: jwt-test
  namespace: jwt-test
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: echo
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: test-issuer
          audiences: [test]
          jwks:
            inline: |
              {"keys":[{"kty":"RSA","use":"sig","alg":"RS256","kid":"test-key-1","n":"...","e":"AQAB"}]}
        - issuer: "https://login.microsoftonline.com/<tenant-id>/v2.0"
          audiences: ["api://<client-id>"]
          jwks:
            remote:
              jwksPath: "/common/discovery/v2.0/keys"
              backendRef:
                kind: Service
                name: entra-id-proxy
                namespace: auth-system
                port: 443
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - jwt.sub == "agent-service"     # CEL on validated claims
```

> **Docs:** [Set up JWT Auth](https://docs.solo.io/agentgateway/latest/security/jwt/setup/) · [JWT Auth for MCP Services](https://docs.solo.io/agentgateway/latest/mcp/mcp-access/) · [Keycloak as IdP](https://docs.solo.io/agentgateway/latest/security/extauth/oauth/keycloak/)
> **API:** [JWTAuthentication (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#jwtauthentication) · [JWTAuthentication (Enterprise)](https://docs.solo.io/agentgateway/latest/reference/api/solo/#jwtauthentication)

```mermaid
sequenceDiagram
    actor Client
    participant IdP as OIDC Provider
    participant GW as Agent Gateway
    participant Backend
    Client->>IdP: Login (Authorization Code Flow, out-of-band)
    IdP-->>Client: JWT (access_token / id_token)
    Client->>GW: Request + Authorization: Bearer <JWT>
    GW->>IdP: Fetch JWKS (cached per cacheDuration)
    GW->>GW: Validate signature, iss, aud, exp
    alt valid
        GW->>Backend: Forward request
        Backend-->>GW: Response
        GW-->>Client: Response
    else invalid
        GW-->>Client: 401 (no bearer / bad signature)
    end
```


---

## FrontendTLS (mTLS) + BackendTLS `[OSS]`

> **When to use:** Service-to-service traffic in a zero-trust network, or when you want a credential bound to a workload identity (cert) rather than a user. Combine `FrontendTLS` + `BackendTLS` for end-to-end encryption.

Two independent TLS features that often get bundled in conversation but configure separately:

- **FrontendTLS (inbound mTLS):** clients present an X.509 cert at the TLS handshake; the gateway validates it against `caCertificateRefs`. Modes: `AllowValidOnly` (reject invalid/missing certs) or `AllowInsecureFallback` (accept connections without a client cert). This is the *mutual* half. With Gateway API v1.5 this lives under **`spec.tls.frontend`** on the Gateway (`default` for all TLS listeners, or `perPort`), not under the listener.
- **BackendTLS (outbound TLS origination):** the gateway opens a TLS connection to the backend and verifies the backend's server cert. By default this is **one-way TLS** — the gateway presents its own client cert only if you set `mtlsCertificateRef`. Configured either as a standalone Gateway-API `BackendTLSPolicy` or inline via `backend.tls` on a policy.

> **Tested (v2026.9.3, Gateway API v1.5.0):** `listeners[].tls.frontendValidation` (the old shape) is rejected by the API server. `spec.tls.frontend.default.validation` works: no client cert and untrusted-CA client cert fail the handshake in `AllowValidOnly`, a CA-signed client cert gets `200`, and `AllowInsecureFallback` lets both through. The client cert identity is not forwarded as a header by default. For BackendTLS, inline `backend.tls.caCertificateRefs` verifies the backend cert (a wrong CA fails with `503 invalid peer certificate: UnknownIssuer`), `insecureSkipVerify: All` bypasses it, omitting `caCertificateRefs` uses system roots (`policies.tls: {}` on an `AgentgatewayBackend` reaches `httpbin.org:443` fine), and the standard `BackendTLSPolicy` also works.

### YAML — Inbound mTLS (Gateway resource)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: agentgateway        # enterprise-agentgateway on Solo Enterprise
  tls:
    frontend:
      default:                          # applies to every TLS listener (or use perPort[])
        validation:
          mode: AllowValidOnly          # AllowValidOnly | AllowInsecureFallback
          caCertificateRefs:            # CA used to validate client certs
            - group: ""
              kind: ConfigMap
              name: client-ca           # ConfigMap key: ca.crt
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: server-tls
```

### YAML — Outbound BackendTLS (standalone policy)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: BackendTLSPolicy
metadata:
  name: my-backend-tls
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: secured-upstream
  validation:
    hostname: api.upstream.example.com
    caCertificateRefs:
      - kind: ConfigMap
        name: upstream-ca
        group: ""
```

### YAML — Outbound BackendTLS (inline on AgentgatewayPolicy)

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: backend-tls-inline
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: secured-upstream
  backend:
    tls:
      # Omit caCertificateRefs to trust the system roots (public CAs).
      caCertificateRefs:
        - kind: ConfigMap                 # or Secret; bundle read from key ca.crt
          name: upstream-ca
      sni: api.upstream.example.com       # defaults to the destination hostname
      # verifySubjectAltNames: [api.upstream.example.com]   # defaults to the destination hostname
      # insecureSkipVerify: All | Hostname  (omit for full verification)
      # mtlsCertificateRef: [{name: gateway-client-cert}]   # present a client cert (mutual TLS to the backend)
```

> There is no `hostname` or `wellKnownCACertificates` field on `backend.tls`; use `sni` / `verifySubjectAltNames`, and simply omit `caCertificateRefs` for system roots.

> **Docs:** [Set up mTLS (FrontendTLS)](https://docs.solo.io/agentgateway/latest/setup/listeners/mtls/) · [BackendTLS](https://docs.solo.io/agentgateway/latest/security/backendtls/)
> **API:** [FrontendTLS (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#frontendtls) · [BackendTLS (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#backendtls) · [BackendTLS (Enterprise)](https://docs.solo.io/agentgateway/latest/reference/api/solo/#backendtls)

```mermaid
sequenceDiagram
    actor Client
    participant GW as Agent Gateway (TLS terminator)
    participant Backend
    Client->>GW: TLS ClientHello + client cert
    GW->>GW: FrontendTLS — validate client cert against CA
    alt cert valid
        GW->>Backend: BackendTLS — open new TLS conn, verify backend cert
        Backend-->>GW: Response (over TLS)
        GW-->>Client: Response (over TLS)
    else cert missing or invalid
        GW--xClient: TLS handshake failure
    end
```


---

## MCP OAuth with Dynamic Client Registration `[OSS]`

> **When to use:** You're exposing MCP servers and your clients (Claude Code, VS Code extensions, in-house agents) need to onboard automatically without an admin pre-registering OAuth credentials.

The gateway exposes the MCP server's OAuth metadata at `.well-known/oauth-protected-resource/<path>` and `.well-known/oauth-authorization-server/<path>`, validates inbound bearer tokens, and brokers Dynamic Client Registration (RFC 7591) at the configured IdP. **Built-in adapters** (`provider` enum on Kubernetes): `Keycloak`, `Auth0`, `Okta` (added in [PR #1831](https://github.com/agentgateway/agentgateway/pull/1831) — same shape as Auth0: audience injection + JWKS at `.well-known/jwks.json` + CORS-proxied DCR endpoint), `Entra`, `Descope`, `Authentik`; omit `provider` for spec-compliant IdPs. For IdPs with no DCR at all (Entra, Authentik), set `clientId` and the gateway answers `/register` with that pre-registered client. See the Auth0 / Okta caveat below for what these adapters do (and don't) solve.

> **API change:** on Kubernetes the MCP auth config moved from `backend.mcpAuthentication` (no longer a valid field) to route-level **`traffic.jwtAuthentication.mcp`**, with `backend.mcp.authentication` kept as a deprecated alternative. `provider` is a plain string (`Keycloak`), not an object. The standalone binary config still uses `mcpAuthentication` with `provider: { keycloak: {} }`.

> **Tested (v2026.9.3):** with Keycloak in-cluster, an MCP `initialize` without a token returns `401` with `WWW-Authenticate: Bearer resource_metadata=...`; the protected-resource and authorization-server documents are served by the gateway (Keycloak's non-standard endpoints rewritten, `registration_endpoint` pointed at the gateway's `/.well-known/oauth-authorization-server/<path>/client-registration` proxy); an anonymous DCR `POST` returns a fresh `client_id`; the authorization-code + PKCE login with that client yields a token the gateway accepts at `/mcp`. Both the route-level and the deprecated backend-level shape behaved identically. With `provider: Auth0`, the metadata correctly injects `?audience=` on the authorize URL and a client-credentials JWT is accepted — but DCR against the tenant returned `dynamic client registration is disabled` until enabled in Auth0, which is exactly the gap the Enterprise pattern below closes.

### Background: Dynamic Client Registration and MCP

OAuth normally assumes a human admin pre-registers each client application in the IdP and ships its `client_id`/`client_secret` to the client. That model breaks for MCP: every developer's Claude Code, Cursor, VS Code, or in-house agent installation is a separate "client" — there is no admin in the loop to register each one.

**[Dynamic Client Registration (RFC 7591)](https://datatracker.ietf.org/doc/html/rfc7591)** lets clients self-register at runtime: the client `POST`s its metadata to `registration_endpoint`, the IdP responds with a fresh `client_id` (and optionally `client_secret`), and the client uses those for the rest of the OAuth flow. The MCP authorization spec requires a `registration_endpoint` in the authorization-server metadata for exactly this reason.

**Where real DCR works.** Keycloak and other spec-compliant IdPs that expose an unauthenticated registration endpoint. See the YAML below.

**Where the OSS adapters help.** Auth0 and Okta now have first-class OSS adapters (`provider: { auth0: {} }` and `provider: { okta: {} }`). They handle the protocol-level integration smoothly — audience injection on the authorize endpoint, CORS-proxied DCR endpoint, JWKS at `.well-known/jwks.json`, OIDC discovery URL for metadata (Okta doesn't support RFC 8414 path-based issuer format).

**Where they DON'T help.** Auth0 and Okta still gate DCR behind their **management APIs / Initial Access Tokens** — admin-token-gated, rate-limited, and creating a fresh app in the IdP dashboard per call. The OSS adapters make the protocol bits work; they don't change the underlying Auth0/Okta DCR economics. Fine for test deployments and small fleets; untenable for a developer fleet running Claude Code + Cursor + VS Code + in-house agents.

**Enterprise honesty.** As Christian Posta argues in [Understanding MCP Authorization With Dynamic Client Registration](https://blog.christianposta.com/understanding-mcp-authorization-with-dynamic-client-registration/), the MCP spec assumes *anonymous* client registration, which "opens up challenges around monitoring, auditing, and revocation." Enterprise security teams typically reject anonymous trust. So while DCR is the right answer for hobbyist Keycloak setups and the open ecosystem, enterprises usually need the [Gateway-Brokered DCR](#mcp-oauth--gateway-brokered-dcr-for-auth0--okta-enterprise) variant where the gateway substitutes one pre-vetted IdP application that every MCP client uses.

**Real-world gotchas (per Posta):**

- **Keycloak CORS:** Keycloak doesn't enable CORS by default on its metadata endpoints, so MCP Inspector and other browser clients can't fetch them directly — a reverse proxy is required.
- **Scope overreach:** Some MCP clients (notably `mcp-inspector` historically) pass *all* server scopes to the registration endpoint, violating least-privilege. Verify your client doesn't do this.

**Gateway-brokered DCR.** The gateway stands in as the registration endpoint the IdP doesn't offer: `registration_endpoint` in the authorization-server metadata resolves to the gateway, and `/oauth-issuer/register` returns a single **pre-registered** IdP `client_id`/`client_secret` that every MCP client receives. Per-client revocation goes away — there's one IdP application backing the whole fleet — but **per-user identity is preserved**: each user still completes the IdP's authorization-code flow themselves, and the IdP-issued JWT is what the MCP backend validates. See [MCP OAuth — Gateway-Brokered DCR for Auth0 / Okta](#mcp-oauth--gateway-brokered-dcr-for-auth0--okta-enterprise).

> **OSS vs. Enterprise:** The MCP authentication broker is in OSS (validated against the OSS proto and `examples/mcp-authentication/config.yaml`). DCR support comes from the IdP — agentgateway just brokers the OAuth metadata and validates JWTs. The Solo Enterprise UI is **not required**, but if you also want a managed admin UI for MCP server registration and a single per-cluster OAuth experience, that is part of Solo Enterprise.

> **Auth0 / Okta caveat:** The OSS `provider: { auth0: {} }` and `provider: { okta: {} }` adapters handle the protocol mismatch — audience injection, CORS-proxied registration endpoint, JWKS path, OIDC-discovery-style metadata. They do **not** change the fact that Auth0's and Okta's DCR endpoints are gated behind their Management APIs / Initial Access Tokens, rate-limited, and create a new application per MCP client. So the adapters work fine for test/lab deployments and small fleets, but not for production developer fleets running Claude Code + Cursor + VS Code. For those, use [MCP OAuth — Gateway-Brokered DCR for Auth0 / Okta](#mcp-oauth--gateway-brokered-dcr-for-auth0--okta-enterprise) — the gateway hosts its own OAuth AS and substitutes pre-registered credentials at `/oauth-issuer/register`.

### YAML — OSS (Keycloak with metadata adapter)

```yaml
# The HTTPRoute must match /mcp AND the two .well-known/oauth-*/mcp paths.
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mcp-oauth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: mcp-server
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "http://keycloak.example.com/realms/mcp"
          audiences: ["mcp_proxy"]      # add an audience mapper in Keycloak
          jwks:
            remote:
              url: "http://keycloak.example.com/realms/mcp/protocol/openid-connect/certs"
      mcp:                              # turns on MCP OAuth metadata + DCR proxying
        provider: Keycloak              # Keycloak | Auth0 | Okta | Entra | Descope | Authentik
        # clientId: <pre-registered>    # for IdPs without DCR (Entra, Authentik)
        resourceMetadata:
          resource: "https://gateway.example.com/mcp"
          scopesSupported: [openid, profile, offline_access]
          bearerMethodsSupported: [header]
```

<details>
<summary>Deprecated backend-level shape (still accepted)</summary>

```yaml
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-server
  backend:
    mcp:
      authentication:
        mode: Strict
        issuer: "http://keycloak.example.com/realms/mcp"
        audiences: ["mcp_proxy"]
        jwks: { url: "http://keycloak.example.com/realms/mcp/protocol/openid-connect/certs" }
        provider: Keycloak
        resourceMetadata:
          resource: "https://gateway.example.com/mcp"
```

</details>

### YAML — Standalone OSS binary (JSON-config style)

```yaml
# yaml-language-server: $schema=https://agentgateway.dev/schema/config
binds:
  - port: 3000
    listeners:
      - routes:
          - matches:
              - path: { exact: /mcp }
              - path: { exact: /.well-known/oauth-protected-resource/mcp }
              - path: { exact: /.well-known/oauth-authorization-server/mcp }
            policies:
              mcpAuthentication:
                mode: strict
                issuer: http://keycloak:7080/realms/mcp
                audiences: [mcp_proxy]
                jwks: { url: http://keycloak:7080/realms/mcp/protocol/openid-connect/certs }
                provider: { keycloak: {} }
                resourceMetadata:
                  resource: http://localhost:3000/mcp
                  scopesSupported: [openid, profile, offline_access]
            backends:
              - mcp:
                  targets:
                    - name: tools
                      stdio:
                        cmd: npx
                        args: ["@modelcontextprotocol/server-everything"]
```

> **Docs:** [About MCP Auth](https://docs.solo.io/agentgateway/latest/mcp/auth/about/) · [Set up Keycloak for MCP Auth](https://docs.solo.io/agentgateway/latest/mcp/auth/keycloak/)

```mermaid
sequenceDiagram
    participant MCP as MCP Client (Claude Code, VS Code)
    participant GW as Agent Gateway
    participant IdP as OIDC Provider (Keycloak / spec-compliant)
    MCP->>GW: GET /.well-known/oauth-protected-resource/<path>
    GW-->>MCP: Resource metadata
    MCP->>GW: GET /.well-known/oauth-authorization-server/<path>
    GW-->>MCP: Auth-server metadata (adapted for non-spec providers)
    MCP->>IdP: POST /register (RFC 7591 Dynamic Client Registration)
    IdP-->>MCP: client_id + client_secret (unique per MCP client)
    MCP->>IdP: Authorization Code Flow (PKCE)
    IdP-->>MCP: Bearer token
    MCP->>GW: Call MCP endpoint with Bearer token
    GW->>GW: Validate JWT (issuer, audience, JWKS)
    GW-->>MCP: MCP response
```


---

## MCP OAuth — Gateway-Brokered DCR for Auth0 / Okta `[Enterprise]`

> **When to use:** You're exposing MCP servers and your IdP is **Auth0, Okta, Microsoft Entra, or another IdP that gates DCR behind a management API**. Real DCR doesn't scale to a fleet of MCP clients (Claude Code, Cursor, VS Code, in-house agents) on these IdPs. For Keycloak and other open-DCR IdPs, use [MCP OAuth + DCR](#mcp-oauth-with-dynamic-client-registration-oss) instead.

Christian Posta sets the bar for this pattern in [Enterprise MCP SSO With Microsoft Entra and Agentgateway](https://blog.christianposta.com/enterprise-mcp-sso-with-microsoft-entra-and-agentgateway/): *"Any internal enterprise MCP client / AI agent that communicates to a [remote] MCP server should be secured with enterprise SSO."* The catch is that MCP clients — VS Code, Cursor, Claude — aren't browser applications, and the official MCP OAuth spec assumes browser-based interaction. This pattern bridges the gap.

The gateway hosts its own OAuth Authorization Server at `/oauth-issuer/`. From an MCP client's perspective there is exactly one OAuth issuer: the gateway. `/oauth-issuer/register` returns a **single pre-registered** IdP `client_id`/`client_secret` to every MCP client — no IdP-dashboard churn, no Management-API DCR. The gateway then brokers the authorization code flow to the IdP, and the IdP-issued JWT is validated at the MCP backend.

**One-time setup** (per Posta's Entra walkthrough — adapt to your IdP):

1. Create an IdP application (Entra App Registration, Auth0 Application, Okta App) representing the agentgateway.
2. Expose an API scope (e.g., `mcp_access`).
3. Pre-consent known clients. VS Code's baked-in MCP client ID is `aebc6443-996d-45c2-90f0-388ff96faa56` — useful for pre-consenting.
4. Configure custom clients via additional IdP applications with proper redirect URIs.

> **Eager vs lazy:** "Eager" here means the OAuth flow runs **at MCP connect time** — when the client first establishes the MCP session — not lazily on each tool call. Once the session is up, every tool call inside it reuses the same JWT. Contrast with the lazy patterns [Double OAuth Flow](#double-oauth-flow-oidc--elicitation-enterprise) and [Elicitation](#elicitation-enterprise), where the user is prompted on demand. See [Background: DCR and MCP](#background-dynamic-client-registration-and-mcp) for what DCR is and why gateway-brokered DCR exists.

> **Related:** If you also need **per-upstream-provider tokens** (each MCP backend gets its own GitHub / GitLab / Atlassian token), see [Eager Upstream OAuth](#eager-upstream-oauth-gateway-as-oauth-issuer-enterprise) — same `/oauth-issuer/` machinery, plus per-backend token exchange.

### Configuration overview

This pattern shares its controller-side configuration with [Eager Upstream OAuth's Helm values](#yaml--helm-values-the-gateway-as-oauth-issuer): the `tokenExchange.enabled` block, the `KGW_OAUTH_ISSUER_CONFIG` env var, and the `oauth-issuer` HTTPRoute. **Skip the per-upstream `entElicitation.brokered.chainedAuth`** — nothing is exchanged, the IdP JWT is what the MCP backend validates. In the Solo docs this is called [**downstream-only brokered login**](https://docs.solo.io/agentgateway/latest/mcp/token-exchange/auth-only/overview/). The single pre-registered IdP credentials live in `downstream_server` (and optionally `client_config.clients`) and are returned to every MCP client at `/oauth-issuer/register`.

> **Tested (v2026.9.3) with Keycloak as the IdP:** `/.well-known/oauth-authorization-server/<path>` for the MCP resource came back with `authorization_endpoint`, `token_endpoint`, and `registration_endpoint` all pointing at the gateway's `/oauth-issuer/*`; `POST /oauth-issuer/register` returned the pre-registered `client_id` without touching the IdP; a DCR request with a redirect URI outside `incoming_clients.allowed_redirect_uris` was rejected with `invalid_redirect_uri`; the authorization-code + PKCE flow redirected to Keycloak, came back through `/oauth-issuer/callback/downstream`, and the token the issuer handed the client was the **IdP-issued JWT** (`iss` = Keycloak, `azp` = the shared client), which the MCP backend accepted. Two things to get right: `audiences` on the policy must match what the IdP actually mints for the shared client (Keycloak needs an audience mapper; Auth0 needs the tenant default audience), and the policy must be `backend.mcp.authentication` on the backend — the issuer proxy does not index route-level `traffic.jwtAuthentication.mcp` yet ([agentgateway-enterprise#8250](https://github.com/solo-io/agentgateway-enterprise/issues/8250)).

Minimal controller config (Helm values; replace the Entra block in the Eager section with your IdP):

```yaml
tokenExchange:
  enabled: true
  issuer: enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777
  subjectValidators:                    # plural list (singular `subjectValidator` is deprecated)
    - validatorType: remote
      issuer: https://idp.example.com/realms/mcp
      remoteConfig:
        url: https://idp.example.com/realms/mcp/protocol/openid-connect/certs
  actorValidators: [{validatorType: k8s}]
  apiValidators:   [{validatorType: k8s}]
controller:
  extraEnv:
    KGW_OAUTH_ISSUER_CONFIG: |
      {
        "downstream_server": {
          "name": "idp",
          "client_id": "<shared-client-id>",
          "client_secret": "<shared-client-secret>",
          "authorize_url": "https://idp.example.com/realms/mcp/protocol/openid-connect/auth",
          "token_url":     "https://idp.example.com/realms/mcp/protocol/openid-connect/token",
          "redirect_uri":  "https://gateway.example.com/oauth-issuer/callback/downstream",
          "scopes": ["openid", "profile"]
        },
        "gateway_config": { "base_url": "https://gateway.example.com/oauth-issuer" },
        "incoming_clients": {
          "allowed_redirect_uris": [
            "http://localhost:6274/oauth/callback",
            "http://localhost:6274/oauth/callback/debug"
          ]
        }
      }
```

> **Set `incoming_clients.allowed_redirect_uris`.** Without it the issuer accepts the shared client ID with *any* `redirect_uri`, so an authorization code could be sent to a destination you don't own. The controller logs a warning at startup when it is unset. Loopback `http://localhost` entries match regardless of port; MCP Inspector registers both `/oauth/callback` and `/oauth/callback/debug`, so list both.

The `/oauth-issuer` route can target the controller Service directly (same namespace) or an `AgentgatewayBackend` with `static: {host: enterprise-agentgateway.agentgateway-system.svc.cluster.local, port: 7777}` from any namespace.

### Flow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant MCP as MCP Client
    participant GW as Agent Gateway<br/>+ /oauth-issuer
    participant IdP as IdP<br/>(Auth0 / Okta)
    participant Tool as MCP Server

    MCP->>GW: GET /.well-known/oauth-authorization-server/mcp
    GW-->>MCP: AS metadata — registration_endpoint, authorize_url, token_url<br/>all point at gateway's /oauth-issuer/*
    MCP->>GW: POST /oauth-issuer/register (RFC 7591 DCR)
    Note over GW: Gateway-Brokered DCR — returns pre-registered client_id from<br/>KGW_OAUTH_ISSUER_CONFIG.client_config.clients<br/>(no call to IdP)
    GW-->>MCP: client_id (+ client_secret)
    MCP->>GW: GET /oauth-issuer/authorize (PKCE)
    GW-->>MCP: 302 to IdP /authorize<br/>(using downstream_server.client_id/secret)
    User->>IdP: SSO login
    IdP-->>GW: Callback /oauth-issuer/callback/... (code)
    GW->>IdP: POST /token (code -> JWT)
    IdP-->>GW: IdP-issued JWT
    GW-->>MCP: Gateway auth code -> IdP JWT
    MCP->>GW: Call /mcp with Bearer (IdP JWT)
    GW->>GW: Validate JWT (issuer, audience, IdP JWKS)
    GW->>Tool: Forward request with IdP JWT
    Tool-->>GW: Response
    GW-->>MCP: Response
```

The DCR substitution at step 4 is the whole point of the pattern: `registration_endpoint` resolves to the gateway, not the IdP, so MCP clients never hit the IdP's rate-limited Management-API DCR.

### MCP authentication policy

The standard JWT-validation shape with one critical annotation that flips the AS metadata to point at the gateway:

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: mcp-auth-eager
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: mcp-backend
  backend:
    mcp:
      authentication:
        mode: Strict
        issuer: https://your-tenant.auth0.com/        # trailing slash matters for Auth0
        audiences: [https://your-api/]
        jwks:
          backendRef:
            name: idp-jwks
            kind: AgentgatewayBackend
            group: agentgateway.dev
          jwksPath: .well-known/jwks.json             # no leading slash — controller appends one
        resourceMetadata:
          # Critical: tells the gateway to serve the eager-OAuth issuer's metadata at
          # .well-known/oauth-authorization-server/<path> so registration_endpoint points
          # at the gateway, not the IdP. Without this, MCP clients DCR against the IdP
          # directly and hit the rate-limit / Mgmt-API problem this pattern exists to solve.
          agentgateway.dev/issuer-proxy: http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth-issuer
          authorizationServers: [https://gateway.example.com/mcp]
          resource:             https://gateway.example.com/mcp
```

### Per-IdP gotchas (Auth0 vs Okta)

The pattern is identical for both IdPs; the per-IdP setup details differ in non-obvious ways. Both columns below are validated against runnable workshop labs.

| Concern | Auth0 | Okta |
|---|---|---|
| `issuer` value | `https://<tenant>.auth0.com/` — **trailing slash required**. Auth0 puts it in the `iss` claim and the policy compares literally. | `https://<domain>/oauth2/<authz-server-id>` (typically `default`) — **no trailing slash**. The org server (no `/oauth2/...`) shifts every path; use a custom authz server. |
| Audience handling | `KGW_OAUTH_ISSUER_CONFIG.downstream_server` has no `audience` field, so Auth0 won't mint API-scoped tokens unless you set the audience as the **tenant default** (Settings → API Authorization Settings → Default Audience), or drop `audiences` from the policy and validate issuer-only. | `aud` comes from the authz server's "Audience" setting (Security → API → Authorization Servers → *your-server* → Settings). No `?audience=` injection needed; just match the policy's `audiences` to whatever the server is issuing. |
| JWKS path (in `mcp.authentication.jwks.jwksPath`) | `.well-known/jwks.json` | `oauth2/<authz-server-id>/v1/keys` (custom authz server) — `oauth2/v1/keys` if you're using the org server (issuer = `https://<domain>`). No leading slash — the controller appends one. |
| Callback URL registration | Both `…/oauth-issuer/callback/downstream` AND `…/oauth-issuer/callback/upstream` must be in the Auth0 app's Allowed Callback URLs. Registering only one yields `invalid_request: callback url not allowed` after login. | Both required as Sign-in redirect URIs. Single-callback rejection: `The 'redirect_uri' parameter must be a Login redirect URI`. |

> **Walkthroughs (runnable end-to-end with MCP Inspector):**
> - **Auth0** — [Lab 003 (gist)](https://gist.github.com/rvennam/26c3ae46c2f9b2342613a304ec78ca13#file-003-oidc-authentication-md) · [`mcp-eager-auth-auth0.md` (workshop)](https://github.com/solo-io/fe-enterprise-agentgateway-workshop/blob/main/mcp-eager-auth-auth0.md)
> - **Okta** — [`mcp-eager-auth-okta.md` (workshop)](https://github.com/solo-io/fe-enterprise-agentgateway-workshop/blob/main/mcp-eager-auth-okta.md)
>
> Both labs cover HTTPS/cert setup, Postgres, the full Helm-values block, MCP Inspector flow, and a CLI check that `registration_endpoint` actually got rewritten to the gateway.

---

# Token Exchange

Patterns that take an inbound token and transform it before it reaches downstream services. **All require Solo Enterprise** for the STS (the built-in token service), the OAuth issuer, and the `tokenExchange` / `entTokenExchange` / `entElicitation` policy fields. The OSS data plane does ship a generic RFC 8693 / RFC 7523 *client* (`backend.auth.oauthTokenExchange`, with `subjectToken`, `actorToken` + `mayAct: Required`, `clientAuth`, and an in-memory token cache) that can call any standards-compliant STS — but you bring the STS. In testing, pointing it at the Solo STS worked for impersonation and failed for delegation because the Solo STS answers delegation requests with `token_type: N_A`, which the OSS client rejects.

---

## Gateway-Mediated OIDC + Token Exchange `[Enterprise]`

> **When to use:** You want agents to trust **only the gateway's STS issuer** — never the external IdP directly. Useful for decoupling agents from IdP changes and for centralizing claim shaping.

The gateway handles OIDC authentication itself (via `entExtAuth` + an `AuthConfig` of type `oauth2.oidcAuthorizationCode`), then automatically exchanges the IdP token (via RFC 8693) before forwarding to the agent. The agent only ever sees the STS-issued JWT.

> **Tested (v2026.9.3) — works with the shape below.** Three corrections to the original YAML: (1) the `AuthConfig` needs a **Redis-backed session** (`session.redis` pointing at the `ext-cache` Service the Enterprise chart deploys) — with the default cookie session only a `Secure access_token` cookie was set and the next request was redirected to login again; (2) the session cookie is `Secure`, so `appUrl` should be `https://` in practice; (3) the exchange is **not** `backend.tokenExchange: ExchangeOnly` (that field takes its subject from a JWT validated by `jwtAuthentication`, which an ext-auth login does not produce — it fails with `400 invalid request`). Instead, have ext-auth emit the IdP access token into a header (`headers.accessTokenHeader`) and exchange *that* header with `backend.auth.oauthTokenExchange` against the STS. After login, the backend received `Authorization: Bearer <STS JWT>` with `iss` = the STS, `aud` = the requested agent audience, the user's `sub`, and the IdP token itself was not forwarded. This is exactly how the ingress in [rvennam/agent-mesh-demo](https://github.com/rvennam/agent-mesh-demo) rescopes the user token before it reaches an agent.

### YAML — Enterprise (OIDC + Built-in STS)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: idp-client-secret
  namespace: agentgateway-system
type: extauth.solo.io/oauth
stringData:
  client-secret: <idp-client-secret>
---
apiVersion: extauth.solo.io/v1
kind: AuthConfig
metadata:
  name: corporate-sso
  namespace: agentgateway-system
spec:
  configs:
    - oauth2:
        oidcAuthorizationCode:
          appUrl: "https://gateway.example.com"
          callbackPath: /callback
          clientId: <gateway-client-id>
          clientSecretRef:
            name: idp-client-secret
            namespace: agentgateway-system
          issuerUrl: "https://login.microsoftonline.com/<tenant>/v2.0/"
          scopes: [openid, profile, email]
          headers:
            accessTokenHeader: x-user-access-token   # IdP access token -> header for the exchange below
            # idTokenHeader: jwt                     # optional: also forward the ID token
          session:
            failOnFetchFailure: true
            redis:                        # required in practice; cookie-only sessions did not persist
              cookieName: sso-session
              options:
                host: ext-cache-enterprise-agentgateway.agentgateway-system.svc.cluster.local:6379
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: oidc-login
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  traffic:
    entExtAuth:
      authConfigRef: { name: corporate-sso }
      backendRef:
        name: ext-auth-service-enterprise-agentgateway
        namespace: agentgateway-system
        port: 8083
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: agentgateway-sts
  namespace: agentgateway-system
spec:
  static:
    host: enterprise-agentgateway.agentgateway-system.svc.cluster.local
    port: 7777
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: rescope-user-token
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: agent-route
  backend:
    auth:
      oauthTokenExchange:           # Variant A: built-in STS reissues the token (sub preserved, scoped aud)
        backendRef:
          group: agentgateway.dev
          kind: AgentgatewayBackend
          name: agentgateway-sts
          port: 7777
        path: /oauth2/token
        grantType: TokenExchange
        subjectToken:
          source:
            header:
              name: x-user-access-token
          tokenType: Jwt
        audiences: [my-agent]       # scope the new token to the agent being called
        requestedTokenType: Jwt
        location:
          header:
            name: Authorization
            prefix: "Bearer "
```

> `oauthTokenExchange` has a small in-memory cache keyed on the subject token, so the STS is not called on every request. The resulting token has no `act` claim (the gateway has no actor token to present); delegation with `act` happens when the agent itself exchanges — see [OBO Delegation](#obo-delegation-dual-identity-enterprise).

### Variant A: Built-in STS

Uses agentgateway's built-in token exchange server. `mode: ExchangeOnly`. STS issues a JWT with `sub` (user) + `act` (agent).

```mermaid
sequenceDiagram
    actor User
    participant GW as Agent Gateway (Proxy)
    participant IdP as OIDC Provider
    participant STS as AGW Built-in STS
    participant Agent as Agent / MCP Server
    User->>GW: Request (no session cookie)
    GW-->>User: 302 to IdP /authorize
    User->>IdP: Login + submit credentials
    IdP-->>GW: Callback with code → POST /token → User JWT
    GW-->>User: Set session cookie
    GW->>STS: POST /token (subject_token=user JWT, actor_token=K8s SA)
    STS-->>GW: Exchanged JWT (sub=user, act=agent)
    GW->>Agent: Authorization: Bearer <exchanged JWT>
    Agent-->>GW: Response
    GW-->>User: Result
```


#### What the two tokens look like

**Input — User JWT** (issued by the IdP, received by the gateway after the OIDC dance):

```jsonc
// Header
{
  "alg": "RS256",
  "kid": "idp-key-2026-04",
  "typ": "JWT"
}
// Payload
{
  "iss": "https://login.example.com/realms/agents",
  "sub": "u-7f0a3c91",                       // the human user
  "aud": "agentgateway-browser",             // the gateway's IdP client_id
  "exp": 1777300000,
  "iat": 1777296400,
  "email": "alice@example.com",
  "name": "Alice Anderson",
  "scope": "openid profile email",
  "preferred_username": "alice"
}
```

**Output — Exchanged JWT** (issued by the AGW Built-in STS, forwarded to the agent):

```jsonc
// Header
{
  "alg": "RS256",
  "kid": "agw-sts-key-1",
  "typ": "JWT"
}
// Payload — RFC 8693 §4.1
{
  "iss": "https://agentgateway.example.com/sts",   // CHANGED: now the gateway's STS
  "sub": "u-7f0a3c91",                              // PRESERVED: same user
  "aud": "mcp-server.agents.svc",                   // CHANGED: now the agent/MCP server
  "exp": 1777296700,                                // SHORTER: typically minutes, not hours
  "iat": 1777296400,
  "scope": "mcp:invoke",                            // RESHAPED: only what the agent needs
  "act": {                                          // NEW: RFC 8693 actor claim
    "sub": "system:serviceaccount:agentgateway-system:agent-runtime",
    "iss": "https://kubernetes.default.svc"
  }
}
```

What changed and why:

| Field | User JWT | Exchanged JWT | Why |
|---|---|---|---|
| `iss` | IdP | AGW STS | Agent only trusts the STS issuer — IdP is invisible to it |
| `sub` | user id | user id | Preserved so downstream policy can authorize the user |
| `aud` | gateway client_id | agent / MCP server id | Token is now scoped to the resource it's actually calling |
| `exp` | hours | minutes | Exchange-only tokens are short-lived; gateway re-exchanges on demand |
| `scope` | full IdP scopes | minimum needed | Reshaped — agent doesn't need `email`, `profile` |
| `act` | (none) | `{sub: agent SA, iss: K8s}` | RFC 8693 actor claim — auditable agent-on-behalf-of-user |
| signature | IdP private key | AGW STS private key | Agent verifies against `<sts>/.well-known/jwks.json` |

> **OBO Impersonation** produces the same shape as the Exchanged JWT above but **omits the `act` claim** — downstream services see only the user.

### Variant B: External STS (Entra ID)

Uses Microsoft Entra ID as an external token-exchange provider via Entra's OBO flow (`urn:ietf:params:oauth:grant-type:jwt-bearer`).

```yaml
# Current (proxy-native) shape — exchange happens in the data plane, no STS round trip
spec:
  backend:
    entTokenExchange:
      entra:
        tenantId: <tenant-id>
        clientAuth:
          clientId: <gateway-app-client-id>
          clientSecretRef: { name: entra-client-secret, key: client_secret }
        scopes: ["https://graph.microsoft.com/.default"]
        backendRef:                       # AgentgatewayBackend static -> login.microsoftonline.com:443 (tls: {})
          group: agentgateway.dev
          kind: AgentgatewayBackend
          name: entra-login
          port: 443
```

<details>
<summary>Deprecated shape (still accepted; note <code>clientSecretRef.key</code> is required)</summary>

```yaml
spec:
  backend:
    tokenExchange:
      mode: ExchangeOnly
      entra:
        clientId: <gateway-app-client-id>
        clientSecretRef: { name: entra-client-secret, key: client_secret }
        tenantId: <tenant-id>
        scope: "https://graph.microsoft.com/.default"
```

</details>

> **Schema-validated only (no Entra tenant available):** `backend.tokenExchange.entra` without `clientSecretRef.key` is rejected by the CRD; the API marks `tokenExchange.entra` deprecated in favour of `entTokenExchange.entra`. Related Helm note from the docs: Entra never emits `may_act`, so set `skipMayActClaimValidation: true` if you also route Entra tokens through the built-in STS.

```mermaid
sequenceDiagram
    actor User
    participant GW as Agent Gateway (Proxy)
    participant Entra as Entra ID
    participant Agent as Agent / Target API
    User->>GW: Request (no session)
    GW-->>User: 302 to Entra /authorize
    User->>Entra: Login
    Entra-->>GW: Callback → User JWT (aud = gateway app)
    GW->>Entra: POST /token (grant=jwt-bearer, scope=Graph, requested_token_use=on_behalf_of)
    Entra-->>GW: Resource-scoped JWT (aud = Microsoft Graph, signed by Entra)
    GW->>Agent: Authorization: Bearer <Entra-issued token>
    Agent-->>GW: Response
    GW-->>User: Result
```


#### What the two tokens look like

> Unlike Variant A, the exchanged token here is **issued by Entra**, not by agentgateway. The agent validates against Entra's JWKS (`https://login.microsoftonline.com/<tenant>/discovery/v2.0/keys`).

**Input — User JWT** (issued by Entra ID, audience = the gateway's app registration):

```jsonc
// Header
{
  "alg": "RS256",
  "kid": "nOo3ZDrODXEK1jKWhXslHR_KXEg",
  "typ": "JWT"
}
// Payload — Entra v2.0 access token
{
  "iss": "https://login.microsoftonline.com/72f988bf-86f1-41af-91ab-2d7cd011db47/v2.0",
  "aud": "api://4ab8e9b1-...-gateway-app",   // the gateway's Entra app client_id
  "sub": "AAAAAA...user-pairwise-id",
  "oid": "5f6c2c8d-3e4d-4f8e-9b0a-1c2d3e4f5a6b", // stable Entra user object id
  "tid": "72f988bf-86f1-41af-91ab-2d7cd011db47", // tenant id
  "preferred_username": "alice@contoso.com",
  "name": "Alice Anderson",
  "scp": "User.Access",                         // Entra v2 uses `scp` not `scope`
  "ver": "2.0",
  "exp": 1777300000,
  "iat": 1777296400,
  "nbf": 1777296400
}
```

**OBO request the gateway makes to Entra** (server-to-server, no user redirect):

```http
POST https://login.microsoftonline.com/72f988bf-.../oauth2/v2.0/token
Content-Type: application/x-www-form-urlencoded

grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer
client_id=4ab8e9b1-...-gateway-app
client_secret=<from clientSecretRef>
assertion=<the User JWT above>
scope=https://graph.microsoft.com/User.Read
requested_token_use=on_behalf_of
```

**Output — Exchanged JWT** (issued by Entra, audience = the target resource):

```jsonc
// Header
{
  "alg": "RS256",
  "kid": "nOo3ZDrODXEK1jKWhXslHR_KXEg",     // still Entra's signing key
  "typ": "JWT"
}
// Payload — Entra-issued, scoped to Microsoft Graph
{
  "iss": "https://login.microsoftonline.com/72f988bf-.../v2.0",
  "aud": "https://graph.microsoft.com",      // CHANGED: target resource, not the gateway
  "sub": "AAAAAA...graph-pairwise-id",       // CHANGED: pairwise sub for the new audience
  "oid": "5f6c2c8d-3e4d-4f8e-9b0a-1c2d3e4f5a6b", // PRESERVED: stable user identity
  "tid": "72f988bf-86f1-41af-91ab-2d7cd011db47",
  "preferred_username": "alice@contoso.com",
  "name": "Alice Anderson",
  "scp": "User.Read",                         // CHANGED: only the scope requested in the OBO call
  "azp": "4ab8e9b1-...-gateway-app",          // NEW: the app that performed the OBO (the gateway)
  "azpacr": "1",                              // NEW: auth method used (1 = client_secret)
  "ver": "2.0",
  "exp": 1777300000,
  "iat": 1777296400,
  "nbf": 1777296400
}
```

What changed and why:

| Field | User JWT | Exchanged JWT | Why |
|---|---|---|---|
| `iss` | Entra (your tenant) | Entra (your tenant) | Same issuer in both — Entra mints both tokens |
| `aud` | gateway app id | target resource (e.g. Graph) | Token is now scoped to the resource being called |
| `sub` | pairwise for gateway | pairwise for target resource | Entra issues a new pairwise `sub` per audience |
| `oid` | user object id | user object id | Stable across audiences — use this for "who is this user" |
| `scp` | full IdP scopes | only OBO-requested scope | Entra honors the `scope=` parameter in the OBO call |
| `azp` | (none) | gateway app id | RFC 7519 "authorized party" — records which app did the OBO |
| `act` | (none) | (none) | **Entra OBO does not emit RFC 8693 `act` — it's a Microsoft-flavored exchange, not the standard one** |
| signature | Entra | Entra | Agent verifies against Entra JWKS, not AGW STS |

> **Operational consequence:** Variant B's agent must be configured to trust **Entra** as the JWT issuer. With Variant A the agent trusts the **AGW STS** and the IdP is invisible — that's the main reason teams choose Variant A even when they're already on Entra.

> **Docs:** [OBO Token Exchange](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/obo/) · [Set up JWT Auth](https://docs.solo.io/agentgateway/latest/security/jwt/setup/)
> **API / Helm:** [tokenExchange Helm values](https://docs.solo.io/agentgateway/latest/reference/helm/agentgateway/)

---

## OBO Delegation (Dual Identity) `[Enterprise]`

> **When to use:** You need an audit trail showing **both** who the user is **and** which agent acted on their behalf. Common in agentic systems where multiple agents touch a single user request and you need attribution at each hop.

The agent exchanges the user's JWT for a delegated OBO token via RFC 8693. The user's JWT must include a `may_act` claim authorizing the agent. The STS validates the user JWT **and** the agent's Kubernetes service-account token, then issues a new JWT (signed by agentgateway) containing both `sub` (user) and `act` (agent). Downstream services trust the agentgateway issuer and can enforce policies on either identity.

> **Why both identities matter.** Christian Posta makes the case in [Explaining OAuth Delegation, 'On Behalf Of', and Agent Identity for AI Agents](https://blog.christianposta.com/explaining-on-behalf-of-for-ai-agents/): *"OAuth-style flows already solve delegation. What OAuth never considered was autonomy and non-deterministic applications making decisions."* Agents don't propagate user intent the way a traditional client does — they CREATE intent. Without a separate `act` identifier, the audit log can't tell agent action from direct user action, and you can't revoke 'just this agent' without revoking the user. Multi-hop agent chains preserve full causality via nested actor claims: 'agent A called agent B which is why agent B is calling API foo' becomes traceable. RFC 8693 supports this natively; Microsoft Entra exposes the same concept via `xms_act_fct`.

### YAML — Enterprise (delegation, agent SA mounted)

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: obo-delegation
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: agent-route
  traffic:
    jwtAuthentication:                # validate inbound user JWT
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
      mode: ExchangeOnly              # require may_act in the user JWT
```

> The user's JWT must carry `may_act: { sub: "agent-service-account" }`. STS configuration is set via Helm `tokenExchange.*` values.

> **Tested (v2026.9.3) — read this before copying the YAML above.** The inline `backend.tokenExchange: ExchangeOnly` policy sends **only the subject token** to the STS; it has no way to attach the agent's actor token, so the token it produces is the *impersonation* shape (`sub` only, no `act`) even when the user JWT carries `may_act`. Real delegation happens when the **agent itself** calls the STS (`POST http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token`, grant `urn:ietf:params:oauth:grant-type:token-exchange`, `subject_token` = user JWT, `actor_token` = the agent's projected Kubernetes SA token) — the [`agentsts-adk`](https://pypi.org/project/agentsts-adk/) package does this for you. Observed at the STS endpoint:
>
> - Subject with `may_act.sub` naming the agent SA + that SA's token → token with `act: {sub: "system:serviceaccount:<ns>:<sa>", iss: <cluster issuer>}`.
> - Actor SA not named in `may_act` → `401 unauthorized_client: actor subject ... does not match may_act claim`; subject without `may_act` at all → `subject token does not contain may_act claim`.
> - Second hop (subject = hop-1 token, actor = agent-two) succeeds **only** if the user's `may_act.sub` is a *list* naming both agents; the result nests `act.act`. A scalar `may_act` allows exactly one hop.
> - The STS keeps `sub`, `scope`, and `may_act` and **drops other subject claims** (`role`, `tier`, `email` were gone) unless listed in Helm `tokenExchange.allowedSubjectClaims`. `aud` is set only when the caller passes `audience=`.
> - Delegation responses carry `token_type: N_A` (RFC 8693 §2.2.1); the OSS `backend.auth.oauthTokenExchange` client rejects that as `unsupported token_type`, so today the inline OSS policy cannot be pointed at the Solo STS for delegation either.

> **Docs:** [OBO Token Exchange](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/obo/) · [About OBO & Elicitations](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/about/)
> **API / Helm:** [tokenExchange Helm values](https://docs.solo.io/agentgateway/latest/reference/helm/agentgateway/)

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Agent
    participant GW as Agent Gateway (Proxy)
    participant STS as AGW Built-in STS
    participant Tool as MCP Tool Server

    User->>Agent: Request with user JWT (contains may_act)
    Agent->>GW: Authorization: Bearer <user JWT>
    GW->>STS: POST /token (subject_token=user JWT, actor_token=agent K8s SA)
    STS-->>GW: OBO token (sub=user, act.sub=agent)
    GW->>Tool: Call with OBO token
    Tool-->>GW: Response
    GW-->>Agent: Response
    Agent-->>User: Result
```

> **Where the work happens:** the gateway proxy intercepts the agent's outbound call, posts to the STS (`grant_type=urn:ietf:params:oauth:grant-type:token-exchange`), receives the new JWT, and forwards it to the tool. The STS verifies that `may_act.sub` in the user JWT matches the `sub` of the actor token. The tool validates `sub` (user) **and** `act` (agent) before serving the request.

#### What the three tokens look like

OBO Delegation is the only pattern where the *input* JWT must carry a special claim — `may_act` — that the user pre-authorizes for a specific agent. There are **three** tokens in play: the user JWT, the agent's actor token, and the resulting OBO JWT.

**Input 1 — User JWT (with `may_act`)**

The user obtains this from the IdP. Critically, the IdP must be configured to mint a `may_act` claim naming the agent service account that's allowed to act on the user's behalf.

```jsonc
// Header
{
  "alg": "RS256",
  "kid": "idp-key-2026-04",
  "typ": "JWT"
}
// Payload
{
  "iss": "https://login.example.com/realms/agents",
  "sub": "u-7f0a3c91",                       // the human user
  "aud": "agent-platform",
  "exp": 1777300000,
  "iat": 1777296400,
  "email": "alice@example.com",
  "scope": "openid profile mcp:invoke",
  "may_act": {                               // KEY: pre-authorizes a specific actor
    "sub": "system:serviceaccount:agents:agent-runtime",
    "iss": "https://kubernetes.default.svc"
  }
}
```

> Without `may_act`, the STS rejects the exchange with `invalid_request`. This claim is what makes Delegation **opt-in by the user** instead of an unrestricted swap.

**Input 2 — Actor token (Kubernetes ServiceAccount JWT, projected into the agent pod)**

The agent pod mounts a projected SA token at `/var/run/secrets/tokens/...` and sends it as the `actor_token`:

```jsonc
// Payload (Kubernetes-issued)
{
  "iss": "https://kubernetes.default.svc",
  "sub": "system:serviceaccount:agents:agent-runtime",  // MUST match user JWT's may_act.sub
  "aud": ["agent-gateway-sts"],                          // audience-bound to the STS
  "exp": 1777296700,
  "iat": 1777296400,
  "kubernetes.io": {
    "namespace": "agents",
    "serviceaccount": { "name": "agent-runtime", "uid": "..." },
    "pod":            { "name": "agent-runtime-7d9c-x4f2", "uid": "..." }
  }
}
```

The STS validates this against the Kubernetes API (`TokenReview`).

**Output — OBO Token (issued by AGW STS)**

After the STS validates both inputs and confirms `may_act.sub == actor_token.sub`, it mints:

```jsonc
// Header
{
  "alg": "RS256",
  "kid": "agw-sts-key-1",
  "typ": "JWT"
}
// Payload — RFC 8693 §4.1 with full delegation chain
{
  "iss": "https://agentgateway.example.com/sts",   // CHANGED: AGW STS, not the IdP
  "sub": "u-7f0a3c91",                              // PRESERVED: the user
  "aud": "mcp-tool-server.agents.svc",              // CHANGED: scoped to the MCP tool server
  "exp": 1777296700,
  "iat": 1777296400,
  "scope": "mcp:invoke",
  "act": {                                          // NEW: full delegation chain
    "sub": "system:serviceaccount:agents:agent-runtime",
    "iss": "https://kubernetes.default.svc"
  }
}
```

What's distinctive vs. Gateway-Mediated OIDC (Variant A):

| Aspect | Gateway-Mediated OIDC (Variant A) | OBO Delegation |
|---|---|---|
| Who triggers the exchange | The **gateway**, on every backend call | The **agent** (one hop deeper in the call chain) |
| User JWT requirement | Any valid OIDC token | Must contain `may_act` |
| Who the user authenticates to | The gateway (gateway is the OAuth client) | The IdP directly (user holds the JWT) |
| Actor token | The agent's K8s SA token, but `may_act` is not required | K8s SA token + must satisfy `may_act` |
| Output `act` claim | Set to whatever actor was supplied | Cryptographically tied to a user-authorized SA |
| Trust story | "Gateway speaks for users" | "User explicitly delegated to this agent" |

> **OBO Impersonation** uses the same exchange but **without an actor token** and produces the output JWT with `sub` only (no `act`).

---

## OBO Impersonation (Token Swap) `[Enterprise]`

> **When to use:** You want downstream services to see **only the user's identity**, not the agent's, and you want to keep the original IdP token off the wire after the gateway. Cleanest for systems already designed around end-user JWTs.

Same as Delegation, but **without** an actor token. The STS validates the user JWT and issues a new JWT (signed by agentgateway) with the same `sub` and scopes — no `act` claim. Original IdP token is replaced.

> **The `sub` stays the same on purpose** — downstream services still need to know who the user is, so authorization policy keyed on `sub` keeps working. What changes is everything *around* `sub`:
>
> | Field | IdP token | Exchanged token | Why it matters |
> |---|---|---|---|
> | `iss` | external IdP | gateway STS | Agents only trust one issuer; IdP becomes invisible |
> | `aud` | gateway client_id | the specific backend | Token can't be replayed against the IdP or other resources |
> | `exp` | hours | minutes | Smaller blast radius if it leaks |
> | `scope` | full IdP scopes | only what the agent needs | Reduces what an attacker can do with a stolen token |
> | signature | IdP private key | gateway STS key | Agent verifies against gateway JWKS, not the IdP |
>
> One nuance worth flagging — see Posta's [Explaining OAuth Delegation for AI Agents](https://blog.christianposta.com/explaining-on-behalf-of-for-ai-agents/): pure Impersonation hides important information about WHO decided to act. Downstream services lose the ability to tell agent action from direct user action. For multi-agent systems or anything with compliance scrutiny, [OBO Delegation](#obo-delegation-dual-identity-enterprise) is the safer default.

### YAML — Enterprise (impersonation)

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: obo-impersonation
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: agent-route
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
      mode: ExchangeOnly       # impersonation: no actor; STS reissues with user sub only
```

> **Trade-offs vs. Delegation:** Simpler downstream model (single identity), but loses agent attribution.

> **Tested (v2026.9.3):** this is exactly what the inline policy does. With a Keycloak or locally minted user JWT validated by `jwtAuthentication`, the backend received `Authorization: Bearer <STS JWT>` with `iss` = `enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777`, the same `sub`, the original `scope`, and `exp` = Helm `tokenExpiration` (no `act`). It works with the policy on the `HTTPRoute` (as above) or on the `AgentgatewayBackend`. Prerequisite on the proxy: `STS_URI` on the `EnterpriseAgentgatewayParameters` must point at `.../7777/oauth2/token`; if it points at the elicitations endpoint (see [Elicitation](#elicitation-enterprise)), ExchangeOnly fails with `400 invalid request` — one proxy can't do both with the legacy field ([agentgateway-enterprise#7388](https://github.com/solo-io/agentgateway-enterprise/issues/7388)).

> **Docs:** [OBO Token Exchange](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/obo/) · [About OBO & Elicitations](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/about/)
> **API / Helm:** [tokenExchange Helm values](https://docs.solo.io/agentgateway/latest/reference/helm/agentgateway/)

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant Agent
    participant GW as Agent Gateway (Proxy)
    participant STS as AGW Built-in STS
    participant Tool as MCP Tool Server

    User->>Agent: Request with user JWT
    Agent->>GW: Authorization: Bearer <user JWT>
    GW->>STS: POST /token (subject_token=user JWT, NO actor_token)
    STS-->>GW: New token (sub=user, NO act claim)
    GW->>Tool: Call with swapped token
    Tool-->>GW: Response
    GW-->>Agent: Response
    Agent-->>User: Result
```

> **Where the work happens:** same gateway-mediated flow as Delegation, but the gateway sends only `subject_token` to the STS — no actor token, no `may_act` check. The STS mints a fresh JWT with the same `sub` and scopes, signed by AGW, and **omits the `act` claim**. Downstream policies see only the user identity.

---

## Double OAuth Flow (OIDC + Elicitation) `[Enterprise]`

> **When to use:** Your agent calls a third-party API (GitHub, Atlassian, Salesforce) on behalf of the user, and that API requires its own OAuth consent — separate from your gateway's IdP. The user authenticates twice: once for the gateway, once for the upstream API.

Two sequential user-facing OAuth flows orchestrated by the gateway:

1. **Inbound** — user authenticates against the corporate IdP via OIDC (the gateway runs the redirect via `entExtAuth`).
2. **Outbound** — when the gateway needs to call a third-party API, it triggers an [elicitation](#elicitation-enterprise). The user completes a second OAuth flow at the third-party (GitHub, Atlassian, etc.) via the **Solo Enterprise UI**. The STS stores the upstream token; subsequent requests reuse it.

> **Terminology note:** The Solo docs use "downstream" (inbound, corporate SSO) and "upstream" (outbound, third-party). It's a common point of confusion — both flows are user-facing, but they happen at opposite ends of the gateway. The YAML below uses the docs' terminology, but think of them as inbound (user → gateway) and outbound (gateway → third-party).

> **Where this fits in Posta's framework.** In [MCP Authorization Patterns for Upstream API Calls](https://blog.christianposta.com/mcp-authorization-patterns-upstream-api-calls/), Christian Posta calls out five patterns for upstream API access. The pattern combining inbound OIDC at the gateway plus *lazy* outbound OAuth-via-elicitation is his recommended approach for organizations that want the agent flow to "just work" today — credentials never leak to MCP clients or servers, and the gateway is positioned to adopt emerging token-exchange standards.

> **What changed in 2026.9.x.** The upstream OAuth client is now configured with **typed fields** under `backend.entElicitation` (`interactive.oauth.*` for the Solo-UI-driven flow, `brokered.chainedAuth.oauth.*` for the MCP-client-driven flow in [Eager Upstream OAuth](#eager-upstream-oauth-gateway-as-oauth-issuer-enterprise)); only the `client_secret` stays in a Secret referenced by `clientSecretRef`. The data-plane lookup/injection is a separate field, `backend.entTokenExchange.solo.elicitation: {}`. The old `backend.tokenExchange.elicitation.secretName` (an *opaque* Secret with `client_id`, `client_secret`, `authorize_url`, `access_token_url`, `scopes`, `app_id`) is deprecated but still works. The `type: extauth.solo.io/oauth` Secret with `client-id`/`client-secret` keys that this guide used to show is **not** read by the STS — it is the AuthConfig (ext-auth) secret format.

### YAML — Enterprise (downstream OIDC + upstream elicitation)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-oauth-app
  namespace: agentgateway-system
type: Opaque
stringData:
  client_secret: <github-app-client-secret>
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: github-double-oauth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: github-mcp
  traffic:
    entExtAuth:                 # 1) downstream OIDC (e.g., corporate SSO) — see the AuthConfig above
      authConfigRef: { name: corporate-sso }
      backendRef:
        name: ext-auth-service-enterprise-agentgateway
        namespace: agentgateway-system
        port: 8083
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: github-upstream-oauth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: github
  backend:
    entElicitation:             # 2) upstream OAuth app the user consents to in the Solo UI
      interactive:
        oauth:
          clientId: <github-app-client-id>
          clientSecretRef: { name: github-oauth-app, key: client_secret }
          scopes: [repo, read:org]
          redirectUri: https://solo-ui.example.com/age/elicitations
          authorizeUrl: https://github.com/login/oauth/authorize
          accessTokenUrl: https://github.com/login/oauth/access_token
    entTokenExchange:           # 3) look up / inject the stored upstream token on each request
      solo:
        elicitation: {}
```

> **Docs:** [About OBO & Elicitations](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/about/) · [Elicitations](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/elicitations/)
> **API:** [TokenExchangeMode](https://docs.solo.io/agentgateway/latest/reference/api/solo/#tokenexchangemode)

```mermaid
sequenceDiagram
    actor User
    participant GW as Agent Gateway (Proxy)
    participant IdP as Enterprise IdP (downstream)
    participant SoloUI as Solo Enterprise UI
    participant Upstream as Upstream Provider (e.g. GitHub)
    participant Agent
    User->>GW: Request needing upstream API
    GW-->>User: 302 to IdP /authorize (downstream OIDC)
    User->>IdP: Login
    IdP-->>GW: Downstream JWT
    GW-->>User: PENDING + elicitation URL (no upstream token yet)
    User->>SoloUI: Open elicitation URL
    SoloUI->>Upstream: OAuth flow (user grants consent)
    Upstream-->>SoloUI: Upstream token
    SoloUI->>GW: Store token, mark COMPLETED
    User->>GW: Retry original request
    GW->>Agent: Forward + downstream JWT + injected upstream token
    Agent-->>GW: Response
    GW-->>User: Result
```


---

## Eager Upstream OAuth (Gateway as OAuth Issuer) `[Enterprise]`

> **Available:** GA from Solo Enterprise for agentgateway **2.3.x**. The canonical reference deployment is [`solo-io/mk-k8s-demos/mcp-auth`](https://github.com/solo-io/mk-k8s-demos/tree/main/mcp-auth) (Helmfile + Helm chart). Earlier prototype shapes live at [`solo-io/agentgateway-eager-oauth`](https://github.com/solo-io/agentgateway-eager-oauth).

> **When to use:** You expose multiple MCP servers backed by different third-party providers (GitHub, GitLab, Atlassian, Databricks…) and you want users to sign in to enterprise SSO **once** plus complete a **one-time consent at each upstream provider** — and then have no further OAuth prompts for the lifetime of those stored tokens.

> **Honesty about the user experience.** The Solo marketing line is "sign in once and access everything." That's accurate for the **corporate SSO** half — login at the IdP happens once and is reused. But for each **upstream provider** (GitHub, GitLab, Atlassian, Databricks), a brand-new user still has to click through that provider's consent screen the first time. With four upstream backends, a first-time user sees four consent pop-ups in sequence at MCP-connect time. After that one-time gauntlet, the gateway persists the tokens and future sessions skip the pop-ups entirely.

> **Why this pattern exists, per Posta.** In [Connecting SaaS MCP Servers to Enterprise With Agentgateway](https://blog.christianposta.com/connecting-saas-mcp-servers-to-enterprise-with-agentgateway/), Christian Posta puts it bluntly: *"SSO gives you user identity. What you need is user authorization: OAuth access tokens scoped to specific SaaS APIs on behalf of a specific user."* Federated SSO alone is not enough — most SaaS providers want their own OAuth tokens, not just identity assertions from your IdP. Provider reality check: GitHub uses standard OAuth, Atlassian's Remote MCP requires federated credentials, Databricks offers some SSO-to-OAuth mapping, and "most other providers don't support it at all."

The gateway hosts its **own OAuth Authorization Server** at `/oauth-issuer/`. From an MCP client's perspective there is exactly one OAuth issuer: the gateway. Behind the scenes the gateway:

1. Delegates the user's actual login to an **enterprise IdP** (Entra/Okta/Cognito/Keycloak) via `/oauth-issuer/callback/downstream` — same Authorization Code flow as Variant A.
2. **Pre-stages** upstream OAuth credentials for each MCP backend at config time (static OAuth app for GitHub, Dynamic Client Registration for GitLab and Atlassian).
3. Shows an optional **consent screen** (`/oauth-issuer/consent`), then chains into the upstream provider's OAuth flow and receives the upstream token at `/oauth-issuer/callback/upstream`.
4. Persists upstream tokens (SQLite by default, **PostgreSQL** for anything beyond a demo) so they survive restarts and are reused across requests.
5. Each MCP backend declares its upstream provider with `backend.entElicitation.brokered.chainedAuth` and turns on per-request injection with `backend.entTokenExchange.solo.elicitation: {}`. In the Solo docs this is [**brokered elicitation (chained flow)**](https://docs.solo.io/agentgateway/latest/mcp/token-exchange/elicitations/overview/).

> **Tested (v2026.9.3)** with Keycloak as the downstream IdP and a second Keycloak realm standing in for the upstream SaaS provider: the MCP client hit `/oauth-issuer/authorize` → Keycloak login → consent page (`POST decision=allow`) → upstream realm login → `/oauth-issuer/callback/upstream` → redirect back to the client with a code → token. A subsequent `tools/call` reached the MCP server with `Authorization: Bearer <upstream-realm token>` (`iss` = upstream realm, `preferred_username` = the logged-in user) — the client never saw it. Both the static-client variant and the DCR variant (`baseUrl` discovery) worked. Without `entTokenExchange.solo.elicitation: {}` the flow completes but nothing is injected.

> **What does "Eager" mean here?** The OAuth flow with each upstream provider runs **at MCP connect time** — when the client first establishes the MCP session — not lazily on the first tool call that needs the token. Once the session is up, every tool call inside it reuses the cached upstream tokens without further user interaction. Contrast with the lazy patterns [Double OAuth Flow](#double-oauth-flow-oidc--elicitation-enterprise) and [Elicitation](#elicitation-enterprise), where the user is prompted on demand whenever a request needs a fresh upstream token.

> **Single-IdP shape?** If you don't need per-upstream-provider tokens — i.e. one IdP, JWT goes straight to the backend, and you just need gateway-brokered DCR because real DCR isn't viable on your IdP — see [MCP OAuth — Gateway-Brokered DCR for Auth0 / Okta](#mcp-oauth--gateway-brokered-dcr-for-auth0--okta-enterprise). It uses the same `/oauth-issuer/` machinery without the per-backend `backend.tokenExchange` policy or Variants 1/2 below.

### How it differs from the lazy patterns

| | [Double OAuth Flow](#double-oauth-flow-oidc--elicitation-enterprise) | [Elicitation](#elicitation-enterprise) | **Eager Upstream OAuth** |
|---|---|---|---|
| OAuth issuer the MCP client sees | External IdP | External IdP + Solo UI | **The gateway itself** |
| When upstream consent is collected | First request that needs it | First request that needs it | **At downstream login (or before)** |
| Interactive flows the user sees | 2 (SSO + Solo UI) | 1 per provider, on demand | **1 (SSO only)** |
| Upstream client registration | Per-provider in Solo UI | Per-provider in Solo UI | **Static config or DCR** |
| Token storage | Solo Enterprise control plane | Solo Enterprise control plane | **PostgreSQL owned by the gateway** |

### Flow

```mermaid
sequenceDiagram
    autonumber
    actor User
    participant MCP as MCP Client
    participant GW as Agent Gateway (Proxy)<br/>+ /oauth-issuer
    participant IdP as Enterprise IdP (Entra)
    participant Upstream as Upstream Provider<br/>(GitHub / GitLab / Atlassian)
    participant DB as Postgres
    participant Tool as MCP Server

    MCP->>GW: GET /.well-known/oauth-authorization-server/mcp/github
    GW-->>MCP: Issuer = gateway, authorize URL = /oauth-issuer/authorize
    MCP->>GW: /oauth-issuer/authorize (PKCE)
    GW-->>MCP: 302 to IdP /authorize
    User->>IdP: SSO login
    IdP-->>GW: Callback /oauth-issuer/callback/downstream (code)
    GW->>IdP: POST /token (code) → user JWT
    GW-->>MCP: Issue gateway-issued auth code → access token
    MCP->>GW: Call /mcp/github with gateway-issued token
    GW->>DB: Look up upstream token for (user, github)
    alt no upstream token yet
        GW->>Upstream: OAuth code-flow (or DCR + code-flow) at /oauth-issuer/callback/upstream
        Upstream-->>GW: Upstream access token
        GW->>DB: Persist upstream token
    end
    GW->>Tool: Forward request with upstream provider token
    Tool-->>GW: Response
    GW-->>MCP: Response
```

### YAML — Helm values (the gateway as OAuth issuer)

```yaml
tokenExchange:
  enabled: true
  issuer: "enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777"
  tokenExpiration: 24h
  maintenance:
    enabled: true                       # janitor for expired tokens / stale elicitations
  subjectValidators:                    # list, tried in order (singular form is deprecated)
    - validatorType: remote
      issuer: "https://login.microsoftonline.com/<tenant>/v2.0"
      remoteConfig:
        url: "https://login.microsoftonline.com/<tenant>/discovery/v2.0/keys"
  actorValidators: [{validatorType: k8s}]
  apiValidators:   [{validatorType: k8s}]     # all three validator lists are required at boot
  database:
    type: postgres
    postgres:
      url: postgres://myuser:mypassword@postgres.postgres:5432/mydb

controller:
  extraEnv:
    KGW_OAUTH_ISSUER_CONFIG: |
      {
        "gateway_config": {
          "base_url": "https://gateway.example.com/oauth-issuer"
        },
        "downstream_server": {
          "name": "down",
          "client_id": "<entra-client-id>",
          "client_secret": "<entra-client-secret>",
          "authorize_url": "https://login.microsoftonline.com/<tenant>/oauth2/v2.0/authorize",
          "token_url":     "https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token",
          "redirect_uri":  "https://gateway.example.com/oauth-issuer/callback/downstream",
          "scopes":        ["api://<entra-client-id>/agentgateway"]
        },
        "incoming_clients": {
          "allowed_redirect_uris": [
            "http://localhost:6274/oauth/callback",
            "http://localhost:6274/oauth/callback/debug",
            "vscode://solo.agentgateway/callback"
          ]
        },
        "consent": {
          "enabled": true,
          "force_refresh": false,
          "platform_name": "Acme AI Gateway",
          "legal_text": "By clicking Allow you authorize Acme AI Gateway to act on your behalf against the selected upstream service."
        }
      }
```

The proxy pod reaches the STS through `STS_URI` on the `EnterpriseAgentgatewayParameters`; the typed `entTokenExchange.solo` path defaults to the controller Service, so this is only needed for the legacy `backend.tokenExchange` field:

```yaml
spec:
  env:
    - name: STS_URI
      # /oauth2/token for ExchangeOnly, /elicitations/oauth2/token for legacy elicitation — not both
      value: http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth2/token
    - name: STS_AUTH_TOKEN
      value: /var/run/secrets/xds-tokens/xds-token
```

### YAML — Variant 1: static OAuth app (GitHub)

GitHub doesn't support DCR, so you pre-register an OAuth app there and give the gateway its `client_id` / `client_secret`:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-oauth-app
  namespace: default
type: Opaque
stringData:
  client_secret: "<github-app-client-secret>"
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: github-upstream
  namespace: default
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: github
  backend:
    entElicitation:
      brokered:
        mcpResourcePath: /mcp/github           # path part of the protected-resource identifier
        chainedAuth:
          oauth:
            clientId: "<github-app-client-id>"
            clientSecretRef: { name: github-oauth-app, key: client_secret }
            scopes: [repo, read:org]
            authorizeUrl:   https://github.com/login/oauth/authorize
            accessTokenUrl: https://github.com/login/oauth/access_token
    entTokenExchange:
      solo:
        elicitation: {}                        # inject the stored GitHub token on every call
```

<details>
<summary>Deprecated opaque-Secret shape (still accepted)</summary>

```yaml
apiVersion: v1
kind: Secret
metadata: {name: github-token-exchange, namespace: default}
type: Opaque
stringData:
  app_id: "github"
  authorize_url:    "https://github.com/login/oauth/authorize"
  access_token_url: "https://github.com/login/oauth/access_token"
  client_id:        "<github-app-client-id>"
  client_secret:    "<github-app-client-secret>"
  mcp_resource:     "/mcp/github"
  scopes:           "repo read:org"
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: github-exchange, namespace: default}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: github}]
  backend:
    tokenExchange:
      mode: ElicitationOnly
      elicitation: {secretName: github-token-exchange}
```

</details>

### YAML — Variant 2: Dynamic Client Registration (GitLab, Atlassian)

GitLab and Atlassian support RFC 7591 DCR, so the gateway can register itself as an OAuth client at runtime — omit `clientId` and point at the provider's discovery base URL (or an explicit `registrationUrl`):

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: gitlab-upstream
  namespace: default
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: gitlab
  backend:
    entElicitation:
      brokered:
        mcpResourcePath: /mcp/gitlab
        chainedAuth:
          oauth:
            baseUrl: https://gitlab.com            # metadata discovery + DCR; or authorizeUrl/accessTokenUrl/registrationUrl
            scopes: [mcp]
            clientName: Acme AI Gateway            # client_name sent during DCR
    entTokenExchange:
      solo:
        elicitation: {}
```

### YAML — MCP backend wiring (the same for both variants)

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: github
spec:
  mcp:
    targets:
      - name: mcp-target
        static: { host: api.githubcopilot.com, port: 443 }
  policies:
    tls: {}
    mcp:
      authentication:
        mode: Strict
        issuer: https://sts.windows.net/<tenant>/
        audiences: [api://<entra-client-id>]
        jwks:
          backendRef:
            name: entra-jwks
            kind: AgentgatewayBackend
            group: agentgateway.dev
          jwksPath: <tenant>/discovery/v2.0/keys
        resourceMetadata:
          # Tells MCP clients to find auth metadata at the gateway's own /oauth-issuer
          agentgateway.dev/issuer-proxy: http://enterprise-agentgateway.agentgateway-system.svc.cluster.local:7777/oauth-issuer
          authorizationServers: [https://gateway.example.com/mcp/github]
          resource:             https://gateway.example.com/mcp/github
          scopesSupported:      [api://<entra-client-id>/agentgateway]
```

### Operational notes

- **HTTPS is mandatory** for non-localhost OAuth callbacks. The reference setup uses ngrok or cert-manager + Let's Encrypt.
- **Token storage in Postgres** survives restarts. SQLite in-memory is supported for dev only.
- **DCR for GitLab** can be done out-of-band first (the README shows a `curl https://gitlab.com/oauth/register`); the runtime registration is what makes scaling to many providers tractable.
- **Single front door:** MCP clients only need to know `https://gateway.example.com` — they discover OAuth metadata via `.well-known/oauth-authorization-server/<path>` and never see the upstream providers' OAuth endpoints directly.

> **Source / repo:** [solo-io/mk-k8s-demos/mcp-auth](https://github.com/solo-io/mk-k8s-demos/tree/main/mcp-auth) (canonical Helmfile + chart) · [solo-io/agentgateway-eager-oauth](https://github.com/solo-io/agentgateway-eager-oauth) (earlier prototype) · [Enterprise MCP SSO with Microsoft Entra and Agentgateway (blog)](https://www.solo.io/blog/enterprise-mcp-sso-with-microsoft-entra-and-agentgateway)

---

# Upstream / Backend Auth

Patterns for authenticating the gateway → backend hop.

---

## Passthrough Token `[OSS]`

> **When to use:** The backend is in the same identity federation as the gateway (e.g., both trust the same IdP) and you want the user's original token to reach the backend unchanged.

Inbound auth (JWT or API key) validates the client and may strip the `Authorization` header. **Passthrough** re-attaches the validated token to the outbound request so the backend receives it as-is.

> **Anti-pattern warning for MCP / agent contexts.** Christian Posta flags this in [MCP Authorization Patterns for Upstream API Calls](https://blog.christianposta.com/mcp-authorization-patterns-upstream-api-calls/): the MCP spec explicitly calls token passthrough *"an anti-pattern where an MCP server accepts tokens from an MCP client without validating proper issuance."* The risk: if the backend doesn't independently validate the token (issuer, audience, signature), an attacker can replay a token from one service to another within the same trust domain.
>
> **Safe-use checklist for Passthrough:**
> 1. Backend and gateway share the same IdP / identity federation.
> 2. Backend independently validates `iss`, `aud`, `exp`, signature — not just "is there an Authorization header."
> 3. Tokens are short-lived (minutes, not hours).

### YAML — OSS

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: backend-passthrough
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: ""
      kind: Service
      name: agents-backend
  backend:
    auth:
      passthrough: {}            # forward the original Authorization header
```

> **Trade-offs:** Simplest backend-auth pattern when it fits. Couples the backend to the IdP — if you ever want to decouple, you'll need [OBO](#obo-impersonation-token-swap-enterprise) or [Token Exchange](#gateway-mediated-oidc--token-exchange-enterprise).

> **Tested (v2026.9.3):** with `jwtAuthentication` alone the backend receives **no** `Authorization` header (the validated JWT is stripped). Adding `backend.auth.passthrough: {}` on the backend Service restores the original `Bearer <JWT>`; unauthenticated requests are still rejected at the gateway with `401`. Alternative when you don't want a backend policy: `jwtAuthentication.preserveToken: true`.

> **Docs:** [API Keys — Passthrough Token](https://docs.solo.io/agentgateway/latest/llm/api-keys/)
> **API:** [BackendAuthPassthrough (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#backendauthpassthrough) · [BackendAuth (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#backendauth)

```mermaid
sequenceDiagram
    actor Client
    participant GW as Agent Gateway
    participant Backend
    Note over Client: Client already holds a token<br/>(JWT, opaque, etc.)
    Client->>GW: Request + Authorization: Bearer <token>
    GW->>GW: Inbound auth validates (JWT / API key) — strips header
    GW->>GW: backend.auth.passthrough — re-attach original Authorization
    GW->>Backend: Forward request (original Authorization preserved)
    Backend-->>GW: Response
    GW-->>Client: Response
```


---

## Static Secret Injection (Shared Credential) `[OSS]`

> **When to use:** The backend (e.g., OpenAI, Anthropic) accepts a single API key and you want the gateway to attach it to every outbound request. The user's identity is established at the gateway via a separate inbound auth policy.

Inbound auth validates the user. A separate `backend.auth.secretRef` policy injects a static credential into the outbound `Authorization` header. **All users share the same upstream token.** For per-user upstream tokens see [Claim-Based Token Mapping](#claim-based-token-mapping-oss) or [Elicitation](#elicitation-enterprise).

> **Security framing.** Christian Posta's [API Keys Are a Bad Idea for Enterprise LLM, Agent, and MCP Access](https://blog.christianposta.com/api-keys-are-a-bad-idea-for-enterprise-llm-agent-and-mcp-access/) recommends "AI Gateway Architecture" as the pragmatic way to handle broad-permission upstream keys: *"contain provider API keys in a single gateway that shields internal systems. Internal services use stronger authentication methods while the gateway handles upstream credentials."* This pattern is exactly that — the gateway holds the shared credential, agents and users never see it, and the gateway becomes the centralized control point for rotation, audit, and rate limiting.

### YAML — OSS (real shape from a live cluster)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: github-auth
  namespace: mcp-tools
type: Opaque
stringData:
  Authorization: "Bearer ghp_..."   # NOTE: must be stored under key "Authorization"
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: mcp-auth
  namespace: mcp-tools
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agw-waypoint
  backend:
    auth:
      secretRef:
        name: github-auth
```

### YAML — OSS (inline `key`)

```yaml
spec:
  backend:
    auth:
      key: "Bearer sk-...redacted..."   # least-secure variant; prefer secretRef
```

### YAML — OSS (custom Secret key + non-Authorization header)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: upstream-apikey
stringData:
  apikey: "k-upstream-123"
---
spec:
  backend:
    auth:
      secretRef:
        name: upstream-apikey
        key: apikey                 # default key is "Authorization"
      location:
        header:
          name: x-api-key           # default is Authorization with a "Bearer " prefix
```

> **Tested (v2026.9.3):** all three shapes work. With `secretRef`/`key` the user's JWT is replaced by the shared credential (it does not leak upstream); with `location.header.name: x-api-key` the raw Secret value lands in that header. A `Bearer ` prefix in the Secret is honored only for the default `Authorization` key.

> **Docs:** [API Keys — Manage API Keys](https://docs.solo.io/agentgateway/latest/llm/api-keys/)
> **API:** [BackendAuth (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#backendauth)

```mermaid
sequenceDiagram
    actor Client
    participant GW as Agent Gateway
    participant Secret as K8s Secret (shared)
    participant Backend as Upstream API (e.g. OpenAI)
    Client->>GW: Request (authenticated as user via JWT/API key)
    GW->>GW: Inbound auth validates user
    GW->>Secret: Read shared upstream credential (secretRef)
    Secret-->>GW: Authorization header value
    GW->>Backend: Forward + Authorization: <shared token>
    Backend-->>GW: Response
    GW-->>Client: Response (all users share one upstream token)
```


---

## Claim-Based Token Mapping `[OSS]`

> **When to use:** Different users, teams, or tiers should call the backend with **different** upstream credentials (e.g., free vs. paid OpenAI keys; per-team Anthropic keys). You don't need user OAuth — a static map keyed by JWT claim is enough.

Validate the inbound JWT, then use a CEL request transformation to set the `Authorization` header based on a JWT claim (`sub`, `team`, `tier`, etc.).

### YAML — OSS (JWT claim → Authorization header via CEL)

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: claim-based-mapping
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: openai-route
  traffic:
    jwtAuthentication:
      mode: Strict
      providers:
        - issuer: "https://idp.example.com"
          audiences: [agent-gateway]
          jwks:
            remote:
              jwksPath: "/.well-known/jwks.json"
              backendRef: { kind: Service, name: idp, namespace: idp-system, port: 443 }
    transformation:
      request:
        set:
          # Pick a key based on the user's `tier` claim. `value` is a CEL expression.
          # Guard with has(): if the expression errors (claim missing) the header is
          # dropped and the request continues without any Authorization header.
          - name: Authorization
            value: |
              "Bearer " + (
                !has(jwt.tier) ? "<free-tier-key>" :
                jwt.tier == "paid" ? "<paid-tier-key>" :
                jwt.tier == "internal" ? "<internal-key>" :
                "<free-tier-key>"
              )
```

> **Tested (v2026.9.3):** the field is `set[].value` (CEL) — `set[].expression` is rejected as an unknown field. `tier=paid`, `free`, and `internal` tokens each produced the mapped key at the backend; a token without `tier` produced **no** `Authorization` header at all (CEL error → header unset, request still forwarded), hence the `has()` guard above.

> **Docs:** [CEL Transformations](https://docs.solo.io/agentgateway/latest/traffic-management/transformations/) · [JWT Auth for MCP Services](https://docs.solo.io/agentgateway/latest/mcp/mcp-access/)
> **API:** [TransformationPolicy (OSS)](https://docs.solo.io/agentgateway/latest/reference/api/api/#transformationpolicy) · [EnterpriseAgentgatewayBackendPolicy](https://docs.solo.io/agentgateway/latest/reference/api/solo/#enterpriseagentgatewaybackendpolicy)

```mermaid
sequenceDiagram
    actor Client
    participant GW as Agent Gateway
    participant Backend
    Client->>GW: Request + Authorization: Bearer <user JWT>
    GW->>GW: Validate JWT, extract claims (tier, team, sub)
    GW->>GW: CEL transform sets Authorization based on jwt.tier<br/>(e.g. paid → key A, free → key B)
    GW->>Backend: Forward with mapped Authorization header
    Backend-->>GW: Response
    GW-->>Client: Response (per-tier upstream credential)
```


---

# Credential Gathering

---

## Elicitation `[Enterprise]`

> **When to use:** The agent occasionally needs to call upstream APIs (GitHub, Atlassian, Google Workspace) on behalf of the user, and you need real user consent for each provider. Triggers a one-time per-user OAuth flow when needed; subsequent requests reuse the stored token.

When a request needs an upstream OAuth token but none is available yet, the gateway returns the **elicitation URL** to the client with a `PENDING` status. The user opens that URL in the **Solo Enterprise UI** to complete the upstream OAuth flow. Once `COMPLETED`, the client retries the original request and the gateway injects the stored token.

> **Posta's Pattern 4 — URL Elicitation.** Christian Posta's [MCP Authorization Patterns for Upstream API Calls](https://blog.christianposta.com/mcp-authorization-patterns-upstream-api-calls/) calls this his Pattern 4 and one of the right answers for organizations starting today: it works, it keeps credentials away from MCP clients, and a recent MCP spec proposal formalizes the elicitation flow. Trade-off he flags: it "depends on user experience design and requires all agents in a chain to support it" — multi-hop agent setups need every hop to be elicitation-aware.

> **Async-flow story.** When an autonomous agent runs without a user actively present, the elicitation flow can be delivered out-of-band — the gateway produces the elicitation URL and the user completes consent later via Slack, Teams, or email. The agent retries when the token arrives. That's the key difference between Elicitation and a synchronous OAuth redirect: it doesn't require the user to be on the call at the moment of consent.

> **Why Enterprise:** Requires the Solo Enterprise UI to host the consent flow and the Enterprise control plane (STS) to durably store per-user upstream tokens. The `entElicitation` / `entTokenExchange` fields are in the Enterprise CRD only.

> **Tested (v2026.9.3):** with no stored token, a request carrying a valid user JWT to the elicitation-protected backend came back as `HTTP 500 {"url":"<elicitation-url>","status_url":null}` on the legacy field and `HTTP 400 {"url":...}` on the typed `entTokenExchange.solo` field — i.e. the PENDING/elicit response the client has to surface to the user. The URL points at the Solo UI's `/age/elicitations` view (a placeholder host appears until the UI URL is configured). Completing the consent in the UI was not exercised here. Note the two STS endpoints: the legacy `backend.tokenExchange` field needs the proxy's `STS_URI` to be `.../7777/elicitations/oauth2/token` for elicitation (and `.../7777/oauth2/token` for ExchangeOnly — one or the other per proxy); the typed `entTokenExchange.solo` path has no such dependency and worked with either value.

### YAML — Enterprise (elicit-only, typed fields)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: jira-oauth-app
  namespace: agentgateway-system
type: Opaque
stringData:
  client_secret: <jira-app-client-secret>
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: jira-elicit-only
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: agentgateway.dev
      kind: AgentgatewayBackend
      name: jira-mcp
  backend:
    entElicitation:
      interactive:                     # user completes consent in the Solo Enterprise UI
        oauth:
          clientId: <jira-app-client-id>
          clientSecretRef: { name: jira-oauth-app, key: client_secret }
          scopes: [read:jira-work, offline_access]
          redirectUri: https://solo-ui.example.com/age/elicitations
          authorizeUrl: https://auth.atlassian.com/authorize
          accessTokenUrl: https://auth.atlassian.com/oauth/token
    entTokenExchange:
      solo:
        elicitation: {}                # look up the stored token; return the elicitation URL if missing
```

<details>
<summary>Deprecated shape: <code>tokenExchange.mode: ElicitationOnly</code> + opaque Secret</summary>

```yaml
apiVersion: v1
kind: Secret
metadata: {name: jira-oauth-app, namespace: agentgateway-system}
type: Opaque
stringData:
  app_id: jira
  client_id: <jira-app-client-id>
  client_secret: <jira-app-client-secret>
  authorize_url: https://auth.atlassian.com/authorize
  access_token_url: https://auth.atlassian.com/oauth/token
  scopes: "read:jira-work offline_access"
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata: {name: jira-elicit-only, namespace: agentgateway-system}
spec:
  targetRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: jira-mcp}]
  backend:
    tokenExchange:
      mode: ElicitationOnly
      elicitation: {clientName: jira, secretName: jira-oauth-app}
```

</details>

> **Docs:** [Elicitations](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/elicitations/) · [About OBO & Elicitations](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/about/)
> **API:** [TokenExchangeMode](https://docs.solo.io/agentgateway/latest/reference/api/solo/#tokenexchangemode)

```mermaid
sequenceDiagram
    actor Client
    participant GW as Agent Gateway (Proxy)
    participant STS as Token Exchange Server
    participant SoloUI as Solo Enterprise UI
    participant Upstream as External OAuth Provider
    participant API as Upstream API
    Client->>GW: Request (needs upstream OAuth token)
    GW->>STS: Look up upstream token for this user
    STS-->>GW: PENDING + elicitation URL
    GW-->>Client: PENDING + elicitation URL
    Client->>SoloUI: Open elicitation URL (browser)
    SoloUI->>Upstream: Authorize (user consents)
    Upstream-->>SoloUI: Authorization code → token
    SoloUI->>STS: Complete elicitation, store token
    Client->>GW: Retry original request
    GW->>STS: Fetch stored token
    STS-->>GW: Stored upstream token
    GW->>API: Forward + inject upstream token
    API-->>GW: Response
    GW-->>Client: Result
```


---

# East-West: agentgateway as an Istio Ambient Waypoint

Everything above is the **north-south** story: a client outside the cluster talks to the gateway. Inside an Istio ambient mesh, agentgateway can also run as the **waypoint proxy** — the L7 hop ztunnel inserts between any two in-mesh workloads. That changes the identity story: the caller's identity is the **SPIFFE ID from the mTLS connection** (`spiffe://<trust-domain>/ns/<namespace>/sa/<service-account>`), issued by Istio, with no token, API key, or certificate configured in the agent. The same `EnterpriseAgentgatewayPolicy` CEL engine sees it as `source.identity.*`.

The two patterns below are the auth-relevant slice. The complete picture — per-tool MCP authorization that requires the workload identity *and* the user's consent, agent-to-agent delegation chains, LLM budgets, prompt guards, and the traces that tie it together — is a runnable demo: **[rvennam/agent-mesh-demo](https://github.com/rvennam/agent-mesh-demo)** (Solo Istio ambient + agentgateway as the waypoint, Keycloak, a notebook you run cell by cell).

> **Requirements (verified):** Solo distribution of Istio **1.30 or later** in ambient mode and the `enterprise-agentgateway` Helm chart installed with `istio.autoEnabled=true`. If your ztunnel is configured with a network name (`network: cluster1`), the `istio-system` namespace must carry the matching `topology.istio.io/network` label and the chart needs `istio.network` / `istio.clusterId` set to match — without that, ztunnel silently passes traffic through in plaintext and never consults the waypoint. Docs: [Install agentgateway as a waypoint](https://docs.solo.io/agentgateway/latest/integrations/agentic-mesh/waypoint/install/).

### Waypoint setup (shared by both patterns)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agw-waypoint
  namespace: ai-tools
  labels:
    istio.io/waypoint-for: all          # Services and ServiceEntries (use `service` for Services only)
spec:
  gatewayClassName: enterprise-agentgateway-waypoint
  listeners:
    - name: mesh
      protocol: HBONE
      port: 15008
```

```bash
# Enroll a Service (or label the namespace to enroll everything in it)
kubectl label svc inventory-mcp -n ai-tools istio.io/use-waypoint=agw-waypoint
```

---

## Mesh Identity Authorization (SPIFFE, no tokens) `[Enterprise]`

> **When to use:** Agent → MCP server or agent → agent calls that stay inside the cluster. You want "only *this* agent workload may call *this* tool server" enforced on the caller's cryptographic workload identity, not on a bearer token the agent could leak or a key you have to rotate. Pair it with the JWT patterns above when you also need *user* identity on the same call (the agent-mesh demo requires both).

ztunnel terminates mTLS and hands the waypoint the caller's SPIFFE identity. A CEL `authorization` policy on the waypoint Gateway allows or denies on `source.identity.serviceAccount`, `.namespace`, `.trustDomain`, optionally combined with `request.*`. A `transformation` can also stamp that identity into request headers so the MCP server (or an audit log) sees who called without parsing certificates.

### YAML — Enterprise (allow one agent, propagate identity)

```yaml
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: waypoint-authz
  namespace: ai-tools
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agw-waypoint
  traffic:
    authorization:
      action: Allow
      policy:
        matchExpressions:
          - 'source.identity.namespace == "ai-agents" && source.identity.serviceAccount == "customer-agent"'
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: waypoint-identity-headers
  namespace: ai-tools
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agw-waypoint
  traffic:
    transformation:
      request:
        set:
          - name: x-caller-spiffe
            value: 'source.identity.trustDomain + "/ns/" + source.identity.namespace + "/sa/" + source.identity.serviceAccount'
          - name: x-caller-sa
            value: source.identity.serviceAccount
```

> **Tested (v2026.9.3, Solo Istio 1.31.1):** with the Service enrolled, `customer-agent` → `inventory-mcp` returned `200` and `rogue-agent` (same namespace, different ServiceAccount) returned `403` in under a millisecond at the waypoint; the waypoint access log carried `src.identity=spiffe://cluster.local/ns/authtest-mesh/sa/customer-agent`, and the backend saw `X-Caller-Spiffe: cluster.local/ns/authtest-mesh/sa/customer-agent`. Istio `AuthorizationPolicy` resources are **not** honored by the agentgateway waypoint; use `EnterpriseAgentgatewayPolicy`.

```mermaid
sequenceDiagram
    participant Agent as Agent pod (SA: customer-agent)
    participant ZT as ztunnel
    participant WP as agentgateway waypoint
    participant MCP as MCP server
    Agent->>ZT: plain HTTP to inventory-mcp
    ZT->>WP: HBONE (mTLS, SPIFFE: customer-agent)
    WP->>WP: CEL on source.identity.* (+ optional jwt.*)
    alt allowed
        WP->>MCP: forward (+ x-caller-spiffe)
        MCP-->>Agent: response
    else denied
        WP-->>Agent: 403 (MCP server never sees the call)
    end
```

---

## LLM Egress with Waypoint-Injected Credentials `[Enterprise]`

> **When to use:** In-mesh agents need to call OpenAI / Anthropic / Bedrock, and you want zero provider keys in agent pods, a single place to rotate them, per-agent authorization, and `gen_ai.*` usage telemetry — the mesh-native version of [Static Secret Injection](#static-secret-injection-shared-credential-oss).

A `ServiceEntry` gives the agents a stable in-mesh hostname (`myllm.com`) enrolled on the waypoint. An `HTTPRoute` whose `parentRefs` is the **ServiceEntry** (not the Gateway) routes paths to `AgentgatewayBackend`s, one per provider, each carrying its own `policies.auth.secretRef`. Agents send plain HTTP with no key; the waypoint originates TLS, injects the key, and the same identity authorization as above decides which agents may call the model at all.

### YAML — Enterprise (ServiceEntry + per-provider backend)

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: myllm
  namespace: ai-tools
  labels:
    istio.io/use-waypoint: agw-waypoint
spec:
  hosts: [myllm.com]
  location: MESH_EXTERNAL
  ports: [{number: 80, name: http, protocol: HTTP}]
  resolution: STATIC
  endpoints: [{address: 1.1.1.1}]          # placeholder; the waypoint never dials it
---
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: openai
  namespace: ai-tools
spec:
  ai:
    provider:
      openai: {model: gpt-4o-mini}
  policies:
    auth:
      secretRef: {name: openai-secret}      # Secret key "Authorization": "Bearer sk-..."
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-routes
  namespace: ai-tools
spec:
  parentRefs:
    - group: networking.istio.io
      kind: ServiceEntry
      name: myllm
  rules:
    - matches: [{path: {type: PathPrefix, value: /openai}}]
      backendRefs: [{group: agentgateway.dev, kind: AgentgatewayBackend, name: openai}]
```

> **Tested (v2026.9.3, Solo Istio 1.31.1):** `customer-agent` ran `curl http://myllm.com/openai/v1/chat/completions` with no credentials and got a real completion back (`200`, "Pong"); `rogue-agent` got `403` from the identity policy before any egress happened. The waypoint log for the call carried `gen_ai.provider.name=openai`, `gen_ai.request.model`, and token usage counters alongside the caller's SPIFFE identity — per-agent attribution for free.

```mermaid
sequenceDiagram
    participant Agent as Agent pod (no API key)
    participant ZT as ztunnel
    participant WP as agentgateway waypoint
    participant LLM as api.openai.com
    Agent->>ZT: POST http://myllm.com/openai/v1/chat/completions
    ZT->>WP: HBONE (mTLS, SPIFFE identity)
    WP->>WP: authorize caller; pick backend by path; read Secret
    WP->>LLM: TLS + Authorization: Bearer sk-... (+ gen_ai.* telemetry)
    LLM-->>WP: completion
    WP-->>Agent: completion (budget / guardrails can apply here too)
```

---

# Decision Flowchart

## How Should This Request Be Authenticated?

> **Docs:** [Security Overview](https://docs.solo.io/agentgateway/latest/security/) · [OBO & Elicitations](https://docs.solo.io/agentgateway/latest/security/obo-elicitations/) · [External Auth](https://docs.solo.io/agentgateway/latest/security/extauth/) · [MCP Auth](https://docs.solo.io/agentgateway/latest/mcp/auth/about/)
> **API:** [Enterprise API Reference](https://docs.solo.io/agentgateway/latest/reference/api/solo/)

![Decision Flowchart](images/decision-flowchart.png)

---

# Glossary

| Term | Meaning |
|---|---|
| **`act` claim** | An RFC 8693 JWT claim identifying the actor (the agent/service) acting on behalf of the subject. Paired with `sub`. |
| **AuthConfig** | Solo Enterprise CRD (`extauth.solo.io/v1`) describing an external auth flow (OIDC, OAuth2, API key, OPA, etc.) consumed by the Enterprise external auth service. Used by `entExtAuth`. |
| **DCR** | Dynamic Client Registration (RFC 7591). Lets OAuth clients register themselves with an authorization server at runtime instead of via human onboarding. See [Background: DCR and MCP](#background-dynamic-client-registration-and-mcp) for why MCP needs it and where it works. |
| **Eager OAuth** | An OAuth flow that runs **at MCP connect time** — when the client first establishes the MCP session — rather than lazily on each tool call. Once the session is up, every tool call inside it reuses the cached token(s). Contrasts with [Elicitation](#elicitation-enterprise) and [Double OAuth Flow](#double-oauth-flow-oidc--elicitation-enterprise) (lazy: prompt the user when a request needs a fresh token). |
| **Gateway-Brokered DCR** | A workaround for IdPs whose real DCR is impractical at scale (Auth0, Okta — DCR is gated behind their management APIs). The gateway intercepts the DCR call and returns a single pre-registered IdP `client_id`/`client_secret` to every MCP client, instead of forwarding to the IdP. See [MCP OAuth — Gateway-Brokered DCR for Auth0 / Okta](#mcp-oauth--gateway-brokered-dcr-for-auth0--okta-enterprise). |
| **`entExtAuth`** | Enterprise field on `EnterpriseAgentgatewayPolicy.traffic` that delegates auth to the Solo Enterprise external auth service via an `AuthConfig`. |
| **`extAuth`** | OSS field on `AgentgatewayPolicy.traffic` that delegates to a user-supplied gRPC or HTTP service via the Envoy `ext_authz` protocol. |
| **Elicitation** | An agentgateway flow that prompts a user to complete an upstream OAuth authorization out-of-band (in the Solo UI) so the gateway can inject the resulting token on later requests. Enterprise-only. |
| **JWKS** | JSON Web Key Set — the public keys an IdP publishes (typically at `/.well-known/jwks.json`) so receivers can verify JWT signatures. |
| **`may_act` claim** | A JWT claim a user issues authorizing a specific actor (agent) to call services on their behalf. Required by [OBO Delegation](#obo-delegation-dual-identity-enterprise). |
| **MCP** | Model Context Protocol — an open protocol for connecting LLM clients to tool-providing servers. |
| **OBO** | On-Behalf-Of. A pattern (typically via RFC 8693 or Microsoft's `jwt-bearer` grant) where one service exchanges a user token for a token scoped to a downstream resource. |
| **OIDC** | OpenID Connect. An authentication layer on top of OAuth 2.0 that produces an `id_token` (JWT) describing the user. |
| **RFC 7617** | The HTTP Basic Authentication scheme. |
| **RFC 8693** | The OAuth 2.0 Token Exchange spec — the standard for swapping one token for another. |
| **STS** | Security Token Service. The component that issues new tokens during exchange. agentgateway has a built-in STS for OBO flows; Entra ID can act as an external STS. Enterprise-only. |
| **`sub` claim** | The standard JWT claim identifying the subject (user or principal) the token is about. |

