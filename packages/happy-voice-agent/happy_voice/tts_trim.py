"""Drop the speech-free lead Kokoro puts in front of a synthesized segment.

For some inputs — and only with the fine-tuned `am_morgan` voice pack — Kokoro-FastAPI
returns 0.7-0.9 s of audible but speech-free audio before the speech: a band-limited burst
(55-58 % of its energy in 300-1000 Hz, ~0-2 % above 3 kHz) rising over 200-400 ms, then
decaying into a near-silent valley, then the real speech. `tests/tts_lead_sweep.py` measures
it: 17-18 of 25 texts over two sweeps, leads of 680-910 ms, and the same shape in streaming
and non-streaming responses, so it is the voice pack, not the chunker. `af_heart` shows it in
0 of 25 and `bm_george` in 1 of 25 (50 ms at rms 10-19, inaudible).

On its own that is a glitch before each reply. What makes it loud is `StreamAdapter`: it
sends one HTTP synthesize request per sentence batch, so the artifact lands at the start of
*every sentence*. A four-sentence reply measured 8.736 s as one direct request and 10.743 s
through the pipeline — two whole seconds of inserted dead air. And because the real speech
arrives ~0.8 s late behind audio you cannot hear, the agent counts as speaking while nothing
intelligible plays: the opening sounds missing, and a listener who talks into that gap barges
in and truncates the reply.

So trim it, on levels the sweep measures rather than guesses. Sustained over two consecutive
10 ms windows (one window can be a click), the artifact reaches at most 973-1007 while the
quietest unmistakable speech holds 1018-1240 across both Kokoro backends, so `ONSET_RMS` sits
between them. That bracket is
narrow, which is why the threshold does not decide the cut: it only locates speech, and the
cut goes to the *quietest window* of the valley in front of it, found by search. A valley
floor is deep (at most 116 measured, against `VALLEY_CEILING`), so a few hundred rms of
threshold error does not move the cut, and both ways of being wrong degrade to keeping audio
rather than cutting speech — a threshold too high finds no onset and passes the segment
through, one too low finds its onset inside the artifact, where the valley search then lands
at the very start and trims nothing.

Everything the search cannot positively identify is passed through untouched: a segment quiet
throughout, one whose speech starts later than `max_trim`, and one whose valley is not quiet
enough to be a valley. The cut keeps a 30 ms pad and fades in over 5 ms. Trailing padding is
left alone; it reads as sentence spacing.

An earlier version of this module read the artifact at "rms 133, speech at 235" and set the
threshold to 180 — which is the artifact's own second window. It therefore reported an onset
~50 ms in and kept the whole lead, and every capture that used the same metric to check the
result agreed with it. The lead was found again at the far end of the pipeline, in the frames
the agent pushes to its LiveKit track, after the transport and the TTS taps had been cleared
by measurement.
"""

from __future__ import annotations

import logging
from typing import TYPE_CHECKING

from livekit.agents import DEFAULT_API_CONNECT_OPTIONS, APIConnectOptions, tts, utils

if TYPE_CHECKING:
    from livekit.agents.tts import AudioEmitter

logger = logging.getLogger("happy-voice")

ONSET_RMS = 1012
"""Level, held over two 10 ms windows, that counts as speech.

The sweep brackets it, and the two Kokoro backends bracket it differently:

    backend                  loudest artifact   quietest speech
    CUDA Kokoro (GPU)              979-1005         1096-1240
    MLX Kokoro (prep-air Mac)      973-1007         1018-1034

1012 is inside both, which is why it is not the 1050 the GPU sweeps alone supported: that sits
above the Mac's quietest speech, so on those clips no onset is found and the whole ~900 ms lead
plays. The Mac needs the trim more, not less -- it leads on 25 of 25 texts where CUDA leads on
17. It only locates speech; `find_speech_onset` then cuts at the valley in front of it.
"""

VALLEY_CEILING = 260
"""How quiet the valley behind the artifact must be for its floor to be a cut point.

Measured floors reach 116, so this is better than twice the margin, and it is what stops a
dip between two words from being mistaken for the end of a lead.
"""

MIN_LEAD = 0.4
"""Shortest lead this will cut, in seconds.

Measured leads run 680-910 ms. Below this a quiet stretch in front of speech is far more
likely to be a soft syllable or a stop closure *inside* the speech, and cutting there would
drop the opening word -- so a cut that early is declined and the segment kept whole.
"""

KEEP_PAD = 0.030
"""Seconds of audio kept before the cut, in case the valley clips a soft attack."""

MAX_TRIM = 1.5
"""Never buffer (or cut) more than this.

The longest lead measured is 910 ms and the speech comes *after* it, so the 1.0 s this was
originally set to could expire before the onset it is looking for and pass the lead through.
"""

FADE = 0.005
"""Fade-in over the cut so it cannot click."""


class _OnsetScanner:
    """Finds where a segment's speech begins, over audio arriving in pieces.

    Levels are compared as sums of squares (`rms >= t  <=>  sum(x^2) >= t^2 * n`), so the
    scan stays in integers with no sqrt. Each window's energy is computed once as its bytes
    arrive, and the valley search runs over those energies, so a segment costs one pass over
    its audio however many pieces it comes in.
    """

    def __init__(
        self,
        sample_rate: int,
        *,
        window_ms: int = 10,
        onset_rms: int = ONSET_RMS,
        min_lead: float = MIN_LEAD,
    ) -> None:
        self._step = (sample_rate * window_ms // 1000) * 2  # bytes per window
        self._samples = max(self._step // 2, 1)
        self._min_lead = int(min_lead * sample_rate) * 2
        self._limit = onset_rms * onset_rms * self._samples
        self._energies: list[int] = []
        self._partial = bytearray()  # bytes short of a whole window
        self._scanned = 0  # window pairs up to here have been ruled out
        self._onset: int | None = None  # first window of the first speech-level pair

    def push(self, pcm: bytes) -> None:
        """Take more of the segment. `pcm` is mono signed 16-bit little-endian."""
        if self._step <= 0:
            return
        self._partial += pcm
        whole = len(self._partial) // self._step
        for w in range(whole):
            window = self._partial[w * self._step : (w + 1) * self._step]
            total = 0
            for i in range(0, len(window), 2):
                x = window[i] | (window[i + 1] << 8)
                if x >= 0x8000:
                    x -= 0x10000
                total += x * x
            self._energies.append(total)
        del self._partial[: whole * self._step]

    def cut_offset(self, *, valley_ceiling: int = VALLEY_CEILING) -> int | None:
        """Byte offset to cut at, 0 to keep the segment whole, or None to keep looking.

        Speech counts as two consecutive windows at `onset_rms` -- a single one can be a
        click. The cut then goes to the quietest window in front of that, which is the floor
        of the valley the artifact decays into. 0 comes back when there is nothing in front
        of the speech, or when what is in front never drops to `valley_ceiling` and so is
        speech already running; None means no speech found yet in the audio pushed so far.
        """
        if self._step <= 0:
            return None
        if self._onset is None:
            energies = self._energies
            while self._scanned + 1 < len(energies):
                if (
                    energies[self._scanned] >= self._limit
                    and energies[self._scanned + 1] >= self._limit
                ):
                    self._onset = self._scanned
                    break
                self._scanned += 1
            if self._onset is None:
                return None

        before = self._energies[: self._onset]
        if not before:
            return 0
        # The *end* of the quiet stretch in front of the speech, not its quietest point: the
        # artifact's own first windows are quieter than the valley it decays into (it fades
        # in), so the quietest window of all is usually window 0.
        quiet = valley_ceiling * valley_ceiling * self._samples
        last = next(
            (
                i
                for i in range(len(before) - 1, 0, -1)
                if before[i] <= quiet and before[i - 1] <= quiet
            ),
            None,
        )
        if last is None or last * self._step < self._min_lead:
            # Nothing quiet in front of the speech, or a cut too early to be this artifact:
            # a lead measures 680-910 ms, so anything shorter is a quiet syllable or a stop
            # closure inside speech, and cutting there would eat the opening word.
            return 0
        return last * self._step


def find_speech_onset(
    pcm: bytes,
    *,
    sample_rate: int,
    window_ms: int = 10,
    onset_rms: int = ONSET_RMS,
    valley_ceiling: int = VALLEY_CEILING,
    min_lead: float = MIN_LEAD,
) -> int | None:
    """Where to cut `pcm` to drop a speech-free lead: see `_OnsetScanner.cut_offset`.

    `pcm` is mono signed 16-bit little-endian, and a partial trailing window is ignored.
    """
    scanner = _OnsetScanner(
        sample_rate, window_ms=window_ms, onset_rms=onset_rms, min_lead=min_lead
    )
    scanner.push(pcm)
    return scanner.cut_offset(valley_ceiling=valley_ceiling)


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
        valley_ceiling: int = VALLEY_CEILING,
        min_lead: float = MIN_LEAD,
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
        self._valley_ceiling = valley_ceiling
        self._min_lead = min_lead
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
        scanner = _OnsetScanner(rate, onset_rms=parent._onset_rms, min_lead=parent._min_lead)

        async with parent._inner.synthesize(self.input_text, conn_options=self._conn_options) as inner:
            async for audio in inner:
                data = audio.frame.data.tobytes()
                if not searching:
                    output_emitter.push(data)
                    continue

                held += data
                scanner.push(data)
                onset = scanner.cut_offset(valley_ceiling=parent._valley_ceiling)
                if onset is None:
                    if len(held) >= cap:
                        # No speech within the cap: this is not the artifact we know how to
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
