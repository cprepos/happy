import time, onnxruntime as ort
from kokoro_onnx import Kokoro
print(ort.get_available_providers())
txt = "Refactor the authentication middleware so it validates the session token before parsing the request body."
for prov in ["CPUExecutionProvider", "CoreMLExecutionProvider"]:
    try:
        sess = ort.InferenceSession("models/kokoro-v1.0.onnx", providers=[prov])
        k = Kokoro.from_session(sess, "models/voices-v1.0.bin")
        for t in ["Hello there.", txt, "Hello there.", txt]:
            t0=time.time(); a, sr = k.create(t, voice="af_heart", speed=1.0, lang="en-us")
            print(prov, f"{1000*(time.time()-t0):.0f}ms audio {len(a)/sr:.2f}s", flush=True)
    except Exception as e: print(prov, "ERR", e)
