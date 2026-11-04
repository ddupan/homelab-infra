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

## Anthropic credential: Workload Identity Federation

No `sk-ant-` key exists. CronJob `anthropic-wif` swaps a SPIRE JWT-SVID for a 1-hour access
token every 15 minutes (`anthropic-wif.yaml`, Console setup in its header). Anthropic verifies
it against the public JWKS copy at `https://spire-oidc.ddupan.top/keys`. Usage is billed to the
rule's workspace exactly like an API key, so the credit grant applies.

- Refresh now (first deploy, or after fixing the Console side):
  `kubectl -n ai-gateway create job --from=cronjob/anthropic-wif wif-manual`
- Exchange fails with 401: the Console's *authentication history* tab says why. A signature
  error usually means `https://spire-oidc.ddupan.top/keys` is unreachable from outside, so
  Anthropic cannot see SPIRE's rotated keys.

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

## Gateway keys

Issue and revoke them at **https://ai-keys.lab.ddupan.top** (platform-admins; `keys-ui.yaml`,
code in `panxiao81/ai-gateway-keys`). It shows who created each key and when, when it was last
used, and 30-day requests/tokens (Agent Router metrics, `podmonitor.yaml`). A key is shown once;
names are never reused.

Behind it, one Bao secret per key at `kv/k8s/ai-gateway-keys/<id>`, field `key`, with
`custom_metadata` `status`/`created_by`/`description`/`revoked_*`. ESO passes only
`status=active` keys to the gateway (`external-secret.yaml`); revoking destroys the key's
versions and keeps the metadata. Upstream sees the client as `x-ai-client: <id>`.

## Other secrets (Bao)

| path | property | what |
|---|---|---|
| `kv/k8s/ai-gateway` | `cliproxyapi_api_key` | shared secret between the ai Envoy and CLIProxyAPI; random, rotate freely |
| `kv/k8s/ai-gateway-keys-sso` | `client_id`, `client_secret` | key UI's iam-login client (written by `apps/iam-login/terraform`) |
| `kv/k8s/ai-gateway-keys-session` | `session_secret` | signs the key UI's login cookie; rotating it logs everyone out |
