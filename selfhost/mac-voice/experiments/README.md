# Experiments

One-off scripts behind the measurements in `../README.md` (the "Why the TTS splits the first
sentence" table, the `STT_DTYPE` row). Not used by the services. Run them from `selfhost/mac-voice`
with its venv, since they read `bench/clips/` and `models/`:

```sh
.venv/bin/python experiments/tts_variants.py ma-bf16
```

- `smoke_stt.py`, `smoke_tts.py`: load a model and time a clip end to end.
- `tts_variants.py`: mlx-audio fp32 / bf16 / 8-bit / 4-bit and kokoro-mlx, first chunk and RTF.
- `tts_prof.py`, `kprof.py`, `tts_thr.py`: where Kokoro's time goes (g2p, vocoder, thread vs main).
- `onnx_prof.py`: kokoro-onnx on CPU and CoreML. Needs `kokoro-onnx` and the onnx files in `models/`.
- `prof_stt.py`, `prof_stt2.py`: Nemotron encoder dtype, `mx.compile` and quantization.
