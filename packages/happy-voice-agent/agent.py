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

server = AgentServer(
    setup_fnc=prewarm,
    num_idle_processes=int(os.environ.get("VOICE_AGENT_IDLE_PROCESSES", "2")),
)
server.rtc_session(entrypoint, agent_name=Settings().agent_name)

if __name__ == "__main__":
    cli.run_app(server)
