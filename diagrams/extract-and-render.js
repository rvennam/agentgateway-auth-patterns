// Extract mermaid sequence diagrams from README + add new ones for added patterns,
// then render each to a brand-themed PNG via mmdc.
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const ROOT = path.resolve(__dirname, "..");
const DIA = __dirname;
const README = fs.readFileSync(path.join(ROOT, "README.md"), "utf8");

// Section title (rough h2 string) -> output slug
const README_PATTERNS = [
  { match: "API Key Auth", slug: "api-key" },
  { match: "Basic Auth (RFC 7617)", slug: "basic-auth" },
  { match: "BYO External Auth (gRPC ext_authz)", slug: "byo-extauth" },
  { match: "Standard OIDC / JWT Authentication", slug: "oidc-jwt" },
  { match: "FrontendTLS (mTLS) + BackendTLS", slug: "mtls" },
  { match: "MCP OAuth with Dynamic Client Registration", slug: "mcp-dcr" },
  { match: "Brokered OAuth Issuer — Downstream-Only and Chained", slug: "mcp-fake-dcr" },
  { match: "Gateway-Mediated OIDC + Token Exchange", slug: "gw-oidc-exchange" },
  { match: "OBO Delegation (Dual Identity)", slug: "obo-delegation" },
  { match: "OBO Impersonation (Token Swap)", slug: "obo-impersonation" },
  { match: "Double OAuth Flow (OIDC + Elicitation)", slug: "double-oauth" },
  { match: "Passthrough Token", slug: "passthrough" },
  { match: "Static Secret Injection (Shared Credential)", slug: "static-secret" },
  { match: "Claim-Based Token Mapping", slug: "claim-based" },
  { match: "Elicitation `[Enterprise]`", slug: "elicitation" }
];

function extractFirstMermaidAfter(heading) {
  const idx = README.indexOf("## " + heading);
  if (idx < 0) {
    console.warn("not found:", heading);
    return null;
  }
  const after = README.slice(idx);
  const m = after.match(/```mermaid\n([\s\S]*?)\n```/);
  return m ? m[1] : null;
}

// Pull diagrams from README
const diagrams = {};
for (const p of README_PATTERNS) {
  const d = extractFirstMermaidAfter(p.match);
  if (d) diagrams[p.slug] = d;
}

// New patterns (not in README) — author concise sequence diagrams
diagrams["multi-header"] = `sequenceDiagram
    actor Client
    participant GW as Agent Gateway
    participant Auth as Auth Layers
    participant Backend
    Client->>GW: Authorization: Bearer JWT<br/>X-Api-Key: tenant-key
    GW->>Auth: 1) jwtAuthentication (Authorization)
    GW->>Auth: 2) apiKeyAuthentication (X-Api-Key)
    alt all layers pass
        Auth-->>GW: ALLOW (claims + key metadata)
        GW->>Backend: Forward request
        Backend-->>GW: Response
        GW-->>Client: Response
    else any layer fails
        Auth--xGW: 401
        GW-->>Client: 401 Unauthorized
    end`;

diagrams["rbac-mcp"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant MCP as MCP Tool Server
    User->>GW: Call MCP tool + JWT
    GW->>GW: Validate JWT → extract claims (sub, groups, tier)
    GW->>GW: Evaluate CEL per-tool policy<br/>(e.g. jwt.groups.exists(g, g=='admin'))
    alt CEL allows
        GW->>MCP: Invoke tool
        MCP-->>GW: Result
        GW-->>User: Result
    else CEL denies
        GW-->>User: 403 Forbidden
    end`;

diagrams["rbac-llm"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant LLM as LLM Backend
    User->>GW: POST /v1/chat/completions + JWT
    GW->>GW: Validate JWT → claims (tier, groups)
    GW->>GW: Per-route CEL<br/>(e.g. jwt.tier == 'paid')
    alt allow
        GW->>LLM: Forward to GPT-4 / Bedrock / Gemini
        LLM-->>GW: Completion
        GW-->>User: Completion
    else deny
        GW-->>User: 403 Forbidden
    end`;

diagrams["rate-limit-llm"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant Redis
    participant LLM as LLM Backend
    User->>GW: POST /v1/chat/completions + JWT
    GW->>GW: CEL descriptor = jwt.sub
    GW->>Redis: INCR counter for (jwt.sub, window)
    Redis-->>GW: current count
    alt under limit
        GW->>LLM: Forward request
        LLM-->>GW: Completion + token usage
        GW->>Redis: INCR token counter
        GW-->>User: Completion
    else over limit
        GW-->>User: 429 + Retry-After
    end`;

diagrams["rate-limit-mcp"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant Redis
    participant MCP as MCP Tool Server
    User->>GW: Call MCP tool + JWT
    GW->>GW: CEL descriptor = (jwt.sub, tool_name)
    GW->>Redis: INCR (descriptor, window)
    alt under limit
        GW->>MCP: Invoke tool
        MCP-->>GW: Result
        GW-->>User: Result
    else over limit
        GW-->>User: 429 + Retry-After
    end`;

diagrams["regex-guardrail"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant LLM
    User->>GW: Prompt: "ssn 123-45-6789"
    GW->>GW: Regex match on body
    alt matches REJECT pattern
        GW-->>User: 400 — Blocked by guardrail
    else matches MASK pattern
        GW->>GW: Replace match with [REDACTED]
        GW->>LLM: Forward sanitized prompt
        LLM-->>GW: Completion
        GW-->>User: Completion
    else no match
        GW->>LLM: Forward prompt
        LLM-->>GW: Completion
        GW-->>User: Completion
    end`;

diagrams["moderation-guardrail"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant Mod as OpenAI Moderation API
    participant LLM
    User->>GW: Prompt
    GW->>Mod: POST /moderations with prompt
    Mod-->>GW: Per-category scores
    alt any category over threshold
        GW-->>User: 400 — Content blocked
    else all under threshold
        GW->>LLM: Forward prompt
        LLM-->>GW: Completion
        GW->>Mod: (optional) Moderate response
        GW-->>User: Completion
    end`;

diagrams["bedrock-guardrail"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant Bedrock as AWS Bedrock Guardrails
    participant LLM
    User->>GW: Prompt
    GW->>Bedrock: ApplyGuardrail(id, version, content)
    Bedrock-->>GW: GUARDRAIL_INTERVENED or NONE
    alt INTERVENED
        GW-->>User: 400 — Blocked
    else NONE
        GW->>LLM: Forward prompt
        LLM-->>GW: Completion
        GW-->>User: Completion
    end`;

diagrams["model-armor-guardrail"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant MA as GCP Model Armor
    participant LLM
    User->>GW: Prompt
    GW->>MA: SanitizeUserPrompt(template, content)
    MA-->>GW: BLOCK or ALLOW + findings
    alt BLOCK
        GW-->>User: 400 — Blocked (jailbreak / injection)
    else ALLOW
        GW->>LLM: Forward prompt
        LLM-->>GW: Completion
        GW->>MA: SanitizeModelResponse (optional)
        GW-->>User: Completion
    end`;

diagrams["webhook-guardrail"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant WH as Your Webhook<br/>(OPA / OpenFGA / custom)
    participant LLM
    User->>GW: Prompt or response body
    GW->>WH: POST guardRequest
    WH-->>GW: guardResponse: ALLOW / REJECT / MASK
    alt ALLOW
        GW->>LLM: Forward
        LLM-->>GW: Result
        GW-->>User: Result
    else MASK
        GW->>GW: Replace body with sanitized version
        GW->>LLM: Forward sanitized
        LLM-->>GW: Result
        GW-->>User: Result
    else REJECT
        GW-->>User: 400 + custom message
    end`;

diagrams["multi-layer-guardrail"] = `sequenceDiagram
    actor User
    participant GW as Agent Gateway
    participant Regex
    participant Mod as Moderation
    participant WH as Webhook
    participant LLM
    User->>GW: Prompt
    GW->>Regex: Check + maybe MASK
    Regex-->>GW: Sanitized body
    GW->>Mod: Check sanitized body
    alt Mod REJECT
        GW-->>User: 400 — Blocked
    else Mod ALLOW
        GW->>WH: Custom checks
        alt WH REJECT
            GW-->>User: 400 — Blocked
        else WH ALLOW
            GW->>LLM: Forward
            LLM-->>GW: Result
            GW-->>User: Result
        end
    end`;

diagrams["cors"] = `sequenceDiagram
    participant Browser as Browser SPA
    participant GW as Agent Gateway
    participant Backend
    Note over Browser: Cross-origin call to gateway
    Browser->>GW: OPTIONS /api (preflight)<br/>Origin: app.example.com
    GW->>GW: Check Origin against allowOrigins
    alt allowed
        GW-->>Browser: 200 + Access-Control-Allow-*
        Browser->>GW: Actual request (e.g. POST /api)
        GW->>Backend: Forward
        Backend-->>GW: Response
        GW-->>Browser: Response
    else not allowed
        GW-->>Browser: 200 (no CORS headers)
        Note over Browser: Browser blocks the actual request
    end`;

// Variant B for Gateway-Mediated — extract second mermaid block of that section
{
  const idx = README.indexOf("### Variant B: External STS");
  if (idx >= 0) {
    const after = README.slice(idx);
    const m = after.match(/```mermaid\n([\s\S]*?)\n```/);
    if (m) diagrams["gw-oidc-exchange-variant-b"] = m[1];
  }
}

const themePath = path.join(DIA, "_theme.json");
const puppPath = path.join(DIA, "_puppeteer.json");

let ok = 0, fail = 0;
for (const [slug, src] of Object.entries(diagrams)) {
  const mmd = path.join(DIA, slug + ".mmd");
  const png = path.join(DIA, slug + ".png");
  fs.writeFileSync(mmd, src);
  try {
    execSync(
      `npx --yes --package=@mermaid-js/mermaid-cli mmdc -i "${mmd}" -o "${png}" -c "${themePath}" -p "${puppPath}" -b "#151927" -w 1600 -H 900 -s 2`,
      { stdio: "pipe" }
    );
    ok++;
    process.stdout.write(".");
  } catch (e) {
    fail++;
    console.error("\nFAIL", slug, e.message.split("\n")[0]);
  }
}
console.log(`\nRendered ${ok} OK, ${fail} failed of ${Object.keys(diagrams).length}.`);
