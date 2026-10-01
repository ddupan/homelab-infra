#!/usr/bin/env python3
"""Gitea workflow_job webhook to NATS JetStream producer."""

import hashlib
import hmac
import json
import os
import ssl
from pathlib import Path

import nats
from aiohttp import web
from nats.js.api import DiscardPolicy, RetentionPolicy, StorageType, StreamConfig
from nats.js.errors import NotFoundError

LABEL = os.environ.get("RUNNER_LABEL", "kind-microvm")
SUBJECT = os.environ.get("NATS_SUBJECT", f"ci.runner.{LABEL}")
STREAM = os.environ.get("NATS_STREAM", "CI_RUNNER")
NATS_URL = os.environ.get("NATS_URL", "tls://nats.nats.svc.cluster.local:4222")
NATS_USER = os.environ.get("NATS_USER", "ci-producer")
NATS_PASSWORD_FILE = Path(os.environ.get("NATS_PASSWORD_FILE", "/run/secrets/nats/password"))
NATS_CA_FILE = os.environ.get("NATS_CA_FILE", "/etc/ssl/certs/ca-certificates.crt")
WEBHOOK_SECRET_FILE = Path(os.environ.get("WEBHOOK_SECRET_FILE", "/run/secrets/gitea/webhook-secret"))


def accepts(payload: object) -> tuple[bool, str | None]:
    if not isinstance(payload, dict) or payload.get("action") != "queued":
        return False, None
    job = payload.get("workflow_job")
    if not isinstance(job, dict) or LABEL not in job.get("labels", []):
        return False, None
    job_id = job.get("id")
    if not isinstance(job_id, int):
        return False, None
    return True, str(job_id)


def valid_signature(body: bytes, signature: str) -> bool:
    expected = hmac.new(WEBHOOK_SECRET_FILE.read_bytes().strip(), body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)


async def ensure_stream(js: object) -> None:
    config = StreamConfig(
        name=STREAM,
        subjects=["ci.runner.*"],
        retention=RetentionPolicy.WORK_QUEUE,
        storage=StorageType.FILE,
        discard=DiscardPolicy.OLD,
        max_age=24 * 60 * 60,
        max_msgs=10_000,
        max_bytes=256 * 1024 * 1024,
        duplicate_window=24 * 60 * 60,
    )
    try:
        await js.stream_info(STREAM)
    except NotFoundError:
        await js.add_stream(config=config)
    else:
        await js.update_stream(config=config)


async def webhook(request: web.Request) -> web.Response:
    body = await request.read()
    if not valid_signature(body, request.headers.get("X-Gitea-Signature", "")):
        raise web.HTTPUnauthorized()
    try:
        payload = json.loads(body)
    except json.JSONDecodeError as error:
        raise web.HTTPBadRequest(text="invalid JSON\n") from error
    accepted, job_id = accepts(payload)
    if not accepted:
        return web.Response(status=204)
    await request.app["js"].publish(
        SUBJECT,
        body,
        headers={"Nats-Msg-Id": f"gitea-workflow-job-{job_id}"},
    )
    return web.Response(status=202, text="queued\n")


async def health(request: web.Request) -> web.Response:
    return web.Response(text="ok\n" if request.app["nc"].is_connected else "disconnected\n",
                        status=200 if request.app["nc"].is_connected else 503)


async def nats_context(app: web.Application):
    tls = ssl.create_default_context(cafile=NATS_CA_FILE)
    nc = await nats.connect(
        NATS_URL,
        user=NATS_USER,
        password=NATS_PASSWORD_FILE.read_text().strip(),
        tls=tls,
        name="microvm-runner-controller",
    )
    app["nc"] = nc
    app["js"] = nc.jetstream()
    await ensure_stream(app["js"])
    yield
    await nc.drain()


def create_app() -> web.Application:
    app = web.Application(client_max_size=1024 * 1024)
    app.cleanup_ctx.append(nats_context)
    app.router.add_post("/webhook", webhook)
    app.router.add_get("/healthz", health)
    return app


if __name__ == "__main__":
    web.run_app(create_app(), host=os.environ.get("LISTEN", "0.0.0.0"),
                port=int(os.environ.get("PORT", "8787")))
