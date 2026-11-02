import time, threading, numpy as np
from concurrent.futures import ThreadPoolExecutor
from mlx_audio.tts.utils import load_model
m = load_model("prince-canuma/Kokoro-82M")
txt = "Refactor the authentication middleware so it validates the session token before parsing the request body."
def run(tag, sp):
    ts=[]
    for _ in range(3):
        t=time.time()
        for r in m.generate(text=txt, voice="af_heart", speed=1.0, lang_code="a", split_pattern=sp): pass
        ts.append(time.time()-t)
    print(tag, sp, [round(x*1000) for x in ts], flush=True)
run("main", r"\n+"); run("main", None)
ex = ThreadPoolExecutor(1)
ex.submit(run, "thread", r"\n+").result(); ex.submit(run, "thread", None).result()
run("main again", r"\n+")
