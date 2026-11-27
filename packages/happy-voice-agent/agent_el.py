"""Voice agent worker for the ElevenLabs SDK protocol (happy_voice/elevenlabs_agent.py).

    python agent_el.py start           # production worker (explicit dispatch "happy-voice-el")

Same env as agent.py; VOICE_AGENT_NAME defaults to happy-voice-el and the health port
VOICE_AGENT_HTTP_PORT to 8792, so it runs beside the `happy-voice` worker.
"""

from __future__ import annotations

import os
import warnings

warnings.filterwarnings("ignore", category=DeprecationWarning, module=r"livekit\.plugins\.turn_detector")

from livekit.agents import AgentServer, cli  # noqa: E402

# Imported at module level so the plugins register before the worker starts.
from livekit.plugins import silero, turn_detector  # noqa: E402,F401

from happy_voice.assistant import prewarm  # noqa: E402
from happy_voice.elevenlabs_agent import agent_name, entrypoint  # noqa: E402

MAX_JOBS = int(os.environ.get("VOICE_AGENT_MAX_JOBS", "8"))


def _job_load(srv: AgentServer) -> float:
    # as agent.py: load is the share of job slots in use, not host CPU
    return min(len(srv.active_jobs) / MAX_JOBS, 1.0)


server = AgentServer(
    setup_fnc=prewarm,
    load_fnc=_job_load,
    load_threshold=1.0,
    num_idle_processes=int(os.environ.get("VOICE_AGENT_IDLE_PROCESSES", "1")),
    host=os.environ.get("VOICE_AGENT_HTTP_HOST", "127.0.0.1"),
    port=int(os.environ.get("VOICE_AGENT_HTTP_PORT", "8792")),
)
server.rtc_session(entrypoint, agent_name=agent_name())

if __name__ == "__main__":
    cli.run_app(server)
