# Generating images on `llm` (FLUX.2-dev)

You have SSH access to one host, `llm`, a GPU VM in a homelab, as user `dev`
with passwordless `sudo`. It runs FLUX.2-dev image generation. You submit jobs
over SSH and copy the finished PNGs back with `scp`. All commands below run on
this machine; each `ssh llm '…'` runs one command on the VM.

## Rules

- **Never print, copy or store the API key.** Always read it on the VM inside
  the same remote command that uses it, exactly as shown below. Never `cat`
  `/etc/llama/api-keys` or move it off the VM.
- **Never print a job response body unfiltered.** A finished job's JSON holds
  the image as several MB of base64. Always pipe it through the `jq` filter shown.
- **Image mode takes the GPU from everything else.** While it's on, the
  homelab's chat models and its voice assistant's speech-to-text are offline.
  Switch back to normal mode when your whole batch is done (step 5), not after
  each image. Don't leave it in image mode.
- Use `sudo` only for `llm-mode` and for reading the key as shown. Don't
  start, stop or change any other service, and don't delete or overwrite
  anything in `/models/images/`.
- One job at a time: submit, poll to completion, then submit the next.

## 1. Check the mode

```bash
ssh llm sudo llm-mode status
```

`sd-server:    active` means image mode is already on; go to step 3.

## 2. Switch to image mode

```bash
ssh llm sudo llm-mode image
```

Takes up to a minute. It prints `sd-server ready on :8082` on success.

## 3. Submit a job

Write the request as JSON and pipe it over SSH (this avoids quoting problems):

```bash
echo '{"prompt":"a paper crane on a desk, soft light","width":1024,"height":1024}' \
  | ssh llm 'K=$(sudo sed -n 3p /etc/llama/api-keys); curl -s -H "Authorization: Bearer $K" -H "Content-Type: application/json" --data-binary @- localhost:8082/sdcpp/v1/img_gen'
```

The reply contains the job id: `{"id":"job_6ac983f5_00000000","status":"queued",…}`.

Request fields:

| Field | Default | Notes |
|---|---|---|
| `prompt` | required | Natural language works well; FLUX.2 reads long, detailed prompts |
| `width`, `height` | 1024 | Multiples of 16. Time grows with pixel count |
| `sample_params` | `{"sample_steps":28}` | 20–28 for finished images; 4–8 for quick drafts |
| `seed` | -1 (random) | Set a number to reproduce an image |
| `negative_prompt` | none | Has little effect on this model |

**Expect about 7 minutes per 1024×1024 image at 28 steps** (~12.5 s per step,
plus about a minute of loading). Smaller sizes and fewer steps are faster.

## 4. Poll until it finishes, then copy the file

Every 15–30 s, run this (put your job id in place of `JOB`):

```bash
ssh llm 'K=$(sudo sed -n 3p /etc/llama/api-keys); h=$(mktemp); curl -s -D "$h" -H "Authorization: Bearer $K" localhost:8082/sdcpp/v1/jobs/JOB | jq -c "{status, queue_position, error}"; grep -i "^x-saved-images" "$h"; rm -f "$h"'
```

- `"status":"queued"` or `"generating"`: poll again later.
- `"status":"completed"`: the next line is
  `X-Saved-Images: 20261010-001848-6ac983f5-0.png`. The image is saved on the VM
  at the first poll that sees the job completed, so **keep polling until then**:
  a finished job that's never polled is never saved, and the server forgets
  finished jobs after a while. Later polls don't repeat the header.
- `"status":"failed"`: report the `error` value.

Copy the image back:

```bash
scp llm:/models/images/20261010-001848-6ac983f5-0.png .
```

If you lost the filename, list the newest files:

```bash
ssh llm ls -t /models/images | head
```

## 5. Switch back to normal mode when the batch is done

```bash
ssh llm sudo llm-mode normal
```

It prints `llama-fast ready` on success.

## Troubleshooting

| Symptom | Meaning |
|---|---|
| `curl` prints nothing, or the connection is refused | Image mode is off; do step 2 |
| `{"error":"invalid api key"}` | The key wasn't read; use the commands exactly as written |
| `{"error":"sd-server unreachable"}`, or `404`/`410` for a job you submitted | `sd-server` restarted and lost the job; submit it again. If it repeats, report `ssh llm sudo journalctl -u sd-server -n 30 --no-pager` |
| `429` on submit | A job is already queued; wait for it |
