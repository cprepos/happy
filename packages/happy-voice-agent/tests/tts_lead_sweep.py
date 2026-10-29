"""Measure the speech-free lead Kokoro puts in front of a segment, per voice and text.

This is where `happy_voice/tts_trim.py`'s thresholds come from. It reports, per clip, the
artifact's level, the floor of the near-silent gap behind it, and the level of the first real
speech -- then the bracket the detector has to live in: the loudest artifact it must ignore
and the quietest speech it must still catch.

    python tests/tts_lead_sweep.py [--env ../../selfhost/.env.voice] [--voice am_morgan ...]

The lead is labelled by shape, never by level, so the output cannot be biased by the
threshold being derived: a clip whose speech starts late has, in front of it, a run that
decays into a near-silent gap, and the lead is everything up to the end of that gap. A clip
that starts speaking straight away is reported as "no lead".

Levels are 10 ms-window RMS of mono s16le, the measure `find_speech_onset` uses, and every
level is reported *sustained* over two consecutive windows -- also what the detector uses,
since a single window can be a click. Exit code 0 when every voice was synthesized.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
from pathlib import Path

import aiohttp
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from e2e_fake_app import DEFAULT_ENV, load_env, synthesize  # noqa: E402

WINDOW_MS = 10
# A window counts as speech at this fraction of the clip's peak, and the gap behind the
# artifact at this fraction -- both relative to the clip, so no absolute level is assumed.
SPEECH_FRACTION = 0.35
GAP_FRACTION = 0.03
# Speech starting this early leaves no room for a lead; the clip is reported as clean.
MIN_LEAD_MS = 250
# The lead the trim is willing to buffer (MAX_TRIM in tts_trim.py), so measure that far.
MAX_LEAD_MS = 1000

TEXTS = [
    "sent",
    "done",
    "Yes.",
    "Okay.",
    "Hi, Happy here.",
    "Sure thing.",
    "On it now.",
    "That is done.",
    "Claude is finished.",
    "I asked Claude to do that.",
    "The source folder has twelve files.",
    "You have two sessions open right now.",
    "This session is about refactoring the auth module.",
    "All forty-two tests pass.",
    "I could not reach the server, so nothing was sent.",
    "Claude refactored the login handler to use the new token service.",
    "Do you want me to go ahead and merge that branch?",
    "There were three errors, all of them in the token tests.",
    "Claude is done. The source folder has twelve files.",
    "Sure. I asked Claude to list the files, and it found twelve.",
    "That is done. All forty-two tests pass. Nothing else is waiting on you.",
    "This session is about refactoring the auth module of the web server. Claude already "
    "refactored the login handler. All forty-two tests pass. Do you want anything else?",
    "Two sessions are open: the auth refactor, which is this one, and a dark mode fix. "
    "The dark mode one has a permission request waiting. Should I allow it?",
    "No.",
    "I am not sure what you mean.",
]


def rms_trace(pcm: np.ndarray, sample_rate: int, window_ms: int = WINDOW_MS) -> list[int]:
    n = sample_rate * window_ms // 1000
    usable = len(pcm) // n * n
    if usable == 0:
        return []
    x = pcm[:usable].astype(np.float64).reshape(-1, n)
    return [int(v) for v in np.sqrt((x * x).mean(axis=1))]


def sustained(trace: list[int], start: int = 0, stop: int | None = None) -> int:
    """The highest level held across two consecutive windows in `trace[start:stop]`."""
    part = trace[start : stop if stop is not None else len(trace)]
    return max((min(a, b) for a, b in zip(part, part[1:])), default=0)


class Lead:
    """What one clip's head looks like, in 10 ms windows."""

    def __init__(self, trace: list[int]) -> None:
        self.trace = trace
        self.peak = max(trace) if trace else 0
        self.lead_windows: int | None = None  # None = no lead found
        self.artifact = 0  # sustained level of the lead: what the detector must ignore
        self.gap_floor = 0  # the quietest window of the gap behind it
        self.speech = 0  # sustained level where speech is unmistakable: what it must catch
        self.rise = 0  # the first window past the gap, a soft attack

        if not trace:
            return
        speech_at = next(
            (i for i, v in enumerate(trace) if v >= self.peak * SPEECH_FRACTION), None
        )
        if speech_at is None:
            return
        self.speech = min(trace[speech_at], trace[speech_at + 1]) if speech_at + 1 < len(trace) else trace[speech_at]
        if speech_at * WINDOW_MS < MIN_LEAD_MS:
            return  # speaks straight away: nothing in front of it
        limit = min(speech_at, MAX_LEAD_MS // WINDOW_MS)
        gap = self.peak * GAP_FRACTION
        gap_at = next((i for i in range(limit - 1, -1, -1) if trace[i] <= gap), None)
        if gap_at is None:
            return  # loud all the way to the speech: not the shape this trim knows
        self.lead_windows = gap_at + 1
        self.artifact = sustained(trace, 0, self.lead_windows)
        self.gap_floor = trace[gap_at]
        self.rise = trace[self.lead_windows]

    @property
    def lead_ms(self) -> int | None:
        return None if self.lead_windows is None else self.lead_windows * WINDOW_MS


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--env", default=str(DEFAULT_ENV))
    ap.add_argument("--tts", default=None, help="Kokoro base URL (default: env TTS_URL)")
    ap.add_argument("--voice", action="append", default=None, metavar="NAME")
    ap.add_argument("--trace", action="store_true", help="print the 10 ms RMS trace of each head")
    args = ap.parse_args()

    env = load_env(Path(args.env)) if Path(args.env).exists() else {}
    tts_url = args.tts or env.get("TTS_URL") or "http://127.0.0.1:8880/v1"
    # am_morgan is the one with the artifact and the stock pair is the control, so all three
    # are always swept; the configured voice joins them when it is a fourth.
    voices = args.voice or list(
        dict.fromkeys(["am_morgan", "af_heart", "bm_george", env.get("TTS_VOICE") or ""])
    )
    voices = [v for v in voices if v]
    sample_rate = 24000  # Kokoro PCM

    summary: dict[str, dict[str, int]] = {}
    async with aiohttp.ClientSession() as http:
        for voice in voices:
            print(f"\n== {voice} ({len(TEXTS)} texts via {tts_url})", flush=True)
            print(f"{'lead':>6} {'artifact':>9} {'gap':>5} {'rise':>5} {'speech':>7}  text")
            leads: list[Lead] = []
            for text in TEXTS:
                pcm = await synthesize(http, tts_url, text, voice)
                lead = Lead(rms_trace(pcm, sample_rate))
                leads.append(lead)
                shown = text if len(text) <= 46 else text[:43] + "..."
                if lead.lead_ms is None:
                    print(f"{'--':>6} {'--':>9} {'--':>5} {'--':>5} {lead.speech:>7}  {shown}")
                else:
                    print(
                        f"{lead.lead_ms:>5}ms {lead.artifact:>9} {lead.gap_floor:>5} "
                        f"{lead.rise:>5} {lead.speech:>7}  {shown}"
                    )
                if args.trace:
                    print(f"        {lead.trace[:120]}")

            with_lead = [x for x in leads if x.lead_windows is not None]
            summary[voice] = {
                "clips": len(leads),
                "with_lead": len(with_lead),
                "artifact_max": max((x.artifact for x in with_lead), default=0),
                "gap_floor_max": max((x.gap_floor for x in with_lead), default=0),
                "speech_min": min((x.speech for x in leads if x.speech), default=0),
                "rise_min": min((x.rise for x in with_lead if x.rise), default=0),
                "lead_max": max((x.lead_ms or 0 for x in with_lead), default=0),
            }

    print("\n== what each voice shows")
    for voice, w in summary.items():
        print(
            f"{voice:>12}: {w['with_lead']}/{w['clips']} clips with a lead, longest "
            f"{w['lead_max']} ms; artifact holds at most {w['artifact_max']}, deepest gap "
            f"floor {w['gap_floor_max']}, softest rise past the gap {w['rise_min']}, "
            f"quietest unmistakable speech {w['speech_min']}"
        )

    artifact_max = max((w["artifact_max"] for w in summary.values()), default=0)
    speech_min = min((w["speech_min"] for w in summary.values() if w["speech_min"]), default=0)
    gap_max = max((w["gap_floor_max"] for w in summary.values()), default=0)
    rise_min = min((w["rise_min"] for w in summary.values() if w["rise_min"]), default=0)
    print("\n== thresholds this sweep supports")
    print(
        f"ONSET_RMS  above {artifact_max} (loudest artifact), below {speech_min} (quietest speech)"
        f"{'  -- NO SEPARATION' if speech_min <= artifact_max else ''}"
    )
    # The cut lands on the quietest window of the valley, found by search, so the only bound
    # needed is a ceiling confirming a valley is a valley. `rise_min` ({rise_min}) is the
    # window right after it in the same smooth decay, so it is reported, not used as a bound.
    print(
        f"VALLEY_CEILING above {gap_max} (deepest valley floor; the window after it reads "
        f"{rise_min})"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
