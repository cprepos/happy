"""A small ElevenLabs-compatible conversation server in front of a LiveKit deployment.

The ElevenLabs Swift SDK (3.4.0) makes one HTTP call before a call:

    GET <apiEndpoint>?agent_id=<id>&source=swift_sdk&version=3.4.0

with no auth header, and wants 200 {"token": "<LiveKit JWT>"}. It then connects LiveKit to
`websocketUrl` (LiveKit appends /rtc, or /rtc/v1 with a fall back to /rtc on 404, and may call
GET /rtc/validate after a failure). This server answers the token call for a configured set of
agents (minting a JWT that dispatches the named LiveKit agent into a fresh room) and passes
/rtc* through to LIVEKIT_URL, so the app only ever knows this server's address.

Environment:
    LIVEKIT_URL            ws(s)://host:port of the LiveKit server (signaling)
    LIVEKIT_API_KEY        key the tokens are signed with
    LIVEKIT_API_SECRET
    ELEVENLABS_AGENTS      agent_id:livekit_agent_name[,agent_id:name...]
    TOKEN_TTL_SECONDS      default 600
    RATE_LIMIT_PER_MINUTE  token calls per client IP per minute, default 30 (burst the same)
    TRUSTED_PROXIES        CIDRs whose X-Forwarded-For is believed, default loopback + private
    PORT                   default 8080
"""

from __future__ import annotations

import asyncio
import ipaddress
import logging
import os
import time
import uuid
from dataclasses import dataclass, field

import aiohttp
import jwt
from aiohttp import WSMsgType, web

log = logging.getLogger("elevenlabs_server")

# Headers that describe one hop and must not be forwarded as they are.
HOP_BY_HOP = {
    "connection",
    "keep-alive",
    "proxy-authenticate",
    "proxy-authorization",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
    "host",
    "content-length",
}
# The WebSocket handshake is redone on the upstream leg.
WS_HANDSHAKE = {"sec-websocket-key", "sec-websocket-version", "sec-websocket-extensions", "sec-websocket-accept"}


@dataclass
class Config:
    livekit_url: str
    api_key: str
    api_secret: str
    agents: dict[str, str]
    token_ttl: int = 600
    rate_per_minute: int = 30
    trusted_proxies: list[ipaddress._BaseNetwork] = field(default_factory=list)

    @classmethod
    def from_env(cls, env: dict[str, str] | None = None) -> "Config":
        env = dict(os.environ if env is None else env)
        return cls(
            livekit_url=env.get("LIVEKIT_URL", "ws://127.0.0.1:7880"),
            api_key=env.get("LIVEKIT_API_KEY", ""),
            api_secret=env.get("LIVEKIT_API_SECRET", ""),
            agents=parse_agents(env.get("ELEVENLABS_AGENTS", "")),
            token_ttl=int(env.get("TOKEN_TTL_SECONDS", "600")),
            rate_per_minute=int(env.get("RATE_LIMIT_PER_MINUTE", "30")),
            trusted_proxies=parse_cidrs(
                env.get("TRUSTED_PROXIES", "127.0.0.0/8,::1/128,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16")
            ),
        )


def parse_agents(spec: str) -> dict[str, str]:
    """`agent_a:name-a, agent_b:name-b` -> {agent_a: name-a, agent_b: name-b}."""
    out: dict[str, str] = {}
    for item in spec.split(","):
        item = item.strip()
        if not item:
            continue
        agent_id, sep, name = item.partition(":")
        if not sep or not agent_id.strip() or not name.strip():
            raise ValueError(f"bad ELEVENLABS_AGENTS entry {item!r} (want agent_id:livekit_agent_name)")
        out[agent_id.strip()] = name.strip()
    return out


def parse_cidrs(spec: str) -> list[ipaddress._BaseNetwork]:
    return [ipaddress.ip_network(c.strip(), strict=False) for c in spec.split(",") if c.strip()]


def mint_token(cfg: Config, agent_name: str, now: float | None = None) -> tuple[str, str, str]:
    """A LiveKit access token for a fresh room with `agent_name` dispatched into it.

    Returns (jwt, room, identity). Claims follow livekit-api's AccessToken.to_jwt().
    """
    now = int(time.time() if now is None else now)
    room = f"el-{uuid.uuid4()}"
    identity = f"user-{uuid.uuid4()}"
    claims = {
        "iss": cfg.api_key,
        "sub": identity,
        "nbf": now,
        "exp": now + cfg.token_ttl,
        "jti": identity,
        "name": identity,
        "video": {
            "roomJoin": True,
            "room": room,
            "canPublish": True,
            "canSubscribe": True,
            "canPublishData": True,
        },
        "roomConfig": {"agents": [{"agentName": agent_name}]},
    }
    return jwt.encode(claims, cfg.api_secret, algorithm="HS256"), room, identity


class RateLimiter:
    """Token bucket per key: `per_minute` refills a minute, burst of the same size."""

    def __init__(self, per_minute: int, clock=time.monotonic):
        self.rate = per_minute / 60.0
        self.burst = float(per_minute)
        self.clock = clock
        self.buckets: dict[str, tuple[float, float]] = {}

    def allow(self, key: str) -> bool:
        if self.rate <= 0:
            return True
        now = self.clock()
        tokens, last = self.buckets.get(key, (self.burst, now))
        tokens = min(self.burst, tokens + (now - last) * self.rate)
        if len(self.buckets) > 10000:  # forget idle clients
            self.buckets = {k: v for k, v in self.buckets.items() if now - v[1] < 120}
        if tokens < 1.0:
            self.buckets[key] = (tokens, now)
            return False
        self.buckets[key] = (tokens - 1.0, now)
        return True


def client_ip(request: web.Request, trusted: list[ipaddress._BaseNetwork]) -> str:
    """The peer, or the last X-Forwarded-For hop when the peer is a trusted proxy (Caddy)."""
    peer = request.remote or ""
    try:
        peer_ip = ipaddress.ip_address(peer)
    except ValueError:
        return peer
    if any(peer_ip in net for net in trusted):
        xff = request.headers.get("X-Forwarded-For", "")
        hops = [h.strip() for h in xff.split(",") if h.strip()]
        if hops:
            return hops[-1]
    return peer


def upstream_url(livekit_url: str, path_qs: str, websocket: bool) -> str:
    """LIVEKIT_URL + the request's own path and query; http(s) for plain requests."""
    base = livekit_url.rstrip("/")
    if not websocket:
        if base.startswith("wss://"):
            base = "https://" + base[len("wss://") :]
        elif base.startswith("ws://"):
            base = "http://" + base[len("ws://") :]
    else:
        if base.startswith("https://"):
            base = "wss://" + base[len("https://") :]
        elif base.startswith("http://"):
            base = "ws://" + base[len("http://") :]
    return base + path_qs


def forward_headers(headers, websocket: bool) -> dict[str, str]:
    drop = HOP_BY_HOP | (WS_HANDSHAKE if websocket else set())
    return {k: v for k, v in headers.items() if k.lower() not in drop}


def el_error(status: int, code: str, message: str) -> web.Response:
    # ElevenLabs errors look like {"detail": {"status": "...", "message": "..."}}
    return web.json_response({"detail": {"status": code, "message": message}}, status=status)


CFG = web.AppKey("cfg", Config)
LIMITER = web.AppKey("limiter", RateLimiter)
HTTP = web.AppKey("http", aiohttp.ClientSession)
LOG = web.RequestKey("log", dict)  # what the access log line shows


async def health(request: web.Request) -> web.Response:
    return web.json_response({"status": "ok", "agents": len(request.app[CFG].agents)})


async def conversation_token(request: web.Request) -> web.Response:
    cfg = request.app[CFG]
    ip = client_ip(request, cfg.trusted_proxies)
    request[LOG]["client_ip"] = ip
    if not request.app[LIMITER].allow(ip):
        return el_error(429, "rate_limit_exceeded", "Too many requests, slow down.")
    agent_id = request.query.get("agent_id", "")
    request[LOG]["agent_id"] = agent_id
    agent_name = cfg.agents.get(agent_id)
    if not agent_name:
        return el_error(404, "agent_not_found", f"Agent with id {agent_id!r} was not found." if agent_id else "agent_id is required.")
    token, room, _identity = mint_token(cfg, agent_name)
    request[LOG]["room"] = room
    return web.json_response({"token": token}, headers={"Cache-Control": "no-store"})


async def rtc_proxy(request: web.Request) -> web.StreamResponse:
    cfg = request.app[CFG]
    request[LOG]["client_ip"] = client_ip(request, cfg.trusted_proxies)
    is_ws = request.headers.get("Upgrade", "").lower() == "websocket"
    target = upstream_url(cfg.livekit_url, request.path_qs, websocket=is_ws)
    session = request.app[HTTP]
    if is_ws:
        return await _proxy_ws(request, session, target)
    body = await request.read()
    try:
        async with session.request(
            request.method,
            target,
            headers=forward_headers(request.headers, websocket=False),
            data=body or None,
            allow_redirects=False,
        ) as up:
            payload = await up.read()
            return web.Response(
                status=up.status,
                body=payload,
                headers={k: v for k, v in up.headers.items() if k.lower() not in HOP_BY_HOP | {"content-encoding"}},
            )
    except aiohttp.ClientError as e:
        log.warning("upstream %s failed: %s", request.path, type(e).__name__)
        return el_error(502, "upstream_unavailable", "LiveKit is not reachable.")


async def _proxy_ws(request: web.Request, session: aiohttp.ClientSession, target: str) -> web.StreamResponse:
    protocols = [p.strip() for p in request.headers.get("Sec-WebSocket-Protocol", "").split(",") if p.strip()]
    headers = forward_headers(request.headers, websocket=True)
    headers.pop("Sec-WebSocket-Protocol", None)
    try:
        up = await session.ws_connect(
            target,
            headers=headers,
            protocols=protocols,
            autoping=True,
            heartbeat=None,
            max_msg_size=0,
            compress=0,
        )
    except aiohttp.WSServerHandshakeError as e:
        # e.g. 404 on /rtc/v1 (the client then falls back to /rtc), 401 on a bad token
        return web.Response(status=e.status, text=e.message or "")
    except aiohttp.ClientError as e:
        log.warning("upstream ws %s failed: %s", request.path, type(e).__name__)
        return el_error(502, "upstream_unavailable", "LiveKit is not reachable.")

    down = web.WebSocketResponse(
        protocols=[up.protocol] if up.protocol else (),
        autoping=True,
        heartbeat=None,
        max_msg_size=0,
        compress=False,
    )
    await down.prepare(request)
    request[LOG]["ws"] = True

    async def pump(src, dst) -> None:
        async for msg in src:
            if msg.type == WSMsgType.BINARY:
                await dst.send_bytes(msg.data)
            elif msg.type == WSMsgType.TEXT:
                await dst.send_str(msg.data)
            elif msg.type in (WSMsgType.CLOSE, WSMsgType.CLOSING, WSMsgType.CLOSED, WSMsgType.ERROR):
                break

    tasks = [asyncio.create_task(pump(down, up)), asyncio.create_task(pump(up, down))]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for t in tasks:
            t.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        code = up.close_code or down.close_code or 1000
        if not up.closed:
            await up.close(code=code)
        if not down.closed:
            await down.close(code=code)
    return down


@web.middleware
async def access_log(request: web.Request, handler):
    t0 = time.monotonic()
    status = 500
    request[LOG] = ctx = {}
    try:
        resp = await handler(request)
        status = resp.status
        return resp
    except web.HTTPException as e:
        status = e.status
        raise
    finally:
        # path only: the query of /rtc carries the access token
        extra = ""
        if ctx.get("agent_id") is not None:
            extra += f" agent_id={ctx['agent_id']!r}"
        if ctx.get("room"):
            extra += f" room={ctx['room']}"
        if ctx.get("ws"):
            extra += " ws"
        ip = ctx.get("client_ip") or request.remote
        log.info("%s %s %s %d %.0fms%s", ip, request.method, request.path, status, (time.monotonic() - t0) * 1000, extra)


def make_app(cfg: Config, clock=time.monotonic) -> web.Application:
    app = web.Application(middlewares=[access_log])
    app[CFG] = cfg
    app[LIMITER] = RateLimiter(cfg.rate_per_minute, clock=clock)

    async def http_session(app: web.Application):
        app[HTTP] = aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None, connect=10, sock_read=None))
        yield
        await app[HTTP].close()

    app.cleanup_ctx.append(http_session)
    app.router.add_get("/health", health)
    app.router.add_get("/v1/convai/conversation/token", conversation_token)
    app.router.add_route("*", "/rtc", rtc_proxy)
    app.router.add_route("*", "/rtc/{tail:.*}", rtc_proxy)
    return app


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    cfg = Config.from_env()
    if not cfg.api_key or not cfg.api_secret:
        raise SystemExit("LIVEKIT_API_KEY and LIVEKIT_API_SECRET are required")
    if not cfg.agents:
        raise SystemExit("ELEVENLABS_AGENTS is empty")
    log.info("agents=%s livekit=%s ttl=%ds", sorted(cfg.agents), cfg.livekit_url, cfg.token_ttl)
    web.run_app(make_app(cfg), host="0.0.0.0", port=int(os.environ.get("PORT", "8080")), access_log=None, print=None)


if __name__ == "__main__":
    main()
