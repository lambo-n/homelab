#!/usr/bin/env bash
# Resize the Intel Arc Pro B70's BAR 2 to 32 GiB at boot, before any guest starts.
#
# RUNS ON THE PROXMOX HOST (192.168.50.101) AS ROOT, from gpu-rebar.service.
# See homelab/GPU-VM.md Phase D for how this was established.
#
# Why three steps: the card boots with a 256 MiB BAR 2 and a 56 GiB SR-IOV VF
# BAR 2 reservation filling its 64 GiB bridge window, so 32 GiB doesn't fit.
# What releases that reservation is a FAILED 32 GiB attempt: its rollback
# leaves VF BAR 2 unassigned. A 4 GiB resize does not release it, because 4 GiB
# fits beside it (first boot test, 2026-09-16: 4 GiB OK, then 32 GiB ENOSPC,
# VF BAR 2 still assigned). The sequence that worked by hand was
# 32 GiB (ENOSPC) -> 4 GiB -> 32 GiB, so this replays exactly that, and logs
# VF BAR 2's size before each step so the journal shows whether it held.
#
# Why it's safe to fail: any failure leaves the card at 256 MiB or 4 GiB and
# rebinds it to vfio-pci, and VM 105 works at any BAR size, just with a smaller
# CPU-visible VRAM window. Nothing requires this unit, so boot is never blocked.
set -euo pipefail

GPU=0000:53:00.0
AUD=0000:54:00.0
DEV=/sys/bus/pci/devices
VFIO=/sys/bus/pci/drivers/vfio-pci
WANT=$((32 << 30))

log() { echo "gpu-rebar: $*"; }

# sysfs resource file: line N+1 is resource index N. BAR 2 is index 2 (line 3);
# SR-IOV VF BARs are indices 7-12, so VF BAR 2 is index 9 (line 10).
# An unassigned resource reads 0x0 0x0, which yields size 1 -- reported as 0.
res_size() {
  local start end _flags
  read -r start end _flags < <(sed -n "$1p" "$DEV/$GPU/resource")
  if [ $(( end )) -eq 0 ]; then echo 0; else echo $(( end - start + 1 )); fi
}
bar2_size() { res_size 3; }
vfbar2() { echo "VF BAR 2 $(( $(res_size 10) >> 30 )) GiB"; }

drivers() {
  local f d
  for f in "$GPU" "$AUD"; do
    d=$(readlink "$DEV/$f/driver" 2>/dev/null || true)
    if [ -n "$d" ]; then log "$f driver: ${d##*/}"; else log "$f driver: NONE"; fi
  done
}

size=$(bar2_size)
if [ "$size" -eq "$WANT" ]; then
  log "BAR 2 already 32 GiB; nothing to do"
  exit 0
fi

# Unbinding vfio-pci while QEMU holds the card blocks, so never touch it then.
if [ -e /var/run/qemu-server/105.pid ] && kill -0 "$(cat /var/run/qemu-server/105.pid)" 2>/dev/null; then
  log "VM 105 is running; refusing to touch the card"
  exit 1
fi

# Everything below assumes vfio-pci owns the card (GPU-VM.md B1).
if [ ! -d "$VFIO" ]; then
  log "vfio-pci driver not present; refusing"
  exit 1
fi

rebind() {
  local f
  for f in "$GPU" "$AUD"; do
    [ -e "$DEV/$f/driver" ] || echo "$f" > "$VFIO/bind" 2>/dev/null || true
  done
  log "BAR 2 is $(( $(bar2_size) >> 20 )) MiB"
  drivers
}
trap rebind EXIT

# driver_override BEFORE unbinding: xe is loaded on the host too, and any stray
# probe while the card is unbound must only be able to land on vfio-pci.
for f in "$GPU" "$AUD"; do
  echo vfio-pci > "$DEV/$f/driver_override"
  if [ -e "$DEV/$f/driver" ]; then echo "$f" > "$DEV/$f/driver/unbind"; fi
done

log "BAR 2 is $(( size >> 20 )) MiB, $(vfbar2); trying 32 GiB directly"
if echo 15 > "$DEV/$GPU/resource2_resize" 2>/dev/null; then
  log "resize complete (32 GiB on the first try)"
  exit 0
fi
log "direct 32 GiB refused, as expected while VF BAR 2 is assigned; now $(vfbar2)"
if ! echo 12 > "$DEV/$GPU/resource2_resize"; then
  log "4 GiB step failed"
  exit 1
fi
log "4 GiB done, $(vfbar2); trying 32 GiB"
if ! echo 15 > "$DEV/$GPU/resource2_resize"; then
  log "32 GiB step failed; BAR 2 stays at 4 GiB, $(vfbar2)"
  exit 1
fi
log "resize complete"
