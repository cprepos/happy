import time, json, numpy as np, mlx.core as mx
from mlx_audio.stt import load
t=time.time()
m = load("nvidia/nemotron-speech-streaming-en-0.6b")
print("load", time.time()-t, type(m), getattr(m,'model_type',None))
pcm = np.fromfile("bench/clips/c00_af_heart.pcm", dtype="<i2").astype(np.float32)/32768
for rep in range(2):
    s = m.create_streaming_session(transcription_delay_ms=160)
    out=[]; t=time.time(); steps=[]
    for i in range(0, pcm.size, 2560):
        s.feed(pcm[i:i+2560]); t1=time.time()
        while True:
            d = s.step(max_decode_tokens=64)
            out += d
            if not d and (not s._encoded): break
        steps.append(time.time()-t1)
    t1=time.time(); s.close()
    while not s.done: out += s.step(max_decode_tokens=64)
    print("text:", "".join(out)); print(f"total {time.time()-t:.2f}s step mean {np.mean(steps)*1000:.1f} max {max(steps)*1000:.1f} flush {(time.time()-t1)*1000:.0f}ms")
t=time.time(); print(m.generate(mx.array(pcm)).text, time.time()-t)
