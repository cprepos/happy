"""Unit tests: token claims, agent map, 404, rate limiting, client IP, and the /rtc proxy."""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

import jwt
import pytest
from aiohttp import WSMsgType, web
from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from elevenlabs_server import app as srv  # noqa: E402

KEY, SECRET = "test-key", "test-secret-0123456789abcdef0123456789"


def cfg(**kw) -> srv.Config:
    base = dict(
        livekit_url="ws://127.0.0.1:1",
        api_key=KEY,
        api_secret=SECRET,
        agents={"agent_happy_voice_el": "happy-voice-el"},
        rate_per_minute=30,
        trusted_proxies=srv.parse_cidrs("127.0.0.0/8,::1/128"),
    )
    base.update(kw)
    return srv.Config(**base)


def run(coro):
    return asyncio.run(coro)


async def with_client(app: web.Application, fn):
    async with TestClient(TestServer(app)) as client:
        return await fn(client)


# --- config ---


def test_parse_agents():
    assert srv.parse_agents("a:x, b:y ,") == {"a": "x", "b": "y"}
    assert srv.parse_agents("") == {}
    with pytest.raises(ValueError):
        srv.parse_agents("no-colon")
    with pytest.raises(ValueError):
        srv.parse_agents("a:")


def test_config_from_env():
    c = srv.Config.from_env(
        {
            "LIVEKIT_URL": "ws://192.168.2.56:7880",
            "LIVEKIT_API_KEY": "k",
            "LIVEKIT_API_SECRET": "s",
            "ELEVENLABS_AGENTS": "agent_happy_voice_el:happy-voice-el",
        }
    )
    assert c.agents == {"agent_happy_voice_el": "happy-voice-el"}
    assert c.token_ttl == 600 and c.rate_per_minute == 30


# --- token ---


def test_mint_token_claims():
    token, room, identity = srv.mint_token(cfg(), "happy-voice-el", now=1_000_000)
    claims = jwt.decode(token, SECRET, algorithms=["HS256"], options={"verify_exp": False, "verify_nbf": False})
    assert claims["iss"] == KEY
    assert claims["sub"] == identity and identity.startswith("user-")
    assert claims["exp"] - claims["nbf"] == 600 and claims["nbf"] == 1_000_000
    assert room.startswith("el-")
    assert claims["video"] == {
        "roomJoin": True,
        "room": room,
        "canPublish": True,
        "canSubscribe": True,
        "canPublishData": True,
    }
    assert claims["roomConfig"] == {"agents": [{"agentName": "happy-voice-el"}]}


def test_mint_token_fresh_room_each_time():
    a = srv.mint_token(cfg(), "x")
    b = srv.mint_token(cfg(), "x")
    assert a[1] != b[1] and a[2] != b[2]


def test_mint_token_verifies_with_livekit_api_if_available():
    lk = pytest.importorskip("livekit.api")
    token, room, identity = srv.mint_token(cfg(), "happy-voice-el")
    claims = lk.TokenVerifier(KEY, SECRET).verify(token)
    assert claims.identity == identity
    assert claims.video.room == room and claims.video.room_join and claims.video.can_publish_data
    assert claims.room_config.agents[0].agent_name == "happy-voice-el"


def test_token_route_sdk_call():
    async def go(client):
        r = await client.get(
            "/v1/convai/conversation/token",
            params={"agent_id": "agent_happy_voice_el", "source": "swift_sdk", "version": "3.4.0"},
        )
        assert r.status == 200
        body = await r.json()
        claims = jwt.decode(body["token"], SECRET, algorithms=["HS256"])
        assert claims["roomConfig"]["agents"][0]["agentName"] == "happy-voice-el"
        assert r.headers["Cache-Control"] == "no-store"

    run(with_client(srv.make_app(cfg()), go))


@pytest.mark.parametrize("params", [{"agent_id": "agent_nope"}, {}, {"agent_id": ""}])
def test_token_route_unknown_agent_404(params):
    async def go(client):
        r = await client.get("/v1/convai/conversation/token", params=params)
        assert r.status == 404
        body = await r.json()
        assert body["detail"]["status"] == "agent_not_found"
        assert "token" not in body

    run(with_client(srv.make_app(cfg()), go))


def test_health():
    async def go(client):
        r = await client.get("/health")
        assert r.status == 200 and (await r.json())["status"] == "ok"

    run(with_client(srv.make_app(cfg()), go))


# --- rate limiting / client ip ---


def test_rate_limiter_bucket():
    t = [0.0]
    rl = srv.RateLimiter(3, clock=lambda: t[0])
    assert [rl.allow("a") for _ in range(4)] == [True, True, True, False]
    assert rl.allow("b")  # per key
    t[0] += 20.0  # one token back (3/min)
    assert rl.allow("a") and not rl.allow("a")


def test_token_route_rate_limited_per_forwarded_ip():
    t = [0.0]

    async def go(client):
        q = {"agent_id": "agent_happy_voice_el"}
        for _ in range(2):
            assert (await client.get("/v1/convai/conversation/token", params=q, headers={"X-Forwarded-For": "1.2.3.4"})).status == 200
        r = await client.get("/v1/convai/conversation/token", params=q, headers={"X-Forwarded-For": "1.2.3.4"})
        assert r.status == 429
        assert (await r.json())["detail"]["status"] == "rate_limit_exceeded"
        # another client behind the same proxy is not affected
        assert (await client.get("/v1/convai/conversation/token", params=q, headers={"X-Forwarded-For": "5.6.7.8"})).status == 200

    run(with_client(srv.make_app(cfg(rate_per_minute=2), clock=lambda: t[0]), go))


class FakeReq:
    def __init__(self, remote, xff=None):
        self.remote = remote
        self.headers = {"X-Forwarded-For": xff} if xff else {}


def test_client_ip():
    trusted = srv.parse_cidrs("127.0.0.0/8,172.16.0.0/12")
    assert srv.client_ip(FakeReq("127.0.0.1", "9.9.9.9, 1.2.3.4"), trusted) == "1.2.3.4"
    assert srv.client_ip(FakeReq("172.18.0.1", "1.2.3.4"), trusted) == "1.2.3.4"
    assert srv.client_ip(FakeReq("127.0.0.1"), trusted) == "127.0.0.1"
    # an untrusted peer cannot pick its own address
    assert srv.client_ip(FakeReq("8.8.8.8", "1.2.3.4"), trusted) == "8.8.8.8"


# --- proxy ---


def test_upstream_url_mapping():
    q = "/rtc?access_token=t&auto_subscribe=1"
    assert srv.upstream_url("ws://192.168.2.56:7880", q, websocket=True) == "ws://192.168.2.56:7880" + q
    assert srv.upstream_url("ws://192.168.2.56:7880/", "/rtc/validate?x=1", websocket=False) == "http://192.168.2.56:7880/rtc/validate?x=1"
    assert srv.upstream_url("wss://lk.example/base", "/rtc/v1", websocket=False) == "https://lk.example/base/rtc/v1"
    assert srv.upstream_url("https://lk.example", "/rtc", websocket=True) == "wss://lk.example/rtc"


def test_forward_headers():
    h = {"Host": "a", "Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Key": "k", "Authorization": "Bearer x", "User-Agent": "u"}
    assert srv.forward_headers(h, websocket=True) == {"Authorization": "Bearer x", "User-Agent": "u"}
    assert "Sec-WebSocket-Key" in srv.forward_headers(h, websocket=False)


def fake_livekit() -> web.Application:
    up = web.Application()

    async def rtc(request: web.Request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        await ws.send_str(f"hello {request.path_qs} {request.headers.get('X-Test', '')}")
        async for msg in ws:
            if msg.type == WSMsgType.BINARY:
                await ws.send_bytes(b"echo:" + msg.data)
            elif msg.type == WSMsgType.TEXT:
                if msg.data == "bye":
                    await ws.close(code=4001)
                    break
                await ws.send_str("echo:" + msg.data)
        return ws

    async def v1(request):
        return web.Response(status=404, text="404 page not found")

    async def validate(request):
        return web.json_response({"path_qs": request.path_qs, "auth": request.headers.get("Authorization")}, status=401)

    up.router.add_get("/rtc", rtc)
    up.router.add_get("/rtc/v1", v1)
    up.router.add_get("/rtc/validate", validate)
    return up


def test_proxy_websocket_and_http():
    async def go():
        async with TestServer(fake_livekit()) as upstream:
            app = srv.make_app(cfg(livekit_url=f"ws://127.0.0.1:{upstream.port}"))
            async with TestClient(TestServer(app)) as client:
                # websocket: path and query kept, headers forwarded, frames both ways, close code
                ws = await client.ws_connect("/rtc?access_token=abc&protocol=16", headers={"X-Test": "yes"})
                assert (await ws.receive_str()) == "hello /rtc?access_token=abc&protocol=16 yes"
                await ws.send_bytes(b"\x01\x02")
                assert (await ws.receive_bytes()) == b"echo:\x01\x02"
                await ws.send_str("hi")
                assert (await ws.receive_str()) == "echo:hi"
                await ws.send_str("bye")
                msg = await ws.receive()
                assert msg.type == WSMsgType.CLOSE and msg.data == 4001
                await ws.close()

                # a 404 on the upstream handshake is passed back, so the client falls back to /rtc
                r = await client.get(
                    "/rtc/v1?access_token=abc",
                    headers={"Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13", "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="},
                )
                assert r.status == 404

                # plain HTTP: /rtc/validate with its bearer token and status
                r = await client.get("/rtc/validate?access_token=abc", headers={"Authorization": "Bearer t"})
                assert r.status == 401
                assert await r.json() == {"path_qs": "/rtc/validate?access_token=abc", "auth": "Bearer t"}

                # only /rtc* is proxied
                assert (await client.get("/twirp/x")).status == 404

    run(go())


def test_proxy_upstream_down_502():
    async def go(client):
        r = await client.get("/rtc/validate")
        assert r.status == 502

    run(with_client(srv.make_app(cfg(livekit_url="ws://127.0.0.1:1")), go))
