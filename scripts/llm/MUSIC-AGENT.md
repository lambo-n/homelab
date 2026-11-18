# Generating music on `llm`

You have SSH access to one host, `llm`, a GPU VM in a homelab, as user `dev`
with passwordless `sudo`. It runs two music models on its GPU:

| Model | Makes | Mode | Command |
|---|---|---|---|
| **MiniMax Music 3** | Songs with sung lyrics | `music-lyrics` | `music-lyrics-gen` |
| **Stable Audio 3 Medium** | Instrumental music, no vocals | `music-instrument` | `music-instrument-gen` — **not ready yet, see the end** |

Each run writes a WAV file to `/models/music/` on the VM, and you copy it back
with `scp`. All commands below run on your machine; each `ssh llm '…'` runs
one command on the VM.

## Rules

- **Only use the two wrapper commands.** Never run `audiocpp_cli` directly:
  without the wrapper's settings, this GPU produces a file of pure noise and
  still reports success.
- **Music mode takes the GPU from the chat models.** While it's on, the
  homelab's chat and coding models (the `:8080` router) are offline. The small
  `fast` model and the voice assistant keep working. Switch back to normal mode
  when your whole batch is done (step 6), not after each song. Don't leave it
  in music mode.
- Use `sudo` only for `llm-mode`. Don't start, stop or change any other
  service, and don't delete or overwrite anything in `/models/music/`.
- **One song at a time.** Wait for a run to finish before starting the next.
  Files are named by the second they finish, and two runs would also compete
  for GPU memory.
- **Keep songs to 60 seconds or less** unless the owner asks for longer.
  Longer songs haven't been measured on this card and need more GPU memory.

## 1. Check the mode

```bash
ssh llm sudo llm-mode status
```

- `llama-router: inactive` with `llama-fast: active`: a music mode is already
  on; go to step 3.
- `sd-server: active`: someone is generating images. Don't switch modes; wait,
  or ask the owner.

## 2. Switch to music mode

```bash
ssh llm sudo llm-mode music-lyrics
```

It takes up to a minute and prints
`router stopped; fast and whisper kept; run music-lyrics-gen as dev`.

## 3. Write the style and lyrics

`music-lyrics-gen "<style>" "<lyrics>" [seconds] [seed]`

| Argument | Default | Notes |
|---|---|---|
| `style` | required | What the music sounds like. See below |
| `lyrics` | required | What is sung. It can't be empty: this model always sings |
| `seconds` | `30` | A **maximum**, not an exact length. The song may end sooner |
| `seed` | random | The same seed, style, lyrics and length give the identical file. The wrapper prints the seed it used |

**Style** works best covering three things, in plain sentences:

- **Overall:** genre and subgenre, BPM, key, mood and how it develops, and
  production (e.g. "polished studio pop", "lo-fi bedroom recording").
- **Vocals:** gender, timbre, delivery (breathy, belted, rap), harmonies,
  backing vocals, effects.
- **Arrangement:** lead and supporting instruments, groove, bass, drums, and
  how instruments change between sections.

The model treats these as guidance, not guarantees: tempo, key and structure
may not match exactly.

**Lyrics** take section tags: `[Intro]`, `[Verse]`, `[Pre-Chorus]`,
`[Chorus]`, `[Post-Chorus]`, `[Bridge]`, `[Instrumental]`, `[Solo]`,
`[Outro]`. Put each tag before the lines of its section. A tag with no lines
after it, like `[Solo]`, asks for an instrumental passage. For music with no
singing at all, use `music-instrument-gen` once it's ready, not this model.

## 4. Generate

A run takes **about 9 seconds per second of audio**: about 1.5 minutes for a
10 s song, and about 5 minutes for 30 s. The first run after the VM boots
takes a bit longer.

So that quoting can't break the lyrics (apostrophes, quotes), send the
command as a script on standard input, and run it in the background so a
dropped SSH connection doesn't kill it:

```bash
ssh llm 'bash -s' <<'EOF'
nohup music-lyrics-gen \
  "Upbeat indie pop, 118 BPM, bright female vocal, jangly guitars, warm bass" \
  "[Verse]
I left the porch light on for you
[Chorus]
We don't need a reason, we just need the night" \
  30 > ~/music-last.log 2>&1 &
EOF
```

Write the style and lyrics between the double quotes. Inside them, write
`\"` for a double quote and `\$` for a dollar sign. Line breaks inside the
lyrics are fine.

## 5. Wait for it, check the file, copy it back

Every 30–60 s, run:

```bash
ssh llm tail -n 2 ~/music-last.log
```

- No `saved` line yet: still running; check again later.
- `saved /models/music/20261118-070636.wav (seed 1234567)`: done. Note the
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
print(f"{w.getnframes()/w.getframerate():.1f}s peak={p:.3f} clipped={c}")
EOF
```

Put the real filename in place of `FILE`. A healthy song has a peak below
`1.000` and few or no clipped samples. `peak=1.000` with a clipped count close
to the total sample count means the file is noise: report it, don't retry.

Copy it back:

```bash
scp llm:/models/music/20261118-070636.wav .
```

If you lost the filename, list the newest files:

```bash
ssh llm ls -t /models/music | head
```

## 6. Switch back to normal mode when the batch is done

```bash
ssh llm sudo llm-mode normal
```

It prints `llama-fast ready` on success.

## Troubleshooting

| Symptom | Meaning |
|---|---|
| `llama-router holds the card; run: sudo llm-mode music-lyrics` | Music mode is off; do step 2 |
| `sd-server holds the card` | Image mode is on; wait, or ask the owner |
| `usage: music-lyrics-gen …` | Style or lyrics was missing or empty |
| `out of memory` / `OUT_OF_DEVICE_MEMORY` in the log | The song was too long for the GPU; try fewer seconds and report it |
| `peak=1.000` with nearly every sample clipped | The GPU produced noise; report it, don't retry |
| The log stops changing for over 10 minutes with no `saved` line | Report `ssh llm tail -n 20 ~/music-last.log` |

## Instrumental music (Stable Audio 3 Medium): not ready yet

This is still being set up. Until this section is rewritten with full
instructions, **don't run `music-instrument-gen` or
`llm-mode music-instrument`**, even if they exist on the VM. The planned
interface is `music-instrument-gen "<style>" [seconds] [seed]`, in mode
`music-instrument`, with the same output folder and the same rules as above.
