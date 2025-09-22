#!/usr/bin/env bash
set -eo pipefail
source "$HOME/Projects/tools/functions.sh"

# --- Validate input ----------------------------------------------------------
if [[ $# -ne 1 ]]; then
  error "Usage: $0 <domain>"
fi

# --- Require not root privileges ---------------------------------------------
if [[ $EUID -eq 0 ]]; then
  error "This script must NOT be run as root. Try: $0"
fi

# --- Check Docker and Compose availability -----------------------------------
for cmd in docker "docker compose" ufw openssl; do
  if ! $cmd version &>/dev/null; then error "Missing dependency: $cmd"; fi
done

# --- Variables ---------------------------------------------------------------
DOMAIN="$1"
NETWORK_NAME="internal_net"

COMPOSE_DIR="$HOME/Projects/projects/whisper"
DOCKER_FILE="$COMPOSE_DIR/Dockerfile"
COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

APP_PY="$COMPOSE_DIR/app.py"
REQUIREMENTS_TXT="$COMPOSE_DIR/requirements.txt"

SUBDOMAIN_CONF="$HOME/Projects/projects/nginx/subdomains/whisper.$DOMAIN.conf"

# --- Copy root-ca.crt to the context of docker build ------------------------
mkdir -p "$COMPOSE_DIR/certs"
cp "$COMPOSE_DIR/../certs/root-ca.crt" "$COMPOSE_DIR/certs/$DOMAIN.root-ca.crt"

# --- Create Dockerfile ------------------------------------------------------
log "Creating $DOCKER_FILE..."
write "$DOCKER_FILE" '
  FROM python:3.11-slim

  ENV PYTHONDONTWRITEBYTECODE=1 \
      PYTHONUNBUFFERED=1

  # System deps for webrtcvad and faster-whisper (ffmpeg not required for raw PCM)
  RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      && rm -rf /var/lib/apt/lists/*

  WORKDIR /app
  COPY requirements.txt /app/
  RUN pip install --no-cache-dir -r requirements.txt

  COPY app.py /app/

  EXPOSE 8000

  # For CPU. For GPU later: use --gpus all in docker run/compose and ensure CUDA-enabled ctranslate2.
  CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]' 

# --- Create docker-compose.yml ------------------------------------------------------
log "Creating $COMPOSE_FILE..."
write "$COMPOSE_FILE" "
  services:
    whisper:
      build: .
      container_name: whisper
      ports:
        - '8000:8000'
      environment:
        - TZ=America/Porto_Velho
      # For GPU later, uncomment the following lines and ensure CUDA image + drivers:
      # deploy:
      #   resources:
      #     reservations:
      #       devices:
      #         - capabilities: [gpu]
      # runtime: nvidia
      # gpus: all
      restart: unless-stopped
      networks:
        - $NETWORK_NAME
      volumes:
        - whisper-data:/models

  volumes:
    whisper-data:

  networks:
    $NETWORK_NAME:
      external: true"


# --- Create app.py ------------------------------------------------------
log "Creating $APP_PY..."
write "$APP_PY" '
  import asyncio
  import json
  import time
  from typing import Optional, Deque, Tuple
  from collections import deque

  import numpy as np
  import webrtcvad
  from fastapi import FastAPI, WebSocket, WebSocketDisconnect
  from faster_whisper import WhisperModel

  # -------- Config defaults --------
  DEFAULT_SR = 16000
  FRAME_MS = 20                 # size of incoming PCM frames (ms) - must be 10/20/30 for VAD
  VAD_MODE = 2                  # 0=very aggressive silence, 3=very aggressive speech
  SILENCE_MS_TO_FINAL = 800     # finalize utterance after this much continuous silence
  PARTIAL_EVERY_MS = 400        # throttle partial emissions
  PARTIAL_WINDOW_S = 4.0        # only transcribe the last N seconds for partials (cheaper)
  PARA_MIN_CHARS = 120          # minimum chars to flush a paragraph
  PARA_PUNCT = (".", "!", "?", "…")

  # Load model once (CPU by default). Persist downloads to /models (mounted volume).
  # For GPU later: device="cuda", compute_type="float16"
  model = WhisperModel("medium", device="cpu", compute_type="int8", download_root="/models")

  app = FastAPI()

  def pcm16_bytes_to_float32(arr_bytes: bytes) -> np.ndarray:
      # Convert little-endian 16-bit PCM to float32 [-1,1]
      samples = np.frombuffer(arr_bytes, dtype=np.int16).astype(np.float32)
      return samples / 32768.0

  def tail_pcm16(pcm: bytes, sr: int, seconds: float) -> bytes:
      samples = int(sr * seconds)
      byte_len = samples * 2
      return pcm[-byte_len:] if len(pcm) > byte_len else pcm

  class StreamSession:
      def __init__(self, sample_rate: int, lang: Optional[str]):
          self.sr = sample_rate
          self.lang = lang
          self.vad = webrtcvad.Vad(VAD_MODE)
          self.frame_bytes = int(self.sr * FRAME_MS / 1000) * 2  # 2 bytes per sample
          self.buffer = bytearray()
          self.current_utt = bytearray()  # current utterance audio
          self.paragraph_buf = []         # accumulate finalized sentences into a paragraph
          self.last_speech_ts = time.time()
          self.last_partial_ts = 0.0
          self.in_speech = False
          self.silence_run_ms = 0
          self.frames_q: Deque[Tuple[bytes, bool]] = deque()  # (frame, is_speech)

      def process_frame(self, frame: bytes) -> Tuple[bool, bool]:
          """Returns (is_speech, should_finalize)."""
          is_speech = False
          if len(frame) == self.frame_bytes:
              # VAD expects 16-bit mono PCM at 8k/16k/32k/48k and frames of 10/20/30 ms
              is_speech = self.vad.is_speech(frame, self.sr)

          now = time.time()
          if is_speech:
              if not self.in_speech:
                  # transitioned from silence -> speech
                  self.in_speech = True
              self.silence_run_ms = 0
              self.last_speech_ts = now
          else:
              # only count silence after last speech activity
              self.silence_run_ms = int((now - self.last_speech_ts) * 1000)

          should_finalize = False
          if self.in_speech and self.silence_run_ms >= SILENCE_MS_TO_FINAL:
              should_finalize = True
              self.in_speech = False
              self.silence_run_ms = 0

          return is_speech, should_finalize

      def want_partial(self) -> bool:
          now = time.time()
          if (now - self.last_partial_ts) * 1000 >= PARTIAL_EVERY_MS:
              self.last_partial_ts = now
              return True
          return False

  async def transcribe_segment(audio_pcm16: bytes, sr: int, lang: Optional[str]) -> str:
      # Convert to float32 for faster-whisper
      audio = pcm16_bytes_to_float32(audio_pcm16)
      segments, _info = model.transcribe(audio, language=lang, beam_size=1, vad_filter=False)
      text = "".join(seg.text for seg in segments)
      return text.strip()

  @app.websocket("/ws")
  async def ws_handler(ws: WebSocket):
      await ws.accept()
      session: Optional[StreamSession] = None
      try:
          while True:
              msg = await ws.receive()
              if "text" in msg:
                  try:
                      data = json.loads(msg["text"])
                  except Exception:
                      await ws.send_text(json.dumps({"type": "error", "error": "invalid_json"}))
                      continue

                  if data.get("event") == "start":
                      sr = int(data.get("sample_rate", DEFAULT_SR))
                      if sr not in (8000, 16000, 32000, 48000):
                          await ws.send_text(json.dumps({"type": "error", "error": "unsupported_sample_rate"}))
                          continue
                      lang = data.get("lang")
                      session = StreamSession(sr, lang)
                      await ws.send_text(json.dumps({"type": "info", "message": "stream_started", "sr": sr, "lang": lang}))
                      continue

                  if data.get("event") == "stop":
                      if session and len(session.current_utt) > 0:
                          final_text = await transcribe_segment(bytes(session.current_utt), session.sr, session.lang)
                          if final_text:
                              session.paragraph_buf.append(final_text)
                          # Flush any remaining paragraph
                          if session.paragraph_buf:
                              joined = " ".join(session.paragraph_buf).strip()
                              await ws.send_text(json.dumps({
                                  "type": "final",
                                  "text": joined,
                                  "start_ms": 0,
                                  "end_ms": 0
                              }))
                              session.paragraph_buf = []
                          session.current_utt.clear()
                      await ws.send_text(json.dumps({"type": "info", "message": "stream_stopped"}))
                      break

                  await ws.send_text(json.dumps({"type": "error", "error": "unknown_event"}))

              elif "bytes" in msg:
                  if session is None:
                      await ws.send_text(json.dumps({"type": "error", "error": "send_start_first"}))
                      continue

                  frame: bytes = msg["bytes"]
                  # Accumulate to exact FRAME_MS windows for VAD.
                  session.buffer.extend(frame)
                  while len(session.buffer) >= session.frame_bytes:
                      win = bytes(session.buffer[:session.frame_bytes])
                      del session.buffer[:session.frame_bytes]

                      is_speech, should_finalize = session.process_frame(win)
                      session.current_utt.extend(win)

                      # Partials (throttled, only last N seconds for cheaper inference)
                      if is_speech and session.want_partial() and len(session.current_utt) > 0:
                          tail = tail_pcm16(bytes(session.current_utt), session.sr, PARTIAL_WINDOW_S)
                          partial_text = await transcribe_segment(tail, session.sr, session.lang)
                          if partial_text:
                              await ws.send_text(json.dumps({
                                  "type": "partial",
                                  "text": partial_text
                              }))

                      # Finalize an utterance on sufficient silence; accumulate into paragraph
                      if should_finalize and len(session.current_utt) > 0:
                          final_text = await transcribe_segment(bytes(session.current_utt), session.sr, session.lang)
                          session.current_utt.clear()
                          if final_text:
                              session.paragraph_buf.append(final_text)
                              joined = " ".join(session.paragraph_buf).strip()
                              if len(joined) >= PARA_MIN_CHARS and joined.endswith(PARA_PUNCT):
                                  await ws.send_text(json.dumps({
                                      "type": "final",
                                      "text": joined,
                                      "start_ms": 0,
                                      "end_ms": 0
                                  }))
                                  session.paragraph_buf = []

              else:
                  await ws.send_text(json.dumps({"type": "error", "error": "unsupported_message"}))

      except WebSocketDisconnect:
          pass
      except Exception as e:
          await ws.send_text(json.dumps({"type": "error", "error": str(e)}))
      finally:
          await ws.close()

  @app.get("/")
  def root():
      return {"status": "ok"}'

# --- Create requirements.txt ------------------------------------------------------
log "Creating $REQUIREMENTS_TXT..."
write "$REQUIREMENTS_TXT" '
  fastapi==0.111.0
  uvicorn[standard]==0.30.1
  faster-whisper==1.0.0
  webrtcvad==2.0.10
  numpy==1.26.4'

# --- Ensure Docker network exists --------------------------------------------
if ! docker network ls --format '{{.Name}}' | grep -qx "$NETWORK_NAME"; then
  log "Creating Docker network '$NETWORK_NAME'"
  docker network create "$NETWORK_NAME"
fi

# --- Launch Whisper ----------------------------------------------------------
log "Starting Whisper container"
cd "$COMPOSE_DIR"
docker compose build --no-cache
docker compose up -d

# --- UFW rules (safe) ---------------------------------------------------------
log "Configuring UFW (allow 8000)"
sudo ufw allow 8000/tcp  || true
sudo ufw reload || true
sudo ufw --force enable
