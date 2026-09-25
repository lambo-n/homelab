import asyncio
import subprocess

from fastapi import FastAPI, HTTPException, UploadFile
from fastapi.responses import FileResponse
from wyoming.asr import Transcribe, Transcript
from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.client import AsyncTcpClient

# wyoming-whisper on VM 105 -- the same STT backend voice/home-assistant uses.
# Reachable because the three k3s node IPs are already ufw-allowed for :10300
# (see homelab/VOICE.md); nothing here talks to whisper-server directly.
WHISPER_HOST = "192.168.50.107"
WHISPER_PORT = 10300
CHUNK_BYTES = 3200  # 0.1s of 16kHz mono 16-bit PCM

app = FastAPI()


def _decode_to_pcm16(data: bytes) -> bytes:
    # ffmpeg autodetects the input container/codec, so any format it reads
    # (mp3, m4a, wav, ...) works here, not just mp3.
    result = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", "pipe:0", "-ar", "16000", "-ac", "1", "-f", "s16le", "pipe:1"],
        input=data,
        capture_output=True,
    )
    if result.returncode != 0:
        raise HTTPException(400, f"ffmpeg could not decode this file: {result.stderr.decode(errors='replace')}")
    return result.stdout


@app.get("/healthz")
async def healthz():
    return {"ok": True}


@app.get("/transcribe.sh")
async def cli():
    # Lets a LAN device grab the client with `curl -O .../transcribe.sh`
    # instead of the script being copied around by hand.
    return FileResponse("/app/transcribe.sh", media_type="text/x-shellscript", filename="transcribe.sh")


@app.post("/transcribe")
async def transcribe(file: UploadFile):
    pcm = await asyncio.to_thread(_decode_to_pcm16, await file.read())

    async with AsyncTcpClient(WHISPER_HOST, WHISPER_PORT) as client:
        await client.write_event(Transcribe().event())
        await client.write_event(AudioStart(rate=16000, width=2, channels=1).event())
        for i in range(0, len(pcm), CHUNK_BYTES):
            chunk = pcm[i : i + CHUNK_BYTES]
            await client.write_event(AudioChunk(audio=chunk, rate=16000, width=2, channels=1).event())
        await client.write_event(AudioStop().event())

        while True:
            event = await client.read_event()
            if event is None:
                raise HTTPException(502, "wyoming-whisper closed the connection with no transcript")
            if Transcript.is_type(event.type):
                return {"text": Transcript.from_event(event).text}
