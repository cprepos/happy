import time, numpy as np, mlx.core as mx, sys
from mlx_audio.stt import load
import mlx_audio.stt.models.nemotron_asr.streaming as S
pcm = np.fromfile("bench/clips/c00_af_heart.pcm", dtype="<i2").astype(np.float32)/32768
def run(m, tag, dt=None):
    for rep in range(3):
        s = m.create_streaming_session(transcription_delay_ms=160)
        if dt is not None:
            fp = s._frontend.push
            s._frontend.push = lambda x, final=False, _f=fp: _f(x, final=final).astype(dt)
        out=[]; enc=[]; dec=[]
        for i in range(0, pcm.size, 2560):
            s.feed(pcm[i:i+2560]); t1=time.time()
            s._ingest(); t2=time.time()
            while s._encoded: out += s.step(max_decode_tokens=64)
            enc.append(t2-t1); dec.append(time.time()-t2)
        s.close()
        while not s.done: out += s.step(max_decode_tokens=64)
        print(tag, "".join(out)[-50:], f"enc {np.mean(enc[3:])*1000:.1f} dec {np.mean(dec)*1000:.1f} ms/chunk", flush=True)
mode = sys.argv[1]
m = load("nvidia/nemotron-speech-streaming-en-0.6b")
if mode == "f16in":
    m.encoder.set_dtype(mx.float16); run(m, "f16 in", mx.float16)
if mode == "bf16in":
    m.encoder.set_dtype(mx.bfloat16); run(m, "bf16 in", mx.bfloat16)
if mode == "compile":
    orig = S._stream_block
    cache = {}
    def blk(block, x, pos_enc, attn_cache, conv_cache, left_cache, conv_left):
        if attn_cache is None or conv_cache is None:
            return orig(block, x, pos_enc, attn_cache, conv_cache, left_cache, conv_left)
        f = cache.get(id(block))
        if f is None:
            f = mx.compile(lambda x, a, c: orig(block, x, pos_enc, a, c, left_cache, conv_left), inputs=block.state)
            # inputs param list includes model state for weights
            cache[id(block)] = f
        return f(x, attn_cache, conv_cache)
    S._stream_block = blk
    run(m, "compiled fp32")
import mlx.nn as nn
if mode.startswith("q"):
    bits = int(mode[1:])
    m.encoder.set_dtype(mx.float16)
    nn.quantize(m.encoder, group_size=64, bits=bits, class_predicate=lambda p, mod: isinstance(mod, nn.Linear) and mod.weight.shape[-1] % 64 == 0)
    run(m, f"q{bits} f16", mx.float16)
