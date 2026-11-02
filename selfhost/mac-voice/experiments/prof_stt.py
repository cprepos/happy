import time, numpy as np, mlx.core as mx, sys
from mlx.utils import tree_flatten
from mlx_audio.stt import load
m = load("nvidia/nemotron-speech-streaming-en-0.6b")
ps = tree_flatten(m.parameters()); print("dtypes", {str(v.dtype) for _,v in ps}, sum(v.size for _,v in ps)/1e6, "M")
pcm = np.fromfile("bench/clips/c00_af_heart.pcm", dtype="<i2").astype(np.float32)/32768
def run(m, tag):
    for rep in range(2):
        s = m.create_streaming_session(transcription_delay_ms=160)
        out=[]; enc=[]; dec=[]
        for i in range(0, pcm.size, 2560):
            s.feed(pcm[i:i+2560]); t1=time.time()
            s._ingest(); t2=time.time()
            while s._encoded: out += s.step(max_decode_tokens=64)
            enc.append(t2-t1); dec.append(time.time()-t2)
        s.close()
        while not s.done: out += s.step(max_decode_tokens=64)
        print(tag, "".join(out)[:60], f"enc {np.mean(enc)*1000:.1f} dec {np.mean(dec)*1000:.1f} ms/chunk")
run(m, "fp32")
for dt in (mx.bfloat16, mx.float16):
    m2 = load("nvidia/nemotron-speech-streaming-en-0.6b")
    m2.encoder.set_dtype(dt)
    run(m2, f"enc-{dt}")
