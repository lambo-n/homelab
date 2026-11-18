# Generating music on `llm` (Stable Audio 3 Medium)

You have SSH access to one host, `llm`, a GPU VM in a homelab, as user `dev`
with passwordless `sudo`. It runs Stable Audio 3 Medium, which makes
**instrumental music from a text description**. It has no vocals and takes no
lyrics. Each run writes a 44.1 kHz stereo WAV file to `/models/music/` on the
VM, and you copy it back with `scp`. All commands below run on your machine;
each `ssh llm '…'` runs one command on the VM. Logged in on the VM itself,
drop the `ssh llm` and the quotes around it, e.g.
`music-instrument-gen "lo-fi piano, vinyl crackle" 60`.

## Rules

- **Only use `music-instrument-gen`.** Don't run `audiocpp_cli` directly.
  It's a command of its own, run as `dev` without `sudo`: not a subcommand
  of `llm` (the chat CLI) or of `llm-mode` (which only switches modes).
- **Music mode takes the GPU from the chat models.** While it's on, the
  homelab's chat and coding models (the `:8080` router) are offline. The small
  `fast` model and the voice assistant keep working. Switch back to normal mode
  when your whole batch is done (step 6), not after each clip. Don't leave it
  in music mode.
- Use `sudo` only for `llm-mode`. Don't start, stop or change any other
  service, and don't delete or overwrite anything in `/models/music/`.
- **One clip at a time.** Wait for a run to finish before starting the next.
  Files are named by the second they finish.
- **Keep clips to 60 seconds or less** unless the owner asks for longer.
  Longer clips haven't been measured on this card.

## 1. Check the mode

```bash
ssh llm sudo llm-mode status
```

Read the `mode:` line:

- `mode: music-instrument`: music mode is already on; go to step 3.
- `mode: normal`: go to step 2.
- `mode: image`: someone is generating images. Don't switch modes; wait, or
  ask the owner.
- `mode: agent or heretic`: someone has a long-context model session on the
  GPU. Switching ends it, so ask the owner first.

## 2. Switch to music mode

```bash
ssh llm sudo llm-mode music-instrument
```

It takes up to a minute and prints
`router stopped; fast and whisper kept; run music-instrument-gen as dev`.

## 3. Write the prompt

`music-instrument-gen "<style>" [seconds] [seed]`

| Argument | Default | Notes |
|---|---|---|
| `style` | required | What the music sounds like, in English |
| `seconds` | `30` | The length of the file. The music usually fades out over the last 2–4 s |
| `seed` | random | The same style, length and seed give near-identical audio. The wrapper prints the seed it used |

Describe the genre, mood, tempo, instruments and production in one or two
sentences, for example:

- `"Warm lo-fi hip hop, 80 BPM, dusty Rhodes chords, vinyl crackle, soft boom-bap drums"`
- `"Sweeping orchestral score, soaring strings, French horns, timpani rolls, cinematic and triumphant"`

Don't ask for vocals or singing: this model has none. Texture you name is
generated on purpose, so vinyl crackle in a lo-fi prompt is expected.

## 4. Generate

A 30 s clip takes **about 10 seconds**. The first run after the VM boots
takes about 20 s.

Send the command as a script on standard input, so quotes and apostrophes in
the style can't break it, and run it in the background so a dropped SSH
connection doesn't kill it:

```bash
ssh llm 'bash -s' <<'EOF'
nohup music-instrument-gen \
  "Warm lo-fi hip hop, 80 BPM, dusty Rhodes chords, vinyl crackle" \
  30 > ~/music-last.log 2>&1 &
EOF
```

Write the style between the double quotes. Inside them, write `\"` for a
double quote and `\$` for a dollar sign.

## 5. Wait for it, check the file, copy it back

After about 15 s, run:

```bash
ssh llm tail -n 2 ~/music-last.log
```

- No `saved` line yet: still running; check again in 10 s.
- `saved /models/music/20261118-073740.wav (seed 42)`: done. Note the
  filename and the seed.
- Any line with `error`, `abort`, `Aborted` or `out of memory`: it failed.
  Report the last 20 lines (`ssh llm tail -n 20 ~/music-last.log`).

Check that the file holds real audio, not noise:

```bash
ssh llm python3 -I - /models/music/FILE.wav <<'EOF'
import sys, wave, array
w = wave.open(sys.argv[1]); a = array.array("h", w.readframes(w.getnframes()))
p = max(abs(v) for v in a) / 32768
c = sum(1 for v in a if abs(v) >= 32767)
print(f"{w.getnframes()/w.getframerate():.1f}s peak={p:.3f} clipped={c} of {len(a)}")
EOF
```

Put the real filename in place of `FILE`.

- **Healthy:** clipped samples are none or a tiny fraction of the total, e.g.
  `peak=1.000 clipped=202 of 2646000`. This model often peaks at `1.000`
  with a few hundred clipped samples; that's how it mixes.
- **Noise:** the clipped count is close to the total, e.g.
  `clipped=2641920 of 2646000`. Report it, don't retry.

Copy it back:

```bash
scp llm:/models/music/20261118-073740.wav .
```

If you lost the filename, list the newest files:

```bash
ssh llm ls -t /models/music | head
```

## 6. Switch back to normal mode when the batch is done

```bash
ssh llm sudo llm-mode normal
```

It ends with `llama-fast ready` on success.

## Troubleshooting

| Symptom | Meaning |
|---|---|
| `llama-router holds the card; run: sudo llm-mode music-instrument` | Music mode is off; do step 2 |
| `sd-server holds the card` | Image mode is on; wait, or ask the owner |
| `usage: music-instrument-gen …` | The style was missing or empty |
| `Error: Connection error.` | You ran `llm music-instrument-gen`, which asks the chat CLI, whose models music mode stops. Drop the `llm` |
| `usage: sudo llm-mode MODE` | You passed `llm-mode` something that isn't a mode, e.g. `music-instrument-gen`. Run the generator on its own |
| `llm-mode: run with sudo` | `llm-mode` needs `sudo`; `music-instrument-gen` doesn't |
| `out of memory` / `OUT_OF_DEVICE_MEMORY` in the log | The clip was too long for the GPU; try fewer seconds and report it |
| Nearly every sample clipped | The GPU produced noise; report it, don't retry |
| No `saved` line after 2 minutes | Report `ssh llm tail -n 20 ~/music-last.log` |
