"""Benchmarks for the local Mac STT/TTS services (same method as the GPU server's bench).

usage (from ~/happy-voice-local, with the services running unless noted):
  .venv/bin/python bench.py stt  NAME [PORT]     24 clips streamed in real time + file transcription: WER, partial lag, final latency, memory
  .venv/bin/python bench.py tts  NAME [PORT]     time to first byte, RTF and memory for short/medium/long inputs
  .venv/bin/python bench.py sustained NAME [SECONDS]  continuous real-time STT + a TTS request every 20 s, thermal + timings over time
  .venv/bin/python bench.py files NAME           in-process file transcription with mlx-whisper and parakeet-mlx (services may be stopped)
  .venv/bin/python bench.py idle NAME            footprint of both running services
Results go to bench/results/NAME_*.json. Clips: bench/clips/*.pcm (16 kHz PCM16) + meta.json.
"""

import asyncio
import json
import os
import re
import subprocess
import sys
import threading
import time

import httpx
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
CLIPS = os.path.join(HERE, "bench", "clips")
OUT = os.path.join(HERE, "bench", "results")
os.makedirs(OUT, exist_ok=True)
STT_PORT = int(os.environ.get("STT_PORT", "8090"))
TTS_PORT = int(os.environ.get("TTS_PORT", "8880"))

SHORT = "Hello there."
MEDIUM = "Refactor the authentication middleware so it validates the session token before parsing the request body."
LONG = ("Sure, I'll take a look at that now. The failing test is in the websocket handler, and it looks like the "
        "reconnect logic never clears the pending queue. I can add a reset when the socket closes, then rerun the "
        "suite. Do you want me to open a pull request once it passes, or just commit to the current branch?")
PARAGRAPH = " ".join([LONG] * 5)


# ---------------------------------------------------------------- helpers
def words(s):
    s = s.lower().replace("-", " ")
    return [w for w in re.sub(r"[^a-z0-9' ]", " ", s).split() if w]


def edits(ref, hyp):
    r, h = words(ref), words(hyp)
    d = list(range(len(h) + 1))
    for i in range(1, len(r) + 1):
        prev, d[0] = d[0], i
        for j in range(1, len(h) + 1):
            cur = min(d[j] + 1, d[j - 1] + 1, prev + (r[i - 1] != h[j - 1]))
            prev, d[j] = d[j], cur
    return d[len(h)], len(r)


def pid_on_port(port):
    out = subprocess.run(["lsof", "-nP", f"-iTCP:{port}", "-sTCP:LISTEN", "-t"], capture_output=True, text=True).stdout.split()
    return int(out[0]) if out else None


def footprint_mb(pid):
    """Physical footprint (what Activity Monitor shows as Memory), includes Metal/unified GPU memory."""
    o = subprocess.run(["/usr/bin/footprint", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s*([\d.]+)\s*(KB|MB|GB)", o)
    if not m:
        return None
    return float(m.group(1)) * {"KB": 1 / 1024, "MB": 1, "GB": 1024}[m.group(2)]


def rss_mb(pid):
    o = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(o) / 1024 if o else None


def power_state():
    batt = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout.strip().replace("\t", " ")
    therm = subprocess.run(["pmset", "-g", "therm"], capture_output=True, text=True).stdout.strip()
    lowpower = subprocess.run(["pmset", "-g"], capture_output=True, text=True).stdout
    lp = re.search(r"lowpowermode\s+(\d)", lowpower)
    return {"batt": batt, "therm": therm, "lowpowermode": lp.group(1) if lp else "?"}


class MemSampler:
    def __init__(self, pids, period=0.5):
        self.pids, self.period, self.samples, self._stop = pids, period, {p: [] for p in pids}, threading.Event()

    def __enter__(self):
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()
        return self

    def _run(self):
        while not self._stop.is_set():
            for p in self.pids:
                self.samples[p].append((footprint_mb(p), rss_mb(p)))
            self._stop.wait(self.period)

    def __exit__(self, *a):
        self._stop.set()
        self.t.join()

    def peak(self, pid):
        s = [x for x in self.samples[pid] if x[0] is not None]
        return {"footprint_peak_mb": round(max(x[0] for x in s)), "rss_peak_mb": round(max(x[1] for x in s))} if s else {}


def health(port):
    return httpx.get(f"http://127.0.0.1:{port}/health", timeout=5).json()


def save(name, kind, data):
    path = os.path.join(OUT, f"{name}_{kind}.json")
    json.dump(data, open(path, "w"), indent=1)
    print("saved", path)


def load_clips():
    meta = json.load(open(os.path.join(CLIPS, "meta.json")))
    for m in meta:
        m["pcm"] = np.fromfile(os.path.join(CLIPS, m["name"] + ".pcm"), dtype="<i2")
    return meta


# ---------------------------------------------------------------- STT
async def stream_once(port, pcm16, pad_s=0.5):
    """voice-smoke.sh method: 0.5 s silence pad, 20 ms frames paced in real time, flush, wait for final."""
    import websockets

    sil = np.zeros(int(16000 * pad_s), dtype="<i2")
    audio = np.concatenate([sil, pcm16, sil])
    frame = 320
    async with websockets.connect(f"ws://127.0.0.1:{port}/v1/stream?sample_rate=16000", max_size=None) as ws:
        ready = json.loads(await ws.recv())
        assert ready["type"] == "ready", ready
        partials, final = [], {}
        t_start = time.perf_counter()

        async def reader():
            async for m in ws:
                msg = json.loads(m)
                msg["_t"] = time.perf_counter() - t_start
                if msg["type"] == "partial":
                    partials.append(msg)
                elif msg["type"] == "final":
                    final.update(msg)
                    return

        rt = asyncio.create_task(reader())
        for i in range(0, audio.size, frame):
            await ws.send(audio[i: i + frame].tobytes())
            delay = (i + frame) / 16000 - (time.perf_counter() - t_start)
            if delay > 0:
                await asyncio.sleep(delay)
        t_flush = time.perf_counter() - t_start
        await ws.send(json.dumps({"type": "flush"}))
        await asyncio.wait_for(rt, 30)
        await ws.send(json.dumps({"type": "close"}))
    lags = [p["_t"] * 1000 - p["audio_ms"] for p in partials]
    return {"text": final.get("text", ""), "lags": lags, "final_ms": (final["_t"] - t_flush) * 1000, "server_flush_ms": final.get("flush_ms")}


def file_once(port, pcm16):
    import io
    import wave

    bio = io.BytesIO()
    with wave.open(bio, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000); w.writeframes(pcm16.tobytes())
    t = time.perf_counter()
    r = httpx.post(f"http://127.0.0.1:{port}/v1/audio/transcriptions", files={"file": ("a.wav", bio.getvalue(), "audio/wav")}, timeout=300)
    r.raise_for_status()
    return r.json()["text"], (time.perf_counter() - t) * 1000


def summarize_stt(rows):
    lags = [l for r in rows for l in r["lags"]]
    fin = [r["final_ms"] for r in rows]
    E, N = sum(r["edits"] for r in rows), sum(r["n"] for r in rows)
    FE = sum(r["file_edits"] for r in rows)
    ft = [r["file_ms"] / r["sec"] / 1000 for r in rows]
    return {"stream_wer": round(E / N * 100, 2), "edits": E, "words": N, "file_wer": round(FE / N * 100, 2),
            "lag_mean": round(float(np.mean(lags))), "lag_p50": round(float(np.median(lags))), "lag_p95": round(float(np.percentile(lags, 95))),
            "lag_max": round(max(lags)), "final_mean": round(float(np.mean(fin))), "final_p50": round(float(np.median(fin))),
            "final_max": round(max(fin)), "file_rtf_mean": round(float(np.mean(ft)), 3),
            "first_clip_lag_mean": round(float(np.mean(rows[0]["lags"]))), "first_clip_final": round(rows[0]["final_ms"])}


async def bench_stt(name, port):
    meta = load_clips()
    pid = pid_on_port(port)
    p0 = power_state()
    rows = []
    with MemSampler([pid]) as ms:
        for m in meta:
            s = await stream_once(port, m["pcm"])
            ftxt, fms = await asyncio.to_thread(file_once, port, m["pcm"])
            e, n = edits(m["text"], s["text"])
            fe, _ = edits(m["text"], ftxt)
            rows.append({**{k: v for k, v in m.items() if k != "pcm"}, "hyp": s["text"], "edits": e, "n": n, "file_hyp": ftxt,
                         "file_edits": fe, "file_ms": fms, "lags": s["lags"], "final_ms": s["final_ms"], "server_flush_ms": s["server_flush_ms"]})
            print(f"[{name}] {m['name']:16s} wer {e/n:6.1%} file {fe/n:6.1%} lag {np.mean(s['lags']) if s['lags'] else float('nan'):5.0f} "
                  f"final {s['final_ms']:4.0f} file {fms:4.0f}ms  {s['text']!r}", flush=True)
    summ = {**summarize_stt(rows), **ms.peak(pid), "health": health(port), "power_before": p0, "power_after": power_state()}
    print(json.dumps({k: v for k, v in summ.items() if not k.startswith("power") and k != "health"}))
    save(name, "stt", {"summary": summ, "rows": rows})


# ---------------------------------------------------------------- TTS
def tts_once(port, text, voice="af_heart"):
    t0 = time.perf_counter()
    first = None
    n = 0
    with httpx.stream("POST", f"http://127.0.0.1:{port}/v1/audio/speech",
                      json={"model": "kokoro", "input": text, "voice": voice, "response_format": "pcm", "stream": True, "speed": 1.0},
                      timeout=300) as r:
        r.raise_for_status()
        for b in r.iter_bytes():
            if b and first is None:
                first = time.perf_counter() - t0
            n += len(b)
    total = time.perf_counter() - t0
    audio_s = n / 2 / 24000
    return {"ttfb_ms": first * 1000, "total_ms": total * 1000, "audio_s": audio_s, "rtf": total / audio_s}


def bench_tts(name, port, reps=5):
    pid = pid_on_port(port)
    p0 = power_state()
    res = {}
    with MemSampler([pid]) as ms:
        for label, text in [("short", SHORT), ("medium", MEDIUM), ("long", LONG), ("paragraph", PARAGRAPH)]:
            runs = [tts_once(port, text) for _ in range(reps if label != "paragraph" else 2)]
            for r in runs:
                print(f"[{name}] {label:9s} ttfb {r['ttfb_ms']:6.0f} ms  total {r['total_ms']:6.0f} ms  audio {r['audio_s']:5.1f}s  rtf {r['rtf']:.3f}", flush=True)
            res[label] = {"runs": runs, "first_ttfb_ms": round(runs[0]["ttfb_ms"]), "ttfb_p50": round(float(np.median([r["ttfb_ms"] for r in runs]))),
                          "ttfb_max": round(max(r["ttfb_ms"] for r in runs)), "rtf_p50": round(float(np.median([r["rtf"] for r in runs])), 3),
                          "audio_s": round(runs[0]["audio_s"], 1)}
    summ = {k: {kk: vv for kk, vv in v.items() if kk != "runs"} for k, v in res.items()}
    summ.update(ms.peak(pid))
    summ["health"] = health(port)
    summ["power_before"], summ["power_after"] = p0, power_state()
    print(json.dumps({k: v for k, v in summ.items() if not k.startswith("power") and k != "health"}))
    save(name, "tts", {"summary": summ, "detail": res})


# ---------------------------------------------------------------- sustained
async def bench_sustained(name, seconds):
    meta = load_clips()
    stt_pid, tts_pid = pid_on_port(STT_PORT), pid_on_port(TTS_PORT)
    t_begin = time.perf_counter()
    segs, ttsr, therm = [], [], []
    stop = asyncio.Event()

    async def tts_loop():
        while not stop.is_set():
            r = await asyncio.to_thread(tts_once, TTS_PORT, LONG)
            r["t"] = time.perf_counter() - t_begin
            ttsr.append(r)
            print(f"  tts  t={r['t']:5.0f}s ttfb {r['ttfb_ms']:5.0f} rtf {r['rtf']:.3f}", flush=True)
            try:
                await asyncio.wait_for(stop.wait(), 20)
            except asyncio.TimeoutError:
                pass

    async def therm_loop():
        while not stop.is_set():
            p = await asyncio.to_thread(power_state)
            cpu = re.search(r"CPU_Speed_Limit\s*=\s*(\d+)", p["therm"])
            fp = await asyncio.to_thread(lambda: (footprint_mb(stt_pid), footprint_mb(tts_pid)))
            therm.append({"t": time.perf_counter() - t_begin, "therm": p["therm"], "cpu_speed_limit": cpu.group(1) if cpu else None,
                          "batt": p["batt"], "stt_footprint_mb": fp[0], "tts_footprint_mb": fp[1]})
            try:
                await asyncio.wait_for(stop.wait(), 15)
            except asyncio.TimeoutError:
                pass

    tasks = [asyncio.create_task(tts_loop()), asyncio.create_task(therm_loop())]
    i = 0
    while time.perf_counter() - t_begin < seconds:
        m = meta[i % len(meta)]
        s = await stream_once(STT_PORT, m["pcm"], pad_s=0.3)
        e, n = edits(m["text"], s["text"])
        segs.append({"t": time.perf_counter() - t_begin, "clip": m["name"], "edits": e, "n": n, "lag_mean": float(np.mean(s["lags"])),
                     "lag_max": float(max(s["lags"])), "final_ms": s["final_ms"]})
        print(f"  stt  t={segs[-1]['t']:5.0f}s {m['name']} lag {segs[-1]['lag_mean']:4.0f}/{segs[-1]['lag_max']:4.0f} final {s['final_ms']:4.0f} edits {e}", flush=True)
        i += 1
    stop.set()
    await asyncio.gather(*tasks)

    def window(rows, key, lo, hi):
        v = [r[key] for r in rows if lo <= r["t"] < hi]
        return round(float(np.mean(v))) if v else None

    mins = int(np.ceil(seconds / 60))
    per_min = [{"minute": k + 1, "stt_lag_mean": window(segs, "lag_mean", 60 * k, 60 * (k + 1)), "stt_final_mean": window(segs, "final_ms", 60 * k, 60 * (k + 1)),
                "tts_ttfb_mean": window(ttsr, "ttfb_ms", 60 * k, 60 * (k + 1)),
                "tts_rtf_mean": (lambda v: round(float(np.mean(v)), 3) if v else None)([r["rtf"] for r in ttsr if 60 * k <= r["t"] < 60 * (k + 1)])}
               for k in range(mins)]
    E, N = sum(s["edits"] for s in segs), sum(s["n"] for s in segs)
    summ = {"seconds": seconds, "segments": len(segs), "tts_requests": len(ttsr), "wer": round(E / N * 100, 2), "per_minute": per_min,
            "cpu_speed_limits": sorted({t["cpu_speed_limit"] for t in therm}, key=str), "therm_first": therm[0]["therm"] if therm else None,
            "therm_last": therm[-1]["therm"] if therm else None, "batt_first": therm[0]["batt"] if therm else None,
            "batt_last": therm[-1]["batt"] if therm else None,
            "stt_footprint_max": round(max(t["stt_footprint_mb"] for t in therm)), "tts_footprint_max": round(max(t["tts_footprint_mb"] for t in therm))}
    print(json.dumps(summ, indent=1))
    save(name, "sustained", {"summary": summ, "segments": segs, "tts": ttsr, "thermal": therm})


# ---------------------------------------------------------------- in-process file transcription
def bench_files(name):
    import mlx.core as mx

    meta = load_clips()
    out = {}

    def run(label, fn):
        fn(meta[0]["pcm"].astype(np.float32) / 32768)  # warm
        E = N = 0
        t_all = 0.0
        hyps = []
        for m in meta:
            t = time.perf_counter()
            hyp = fn(m["pcm"].astype(np.float32) / 32768)
            t_all += time.perf_counter() - t
            e, n = edits(m["text"], hyp)
            E, N = E + e, N + n
            hyps.append(hyp)
        audio = sum(m["sec"] for m in meta)
        out[label] = {"wer": round(E / N * 100, 2), "edits": E, "rtf": round(t_all / audio, 4), "ms_per_clip": round(t_all / len(meta) * 1000),
                      "mlx_peak_mb": round(mx.get_peak_memory() / 2**20), "hyps": hyps}
        print(label, {k: v for k, v in out[label].items() if k != "hyps"}, flush=True)
        mx.reset_peak_memory()

    import mlx_whisper

    wrepo = "mlx-community/whisper-large-v3-turbo"
    run("whisper-large-v3-turbo", lambda a: mlx_whisper.transcribe(a, path_or_hf_repo=wrepo, language="en")["text"])
    mx.clear_cache()

    from parakeet_mlx import from_pretrained
    from parakeet_mlx.audio import get_logmel

    for repo in ("mlx-community/parakeet-tdt-0.6b-v3", "mlx-community/parakeet-tdt-0.6b-v2"):
        pm = from_pretrained(repo)
        run(repo.split("/")[1], lambda a: pm.generate(get_logmel(mx.array(a, dtype=mx.float32), pm.preprocessor_config).astype(mx.bfloat16))[0].text)
        del pm
        mx.clear_cache()
    save(name, "files", out)


def idle(name):
    stt_pid, tts_pid = pid_on_port(STT_PORT), pid_on_port(TTS_PORT)
    r = {"stt": {"footprint_mb": footprint_mb(stt_pid), "rss_mb": rss_mb(stt_pid), "health": health(STT_PORT)},
         "tts": {"footprint_mb": footprint_mb(tts_pid), "rss_mb": rss_mb(tts_pid), "health": health(TTS_PORT)},
         "power": power_state()}
    r["total_footprint_mb"] = round(r["stt"]["footprint_mb"] + r["tts"]["footprint_mb"])
    vm = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
    r["vm_stat"] = vm
    print(json.dumps({k: v for k, v in r.items() if k != "vm_stat"}, indent=1))
    save(name, "idle", r)


if __name__ == "__main__":
    cmd, name = sys.argv[1], sys.argv[2]
    if cmd == "stt":
        asyncio.run(bench_stt(name, int(sys.argv[3]) if len(sys.argv) > 3 else STT_PORT))
    elif cmd == "tts":
        bench_tts(name, int(sys.argv[3]) if len(sys.argv) > 3 else TTS_PORT)
    elif cmd == "sustained":
        asyncio.run(bench_sustained(name, int(sys.argv[3]) if len(sys.argv) > 3 else 300))
    elif cmd == "files":
        bench_files(name)
    elif cmd == "idle":
        idle(name)
    else:
        print(__doc__)
