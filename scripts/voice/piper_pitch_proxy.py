#!/usr/bin/env python3
"""Wyoming TTS proxy that pitch-shifts a Piper voice without changing its speed.

Sits in front of the real wyoming-piper (default :10200) and advertises a
single derived voice on its own port -- e.g. en_US-norman-medium_x0.8, Norman
(medium) pitched down 20%. Home Assistant sees it as its own Wyoming
integration/voice; wyoming-piper's own voice list is untouched.

The shift is ffmpeg's asetrate+atempo trick: asetrate alone would lower both
pitch and tempo together, so atempo re-speeds playback by 1/pitch to cancel
the tempo change back out, leaving only the pitch shift.
"""
import argparse
import asyncio
import logging

from wyoming.audio import AudioChunk, AudioStart, AudioStop
from wyoming.client import AsyncTcpClient
from wyoming.event import Event
from wyoming.info import Attribution, Describe, Info, TtsProgram, TtsVoice
from wyoming.server import AsyncEventHandler, AsyncServer
from wyoming.tts import Synthesize, SynthesizeVoice

_LOGGER = logging.getLogger(__name__)
_ATTRIBUTION = Attribution(name="rhasspy", url="https://github.com/rhasspy/piper")


async def _pitch_shift(
    pcm: bytes, rate: int, width: int, channels: int, pitch: float
) -> bytes:
    """Pitch-shift raw PCM by `pitch` (e.g. 0.8 = 20% lower), same duration."""
    if width != 2:
        raise ValueError(f"Unsupported sample width: {width} (expected 2)")

    new_rate = round(rate * pitch)
    tempo = 1.0 / pitch
    filt = f"asetrate={new_rate},aresample={rate},atempo={tempo}"

    proc = await asyncio.create_subprocess_exec(
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "s16le",
        "-ar",
        str(rate),
        "-ac",
        str(channels),
        "-i",
        "pipe:0",
        "-filter:a",
        filt,
        "-f",
        "s16le",
        "-ar",
        str(rate),
        "-ac",
        str(channels),
        "pipe:1",
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    out, err = await proc.communicate(pcm)
    if proc.returncode != 0:
        raise RuntimeError(f"ffmpeg failed ({proc.returncode}): {err.decode(errors='replace')}")

    return out


class PitchProxyHandler(AsyncEventHandler):
    def __init__(
        self,
        backend_host: str,
        backend_port: int,
        backend_voice: str,
        voice_name: str,
        pitch: float,
        *args,
        **kwargs,
    ) -> None:
        super().__init__(*args, **kwargs)
        self.backend_host = backend_host
        self.backend_port = backend_port
        self.backend_voice = backend_voice
        self.voice_name = voice_name
        self.pitch = pitch

    def _info(self) -> Info:
        return Info(
            tts=[
                TtsProgram(
                    name="piper-pitch",
                    description="Piper voice, pitch-shifted with tempo held constant",
                    attribution=_ATTRIBUTION,
                    installed=True,
                    version=None,
                    supports_synthesize_streaming=False,
                    voices=[
                        TtsVoice(
                            name=self.voice_name,
                            description=(
                                f"{self.backend_voice}, pitched x{self.pitch} "
                                "(tempo-corrected)"
                            ),
                            attribution=_ATTRIBUTION,
                            installed=True,
                            version=None,
                            languages=[self.backend_voice.split("-", 1)[0]],
                            speakers=None,
                        )
                    ],
                )
            ]
        )

    async def handle_event(self, event: Event) -> bool:
        if Describe.is_type(event.type):
            await self.write_event(self._info().event())
            return True

        if not Synthesize.is_type(event.type):
            return True

        synthesize = Synthesize.from_event(event)
        try:
            await self._handle_synthesize(synthesize)
        except Exception as err:  # noqa: BLE001 -- report to the client, then re-raise
            from wyoming.error import Error

            await self.write_event(Error(text=str(err), code=err.__class__.__name__).event())
            raise

        return True

    async def _handle_synthesize(self, synthesize: Synthesize) -> None:
        rate = width = channels = None
        pcm = bytearray()

        async with AsyncTcpClient(self.backend_host, self.backend_port) as client:
            await client.write_event(
                Synthesize(
                    text=synthesize.text,
                    voice=SynthesizeVoice(name=self.backend_voice),
                ).event()
            )
            while True:
                event = await client.read_event()
                if event is None:
                    break
                if AudioStart.is_type(event.type):
                    start = AudioStart.from_event(event)
                    rate, width, channels = start.rate, start.width, start.channels
                elif AudioChunk.is_type(event.type):
                    pcm += AudioChunk.from_event(event).audio
                elif AudioStop.is_type(event.type):
                    break

        if rate is None:
            raise RuntimeError("Backend wyoming-piper never sent audio-start")

        shifted = await _pitch_shift(bytes(pcm), rate, width, channels, self.pitch)

        await self.write_event(AudioStart(rate=rate, width=width, channels=channels).event())
        await self.write_event(
            AudioChunk(audio=shifted, rate=rate, width=width, channels=channels).event()
        )
        await self.write_event(AudioStop().event())


async def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--uri", default="tcp://0.0.0.0:10201", help="Where this proxy listens")
    parser.add_argument("--backend-host", default="127.0.0.1")
    parser.add_argument("--backend-port", type=int, default=10200)
    parser.add_argument(
        "--voice", default="en_US-norman-medium", help="Underlying Piper voice to shift"
    )
    parser.add_argument("--pitch", type=float, default=0.8, help="Pitch multiplier, <1 = lower")
    parser.add_argument(
        "--name", default=None, help="Advertised voice name (default: <voice>_x<pitch>)"
    )
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    logging.basicConfig(level=logging.DEBUG if args.debug else logging.INFO)

    voice_name = args.name or f"{args.voice}_x{args.pitch}"

    server = AsyncServer.from_uri(args.uri)
    _LOGGER.info(
        "Serving %s (from %s x%s) on %s, backed by %s:%s",
        voice_name,
        args.voice,
        args.pitch,
        args.uri,
        args.backend_host,
        args.backend_port,
    )
    await server.run(
        lambda reader, writer: PitchProxyHandler(
            args.backend_host,
            args.backend_port,
            args.voice,
            voice_name,
            args.pitch,
            reader,
            writer,
        )
    )


if __name__ == "__main__":
    asyncio.run(main())
