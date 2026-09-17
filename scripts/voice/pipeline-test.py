#!/usr/bin/env python3
"""Run a WAV file through a Home Assistant Assist pipeline, end to end.

Feeds audio in over HA's websocket API exactly where a satellite would
(speech-to-text stage), then follows the pipeline through intent/LLM and
text-to-speech, downloads the spoken reply, and prints per-stage timings.
Everything except the ESP32 itself is exercised. See VOICE.md "Pipeline test".

    scripts/voice/pipeline-test.py question.wav [question2.wav ...]

Needs: websockets and aiohttp (a throwaway venv is fine), and
scripts/voice/ha-api.sops.yaml with a Home Assistant long-lived access token
under `token`. The token is decrypted in memory and never printed.
"""

from __future__ import annotations

import argparse
import asyncio
import warnings

with warnings.catch_warnings():
    warnings.simplefilter("ignore", DeprecationWarning)
    import audioop  # stdlib through Python 3.12; the dev VM runs 3.12
import json
import subprocess
import time
import wave
from pathlib import Path

import aiohttp
import websockets

REPO = Path(__file__).resolve().parents[2]
HA = "192.168.50.104:8123"
CHUNK_MS = 20


def token() -> str:
    out = subprocess.run(
        ["sops", "decrypt", "--extract", '["token"]',
         str(REPO / "scripts/voice/ha-api.sops.yaml")],
        check=True, capture_output=True, text=True, cwd=REPO,
    )
    return out.stdout.strip()


def pcm16k(path: Path) -> bytes:
    """Mono 16-bit 16 kHz PCM, which is what HA's STT stage expects."""
    with wave.open(str(path)) as w:
        if w.getsampwidth() != 2:
            raise SystemExit(f"{path}: need 16-bit PCM")
        frames = w.readframes(w.getnframes())
        if w.getnchannels() == 2:
            frames = audioop.tomono(frames, 2, 0.5, 0.5)
        if w.getframerate() != 16000:
            frames, _ = audioop.ratecv(frames, 2, 1, w.getframerate(), 16000, None)
    return frames


async def run_one(ws, msg_id: int, pipeline_id: str, audio: bytes, label: str,
                  tok: str, outdir: Path) -> None:
    t0 = time.monotonic()
    marks: dict[str, float] = {}
    await ws.send(json.dumps({
        "id": msg_id, "type": "assist_pipeline/run",
        "start_stage": "stt", "end_stage": "tts",
        "input": {"sample_rate": 16000},
        "pipeline": pipeline_id, "timeout": 120,
    }))
    stt_text = reply = tts_url = None
    first_delta = None
    while True:
        msg = json.loads(await ws.recv())
        if msg.get("id") != msg_id:
            continue
        if msg["type"] == "result":
            if not msg["success"]:
                raise SystemExit(f"{label}: run refused: {msg.get('error')}")
            continue
        ev = msg["event"]
        et, data = ev["type"], ev.get("data") or {}
        now = time.monotonic() - t0
        marks.setdefault(et, now)
        if et == "run-start":
            hid = data["runner_data"]["stt_binary_handler_id"]
            step = 16000 * 2 * CHUNK_MS // 1000
            marks["audio-sent-start"] = time.monotonic() - t0
            for i in range(0, len(audio), step):
                await ws.send(bytes([hid]) + audio[i:i + step])
            await ws.send(bytes([hid]))  # end of audio
            marks["audio-sent-end"] = time.monotonic() - t0
        elif et == "stt-end":
            stt_text = data["stt_output"]["text"]
        elif et == "intent-progress" and first_delta is None and data.get("chat_log_delta"):
            first_delta = now
        elif et == "intent-end":
            io = data["intent_output"]
            reply = io["response"]["speech"].get("plain", {}).get("speech")
            marks["processed_locally"] = data.get("processed_locally")
        elif et == "tts-end":
            tts_url = data["tts_output"]["url"]
        elif et == "error":
            raise SystemExit(f"{label}: pipeline error: {data}")
        elif et == "run-end":
            break

    fetch_t = None
    if tts_url:
        url = tts_url if tts_url.startswith("http") else f"http://{HA}{tts_url}"
        t1 = time.monotonic()
        async with aiohttp.ClientSession() as s:
            async with s.get(url, headers={"Authorization": f"Bearer {tok}"}) as r:
                body = await r.read()
        fetch_t = time.monotonic() - t1
        ext = Path(url.split("?")[0]).suffix or ".bin"
        out = outdir / f"{label}-reply{ext}"
        out.write_bytes(body)

    def d(a: str, b: str) -> str:
        return f"{(marks[b] - marks[a]) * 1000:7.0f} ms" if a in marks and b in marks else "      n/a"

    print(f"\n== {label}")
    print(f"   heard:   {stt_text!r}")
    print(f"   replied: {reply!r}  (local intent: {marks.get('processed_locally')})")
    print(f"   STT       {d('stt-start', 'stt-end')}  (includes streaming the audio in)")
    print(f"   intent    {d('intent-start', 'intent-end')}"
          + (f"  first token {(first_delta - marks['intent-start']) * 1000:.0f} ms" if first_delta else ""))
    print(f"   TTS       {d('tts-start', 'tts-end')}  (URL issued; audio renders on fetch)")
    if fetch_t is not None:
        print(f"   TTS fetch {fetch_t * 1000:7.0f} ms  -> {out.name} ({len(body):,} B)")
        total = marks["run-end"] + fetch_t
        print(f"   total     {total * 1000:7.0f} ms  from audio start to reply audio in hand")


async def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("wavs", nargs="+", type=Path)
    ap.add_argument("--pipeline", default="Doofus")
    ap.add_argument("--out", type=Path, default=Path("."))
    args = ap.parse_args()

    tok = token()
    async with websockets.connect(f"ws://{HA}/api/websocket", max_size=None) as ws:
        assert json.loads(await ws.recv())["type"] == "auth_required"
        await ws.send(json.dumps({"type": "auth", "access_token": tok}))
        if json.loads(await ws.recv())["type"] != "auth_ok":
            raise SystemExit("HA rejected the token")
        await ws.send(json.dumps({"id": 1, "type": "assist_pipeline/pipeline/list"}))
        items = json.loads(await ws.recv())["result"]["pipelines"]
        pid = next((p["id"] for p in items if p["name"] == args.pipeline), None)
        if not pid:
            raise SystemExit(f"no pipeline named {args.pipeline!r}")
        for n, wav in enumerate(args.wavs, start=2):
            await run_one(ws, n, pid, pcm16k(wav), wav.stem, tok, args.out)


if __name__ == "__main__":
    asyncio.run(main())
