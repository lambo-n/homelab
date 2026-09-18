#!/usr/bin/env bash
# Run an ESPHome command against the voice satellite with its secrets present
# only for the length of the run. See VOICE.md V3.
#
#   scripts/esphome-run.sh config
#   scripts/esphome-run.sh compile
#   scripts/esphome-run.sh upload --device 192.168.50.x   (OTA)
#   scripts/esphome-run.sh logs --device 192.168.50.x
#
# secrets.sops.yaml is decrypted into a private tmpfs directory, and ESPHome's
# build tree (.esphome/, whose generated sources and firmware embed the Wi-Fi
# password and API key) is created beside it. Both go when the script exits, so
# no plaintext secret outlives the run -- AGENTS.md rule 6. The cost is a cold
# project build each time; the toolchain cache in ~/.platformio holds no secrets
# and survives, which keeps rebuilds to a few minutes.
#
# `compile` output is copied out ONLY when ESPHOME_KEEP_FIRMWARE names a
# directory, for the one-time USB flash from the workstation. That .bin embeds
# the secrets: delete it once flashed.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
cfg=voice-satellite.yaml

[ $# -ge 1 ] || { echo "usage: $0 <esphome command> [args]" >&2; exit 2; }
cmd=$1
shift

work=$(mktemp -d /dev/shm/esphome.XXXXXX)
trap 'rm -rf "$work"' EXIT
chmod 700 "$work"

cp "$repo/esphome/$cfg" "$work/$cfg"
# Local wake-word models resolve relative to the YAML, so they travel with it.
cp -r "$repo/esphome/wake_words" "$work/wake_words"
sops decrypt "$repo/esphome/secrets.sops.yaml" > "$work/secrets.yaml"

cd "$repo"
mise exec -- esphome "$cmd" "$work/$cfg" "$@"

if [ "$cmd" = compile ] && [ -n "${ESPHOME_KEEP_FIRMWARE:-}" ]; then
  # Located, not hardcoded: ESPHome 2026.9 builds with native ESP-IDF into
  # build/voice-satellite/build/, not PlatformIO's .pioenvs/ -- the path this
  # used to assume, which failed after a successful compile.
  bin=$(find "$work/.esphome/build" -name firmware.factory.bin | head -n 1)
  [ -n "$bin" ] || { echo "no firmware.factory.bin under $work" >&2; exit 1; }
  install -m 600 "$bin" "$ESPHOME_KEEP_FIRMWARE/"
  echo "kept $ESPHOME_KEEP_FIRMWARE/firmware.factory.bin -- contains secrets"
fi
