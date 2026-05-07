# Orchet Super Agent

Chat- and voice-first AI assistant. The orchestrator runs a Claude
tool-use loop, dispatches each tool to a specialist agent over HTTP,
and coordinates a small set of backend services behind a public
API gateway.

This monorepo is **mid-split**: the Hybrid topology (per
[`docs/architecture/decisions/007-topology-freeze.md`](docs/architecture/decisions/007-topology-freeze.md))
runs all backend code in one Node process today; the planned split
extracts six independently-deployable repos. Until that split
lands, treat this repo as the canonical source for all six.

## Read first

If you're modifying code:

1. [`docs/architecture/canonical.md`](docs/architecture/canonical.md) — layer rules, dependency direction, port discipline, migration state. **Non-negotiable.**
2. [`docs/architecture/runtime-composition.md`](docs/architecture/runtime-composition.md) — composition roots and the rules that prevent runtime DI chaos. Required reading before any wiring / boot work.
3. [`docs/architecture/decisions/`](docs/architecture/decisions/) — Architecture Decision Records. ADR-007 freezes the topology; new packages, facades, or cross-layer dependencies require a new ADR.
4. [`CLAUDE.md`](CLAUDE.md) — repo-wide guidance for AI agents working in this codebase.

## Layer model

```text
apps/        — clients (Next.js web, SwiftUI iOS, Docusaurus docs)
services/    — runtime shells (Express + wiring; no domain logic)
packages/    — domain logic (transport-agnostic; owns ports)
infra/       — deploy artifacts (Vercel, Azure, env templates)
tools/       — repo tooling (eval harnesses, etc.)
samples/     — reference partner-style sample agents
```

Direction of dependency is one-way:

```text
apps  ─►  services  ─►  packages  ─►  packages
                         (ports)        ▲
                         adapters ──────┘
```

Enforced by `npm run lint:package-deps`.

## What lives where (current state)

### `apps/`

| Subfolder | Role |
| --- | --- |
| `apps/web/` | **Frontend shell only.** Next.js 14 App Router. UI + presenters + gateway HTTP clients. Zero backend imports. The remaining 20 routes under `apps/web/app/api/` are compatibility/liveness only (provider OAuth callbacks, Vercel cron URL forwarders, health probes) — see `docs/architecture/apps-web-file-retirement-inventory.md`. |
| `apps/ios/` | SwiftUI app shell. Production builds talk to the gateway directly via `OrchetGatewayBase`; older builds fall back to `apps/web` BFF (now retired post-iOS-gate cleanup). |
| `apps/docs/` | Docusaurus docs site. Reads docs only. |

### `services/` (all `@orchet/svc-*`)

The public API entrypoint is **`services/gateway/`**. Every external
client (web, iOS, future Android) hits the gateway; the gateway
forwards to the appropriate service. Inter-service communication is
HTTP only, mediated by `@orchet/sdk`.

| Service | Role |
| --- | --- |
| `services/gateway/` | Public HTTPS edge. Header-forwarding, auth, route table. |
| `services/backend/` | Hybrid composition root. Mounts every `@orchet/svc-*` under sub-paths in one Node process. |
| `services/orchestrator/` | HTTP shell + wiring around `@orchet/domain-orchestrator`. Owns `/chat` (SSE) and mission/trip endpoints. |
| `services/integrations/` | LLM/STT/TTS providers, OAuth platforms (Google, Microsoft, Meta, Spotify), payments (Stripe). |
| `services/auth/` | Supabase Auth wrapper, OAuth callbacks, OAuth-token resolver. |
| `services/notifications/` | Notification outbox + transports (push, websocket, console). |
| `services/cron/` | Manifest-driven background jobs. 15 jobs across proactive / missions / marketplace / workspace / cost / kg / developer / docs domains. |
| `services/mcp-client/` | Thin HTTP client to the planned `orchet-mcp` sibling repo (the MCP hub itself doesn't live here). |
| `services/ml-brain/` | Python FastAPI on Modal. Embeddings, classifier, system-prompt port. |

### `packages/`

Domain logic. Each `@orchet/domain-*` package owns one bounded
context, exposes its public API via `package.json#exports`, and
reaches outside the domain only through ports declared in
`src/ports/index.ts`.

| Package | Owns |
| --- | --- |
| `@orchet/domain-orchestrator` | Apex. Claude tool-use loop, tool router, missions, trips, compound dispatch, mesh planner. |
| `@orchet/domain-router` | Perf cluster — model routing, intent classifier, fast-turn streaming. |
| `@orchet/domain-agents` | Agent registry, integrations registry, Duffel `MerchantPort`. |
| `@orchet/domain-integrations` | LLM/STT/TTS provider interfaces + adapters; OAuth platform adapters. |
| `@orchet/domain-memory` | Memory facts, profile, archive recall, knowledge graph. |
| `@orchet/domain-marketplace` | Marketplace catalog, submissions, version intelligence, trust pipeline. |
| `@orchet/domain-auth` | Permissions / runtime-policy / approvals / connections subdomains. |
| `@orchet/domain-notifications` | Notification ports + delivery. |
| `@orchet/domain-observability` | Cost accounting, timing spans, telemetry. |
| `@orchet/domain-autonomy` | Autonomy ports + reasoning. |

Cross-cutting packages:

| Package | Owns |
| --- | --- |
| `@orchet/shared-types` | Pydantic-derived TS types (cross-language wire contracts). |
| `@orchet/shared-utils` | Cross-context primitives (circuit breakers, JWT signing, time helpers). |
| `@orchet/data-access` | Provider-agnostic DB layer. Supabase adapter today; postgres adapter stub. |
| `@orchet/db` | Migrations, seeds, `run-all.sql` builder. |
| `@orchet/sdk` | Typed HTTP client used by `apps/*` and inter-service. |
| `@orchet/agent-sdk` | Author SDK + CLI for partner-built agents. |
| `@orchet/logging` | Structured logging facade with pluggable providers. |

## Repo split target

Per [`docs/architecture/repo-split-plan.md`](docs/architecture/repo-split-plan.md), the monorepo splits into six independently-deployable repos once the in-repo cleanup completes:

| Target repo | Contents | Public? |
| --- | --- | --- |
| `orchet-backend` | `services/*` + `packages/*` + `infra/` + most of `docs/`. Owns the OpenAPI spec and publishes the SDKs. | private |
| `orchet-web` | `apps/web/` + the generated `@orchet/sdk-web` + brand consumed via npm. | private |
| `orchet-ios` | `apps/ios/` + the generated `@orchet/sdk-ios`. | private |
| `orchet-android` | Stub at split time; mirrors the iOS shape. | private |
| `orchet-mcp` | Standalone MCP hub. `services/mcp-client/` reaches it via HTTP. | private |
| `orchet-brand` | Tailwind theme tokens, `OrchetLockup`/`BrandMark`, brand SVGs, design tokens. Published as `@orchet/brand` to a private npm registry. | private npm |

Pre-split gates and the deletion order are tracked in
[`docs/architecture/compatibility-deletion-runbook.md`](docs/architecture/compatibility-deletion-runbook.md).

## Run locally

```bash
npm install
npm run dev           # apps/web on http://localhost:3000
```

Backend services run from `services/backend` in the Hybrid
composition (single process, multiple sub-paths) for end-to-end
smoke runs. Standalone-boot of individual services is partial today
(see `canonical.md` for status).

The chat flow exercises the gateway → orchestrator → router → agent
path. Money-moving tools are gated by a confirmation hash; the SDK's
`hashSummary()` is the single place that hash is computed, so the
agent and shell cannot drift.

## Operational posture

- **Kill-switch per agent.** Flip `enabled: false` in
  `packages/domain-agents/src/config/agents.registry*.json`,
  redeploy — that agent stops being offered to Claude on next cold
  start.
- **Health degradation.** The agent registry polls each agent's
  health URL. Score below threshold → silently dropped from the
  system prompt until it recovers.
- **Circuit breaker.** Per-agent breaker in `@orchet/shared-utils`.
  Consecutive failures trip; further calls return `upstream_error`
  for N seconds without touching the agent.

## Deploy

- **`apps/web`** → Vercel (Next.js). Root `vercel.json` is the apps/web
  config.
- **`services/*`** → Vercel functions today (per `infra/vercel/`)
  with Azure Container Apps as the planned long-term target (per
  `infra/azure/main.bicep`). Hybrid topology runs all svc-* in one
  deploy unit; the per-service `createXApp()` factories let each
  one extract independently when needed.
- **`services/ml-brain`** → Modal (Python FastAPI). Separate deploy.

Per-service env templates live in [`infra/env/`](infra/env/).

## Setup

For Supabase setup (one-time, ~15 minutes), see
[`SUPABASE_SETUP.md`](SUPABASE_SETUP.md).

## Branding

New code uses **Orchet** branding (`@orchet/*`, `ORCHET_*`,
`orchet-*`). Existing prod env vars (`LUMO_*`) and persisted IDs
(`lumo-flights`, etc.) stay until coordinated ops migrations — see
[`docs/architecture/lumo-to-orchet-remaining-references.md`](docs/architecture/lumo-to-orchet-remaining-references.md).

## Related repos

- The MCP hub will live in a sibling repo (`orchet-mcp`); the
  in-repo `services/mcp-client/` is a thin HTTP client.
- The author SDK is `@orchet/agent-sdk` (formerly `@lumo/agent-sdk`).

## Help / feedback

- File issues against this repo with the `architecture` or `bug`
  labels as appropriate.
- For docs gaps, see `docs/architecture/README.md` for the
  capability index.
