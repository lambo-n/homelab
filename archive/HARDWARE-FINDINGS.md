# Hardware findings — dated incidents and corrections

> 📦 **Archived 2026-10-05.** Incidents and resolved hazards recorded while
> inventorying the host. Current state: [../HARDWARE.md](../HARDWARE.md).

## 2026-09-09 — the `/mnt/sas{1,2,3}` mount hazard, resolved

> Moved from `HARDWARE.md` → *Devices* in the 2026-10-05 docs pass, as it stood.

| ~~Live hazard~~ | ✅ **Resolved 2026-09-09** — `/mnt/sas{1,2,3}` unmounted, fstab entries removed, host rebooted clean |

## 2026-09-16 — ATS passthrough lockup and the `pci=noats` fix, as first recorded

> Moved from `HARDWARE.md` → *Devices* in the 2026-10-05 docs pass, as it stood.

- 🔴 **Passthrough with ATS enabled hard-locks the host.** First `qm start 105`
  on 2026-09-16: after `vfio-pci` reset the card, VT-d Device-TLB invalidations
  to `53:00.0` timed out (`DMAR: … Invalidation Time-out Error`, `QI PRIOR:
  Device-TLB Invalidation qw0 = 0x5300530000000003`), and 45 s later
  `watchdog: CPU13: Watchdog detected hard LOCKUP`. The whole host was down until
  a power cycle. **Fixed by `pci=noats`**, verified 2026-09-16 02:16 PDT: same
  reset sequence, no Device-TLB timeouts, `ATSCtl: Enable-` with the VM running,
  and the guest booted ([`archive/GPU-VM-BUILD.md`](GPU-VM-BUILD.md) C2a). Removing that parameter
  brings the lockup back.
