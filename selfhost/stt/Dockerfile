FROM pytorch/pytorch:2.14.1-cuda12.6-cudnn9-runtime

ENV DEBIAN_FRONTEND=noninteractive \
    PIP_NO_CACHE_DIR=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libsndfile1 ffmpeg curl \
 && rm -rf /var/lib/apt/lists/*

COPY requirements.txt /app/requirements.txt
# Keep the base image's CUDA torch build: never let a dependency swap it out.
RUN python -c "import torch; print(f'torch=={torch.__version__.split(\"+\")[0]}')" > /tmp/constraints.txt \
 && pip install Cython packaging -c /tmp/constraints.txt \
 && pip install -r /app/requirements.txt -c /tmp/constraints.txt

COPY server.py /app/server.py
WORKDIR /app

EXPOSE 8090
HEALTHCHECK --interval=15s --timeout=5s --start-period=180s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8090/health || exit 1
CMD ["python", "-m", "uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8090", "--ws-max-size", "4194304"]
