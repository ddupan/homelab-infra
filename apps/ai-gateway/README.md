# AI gateway

`https://ai.lab.ddupan.top` — one endpoint and per-client keys in front of LLM providers, so
provider credentials never leave the cluster and a client can be revoked without rotating them.

Provider today: **Anthropic**, paid from the Console credit grant (US$100, refreshed monthly;
covers API, Batch, Agent SDK). Cap spend in the Console, not here — there is no rate limiting.

## Using it

```bash
export ANTHROPIC_BASE_URL=https://ai.lab.ddupan.top/anthropic
export ANTHROPIC_API_KEY=<your gateway key>   # NOT an Anthropic key
```

OpenAI-compatible clients: base URL `https://ai.lab.ddupan.top/v1`, but the key must still
go in an `x-api-key` header — `Authorization: Bearer` is not checked.

## How it fits

```
client ─TLS─▶ eg (LAN ingress) ── apiKeyAuth ──▶ Gateway `ai` (Envoy + ext_proc) ─TLS─▶ api.anthropic.com
              httproute.yaml                      gateway.yaml, anthropic.yaml
```

- Control plane: Agent Router (formerly Envoy AI Gateway),
  `../../platform/envoy-gateway/agent-router.yaml`. Envoy Gateway calls it on every xDS
  translation with `failOpen: true`.
- Gateway `ai` is separate from `eg` on purpose: Agent Router's pod webhook fails closed, so it
  is scoped to `ai`'s Envoy pods and can never block a rollout of the LAN ingress.

## Keys (Bao)

| path | property | what |
|---|---|---|
| `kv/k8s/ai-gateway` | `anthropic_api_key` | Console key; write it yourself, no one else handles it |
| `kv/k8s/ai-gateway-clients` | `<client-id>` | one gateway key per client; property name = client ID |

Add a client: `bao kv patch kv/k8s/ai-gateway-clients <id>=$(openssl rand -hex 24)`.
Revoke: `bao kv patch` the property away. ESO syncs within 5 minutes. Upstream sees the client
as `x-ai-client: <id>`.
