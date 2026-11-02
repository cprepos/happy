import time
from mlx_audio.tts.utils import load_model
m = load_model("prince-canuma/Kokoro-82M")
txt = "Refactor the authentication middleware so it validates the session token before parsing the request body."
for r in m.generate(text=txt, voice="af_heart", lang_code="a"): pass
p = m._get_pipeline("a")
for _ in range(3):
    t=time.time(); out=list(p.g2p(txt)); t1=time.time()
    for r in m.generate(text=txt, voice="af_heart", lang_code="a", split_pattern=None): pass
    t2=time.time()
    print(f"g2p {1000*(t1-t):.0f}ms full {1000*(t2-t1):.0f}ms")
for w in ["Refactor the authentication middleware", "so it validates the session token", "Hello there."]:
    t=time.time()
    for r in m.generate(text=w, voice="af_heart", lang_code="a", split_pattern=None): pass
    print(w, f"{1000*(time.time()-t):.0f}ms")
