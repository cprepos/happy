import time, sys, numpy as np
t=time.time()
from mlx_audio.tts.utils import load_model
m = load_model("prince-canuma/Kokoro-82M") if len(sys.argv)<2 else load_model(sys.argv[1])
print("tts load", time.time()-t)
for txt in ["Hello there.", "Refactor the authentication middleware so it validates the session token before parsing the request body."]*2:
    t=time.time(); first=None; n=0
    for r in m.generate(text=txt, voice="af_heart", speed=1.0, lang_code="a"):
        if first is None: first=time.time()-t
        n+=r.audio.shape[0]
    print(f"first {first*1000:.0f}ms total {(time.time()-t)*1000:.0f}ms audio {n/24000:.2f}s sr")
