# AI gateway

`https://ai.lab.ddupan.top` — one endpoint and per-client keys in front of LLM providers, so
provider credentials never leave the cluster and a client can be revoked without rotating them.

Providers, picked by model name (`anthropic.yaml`):

| model | backend | paid by |
|---|---|---|
| `gpt-*`, `o<n>*`, `codex-*` | CLIProxyAPI (`cliproxyapi.yaml`) | ChatGPT Plus subscription |
| anything else | Anthropic API | Console credit grant (US$100, refreshed monthly) |

Cap Anthropic spend in the Console, not here — there is no rate limiting. The ChatGPT side is
bounded by the Plus plan's own usage limits.

## Using it

```bash
export ANTHROPIC_BASE_URL=https://ai.lab.ddupan.top/anthropic
export ANTHROPIC_API_KEY=<your gateway key>   # NOT an Anthropic key
```

OpenAI-compatible clients (both providers): base URL `https://ai.lab.ddupan.top/v1`, but the
key must still go in an `x-api-key` header — `Authorization: Bearer` is not checked.

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

## ChatGPT login (CLIProxyAPI)

The Codex OAuth credential lives on the `cliproxyapi-auth` PVC, not in Bao — CLIProxyAPI
refreshes and rewrites it. Log in once, and again whenever `/v1/models` lists no `gpt-*`:

```bash
# Device-code flow: open the printed URL in any browser, enter the code.
# Run under a PTY — the code never shows when output is piped (CLAUDE.md).
kubectl --context default -n ai-gateway exec -it deploy/cliproxyapi -- \
  ./CLIProxyAPI -config /etc/cliproxyapi/config.yaml -codex-device-login
```

The running server watches `/data/auths` and picks the new credential up without a restart.

## Keys (Bao)

| path | property | what |
|---|---|---|
| `kv/k8s/ai-gateway` | `anthropic_api_key` | Console key; write it yourself, no one else handles it |
| `kv/k8s/ai-gateway` | `cliproxyapi_api_key` | shared secret between the ai Envoy and CLIProxyAPI; random, rotate freely |
| `kv/k8s/ai-gateway-clients` | `<client-id>` | one gateway key per client; property name = client ID |

Add a client: `bao kv patch kv/k8s/ai-gateway-clients <id>=$(openssl rand -hex 24)`.
Revoke: `bao kv patch` the property away. ESO syncs within 5 minutes. Upstream sees the client
as `x-ai-client: <id>`.
