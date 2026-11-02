import time, numpy as np, mlx.core as mx
from kokoro_mlx import KokoroTTS
tts = KokoroTTS.from_pretrained("prince-canuma/Kokoro-82M")
M = tts._model
ph = tts._get_phonemizer(None, "af_heart")
vm = tts._voices; va = vm.load_voice("af_heart")
for txt in ["Hello there.", "Refactor the authentication middleware so it validates the session token before parsing the request body."]:
    (p, ids), = ph.phonemize_long(txt)
    style = vm.get_style(va, len(ids))
    M.forward(p, style); 
    # timing: wrap decoder
    dec = M.decoder
    for _ in range(3):
        t0=time.perf_counter()
        orig = M.decoder
        times={}
        class W:
            def __call__(s,*a):
                t1=time.perf_counter(); 
                mx.eval(*a); times["pre"]=t1-t0+ (time.perf_counter()-t1)
                t2=time.perf_counter(); o=orig(*a); mx.eval(o); times["dec"]=time.perf_counter()-t2; return o
        M.decoder = W()
        a = M.forward(p, style); mx.eval(a)
        M.decoder = orig
        print(txt[:12], {k: round(v*1000) for k,v in times.items()}, "total", round((time.perf_counter()-t0)*1000), "audio", a.size/24000)
