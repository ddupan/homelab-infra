# OpenViking (Docker)

This folder contains a Docker Compose setup for OpenViking using the official image.

## What this setup assumes

- VLM provider: `openai-codex`
- Embedding model family: `jina-embeddings-v5-text-small-clustering`
- Embedding server: local OpenAI-compatible endpoint powered by `llama.cpp` CUDA12 image
- Persistent OpenViking data lives in `./data`
- Persistent embedding model cache lives in `./models` (mounted to Hugging Face cache)
- HTTP API is exposed on `1933`
- Console/UI is exposed on `8020`
- Local embedding endpoint is exposed on `127.0.0.1:8081`

## Files

- `docker-compose.yml` — the container definition
- `.env.example` — optional port/bot defaults
- `ov.conf.example` — configuration example using local Jina embeddings + Codex VLM
- `ovcli.conf.example` — CLI/client config example

## Setup

1. Copy the env template:

```bash
cp .env.example .env
```

2. Create the persistent directories and copy the config examples:

```bash
mkdir -p data models
cp ov.conf.example data/ov.conf
cp ovcli.conf.example data/ovcli.conf
mkdir -p data/workspace
```

3. Start the containers:

```bash
docker compose up -d
```

4. If Codex auth is not yet available, complete the login/import step inside the OpenViking container:

```bash
docker compose exec -it openviking openviking-server init
```

5. Verify the server:

```bash
docker compose exec -it openviking openviking-server doctor
curl http://localhost:1933/health
```

## Notes

- The embedding service uses the Jina v5 omni small text-matching GGUF model and serves an OpenAI-compatible `/v1` API locally.
- `provider: "openai"` is used in `ov.conf` because the embedding endpoint is OpenAI-compatible, even though the underlying model is Jina.
- `provider: "openai-codex"` does not require `vlm.api_key` once Codex OAuth is available through `openviking-server init`.
- If you want the bundled VikingBot disabled, set `OPENVIKING_WITH_BOT=0` in `.env`.
- The first startup can take a while because the Jina model must be downloaded into `./models`.
