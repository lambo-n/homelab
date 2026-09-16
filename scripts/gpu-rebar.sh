#!/usr/bin/env bash
# Resize the Intel Arc Pro B70's BAR 2 to 32 GiB at boot, before any guest starts.
#
# RUNS ON THE PROXMOX HOST (192.168.50.101) AS ROOT, from gpu-rebar.service.
# See homelab/GPU-VM.md Phase D for how this was established.
#
# Why two steps: the card boots with a 256 MiB BAR 2 and a 56 GiB SR-IOV VF BAR
# reservation filling its 64 GiB bridge window. A direct 32 GiB resize fails with
# -ENOSPC. Resizing to 4 GiB first makes the kernel drop the (unused) VF
# reservation, and 32 GiB then fits inside the root port's firmware-set 72 GiB.
# The reservation comes back on every boot, so both steps run every boot.
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

# BAR 2 is resource index 2, i.e. line 3 of the sysfs resource file.
bar2_size() {
  local start end _flags
  read -r start end _flags < <(sed -n 3p "$DEV/$GPU/resource")
  echo $(( end - start + 1 ))
}

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

log "BAR 2 is $(( size >> 20 )) MiB; resizing to 4 GiB, then 32 GiB"
if ! echo 12 > "$DEV/$GPU/resource2_resize"; then
  log "4 GiB step failed"
  exit 1
fi
if ! echo 15 > "$DEV/$GPU/resource2_resize"; then
  log "32 GiB step failed; BAR 2 stays at 4 GiB"
  exit 1
fi
log "resize complete"
