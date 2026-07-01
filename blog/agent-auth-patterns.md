# Auth for AI Agents: What Actually Changes

Lately I've been spending entire customer meetings on a topic that used to be a checkbox: authentication. The fundamentals haven't moved — a service still needs to know *who are you* and *what are you allowed to do*. What changed is that AI agents broke almost every assumption we used to lean on to answer those two questions.

For years the model was simple. A human opens a browser, logs in, the app gets a token, done. Agents blow that up in three specific ways. Here's what's new, why you should care, and where a gateway earns its keep.

![agentgateway brokers identity inbound and outbound](img/header.png)

*A gateway sits between your clients and your destinations and brokers identity in both directions — inbound (who's calling) and outbound (how we reach the next thing).*

## 1. The client isn't a person anymore

In the old world there was one client — the browser or app — and you registered it with your IdP once, by hand. With agents, the user isn't the one making the call. They're using Claude, Cursor, VS Code, or some in-house agent, and *each of those is its own OAuth client*. Every developer has several, and they change constantly. You can't pre-register them all manually.

OAuth has an answer: **Dynamic Client Registration** (DCR, RFC 7591). A client hits a `/register` endpoint, gets its own `client_id`, and runs the normal login flow. The catch — and it's a big one — is that the IdPs most enterprises actually run (Okta, Entra, Auth0) don't expose open DCR. So you're left with two real options:

![Real DCR with a custom authorization server vs. fake DCR with the gateway](img/dcr.png)

- **Build your own authorization server** that does real DCR and brokers login to your IdP. Each client gets a unique `client_id`, so you can identify and revoke them individually. We run one of these for our own MCP servers at Solo. It works, but now you're operating an authorization server.
- **Let the gateway fake it.** The gateway exposes the `/register` endpoint your IdP won't, hands every client a single pre-registered `client_id`, and brokers the real login upstream. Nothing to build.

"Fake DCR" sounds sketchy until you see what it actually fakes: only the *registration* step. Every user still gets redirected to the real IdP and logs in as themselves, so per-user identity is fully preserved. What you give up is per-client distinction — to the IdP, the whole fleet looks like one app. For most teams that's a fine trade to avoid standing up an auth server.

## 2. The agent acts on your behalf — don't hand it your token

Agentic workflows are multi-hop. You talk to an app, it calls an agent, that agent calls another agent or an MCP server. The token you logged in with is *broad* — it represents everything you're allowed to do, for an hour or more.

If you blindly pass that token down the chain, every hop is now holding credentials that can act as you, anywhere, until they expire. One compromised or sloppy agent and your whole identity is exposed. You don't want that.

![Token exchange scopes a broad user token down before an agent ever sees it](img/token-exchange.png)

The fix is **token exchange** (RFC 8693): before an agent ever touches it, swap the broad token for a fresh one that's scoped down. Change the issuer to something you control, trim the groups to just what this task needs, and cut the lifetime from an hour to a minute. There are two flavors worth knowing:

- **Impersonation** — the new token still says it's you (`sub: alice`), just narrower and short-lived. Downstream, it looks like the user did it.
- **Delegation** — the token keeps the user *and* records who's acting via an `act` claim ("Agent 1, on behalf of Alice"). Now you can write policy on the real chain: *Agent 1 may call Agent 2 when acting for a user in engineering.*

Either way, the agent never holds your original IdP token. That's the whole point.

## 3. Agents call other people's APIs — as you

Your agent doesn't only touch your systems. It calls GitHub, Jira, Snowflake, Salesforce on your behalf — and each of those is its own identity domain with its own OAuth. A shared service key won't do, because the agent has to act as *you* over there, not as some generic app.

So something has to gather a per-user token for each provider, on demand. That's **elicitation**: when a call needs an upstream credential the gateway doesn't have yet, it interrupts, sends you off to authorize that provider, stores the resulting token, and injects it on future calls.

![Eager vs lazy elicitation across multiple upstream providers](img/elicitation.png)

There are two timing models:

- **Eager** — authorize everything up front, at connect time. You log in to your IdP, then immediately to GitHub, Snowflake, and so on. A few logins once, then it just works.
- **Lazy** — defer it. The first time a tool actually needs GitHub, the gateway hands back a pending authorization URL you complete whenever you get to it, even asynchronously. Nothing prompts you until a call genuinely needs it.

Which one fits depends on the server. A GitHub-style server with a fixed set of tools can be lazy. A server like Snowflake that builds its tool list *from your account* needs the credential just to show you what's available — so it's effectively eager whether you call it that or not.

## Where this leaves you

None of these are exotic. They're the natural consequence of three shifts: the client became a fleet of agents, those agents act on your behalf across multiple hops, and they reach into systems that each have their own identity. Registration, token exchange, and elicitation are just the patterns that fall out of that.

The reason a gateway keeps showing up is that it's the one place that sits in the path both ways. It can fake DCR in front of an IdP that won't do it, swap a broad token for a scoped one before an agent ever sees it, and gather per-user upstream credentials on demand — without baking any of that into every app and agent you run.

If you want the implementation detail — the exact flows, the config, the trade-offs per IdP — that's all in the [agentgateway docs](https://docs.solo.io/agentgateway/). But the patterns above are the part worth carrying into your next architecture conversation. Once you can name them, the rest is just wiring.
