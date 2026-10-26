#!/bin/sh
# Local STT + TTS on Apple Silicon. Everything lives in this directory (default ~/happy-voice-local);
# models go to the Hugging Face cache. Both services bind 127.0.0.1 only.
#
#   ./run.sh setup            install uv (~/.local/bin, no profile edits), Python 3.12, .venv, requirements
#   ./run.sh start [stt|tts]  start in the background (default: both); waits until /health is ok
#   ./run.sh stop  [stt|tts]  stop (default: both)
#   ./run.sh status           health + memory of both
#   ./run.sh logs  stt|tts    tail the log
#   ./run.sh fg    stt|tts    run in the foreground
#
# Ports: STT_PORT (8090), TTS_PORT (8880). Other knobs: see README.md.
set -eu
DIR=$(cd "$(dirname "$0")" && pwd)
UV="$HOME/.local/bin/uv"
PY="$DIR/.venv/bin/python"
STT_PORT=${STT_PORT:-8090}
TTS_PORT=${TTS_PORT:-8880}
export STT_PORT TTS_PORT
mkdir -p "$DIR/logs" "$DIR/run"

port_of() { [ "$1" = stt ] && echo "$STT_PORT" || echo "$TTS_PORT"; }

start_one() {
  svc=$1; pidf="$DIR/run/$svc.pid"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then echo "$svc already running (pid $(cat "$pidf"))"; return; fi
  nohup "$PY" "$DIR/${svc}_server.py" >>"$DIR/logs/$svc.log" 2>&1 &
  echo $! >"$pidf"
  printf "%s starting (pid %s) " "$svc" "$!"
  i=0
  while [ $i -lt 600 ]; do
    if curl -fsS "http://127.0.0.1:$(port_of "$svc")/health" >/dev/null 2>&1; then echo "ready after ${i}s"; return; fi
    if ! kill -0 "$(cat "$pidf")" 2>/dev/null; then echo "FAILED, see $DIR/logs/$svc.log"; tail -20 "$DIR/logs/$svc.log"; return 1; fi
    sleep 1; i=$((i + 1))
  done
  echo "timed out"; return 1
}

stop_one() {
  svc=$1; pidf="$DIR/run/$svc.pid"
  if [ -f "$pidf" ] && kill -0 "$(cat "$pidf")" 2>/dev/null; then
    kill "$(cat "$pidf")"; echo "$svc stopped"
  else
    echo "$svc not running"
  fi
  rm -f "$pidf"
}

cmd=${1:-status}; shift || true
which=${1:-"stt tts"}
case $cmd in
  setup)
    if [ ! -x "$UV" ]; then
      curl -LsSf https://astral.sh/uv/install.sh | env UV_NO_MODIFY_PATH=1 UV_INSTALL_DIR="$HOME/.local/bin" sh
    fi
    "$UV" python install 3.12
    [ -x "$PY" ] || "$UV" venv --python 3.12 "$DIR/.venv"
    "$UV" pip install --python "$PY" -r "$DIR/requirements.txt"
    ;;
  start) for s in $which; do start_one "$s"; done ;;
  stop) for s in $which; do stop_one "$s"; done ;;
  restart) for s in $which; do stop_one "$s"; sleep 1; start_one "$s"; done ;;
  status)
    for s in stt tts; do printf "%s: " "$s"; curl -fsS "http://127.0.0.1:$(port_of $s)/health" 2>/dev/null || printf "down"; echo; done ;;
  logs) tail -f "$DIR/logs/$1.log" ;;
  fg) exec "$PY" "$DIR/${1}_server.py" ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
