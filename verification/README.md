# Verification harness

Everything in the top-level README was exercised against a live cluster on **2026-10-08**:

| Component | Version |
|---|---|
| Solo Enterprise for agentgateway (controller + data plane) | v2026.9.3 |
| Gateway API CRDs | v1.5.0 (standard channel) |
| Solo Istio ambient (for the waypoint patterns) | 1.31.1-solo |
| IdP | Keycloak 26.5.2, deployed in-cluster and served through the test gateway at `/keycloak` |
| Kubernetes | GKE 1.35 |

The scripts in `tests/` are the exact checks that were run. `results/` holds their output. They are
not a polished test suite — they are curl-driven, one file per pattern, and they print `PASS`/`FAIL`
lines plus the raw evidence (tokens, headers, metadata documents) that the README's **Tested** notes
quote. Patterns that needed credentials we did not have (Okta, Microsoft Entra, a GitHub OAuth app) were
only validated against the installed CRD schema with `kubectl apply --dry-run=server` (`13-dryrun.sh`).

## Layout

| Path | What it does |
|---|---|
| `setup.sh` | Creates namespace `authtest`, a dedicated `Gateway` (`authtest-gw`), Keycloak + Postgres, httpbin, an MCP server (`server-everything`), an MCP header-echo server, HTTP and gRPC ext-authz servers, TLS material, and one `HTTPRoute` per pattern. |
| `tests/keycloak-setup.py` | Creates realms `authtest` and `upstream` (users `alice`/`bob`, confidential client `agw`, audience/`tier`/`role`/`may_act` mappers, anonymous DCR allowed). Needs `kubectl port-forward -n authtest svc/keycloak 18080:8080`. |
| `tests/lib.sh` | Shared helpers (`expect`, `expect_body`, `mint` for locally signed JWTs, `wait_policy`). |
| `keys/mint.py` | Generates an RSA key + JWKS once and mints JWTs with arbitrary claims (used for inline-JWKS and STS subject tokens). |
| `tests/01-apikey.sh` … `tests/06-upstream.sh` | OSS inbound and outbound patterns. |
| `tests/07-mcp-oauth.sh`, `07b-mcp-auth0.sh` | MCP OAuth + DCR with Keycloak (full DCR + PKCE flow) and the Auth0 adapter. |
| `tests/08-sts-obo.sh` | RFC 8693 at the STS endpoint: impersonation, delegation, nested `act`, `may_act` enforcement. |
| `tests/09-*.sh` | Inline `backend.tokenExchange: ExchangeOnly` and the OSS `backend.auth.oauthTokenExchange` client. |
| `tests/10*-oidc*.sh` | Enterprise ext-auth OIDC (`AuthConfig`) and its combination with token exchange. |
| `tests/11-brokered-dcr.sh`, `12-brokered-dual.sh`, `16-typed-elicit.sh` | Gateway-brokered DCR (downstream-only) and brokered dual OAuth with a second Keycloak realm as the "upstream SaaS provider". |
| `tests/14-*`, `15-*` | Interactive elicitation (legacy and typed fields) and the `STS_URI` mode switch. |
| `tests/20-waypoint.sh` | Ambient waypoint: SPIFFE identity authorization, identity propagation, LLM egress with injected credentials (namespace `authtest-mesh`). |

## Cluster-side prerequisites that are not in `setup.sh`

The Enterprise token-exchange patterns need Helm values on the `enterprise-agentgateway` release. The
values used are summarised in the README sections; in short: `tokenExchange.enabled`, a
`subjectValidators` list (a static key for the locally minted JWTs plus a `remote` Keycloak JWKS entry),
`actorValidators`/`apiValidators` of type `k8s`, `controller.extraEnv.KGW_OAUTH_ISSUER_CONFIG` for the
brokered flows, and `istio.autoEnabled=true` (plus `istio.network`/`istio.clusterId` if your ztunnel
is configured with a network) for the waypoint patterns.

## Running

```bash
./setup.sh
kubectl port-forward -n authtest svc/keycloak 18080:8080 &
python3 -I tests/keycloak-setup.py
./tests/01-apikey.sh      # etc.
```

Each script applies its own policies, so run them one at a time. A few `FAIL` lines are expected and
deliberate: several scripts first apply an earlier draft of the README YAML to confirm which field
names the current API accepts before applying the shape now shown in the README.
