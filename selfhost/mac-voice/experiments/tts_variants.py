import sys, time, json, numpy as np, mlx.core as mx
SH = "Hello there."
MED = "Refactor the authentication middleware so it validates the session token before parsing the request body."
CL = "Sure, I'll take a look at that now."
variant = sys.argv[1]
t0 = time.time()
if variant.startswith("kmlx"):
    from kokoro_mlx import KokoroTTS
    repo = {"kmlx": "mlx-community/Kokoro-82M-bf16", "kmlx-fp32": "prince-canuma/Kokoro-82M"}[variant]
    tts = KokoroTTS.from_pretrained(repo)
    def synth(t):
        first=None; n=0; s=time.perf_counter()
        for c in tts.generate_stream(t, voice="af_heart"):
            if first is None: first=time.perf_counter()-s
            n+=len(c)
        return first, time.perf_counter()-s, n/24000
else:
    from mlx_audio.tts.utils import load_model
    repo = {"ma": "prince-canuma/Kokoro-82M", "ma-bf16": "mlx-community/Kokoro-82M-bf16", "ma-8bit": "mlx-community/Kokoro-82M-8bit",
            "ma-4bit": "mlx-community/Kokoro-82M-4bit"}[variant]
    m = load_model(repo)
    def synth(t):
        first=None; n=0; s=time.perf_counter()
        for r in m.generate(text=t, voice="af_heart", lang_code="a", split_pattern=None):
            if first is None: first=time.perf_counter()-s
            n+=r.audio.shape[0]
        return first, time.perf_counter()-s, n/24000
load = time.time()-t0
c = synth(MED)
res = {"variant": variant, "repo": repo, "load_s": round(load,1), "cold_first_ms": round(c[0]*1000)}
for name, t in [("short", SH), ("clause", CL), ("medium", MED)]:
    fs=[]; rt=[]
    for _ in range(4):
        f, tot, a = synth(t); fs.append(f*1000); rt.append(tot/a)
    res[name] = {"first_ms_p50": round(float(np.median(fs))), "first_ms_min": round(min(fs)), "rtf": round(float(np.median(rt)),3), "audio_s": round(a,2)}
res["mlx_peak_mb"] = round(mx.get_peak_memory()/2**20)
import psutil; res["rss_mb"] = round(psutil.Process().memory_info().rss/2**20)
print("RESULT", json.dumps(res), flush=True)
