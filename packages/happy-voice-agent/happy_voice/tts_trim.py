"""Drop the speech-free lead Kokoro puts in front of a synthesized segment.

For some inputs — and, measured here, only with the fine-tuned `am_morgan` voice pack —
Kokoro-FastAPI returns about 0.7 s of low-level audio before the speech: a burst rising to
roughly rms 99 within 100 ms, then decaying to zero over half a second (peak ~2% of full
scale). It is deterministic per text, carries no speech at all (our own STT transcribes the
region as "" even amplified 24x) and never appears with `af_heart` or `bm_george`.

On its own that is a soft glitch before each reply. What makes it loud is `StreamAdapter`:
it sends one HTTP synthesize request per sentence batch, so the artifact lands at the start
of *every sentence*. A four-sentence reply measured 8.736 s as one direct request and
10.743 s through the pipeline — two whole seconds of inserted dead air. And because the
real speech arrives ~0.7 s late behind audio you cannot hear, the agent counts as speaking
while nothing plays: the opening sounds missing, and a listener who talks into that gap
barges in and truncates the reply.

So trim it. The threshold is measured, not guessed: across every voice and text probed, the
pre-speech artifact peaks at rms 133 in a 10 ms window, while the quietest speech onset
reads 235. 180 sits between them. The cut keeps a 30 ms pad and fades in over 5 ms, and
anything the onset search cannot positively identify as pre-speech is passed through
untouched — a segment that is quiet throughout, or whose onset comes later than `max_trim`,
is emitted whole. Trailing padding is left alone; it reads as sentence spacing.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from livekit.agents import DEFAULT_API_CONNECT_OPTIONS, APIConnectOptions, tts, utils

if TYPE_CHECKING:
    from livekit.agents.tts import AudioEmitter

logger = logging.getLogger("happy-voice")

ONSET_RMS = 180
"""10 ms-window RMS that counts as speech. Artifact tops out at 133, speech starts at 235."""

KEEP_PAD = 0.030
"""Seconds of audio kept before the onset, in case the threshold clips a soft attack."""

MAX_TRIM = 1.0
"""Never buffer (or cut) more than this. The longest artifact measured was 0.77 s."""

FADE = 0.005
"""Fade-in over the cut so it cannot click."""


def find_speech_onset(
    pcm: bytes,
    *,
    sample_rate: int,
    window_ms: int = 10,
    onset_rms: int = ONSET_RMS,
) -> int | None:
    """Byte offset of the first `window_ms` window reaching `onset_rms`, or None.

    `pcm` is mono signed 16-bit little-endian. A partial trailing window is ignored: the
    caller is still buffering and will ask again with more audio.
    """
    step = (sample_rate * window_ms // 1000) * 2
    if step <= 0:
        return None
    # rms >= t  <=>  sum(x^2) >= t^2 * n, so compare in integers and skip the sqrt
    limit = onset_rms * onset_rms * (step // 2)
    for start in range(0, len(pcm) - step + 1, step):
        total = 0
        for i in range(start, start + step, 2):
            x = pcm[i] | (pcm[i + 1] << 8)
            if x >= 0x8000:
                x -= 0x10000
            total += x * x
        if total >= limit:
            return start
    return None


def _fade_in(pcm: bytearray, samples: int) -> None:
    """Linear fade over the first `samples` samples, in place."""
    for n in range(min(samples, len(pcm) // 2)):
        i = n * 2
        x = pcm[i] | (pcm[i + 1] << 8)
        if x >= 0x8000:
            x -= 0x10000
        x = x * n // samples
        pcm[i] = x & 0xFF
        pcm[i + 1] = (x >> 8) & 0xFF


class LeadTrimmedTTS(tts.TTS):
    """Wraps a non-streaming TTS and trims each segment's speech-free lead."""

    def __init__(
        self,
        inner: tts.TTS,
        *,
        onset_rms: int = ONSET_RMS,
        keep_pad: float = KEEP_PAD,
        max_trim: float = MAX_TRIM,
        fade: float = FADE,
    ) -> None:
        super().__init__(
            capabilities=inner.capabilities,
            sample_rate=inner.sample_rate,
            num_channels=inner.num_channels,
        )
        self._inner = inner
        self._onset_rms = onset_rms
        self._keep_pad = keep_pad
        self._max_trim = max_trim
        self._fade = fade

    @property
    def label(self) -> str:
        return f"happy_voice.LeadTrimmedTTS({self._inner.label})"

    def synthesize(
        self,
        text: str,
        *,
        conn_options: APIConnectOptions = DEFAULT_API_CONNECT_OPTIONS,
    ) -> tts.ChunkedStream:
        return _LeadTrimmedStream(tts=self, input_text=text, conn_options=conn_options)

    def prewarm(self) -> None:
        self._inner.prewarm()

    async def aclose(self) -> None:
        await self._inner.aclose()


class _LeadTrimmedStream(tts.ChunkedStream):
    async def _run(self, output_emitter: AudioEmitter) -> None:
        parent: LeadTrimmedTTS = self._tts  # type: ignore[assignment]
        rate = parent.sample_rate
        output_emitter.initialize(
            request_id=utils.shortuuid(),
            sample_rate=rate,
            num_channels=parent.num_channels,
            mime_type="audio/pcm",
        )

        searching = True
        held = bytearray()
        cap = int(parent._max_trim * rate) * 2
        step = (rate // 100) * 2  # one 10 ms window; windows already scanned stay scanned
        scanned = 0

        async with parent._inner.synthesize(self.input_text, conn_options=self._conn_options) as inner:
            async for audio in inner:
                data = audio.frame.data.tobytes()
                if not searching:
                    output_emitter.push(data)
                    continue

                held += data
                found = find_speech_onset(
                    bytes(held[scanned:]), sample_rate=rate, onset_rms=parent._onset_rms
                )
                onset = None if found is None else scanned + found
                if onset is None:
                    scanned += (len(held) - scanned) // step * step
                    if len(held) >= cap:
                        # No onset within the cap: this is not the artifact we know how to
                        # recognise, so emit everything rather than risk cutting speech.
                        logger.debug("tts lead: no onset within %.0fms, passing through", parent._max_trim * 1000)
                        output_emitter.push(bytes(held))
                        held.clear()
                        searching = False
                    continue

                cut = max(0, onset - int(parent._keep_pad * rate) * 2) & ~1
                kept = bytearray(held[cut:])
                if cut:
                    _fade_in(kept, int(parent._fade * rate))
                    logger.debug("tts lead: trimmed %.0fms", cut / 2 / rate * 1000)
                output_emitter.push(bytes(kept))
                held.clear()
                searching = False

        if held:
            # The whole segment stayed below the threshold (a very short or silent
            # synthesis). Keep it as-is.
            output_emitter.push(bytes(held))

        output_emitter.flush()


def trim_leading_artifact(inner: tts.TTS, *, enabled: bool = True) -> tts.TTS:
    """`inner` wrapped in lead trimming, or `inner` itself when disabled."""
    return LeadTrimmedTTS(inner) if enabled else inner
