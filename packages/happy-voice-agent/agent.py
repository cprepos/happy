"""Voice agent worker.

    python agent.py start           # production worker (explicit dispatch "happy-voice")
    python agent.py dev             # development mode with reload
    python agent.py download-files  # fetch VAD and turn-detector weights (done at image build)

Env: LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET, STT_URL, TTS_URL, TTS_VOICE,
LLM_BASE_URL, LLM_MODEL (see happy_voice/config.py for the rest).
"""

from __future__ import annotations

import os
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning, module=r"livekit\.plugins\.turn_detector")

from livekit.agents import AgentServer, cli  # noqa: E402

# Imported at module level so the plugins register before the worker starts
# (needed by download-files and by the inference process).
from livekit.plugins import silero, turn_detector  # noqa: E402,F401

from happy_voice.assistant import entrypoint, prewarm  # noqa: E402
from happy_voice.config import Settings  # noqa: E402

MAX_JOBS = int(os.environ.get("VOICE_AGENT_MAX_JOBS", "8"))


def _job_load(srv: AgentServer) -> float:
    # The default load is host CPU usage, which on a shared GPU box (builds, vLLM, other
    # services) regularly crosses the 0.7 threshold and silently stops dispatch. The heavy
    # work here runs on the GPU services, so load is the share of job slots in use.
    return min(len(srv.active_jobs) / MAX_JOBS, 1.0)


server = AgentServer(
    setup_fnc=prewarm,
    load_fnc=_job_load,
    load_threshold=1.0,
    num_idle_processes=int(os.environ.get("VOICE_AGENT_IDLE_PROCESSES", "2")),
    # health endpoint; loopback only since the container runs on the host network
    host=os.environ.get("VOICE_AGENT_HTTP_HOST", "127.0.0.1"),
    port=int(os.environ.get("VOICE_AGENT_HTTP_PORT", "8791")),
)
server.rtc_session(entrypoint, agent_name=Settings().agent_name)

if __name__ == "__main__":
    cli.run_app(server)
