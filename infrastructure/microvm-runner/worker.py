#!/usr/bin/env python3
"""Capacity-bounded JetStream consumer that launches one ephemeral VM per job."""

import asyncio
import os
import secrets
import ssl
import uuid
from pathlib import Path

import nats
from aiohttp import web
from nats.errors import TimeoutError
from nats.js.api import AckPolicy, ConsumerConfig

CAPACITY = int(os.environ.get("RUNNER_CAPACITY", "1"))
SUBJECT = os.environ.get("NATS_SUBJECT", "ci.runner.kind-microvm")
STREAM = os.environ.get("NATS_STREAM", "CI_RUNNER")
DURABLE = os.environ.get("NATS_DURABLE", "kind-microvm")
MAX_INFLIGHT = int(os.environ.get("RUNNER_MAX_INFLIGHT", "64"))
NATS_URL = os.environ.get("NATS_URL", "tls://nats.ad.ddupan.top:4222")
NATS_USER = os.environ.get("NATS_USER", "ci-worker")
NATS_PASSWORD_FILE = Path(os.environ.get("NATS_PASSWORD_FILE", "/etc/microvm-runner/nats-password"))
NATS_CA_FILE = os.environ.get("NATS_CA_FILE", "/etc/ssl/certs/ca-certificates.crt")
REGISTRATION_TOKEN_FILE = Path(os.environ.get("REGISTRATION_TOKEN_FILE", "/etc/microvm-runner/registration-token"))
LAUNCHER = os.environ.get("LAUNCHER", "/usr/local/libexec/microvm-runner-launch")
TOKEN_LISTEN = os.environ.get("TOKEN_LISTEN", "172.30.0.1")
TOKEN_PORT = int(os.environ.get("TOKEN_PORT", "8787"))

tokens: dict[str, bytes] = {}
token_lock = asyncio.Lock()


async def token(request: web.Request) -> web.Response:
    nonce = request.match_info["nonce"]
    async with token_lock:
        value = tokens.pop(nonce, None)
    if value is None:
        raise web.HTTPNotFound()
    return web.Response(body=value, headers={"Cache-Control": "no-store"})


async def heartbeat(message: object, stop: asyncio.Event) -> None:
    while True:
        try:
            await asyncio.wait_for(stop.wait(), timeout=60)
            return
        except asyncio.TimeoutError:
            await message.in_progress()


async def run_one(message: object) -> None:
    instance_id = str(uuid.uuid4())
    nonce = secrets.token_urlsafe(32)
    async with token_lock:
        tokens[nonce] = REGISTRATION_TOKEN_FILE.read_bytes().strip()
    stop = asyncio.Event()
    pulse = asyncio.create_task(heartbeat(message, stop))
    try:
        process = await asyncio.create_subprocess_exec(LAUNCHER, instance_id, nonce)
        return_code = await process.wait()
        if return_code == 0:
            await message.ack()
        else:
            await message.nak(delay=30)
    except Exception:
        await message.nak(delay=30)
        raise
    finally:
        stop.set()
        await pulse
        async with token_lock:
            tokens.pop(nonce, None)


async def consume() -> None:
    if CAPACITY < 1:
        raise ValueError("RUNNER_CAPACITY must be at least 1")
    tls = ssl.create_default_context(cafile=NATS_CA_FILE)
    nc = await nats.connect(
        NATS_URL,
        user=NATS_USER,
        password=NATS_PASSWORD_FILE.read_text().strip(),
        tls=tls,
        name=DURABLE,
    )
    js = nc.jetstream()
    subscription = await js.pull_subscribe(
        SUBJECT,
        durable=DURABLE,
        stream=STREAM,
        config=ConsumerConfig(
            durable_name=DURABLE,
            filter_subject=SUBJECT,
            ack_policy=AckPolicy.EXPLICIT,
            ack_wait=5 * 60,
            # This durable consumer is shared by every host of this runner type.
            # Local CAPACITY controls each host; this is only a global safety cap.
            max_ack_pending=MAX_INFLIGHT,
            max_deliver=5,
        ),
    )
    active: set[asyncio.Task[None]] = set()
    try:
        while True:
            active = {task for task in active if not task.done()}
            free = CAPACITY - len(active)
            if free == 0:
                await asyncio.wait(active, return_when=asyncio.FIRST_COMPLETED)
                continue
            try:
                messages = await subscription.fetch(batch=free, timeout=5)
            except TimeoutError:
                continue
            for message in messages:
                task = asyncio.create_task(run_one(message))
                task.add_done_callback(lambda done: done.exception())
                active.add(task)
    finally:
        if active:
            await asyncio.gather(*active, return_exceptions=True)
        await nc.drain()


async def main() -> None:
    app = web.Application()
    app.router.add_get("/token/{nonce}", token)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, TOKEN_LISTEN, TOKEN_PORT).start()
    try:
        await consume()
    finally:
        await runner.cleanup()


if __name__ == "__main__":
    asyncio.run(main())
