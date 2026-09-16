# GPU VM — Intel Arc Pro B70 passed whole to one LLM guest

> ✅ **Tofu prerequisites cleared 2026-09-15** (PR #19, `bb68244`): the provider
> lock now installs (`bpg/proxmox` 0.113.1), the LXC's stale state was persisted
> with `apply -refresh-only`, and `tofu plan -refresh=false` reports **No
> changes**. A clean baseline is what makes VM 105's diff readable, so this had
> to come first. The `hostpci { mapping = … }`, `initialization` (cloud-init)
> and `proxmox_virtual_environment_storage_zfspool` attributes used below were
> read from that provider's own schema, not from memory.

> 📝 **Plan, written 2026-09-15. Nothing below has been run yet.** Every host
> step has to be run by hand as root on `192.168.50.101`, because SSH from the
> dev VM is refused and the tofu token is read-only (`tofu/README.md`, "The
> argument for read-only"). Tick each step off here as it's done, and record
> what the host actually printed. `HARDWARE.md` was built the same way.

## Decisions

| | Choice | Why |
|---|---|---|
| Workload | **Local LLM inference** | owner, 2026-09-15 |
| VMID / IP | **`105`** / **`.107`** — both free | owner confirmed 2026-09-15 that no VM 105 exists. `TRUENAS.md` reserved both for a guest that was never created (superseded 2026-09-09 by host-native `sas-pool`), so this reclaims them. |
| GPU mode | **Whole card to one VM** (`vfio-pci`), no SR-IOV split | owner. The host's `xe` currently runs the card as an SR-IOV PF (`HARDWARE.md`), and that mode goes away. |
| Model storage | **`llm-pool`, one ZFS disk on `sde`** (`…150584Y`), with **no redundancy** | Models can be downloaded again, so losing the disk costs a re-download, not data. `sas-pool` belongs to the NAS and `archive-pool` to the DB and object storage. |
| Spare | **`sdf` (`…1505850`) stays a cold spare** | owner |
| Root disk | 32 GiB on `local-lvm` | Matches the other guests. The thin pool has ~82 GiB free, so keep the root disk small. |
| Guest OS | Ubuntu 24.04 LTS on the **HWE kernel (≥ 6.17)** | The host's `6.17.2-1-pve` is known to drive this card, and Intel's GPU compute packages support this release best. |
| Snapshots | **None.** `llm-pool` stays out of `sanoid.conf` on purpose. | Snapshotting multi-GB model files would only use up space. |

---

## Phase A — preflight and storage (no reboot, no guest affected)

### A1. Read before writing

```bash
pvesh get /cluster/nextid                       # expect 105; anything else means something claimed it
qm list; pct list
nproc; lscpu | grep -E 'Model name|Socket|NUMA node'
cat /sys/bus/pci/devices/0000:53:00.0/numa_node # GPU's NUMA node; matters if 2 sockets
readlink /sys/bus/pci/devices/0000:53:00.0/iommu_group   # GPU group; A4 asserts 9, and group numbers move
readlink /sys/bus/pci/devices/0000:54:00.0/iommu_group   # audio group, unrecorded in HARDWARE.md
lspci -nnk -s 53:00.0; lspci -nnk -s 54:00.0    # current drivers (expect xe / snd_hda_intel)
dmidecode -s system-product-name; dmidecode -s bios-version
pveversion
```

✅ **Run 2026-09-16 on the host console. What it printed:**

| | |
|---|---|
| `nextid` | **105** — still free, so A5's literal `/vms/105` ACL paths stand |
| Guests | VMs 101 `dev`, 102 `k3s-control`, 103 `k3s-worker1`, 104 `k3s-worker2`, all running; LXC 100 `tailscale-gateway`. **No 105.** |
| CPU | Xeon Silver 4314 @ 2.40 GHz — **1 socket**, 32 threads, **1 NUMA node** (`node0` = CPUs 0–31) |
| GPU NUMA node | `0` — i.e. the only one |
| IOMMU group, audio `54:00.0` | **10**. The GPU `53:00.0` is **9** (`HARDWARE.md`, 2026-09-09): **different groups.** |
| Drivers in use | `53:00.0` → `xe`; `54:00.0` → `snd_hda_intel` — exactly what B1's `softdep` lines name |
| Machine | **Dell PowerEdge T550**, BIOS **1.8.2** |
| Proxmox | `pve-manager/9.1.1`, kernel `6.17.2-1-pve` |

What that settles:

- **No CPU pinning, and the C2 conditional is closed.** One socket and one NUMA
  node leave `--affinity` / `--numa 1` nothing to choose between; the GPU's
  `numa_node=0` is the same node as every core. VM 105 takes 8 of 32 threads,
  unpinned.
- **The audio function is bound to `vfio-pci` for Phase D's sake, not the
  IOMMU's.** Groups 9 and 10 are separate, so `53:00.0` is assignable on its own
  and `54:00.0` is *not* dragged along by group membership. B1 binds it anyway so
  that no host driver holds a device under the card's bridges while Phase D
  rearranges those bridge windows — a choice, not a requirement. It is still not
  attached to the VM.
- **The B2 menu names are the right family to look for.** The T550 is Dell 15G,
  so *Integrated Devices → Memory Mapped I/O above 4 GB* / *Memory Mapped I/O
  Base* is 15G naming rather than a guess from a different generation. Still
  read the screen and record what it actually says.
- **"This BIOS has no ReBAR option" is now stamped at version 1.8.2.** A Dell
  BIOS update is the one thing that could reopen ReBAR; nothing in Phase D can.
  If the T550 ever ships a newer BIOS, that — and only that — is cause to retest.
- **Memory still fits.** 297 GiB of 503 is committed to the five existing guests
  (`HARDWARE.md`); VM 105 pins 64 more, leaving ~142 GiB free.

⚠️ **Not read: the GPU's own IOMMU group.** Only the audio function's was, and
A4's mapping asserts `iommugroup=9` from a reading taken 2026-09-09, before the
host moved to kernel `6.17.2-1-pve`. Group numbers are assigned at boot and can
shift. The line is now in the block above — run it before A4, and if it is not 9,
correct the `pvesh create` rather than letting PVE reject the mapping.

### A2. Prove `sde` is an orphan, then wipe it

`sdX` names move between boots (`HARDWARE.md`), so **use the by-id path only**:

```bash
D=/dev/disk/by-id/ata-HFS1T9G3H2X069N_ADB5N4365I150584Y
ls -l "$D"                   # confirm the serial ends 584Y
zpool status archive-pool    # 584Y must NOT be listed (members: 584Z, 5855, Micron 58D4)
zpool import                 # must NOT offer a pool built from this disk
zdb -l "${D}-part1"          # expect the OLD raidz2 pool's label, not a live pool
wipefs -a "$D"               # irreversible. Paste the path, don't type it.
```

✅ **Run 2026-09-16. All four proofs passed; `sde` is wiped.**

| Check | What came back |
|---|---|
| `ls -l "$D"` | → `../../sde`, serial ends **584Y** ✓ |
| `zpool status archive-pool` | ONLINE, `mirror-0` = **584Z · 5855 · Micron 58D4**. 584Y absent ✓ |
| `zpool import` | offers **`sas-pool`** only — no pool built from 584Y ✓ (but see the `sas-pool` note below) |
| `zdb -l "${D}-part1"` | the **old 5-disk raidz2**: `pool_guid 326662858968651967`, `txg 989116`, 584Y as `children[3]`, `sdf`/`…5850` as `children[4]` ✓ |
| `wipefs -a "$D"` | GPT at `0x200`, backup GPT at `0x1bf1fc55e00`, PMBR at `0x1fe` erased; partition table re-read OK |

⚠️ **The stale label carries the live pool's name.** `zdb -l` reports
`name: 'archive-pool'` — the same string as the pool that is running right now.
The name proves nothing; what proves these are different pools is their shape.
The live one is a 3-way `mirror-0`; the label is `type: 'raidz'`, `nparity: 2`,
five children, and a different `pool_guid`. **`sdf` (`…1505850`) still carries
that identical label**, so the same trap is waiting the day the spare gets used.
Consequence: never run `zpool import archive-pool` or `zpool import -f -a` on
this host — if an import is ever needed, name the pool by **guid**.

✅ **Both questions this output raised are now closed (2026-09-16).**

**`sas-pool` was not imported**, and had been missing since the host booted for
the GPU install on 2026-09-15 14:20 PDT. `smbd` was serving `/sas-pool` as an
empty directory and `sanoid` was snapshotting a dataset that did not exist —
**both dependants reported healthy**. The owner imported the pool (**140 GiB
intact, nothing lost**) and enabled `zfs-import-scan`. Cause and the durable fix
are in [`SAS-STORAGE.md`](SAS-STORAGE.md); the short version is that `sas-pool`
is not a PVE storage, so — unlike `archive-pool`, which `pvestatd` activates —
nothing owned its import, and both import units were unavailable that boot.

🔴 **This is a Phase B hazard, not just history.** Phase B reboots this host the
same way that boot did. B3 has been corrected accordingly: `zpool status -x`,
which it used to rely on, **cannot detect this** — an unimported pool is absent
rather than unhealthy, and `-x` reports "all pools are healthy" either way.

**`archive-pool`'s 280M was not data loss**, as suspected above, and the numbers
now say so precisely: `ALLOC 285M` against `USED 66.3G`. The gap is
`archive-pool/vm-104-disk-0` — **a zvol attached to running VM 104** — holding
66.1G of `refreservation` over 30.7M of `REFER`. Real contents are `minio-data`
147M and `postgres-data` 13M. `zpool list ALLOC` and `zfs list USED` are not the
same measurement; compare like with like before calling it loss.

> Two consequences worth carrying into Phase B. First, that zvol is attached to a
> **live VM**, so `archive-pool` cannot be exported or rebuilt without stopping
> VM 104 — `homelab-shutdown.sh` already handles this, but nothing ad-hoc should.
> Second, `sanoid` names snapshots in **UTC** while `zpool history` logs local
> **PDT**: a 17:00 history line produces `autosnap_2026-09-16_00:00_hourly`.
> Do not read snapshot names against journal timestamps to infer an outage
> window — that 7-hour skew invents export events that never happened.

### A3.### A3. Create `llm-pool` and register it with Proxmox

```bash
# $D does NOT survive a new shell or a reboot. Set it again, and prove it.
D=/dev/disk/by-id/ata-HFS1T9G3H2X069N_ADB5N4365I150584Y
test -b "$D" || { echo "REFUSING: '$D' is not a block device"; false; }
ls -l "$D"                   # -> ../../sde

zpool create -o ashift=12 -O compression=lz4 -O atime=off llm-pool "$D"
pvesm add zfspool llm-pool --pool llm-pool --content images --blocksize 64k
pvesm status | grep llm-pool
```

> ⚠️ **If `$D` is empty, `zpool create` does not stop — it guesses.** Observed
> 2026-09-16: the variable was lost between A2 and A3 (a new shell), and ZFS
> resolved the empty argument against its device search path, giving
> `cannot use '/dev/mapper/': must be a block device or regular file`. That one
> failed safe because a directory is not a disk. The `test -b` line above is
> there because the next-worst expansion might not.
>
> `pvesm add` then failed with `could not activate storage 'llm-pool'`, which is
> a consequence, not a second problem. **Check whether it left a half-written
> entry before retrying** — a storage that PVE cannot activate breaks later
> plans:
>
> ```bash
> grep -A4 llm-pool /etc/pve/storage.cfg   # expect no output
> pvesm remove llm-pool                    # only if the grep found something
> ```
>
> Using the `by-id` path rather than `sde` is what makes this safe to re-run
> after a reboot: `sdX` names move, `by-id` does not (`HARDWARE.md`).

- `ashift=12` because the SK hynix disks are 512e drives with 4K physical sectors. It can't be changed later.
- `blocksize 64k` sets the block size of each zvol Proxmox creates. Model files are large and read in long runs, so bigger blocks mean less metadata than the 16k default. It only applies to new zvols, so set it before creating the VM.
- `lz4` rather than `zstd`: model weights barely compress, and lz4 gives up quickly on data that doesn't.

✅ **Done 2026-09-16.** `zpool create` went through with no `-f` — as expected,
since A2's re-run found no signatures left — and `/etc/pve/storage.cfg` had no
stale `llm-pool` entry from the failed first attempt.

```
zpool status llm-pool -> ONLINE, single vdev ata-…150584Y (by-id, not sde)
pvesm status          -> llm-pool  zfspool  active  1804599296  408  1804598888  0.00%
```

**1 804 599 296 KiB = 1 721 GiB (1.68 TiB) usable.** The models disk in
`tofu/proxmox-llm-vm.tf` asks for **1400 GiB**, which leaves **321 GiB / 18.7%**
free — the ~20% headroom ZFS wants, so the figure in C2's table stands against
the real pool rather than the estimated one.

`blocksize 64k` is confirmed to have landed — it applies only to zvols created
*after* it is set, and VM 105's models disk is the zvol it exists for, so a
missing value would have meant the 16k default and no way to change it without
recreating the disk:

```
zfspool: llm-pool
    pool llm-pool
    blocksize 64k
    content images
    mountpoint /llm-pool
```

**Phase A storage is finished.** Next is A4, and it needs the GPU's IOMMU group
read first.

> **A clean `zpool create` is expected, and if it refuses with `contains a
> filesystem of type 'zfs_member'`, `-f` is the right answer here.** Re-running
> the A2 block on 2026-09-16 produced **no output from `wipefs -a`** and
> `zdb -l "${D}-part1"` → `No such file or directory`: there is no signature and
> no `part1` left for a probe to find. The old ZFS labels are still physically on
> the disk inside the former partition, with nothing pointing at them, which is
> the only way a complaint could still surface. The `zdb -l` output recorded in A2 is the
> proof of what they belong to: the decommissioned 5-disk raidz2, not a live
> pool. `zpool create` writes its own GPT with `part1` at the same 1 MiB offset,
> so the new labels land on top of the old ones and the ambiguity ends there.

### A4. PCI resource mapping

Proxmox only lets `root@pam` attach a raw `hostpci0: 0000:53:00.0`. A **mapping**
can be attached by any user or token that has `Mapping.Use`, so the VM is later expressible in tofu
without root:

```bash
pvesh create /cluster/mapping/pci --id arc-b70 \
  --description "Intel Arc Pro B70 32GB (ASRock) - whole card, LLM VM" \
  --map node=pve,path=0000:53:00.0,id=8086:e223,subsystem-id=1849:6025,iommugroup=9
pvesh get /cluster/mapping/pci/arc-b70
```

`iommugroup=9` is an assertion PVE checks **when the mapping is used**, not a
label. The 9 comes from a 2026-09-09 reading on an older kernel, and group
numbers are handed out at boot.

✅ **Created 2026-09-16**, `digest ae08d033`, map stored as
`node=pve,path=0000:53:00.0,id=8086:e223,subsystem-id=1849:6025,iommugroup=9`.

✅ **And verified against the running kernel**, which creating it does not do:
`readlink …/0000:53:00.0/iommu_group` → `…/kernel/iommu_groups/9` on
`6.17.2-1-pve`, matching the assertion. `HARDWARE.md`'s 2026-09-09 reading holds
across the kernel change.

> ⚠️ Worth keeping for the next mapping, since this one happened to be right:
> `pvesh get /cluster/mapping/pci/arc-b70` returns the stored string **verbatim**
> and will echo a wrong group number as happily as a right one. PVE compares the
> assertion against the hardware at **VM start**, so a stale number would not
> surface until Phase C — as VM 105 refusing to start, looking like a provider or
> tofu fault rather than a one-character mismatch here. The fix would be
> `pvesh set /cluster/mapping/pci/arc-b70 --map node=pve,path=0000:53:00.0,id=8086:e223,subsystem-id=1849:6025,iommugroup=<N>`,
> not an edit to this document.

The UI equivalent is Datacenter → Resource Mappings → PCI Devices → Add.

### A5. A permanent API token scoped to this VMID alone

The existing `tofu@pve!import` token is `PVEAuditor` and stays that way. This VM
gets a **second token that can write, but only to `/vms/105`** — so tofu creates
and manages this one guest on its own, while the other four keep their
read-only, import-only treatment (`tofu/README.md`, "The argument for
read-only"). Decided with the owner 2026-09-15.

> **VMID `105` is confirmed free** (owner, 2026-09-15 — the TrueNAS guest that
> would have taken it was never created). The ACL paths below are therefore
> literal. If `pvesh get /cluster/nextid` in A1 ever disagrees, stop: something
> else has claimed the id, and an ACL on the wrong `/vms/N` grants write on a
> guest that isn't this one.

**Roles** — three, each holding the narrowest set that does its job.

> ⚠️ **`VM.Monitor` is not a valid privilege on this host and is not in the list
> below.** An earlier draft included it; PVE 9.1.1 rejected the role outright with
> `400 Parameter verification failed. privs: invalid format - invalid privilege
> 'VM.Monitor'` (2026-09-16). It was over-specified in the first place — the
> `bpg/proxmox` provider never uses the QEMU monitor — so it was dropped rather
> than replaced, which suits a role whose whole purpose is to be minimal. The
> authoritative list for any future edit comes from the host, not from memory.
> `--help` does **not** enumerate them (tried 2026-09-16; it prints nothing).
> The built-in `Administrator` role holds every valid privilege, so read it there:
>
> ```bash
> pveum role list | grep -w Administrator
> ```
>
> Note the failure mode: `pveum role add` is **all-or-nothing**, so one bad
> privilege means the role does not exist at all, while the commands after it in
> the same paste still run. Check what actually landed with
> `pveum role list | grep Tofu` before assuming a clean slate.

```bash
# on 192.168.50.101, as root
pveum role add TofuVM --privs "VM.Audit,VM.Allocate,VM.PowerMgmt,\
VM.Config.Disk,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,\
VM.Config.Options,VM.Config.HWType,VM.Config.CDROM,VM.Config.Cloudinit"
pveum role add TofuStorage --privs "Datastore.Audit,Datastore.AllocateSpace,Datastore.AllocateTemplate"
pveum role add TofuMapping --privs "Mapping.Audit,Mapping.Use"
```

✅ **All three roles exist as of 2026-09-16**, `TofuVM` with the eleven
privileges above and no `VM.Monitor`. `TofuStorage` and `TofuMapping` had already
been created by the first, partially-failed paste, so re-running their `role add`
returns `role 'X' already exists` — harmless, and confirmation rather than an
error. Use `pveum role modify` if a set ever needs changing.

> ✅ **`pveum role list` also shows `TofuDisk` (`VM.Config.Disk`), left from the
> import in [`tofu/README.md`](tofu/README.md) §"The sequence" — and its ACL is
> confirmed gone.** The role surviving is expected; only the **grant** was meant
> to be temporary (`tofu/README.md:250`). Checked 2026-09-16:
>
> ```
> pveum acl list | grep -i tofu
> │ /  │ PVEAuditor │ user │ tofu@pve │ 1 │        <- the only row. No TofuDisk.
> ```
>
> That one row is what makes "read-only `!import`" true rather than aspirational.
> A `TofuDisk` row at `/` would have given that token disk-write on every guest.
> Worth re-running after any future import.

> 🔴 **A5 as originally written does not work, and the token it builds cannot
> create VM 105.** Found 2026-09-16, after all seven ACLs were applied exactly as
> written:
>
> ```
> pveum user permissions 'tofu@pve!llm' --path /vms/105  ->  VM.Audit (*)          <- ONE privilege
> pveum user permissions 'tofu@pve!llm' --path /vms/104  ->  the 7 PVEAuditor privs
> ```
>
> The token has **less** power on the VM it owns than on the VM it must never
> touch. Two PVE rules combine to produce it, and the runbook accounted for
> neither:
>
> 1. **A privsep token's effective rights are the *intersection* of its own ACLs
>    and its user's.** A token can never exceed the user it belongs to.
>    `tofu@pve` holds only `PVEAuditor` at `/`.
> 2. **ACL inheritance is nearest-path-wins, not cumulative.** An entry on
>    `/vms/105` *replaces* the one inherited from `/` rather than adding to it.
>
> So at `/vms/105`: token = `TofuVM`, user = `PVEAuditor`, and
> `TofuVM ∩ PVEAuditor` = exactly `{VM.Audit}` — which is precisely what came
> back. At `/vms/104` both sides resolve to `PVEAuditor`, so all seven survive.
>
> **The fix is to mirror the grants onto the user**, keeping the token ACLs as
> they are. The user becomes the union of what any of its tokens may do; each
> token is then narrowed by its own ACLs. But `tofu@pve!import` is
> **`--privsep 0`** (`tofu/README.md:286`), meaning it inherits the user wholesale
> — so widening the user would silently hand the "read-only" token write access
> too. Close that first:
>
> ```bash
> # 1. Make !import bounded by its own ACL instead of by the user.
> #    This does NOT regenerate the secret; the LastPass copy stays valid.
> pveum user token modify tofu@pve import --privsep 1
> pveum acl modify / --tokens 'tofu@pve!import' --roles PVEAuditor
>
> # 2. Now widen the USER, PVEAuditor kept alongside so !import stays a full auditor.
> U='tofu@pve'
> pveum acl modify /vms/105                      --users "$U" --roles PVEAuditor,TofuVM
> pveum acl modify /storage/local-lvm            --users "$U" --roles PVEAuditor,TofuStorage
> pveum acl modify /storage/llm-pool             --users "$U" --roles PVEAuditor,TofuStorage
> pveum acl modify /storage/local                --users "$U" --roles PVEAuditor,TofuStorage
> pveum acl modify /mapping/pci/arc-b70          --users "$U" --roles PVEAuditor,TofuMapping
> pveum acl modify /sdn/zones/localnetwork/vmbr0 --users "$U" --roles PVEAuditor,PVESDNUser
>
> # 3. Prove all three claims at once.
> pveum user permissions 'tofu@pve!llm'    --path /vms/105   # VM.Allocate + VM.Config.* present
> pveum user permissions 'tofu@pve!llm'    --path /vms/104   # audit only, NO VM.Allocate
> pveum user permissions 'tofu@pve!import' --path /vms/105   # audit only -- still read-only
> ```
>
> Keeping `PVEAuditor` in each `--roles` list matters: without it the user's
> nearest entry at `/storage/local-lvm` would be `TofuStorage` alone, and
> `!import` would drop to `Datastore.Audit` there — narrowing the read-only token
> in a way that could break the four-guest import workflow.
>
> **Alternative, if touching `!import` is unappealing:** put the `llm` token under
> a separate user (`tofu-llm@pve`) carrying these grants, leaving `tofu@pve`
> untouched. Cleaner isolation, at the cost of a new token id in LastPass and in
> every document that names one. **Not taken** — the fix above was applied instead.
>
> ✅ **Applied and verified 2026-09-16.** `!import` moved to `--privsep 1` (the
> secret was *not* regenerated), the user was widened, and all three claims now
> hold:
>
> | Query | Result |
> |---|---|
> | `!llm --path /vms/105` | `VM.Allocate`, `VM.Audit`, `VM.PowerMgmt` + the eight `VM.Config.*` — **exactly `TofuVM`** |
> | `!llm --path /vms/104` | the 7 auditor privileges, **no `VM.Allocate`, no `VM.Config.*`** |
> | `!import --path /vms/105` | the 7 auditor privileges — **still read-only**, though the user now holds `TofuVM` there |
>
> That third row is the one that proves `--privsep 1` did its job: the user has
> write on `/vms/105` and the import token still cannot use it.
>
> Note the token gets `TofuVM` alone at `/vms/105`, not `TofuVM` ∪ `PVEAuditor` —
> nearest-path-wins again, on the token's own side. ~~That is sufficient~~
> 🔴 **Corrected 2026-09-16: it is not, once the guest agent is on.** With
> `agent { enabled = true }` the provider reads the VM's addresses through the
> agent, which PVE gates on `VM.GuestAgent.Audit` *at `/vms/105`*. `TofuVM`
> doesn't include it, and the `PVEAuditor` that would have supplied it was
> replaced by the nearer entry. The first agent-enabled apply succeeded, but with
> `403 … (/vms/105, VM.GuestAgent.Audit|VM.GuestAgent.Unrestricted)`. The token's
> grant at `/vms/105` is now **`PVEAuditor,TofuVM`**, mirroring the user's, so its
> read access at that path matches everywhere else. `VM.GuestAgent.Audit` is
> read-only; `Unrestricted` (exec, file write) is deliberately not granted.

**The token**, with privilege separation on so its own ACLs bound it rather than
inheriting the user's — **bounded by the user's rights as well, which is the trap
above**:

```bash
pveum user token add tofu@pve llm --privsep 1
# prints the secret ONCE
```

**The grants.** Everything the provider touches needs a path, and nothing else
gets one:

```bash
T='tofu@pve!llm'
pveum acl modify /                          --tokens "$T" --roles PVEAuditor    # read-only, everywhere
pveum acl modify /vms/105                   --tokens "$T" --roles PVEAuditor,TofuVM  # write, HERE ONLY (+ read incl. agent)
pveum acl modify /storage/local-lvm         --tokens "$T" --roles TofuStorage   # root + EFI disk
pveum acl modify /storage/llm-pool          --tokens "$T" --roles TofuStorage   # models disk
pveum acl modify /storage/local             --tokens "$T" --roles TofuStorage   # cloud image download
pveum acl modify /mapping/pci/arc-b70       --tokens "$T" --roles TofuMapping   # attach the GPU
pveum acl modify /sdn/zones/localnetwork/vmbr0 --tokens "$T" --roles PVESDNUser # attach the NIC
```

- `PVEAuditor` at `/` lets the provider read the datacenter, storages and the
  container. It does **not** make the four VMs refreshable — that needs
  `VM.Config.Disk` on each, which is a write privilege and is deliberately not
  granted. Every plan in this directory therefore runs `-refresh=false`, exactly
  as it does with the read-only token (C2). Read broad, write narrow.
- The `/sdn/...` grant reflects PVE 8.2+ checking bridge use as an SDN
  permission. ✅ **Verified on this host 2026-09-16** — `localnetwork` is the
  right zone for `vmbr0` on PVE 9.1.1, and the grant was accepted. All seven
  ACLs applied, giving eight `tofu` rows in `pveum acl list`: the pre-existing
  `tofu@pve` user row plus seven for the token.
- 🔴 **An eighth grant turned out to be required: `Sys.AccessNetwork` on
  `/nodes/pve`.** Found 2026-09-16 when the first apply failed on the image
  download with `received an HTTP 403 response - Reason: Permission check
  failed`. That 403 came from PVE, not Ubuntu: the provider calls
  `/nodes/pve/query-url-metadata`, then `download-url`. Read from the API source
  on the host, since `pvesh usage --verbose` does not print permissions:

  ```
  Nodes.pm          query_url_metadata: 'or', perm / [Sys.Audit, Sys.Modify],
                                              perm /nodes/{node} [Sys.AccessNetwork]
  Storage/Status.pm download_url:       'and', perm /storage/{storage} [Datastore.AllocateTemplate],
                                              (Sys.Modify on / "for backwards compatibility"
                                               OR Sys.AccessNetwork on the node)
  ```

  `Sys.AccessNetwork` is the narrow side of that `or`: it lets the token make
  the node fetch a URL and nothing else, while `Sys.Modify` would open node and
  datacenter configuration. It is granted permanently because every future
  image checksum change goes through the same download. Two traps from earlier
  in A5 apply here too, so the grant goes to **both** the user and the token
  (privsep intersection), with **`PVEAuditor` alongside** at that path
  (nearest-path-wins would otherwise strip the node-level audit privileges the
  provider reads):

  ```bash
  pveum role add TofuNet --privs "Sys.AccessNetwork"
  pveum acl modify /nodes/pve --users  tofu@pve       --roles PVEAuditor,TofuNet
  pveum acl modify /nodes/pve --tokens 'tofu@pve!llm' --roles PVEAuditor,TofuNet
  pveum user permissions 'tofu@pve!llm'    --path /nodes/pve   # Sys.AccessNetwork + auditor set
  pveum user permissions 'tofu@pve!import' --path /nodes/pve   # auditor set only
  ```
- **Not granted, deliberately:** `Sys.Modify` (datacenter config, incl. adding
  storage), `Mapping.Modify` (creating or editing mappings), `VM.Allocate`
  anywhere above `/vms/105`, `VM.Migrate`, `VM.Backup`, `VM.Snapshot`,
  `Permissions.Modify`. A5's own `pvesm add` and A4's mapping are therefore
  one-time console jobs — the token can use both, and change neither.
- `VM.Allocate` on `/vms/105` does let this token **delete VM 105**. That is
  what makes `prevent_destroy` on the tofu resource load-bearing rather than
  decorative.

**Verify the scoping rather than assuming it.** On the host, pass the *full token
id* as the userid — `pveum user permissions` has **no `--token` flag**, and
supplying one fails with `Unknown option: token` (tried 2026-09-16):

```bash
pveum user permissions 'tofu@pve!llm' --path /vms/105   # write privileges here
pveum user permissions 'tofu@pve!llm' --path /vms/104   # read-only, and NOTHING more
```

> ⚠️ **Do not verify this with `| grep -E '/vms/10[45]'`.** The output is a table
> that prints the path once per block and leaves the column blank on continuation
> rows, so a grep on the path keeps only the **first** privilege of the block and
> drops the rest. Tried 2026-09-16: it returned the single line
> `│ /vms/105 │ VM.Audit (*) │`, which looks like the token got *only* audit —
> while `pveum acl list` showed `TofuVM` correctly attached. `--path` asks the
> question directly and cannot mislead this way.
>
> Expect `/vms/104` to still list the **read** privileges: `PVEAuditor` at `/`
> propagates, which is the intended "read broad, write narrow". What must be
> absent there is `VM.Allocate` and every `VM.Config.*`.

**Or from the dev VM**, authenticating *as* the token, which is the stronger test
because it exercises the credential rather than describing it:

```bash
read -rs TOK && export TOK      # paste: tofu@pve!llm=<uuid>
curl -sk -H "Authorization: PVEAPIToken=$TOK" \
  https://192.168.50.101:8006/api2/json/access/permissions | jq '.data'
```

Expect `VM.Allocate: 1` under `/vms/105` and **not** under `/vms/104`.

**Where the secret lives:** export it as `PROXMOX_VE_API_TOKEN` per shell, and
keep the only copy in LastPass beside the age key. **Never** in
`terraform.tfvars`, the repo, or a shell rc file — `AGENTS.md` rule 6: no
plaintext secret exists on this VM, keep it that way.

---

## Phase B — ONE planned host reboot: `vfio-pci` binding + BIOS MMIO

Both jobs need a reboot, so do them together. **This reboot takes down the whole
cluster.** Shut down with `scripts/homelab-shutdown.sh` (dependency order, and it
refuses to hard-stop the DB VM). The Sunfire Worker serves a 503 while the cluster is down (`AGENTS.md`).

### B1. Bind the card to `vfio-pci` at boot (before the reboot)

The host driver has to let go of the card for passthrough. Proxmox can unbind `xe` when
the VM starts, but binding at boot is more reliable, and `xe` never loads SR-IOV
PF state it would then have to tear down.

```bash
cat > /etc/modprobe.d/vfio-arc-b70.conf <<'EOF'
# Intel Arc Pro B70 (53:00.0) + its HDMI audio (54:00.0) -> vfio-pci, see homelab/GPU-VM.md
options vfio-pci ids=8086:e223,8086:e2f7
softdep xe pre: vfio-pci
softdep i915 pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >> /etc/modules
update-initramfs -u -k all
proxmox-boot-tool refresh   # harmless if not in use
```

Binding the audio function too means no host driver holds anything under the
card's bridges. That matters for the BAR resize in Phase D, which has to rearrange the
bridge windows the audio device also sits behind. The audio function itself doesn't go to the VM.

These IDs match only the Arc card. The host's own video is the Matrox G200 (`mgag200`), so
the host keeps a console.

✅ **Done 2026-09-16.** `update-initramfs` regenerated
`/boot/initrd.img-6.17.2-1-pve`. `proxmox-boot-tool refresh` reported
`No /etc/kernel/proxmox-boot-uuids found, skipping ESP sync` — the expected
no-op: this host boots via plain GRUB from `sda2` (`/boot/efi`, `HARDWARE.md`),
not a `proxmox-boot-tool`-managed ESP. So the initramfs just written is the one
that will be loaded.

> **Verify the config is *inside* the initramfs before spending the reboot on
> it.** The `softdep` lines only help if `modprobe` reads them at the moment `xe`
> would otherwise load, and on this host that moment is inside the initramfs —
> so a `modprobe.d` file that failed to get bundled produces a boot where `xe`
> claims the card anyway, and the whole cluster power cycle is wasted:
>
> ```bash
> lsinitramfs /boot/initrd.img-6.17.2-1-pve | grep -E 'vfio|arc-b70'
> ```
>
> Expect both `etc/modprobe.d/vfio-arc-b70.conf` and the `vfio-pci` module
> under `kernel/drivers/vfio/`. If the `.conf` is missing, re-run
> `update-initramfs -u -k all` and check again before rebooting.
>
> IOMMU itself needs no GRUB change here: `/sys/kernel/iommu_groups/` is
> populated (A1 and A4 both read from it), which only happens with an active
> IOMMU, so `intel_iommu=on` is already in effect on kernel `6.17.2-1-pve`.
>
> ⚠️ `printf … >> /etc/modules` appends. If B1 is ever re-run, check for
> duplicate `vfio*` lines — harmless, but confusing later.

### B2. Shut down and change BIOS settings

```bash
bash homelab-shutdown.sh --dry-run
bash homelab-shutdown.sh --yes --poweroff-host   # or reboot
```

The script now **re-runs itself inside tmux and attaches you to it**, so an SSH
or Tailscale session that drops mid-shutdown no longer takes the run with it —
which matters here because `192.168.50.102`, the Tailscale entry container, is
deliberately the *last* guest stopped. Reattach when the host is reachable again:

```bash
tmux attach -t homelab-shutdown
```

Running from the Proxmox console is still fine; pass `--no-tmux` there if you
would rather not have the extra layer.

> ❌ **This BIOS has no Resizable BAR option. Established 2026-09-15 by the
> owner, before this document existed** — the Dell EMC BIOS setup was searched,
> IOMMU settings were varied, and GRUB kernel parameters were tried across
> reboots. None of it made the resize succeed. **Do not spend another reboot
> looking for a ReBAR switch.**

While the host is down anyway, the two settings still worth confirming are under
**System BIOS → Integrated Devices** (they govern where the 64-bit MMIO window
lands, which is a different knob from ReBAR itself):

- **Memory Mapped I/O above 4 GB** → Enabled
- **Memory Mapped I/O Base** → the highest option offered (e.g. 56 TB / 12 TB rather than 512 GB)

Record what's actually there, including "no such option". A1 confirms this is a
**PowerEdge T550 on BIOS 1.8.2** — Dell 15G, so the names above are the right
generation's.

✅ **Recorded 2026-09-16 (owner, at POST).** Both settings exist under exactly
those names on this machine:

| Setting | Found | Left as |
|---|---|---|
| Memory Mapped I/O above 4 GB | **Enabled** — already, and apparently all along | Enabled |
| Memory Mapped I/O Base | **12 TB** | **56 TB** (the highest offered) |

So the 12 TB base was in effect during every ReBAR attempt on 2026-09-15. Moving
it up does not resize anything by itself — B3 below still reads 256M — but it
raises where firmware places the 64-bit MMIO window, which is the room Phase D's
resize needs if it is to avoid `-ENOSPC`.

### B3. After boot, verify

```bash
lspci -nnk -s 53:00.0 | grep 'in use'    # -> vfio-pci
lspci -nnk -s 54:00.0 | grep 'in use'    # -> vfio-pci
zpool list                               # THREE pools by name: archive-pool, sas-pool, llm-pool
zpool status -x                          # then health. '-x' alone cannot see a MISSING pool.
lspci -vv -s 53:00.0 | grep -E 'Region 2|Resizable BAR' -A0
lspci -vvv -s 53:00.0 | sed -n '/Resizable BAR/,/^\t[A-Z]/p'
```

> ⚠️ **Count the pools in `zpool list`; do not trust `zpool status -x`.** The
> 2026-09-15 GPU-install reboot left `sas-pool` unimported for a day, and `-x`
> reported "all pools are healthy" throughout, because an absent pool is not an
> unhealthy one ([`SAS-STORAGE.md`](SAS-STORAGE.md)). `zfs-import-scan` is now
> enabled, which is what should make this reboot behave — **this is the boot that
> tests that fix.** If `sas-pool` is missing again:
> `zpool import 5068010059978323696`, then find out why before continuing.

✅ **Ran 2026-09-16 00:48 PDT, after the B2 power cycle. Every check passed.**

```
53:00.0 Kernel driver in use: vfio-pci
54:00.0 Kernel driver in use: vfio-pci

NAME           SIZE  ALLOC   FREE  ...  CAP  HEALTH
archive-pool  1.73T   289M  1.73T        0%  ONLINE
llm-pool      1.73T   552K  1.73T        0%  ONLINE
sas-pool      10.5T   210G  10.3T        1%  ONLINE
all pools are healthy

Region 2: Memory at 220e00000000 (64-bit, prefetchable) [disabled] [size=256M]
Capabilities: [420 v1] Physical Resizable BAR
    BAR 2: current size: 256MB, supported: 256MB 512MB 1GB 2GB 4GB 8GB 16GB 32GB
Capabilities: [220 v1] Virtual Resizable BAR
```

What that settles:

- **B1 worked.** Both functions came up on `vfio-pci`; the `lsinitramfs` check
  was not wasted caution — the binding happened in the initramfs as intended.
- **The `zfs-import-scan` fix is proven, by the same kind of reboot that broke
  it.** All three pools imported on their own, `sas-pool` included. That closes
  the question [`SAS-STORAGE.md`](SAS-STORAGE.md) left open.
- **`sas-pool` at `ALLOC 210G` is not 70 GiB of new data** against the ~140 GiB
  seen at recovery. `zpool list` counts raw space *including RAIDZ1 parity*;
  on a 3-disk RAIDZ1 that is ~1.5 × the `zfs list USED` figure, and
  140 × 1.5 = 210. Same ALLOC-vs-USED trap as `archive-pool`, different cause.
- **`[disabled]` on Region 2 is normal, not a fault.** `vfio-pci` leaves memory
  decoding off until a VM opens the device.
- **Region 2 is still 256M, so Phase D is still needed** — but it is now far
  better motivated than before. **The card advertises a Physical Resizable BAR
  capability supporting every size up to 32GB.** The hardware is willing; the
  only thing missing is something to perform the resize, and with `xe` gone,
  the kernel's `-EBUSY` refusal that blocked every 2026-09-15 attempt no longer
  applies. Phase D's precondition is met exactly.

If **Region 2 is already `[size=32G]`**, ReBAR is solved: skip Phase D. If
it's still `[size=256M]`, continue to Phase C anyway. The VM works with a small BAR and only loads data onto the card more slowly.

Then start the guests as usual.

---

## Phase C — create the VM and install the guest

### C1. Image — nothing to do by hand

**Superseded 2026-09-15 by `tofu/proxmox-llm-vm.tf`.** The VM is built from the
Ubuntu **cloud image** plus cloud-init, not from an interactive ISO install, so
tofu downloads the image itself
(`proxmox_virtual_environment_download_file.ubuntu_noble_cloud` →
`local`). That is why `TofuStorage` carries `Datastore.AllocateTemplate`.

> ⚠️ **The `local` storage must allow `import` content.** The image is downloaded
> as content type `import`, because PVE 9 refuses to build a VM disk from an
> `iso`-typed volume. The first apply on 2026-09-16 failed exactly that way:
> `scsi0: local:iso/noble-server-cloudimg-amd64.img has wrong type 'iso' - needs
> to be 'images' or 'import'`. Enabling a content type on a storage needs root,
> like the other one-time console jobs. Check it first, and **append** `import`
> rather than replacing the list:
>
> ```bash
> grep -A4 '^dir: local$' /etc/pve/storage.cfg     # read the current `content` line
> # Only if `import` is missing: re-run `pvesm set local --content` with the
> # existing list plus import, typed out in full, e.g. iso,vztmpl,backup,import
> ```
>
> ✅ Checked 2026-09-16: `content iso,import,vztmpl,backup`. `import` was already
> enabled, so nothing changed on this host. (An earlier version of this step had
> a `<list>` placeholder inside the command. Bash read `<` as an input
> redirect and failed harmlessly before running `pvesm`. Placeholders don't
> belong inside pasteable commands.)

Two variables have no defaults and must be supplied before the apply.

> ⚠️ **Run these on the dev VM (`192.168.50.103`), not the Proxmox host.** Tofu,
> its state and `jq` all live on the dev VM, so an export in a host shell reaches
> nothing. There's a worse trap too: `~/.ssh/authorized_keys` on the host is
> **root@pve's** key list, not the dev VM's, so if `jq` had been installed there,
> VM 105 would have been seeded with the wrong trust set. Tried on the host
> 2026-09-16; it failed only because `jq` is missing there.

```bash
# Read 2026-09-16 from https://cloud-images.ubuntu.com/noble/current/SHA256SUMS
export TF_VAR_ubuntu_noble_image_sha256='612b2c0cc1bc413a6cb8c38fd611794caf0f2b436c50013d8b3794db12ad7354'
# Reuse the same keys that already open the dev VM (two ed25519, ssh-import-id gh:lambo-n)
export TF_VAR_llm_ssh_public_keys="$(jq -R -s -c 'split("\n")|map(select(length>0))' < ~/.ssh/authorized_keys)"
```

⚠️ **Re-read that checksum before applying if any time has passed.** Ubuntu
respins `noble-server-cloudimg-amd64.img` in place, and a stale value fails the
download with a checksum mismatch — which is the failure you want, but only if
you recognise it:

```bash
curl -s https://cloud-images.ubuntu.com/noble/current/SHA256SUMS | grep 'noble-server-cloudimg-amd64.img$'
```

It is a variable rather than a default in `variables.tf` for exactly this
reason: a default would rot silently, and the point of pinning is to notice.

✅ **Re-read 2026-09-16, after Phase B:** still `612b2c0c…7354`, so no respin
since it was recorded. Dev VM `authorized_keys` still holds exactly two
`ssh-ed25519` keys, both `gh:lambo-n`. **`.107` is free:** no ping reply, and
`ip neigh` shows `192.168.50.107 dev ens18 INCOMPLETE`. That means nothing answered
ARP either, which is the stronger check, because a host can drop ping but not ARP
on its own LAN.

**On the keys:** `~/.ssh/authorized_keys` on the dev VM holds two ed25519 keys
imported from GitHub (`ssh-import-id gh:lambo-n`), so the command above gives
VM 105 the same keys that already open this workstation — no new keypair, no
private key created anywhere, nothing to store. They are public keys; the
`llm_ssh_public_keys` variable is not marked `sensitive` because it does not
need to be. **Do not** substitute `~/.ssh/flux-homelab-deploy.pub`: that is
Flux's repo deploy key and reusing it for host login would put one key in two
trust domains.

The checksum is required rather than optional: Ubuntu rewrites `current/` in
place on every respin, so without it the apply imports whatever is published
that day. The key list is what makes the guest reachable — the `dev` account is
created with **no password**, so an empty list leaves the Proxmox console as the
only way in.

### C2. Create — by tofu, with the A5 token

This VM is **authored in tofu and created by apply**, not created by hand and
imported. It is the one guest where that is safe: it is new and empty, so a
wrong diff costs a rebuild rather than data, and the A5 token cannot reach the
other four. The config goes in on a branch (`tofu/` change),
carries `prevent_destroy` from the first commit, and
covers: the VM, `hostpci { mapping = "arc-b70" }`, both disks, and cloud-init.

```bash
# Type this line ON ITS OWN, press Enter, THEN paste the token at the prompt.
# Pasted as part of a block, `read` swallows the next pasted line as the token
# and the real token then runs as a shell command (hit 2026-09-16).
read -rsp 'token: ' PROXMOX_VE_API_TOKEN; echo; export PROXMOX_VE_API_TOKEN
[[ $PROXMOX_VE_API_TOKEN == 'tofu@pve!llm='* ]] && echo OK || echo WRONG
# No Cloudflare token needed. With -refresh=false the Cloudflare provider makes no
# API calls for its two unchanged DNS records, so it never needs credentials.
# Verified 2026-09-16: a plan with no CLOUDFLARE_API_TOKEN at all fails only on
# Proxmox credentials. tofu/README.md "-refresh=false is not optional" says the same.
tofu plan  -refresh=false -out=vm105.tfplan   # READ IT. Separate paste from the apply below.
# only after the plan shows exactly what you expect:
tofu apply vm105.tfplan && rm vm105.tfplan
```

> ⚠️ **Use `-refresh=false`, even though this token can write.** Corrected
> 2026-09-15 — an earlier draft here said to refresh, and that was wrong.
> `tofu@pve!llm` is `PVEAuditor` at `/` plus write on `/vms/105`, and
> **`PVEAuditor` cannot refresh a QEMU guest**: the provider re-resolves every
> volume through an endpoint PVE gates on `VM.Config.Disk`, a *write*
> privilege (`tofu/README.md`, "The privilege that blocked the four VMs"). An
> unqualified `tofu apply` therefore dies on all four existing VMs before it
> reaches VM 105:
>
> ```
> Error: error get file local-lvm:vm-103-disk-0 ... 403 (/vms/103, VM.Config.Disk)
> ```
>
> Observed exactly this way on 2026-09-15. Skipping refresh is safe for a
> **create**: there is no prior state for VM 105 to go stale.
>
> Granting this token `VM.Config.Disk` on the other four would fix the refresh
> and destroy the entire point of scoping it. Don't.

**After any host-side change to VM 105** — `qm set`, a disk resized on the pool,
anything done from the console — reconcile the config and then finish with:

```bash
tofu apply -refresh-only -target=proxmox_virtual_environment_vm.llm
```

A `plan` refreshes in memory and throws it away; only an apply persists state.
Skipping this is what left the LXC's state stale for six days and blocked every
plan in the directory (`tofu/README.md`, "State drift").

The `qm` equivalent below is the **fallback** — use it only if the provider
fights, and then import as the other four were. Either way the machine is the
same:

```bash
qm create 105 --name llm --ostype l26 \
  --machine q35 --bios ovmf \
  --efidisk0 local-lvm:1,efitype=4m,pre-enrolled-keys=0 \
  --cpu host --sockets 1 --cores 8 \
  --memory 65536 --balloon 0 \
  --scsihw virtio-scsi-single \
  --scsi0 local-lvm:32,iothread=1,discard=on,ssd=1 \
  --scsi1 llm-pool:1400,iothread=1,discard=on,ssd=1,backup=0 \
  --net0 virtio,bridge=vmbr0 \
  --ide2 local:iso/<ubuntu-24.04.N-live-server-amd64.iso>,media=cdrom \
  --boot 'order=scsi0;ide2' \
  --agent enabled=1 \
  --hostpci0 mapping=arc-b70,pcie=1 \
  --onboot 0
```

| Setting | Why |
|---|---|
| `q35` + `ovmf` | PCIe passthrough, and a 64-bit MMIO window big enough for a 32 GiB BAR. SeaBIOS/i440fx, which the other guests use, is the wrong platform for this. |
| `cpu host` | Passes through the host's physical address width (46-bit on Ice Lake), which is what OVMF uses to size that window. It also gives llama.cpp's CPU fallback AVX-512 and AMX. |
| `memory 64 GiB`, `balloon 0` | A VM with a passthrough device pins **all** of its RAM, so ballooning can't work. 64 GiB is twice the VRAM, enough to page models through. 206 GiB is uncommitted. |
| `cores 8` | A starting point, out of 32 threads. **No pinning:** A1 found one socket and one NUMA node, so there is no node to pin to. |
| `scsi1 1400 GiB`, `backup=0` | Leaves ~20% of the 1.75 TiB pool free for ZFS. vzdump backups of re-downloadable models would waste space. |
| `pre-enrolled-keys=0` | Secure Boot off. It removes one failure mode with no security cost for this use. |
| no `x-vga`, `rombar` default | Compute only. The console stays on Proxmox's virtual display. |

`--onboot 0` matches the other guests.

### C2a. 🔴 First start hard-locked the host (ATS). Fix before starting 105 again

**2026-09-16, 01:46 PDT.** The apply built everything, and then starting VM 105
took the entire host down. Tasks in `/var/log/pve/tasks/index`:

```
download:noble-server-cloudimg-amd64.qcow2  OK      (37 s)
qmcreate:105                                OK
resize:105                                  OK
qmstart:105                                 unexpected status   <- never finished; closed out at next boot
```

Kernel log for that boot (`journalctl -b -1 -k`):

```
01:46:27 vfio-pci 0000:53:00.0: resetting / reset done
01:46:35 vfio-pci 0000:53:00.0: enabling device (0000 -> 0002)
01:46:35 vfio-pci 0000:53:00.0: resetting / reset done
01:46:35 DMAR: VT-d detected Invalidation Time-out Error: SID 0
01:46:35 DMAR: QI PRIOR: Device-TLB Invalidation qw0 = 0x5300530000000003, ...   (repeats)
01:47:20 watchdog: CPU13: Watchdog detected hard LOCKUP on cpu 13                  <- last line of the boot
```

The host was unreachable until a power cycle at 02:00. Every guest stopped
uncleanly.

**What it means.** `0x5300` in that descriptor is both the source and PF device
ID: bus `53`, device `00`, function `0`, the Arc B70. Descriptor type `3` is a
**Device-TLB invalidation**, which the IOMMU sends to a device that uses **PCIe
ATS** (Address Translation Services) to keep its own translation cache. After
`vfio-pci` reset the card, the card stopped answering those invalidations. The
kernel waits for each one synchronously, so it spun on a CPU until the watchdog
declared a hard lockup. It is not the BAR, not MMIO placement, and not the
64 GiB memory pin. None of those appear in the log.

**The fix is `pci=noats` on the host kernel command line.** It turns off ATS for
all PCIe devices, so the IOMMU keeps every translation to itself and never sends
a Device-TLB flush. The throughput cost is negligible here. ✅ **Verified on this
card 2026-09-16, step 4 below.** Never remove it while this card is passed
through.

**What the crash left behind.** Everything exists on the host, and **none of it is
in tofu state**. tofu's last state write was 08:44:42 UTC, before the apply. It
left `.terraform.tfstate.lock.info` behind (ID `0645dbbf-…`). **That file is
not a lock.** The local backend's lock is an OS-level lock held by the tofu
process, released when the process died. The file only describes it, so it
blocks nothing (`tofu force-unlock` answers `LocalState not locked`). Delete it
and move on; do not count on it to stop an apply.

| On the host | |
|---|---|
| VM 105 config | complete: `hostpci0: mapping=arc-b70,pcie=1,rombar=0,x-vga=0`, cloud-init, EFI |
| `local-lvm` | `vm-105-cloudinit`, `vm-105-disk-0` (EFI), `vm-105-disk-1` (root, 32G) |
| `llm-pool` | `vm-105-disk-0`, 1.37T reserved |
| `local` | `import/noble-server-cloudimg-amd64.qcow2` |

The pools were all healthy after the unclean stop, `sas-pool` imported on its
own again, and `53:00.0` came back on `vfio-pci`.

**Sequence, with the smallest possible blast radius:**

1. **Keep 102–104 stopped** (the k3s cluster, Postgres included) until step 4
   passes. Another lockup would kill Postgres uncleanly a second time.
2. **Add `pci=noats`** to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`,
   run `update-grub` (this host boots plain GRUB, B1), and reboot.
3. **Confirm it took:** `cat /proc/cmdline` shows `pci=noats`.
   ✅ **Done 2026-09-16 02:12 PDT.** `pci=noats` is present and absent from
   `journalctl -b -k | grep 'Unknown option'`, so the kernel accepted it. That
   check also showed `bridge_realloc` and `noiov` are unknown options that have
   never had any effect. They are left in place so this test changes one thing
   only. `ATSCtl: Enable-` idle, but that proves little: ATS is normally only
   enabled when the device is attached to a translation domain, so re-check it
   **while 105 runs**.
4. **Controlled test from the host console:** `journalctl -kf` in one shell,
   `qm start 105` in another. Pass means the VM runs, no `DMAR: … Device-TLB`
   line appears, and `lspci -vvv -s 53:00.0 | grep ATSCtl` still reads
   `Enable-` while it runs.
   ✅ **Passed 2026-09-16 02:16 PDT.** Same reset sequence as the crash, with no
   `DMAR` line after it this time:
   ```
   02:16:27 vfio-pci 0000:53:00.0: resetting / reset done
   02:16:35 vfio-pci 0000:53:00.0: enabling device (0000 -> 0002)   <- where the ITEs began last time
   02:16:35 vfio-pci 0000:53:00.0: resetting / reset done  (x2)
   ```
   `qm status 105` → `running`, and `ATSCtl: Enable-` **with the VM running**.
   The host outlived the 45 s window. From the dev VM at 02:17:30, `.107`
   answered ping from MAC `bc:24:11:cc:26:62` (VM 105's `net0`), and sshd was
   up on 22, so the guest booted and cloud-init applied the static address.
   **`pci=noats` fixes the lockup.**
5. **Then rebuild through tofu, so state and host agree again.** Run
   `qm destroy 105 --destroy-unreferenced-disks 1` (🔴 **never `--purge`**, see
   below) and
   `pvesm free local:import/noble-server-cloudimg-amd64.qcow2`, then remove the
   stale `.terraform.tfstate.lock.info` and plan/apply as in C2.
   ✅ **Host side done 2026-09-16:** VM 105, its three LVM volumes and the
   `llm-pool` zvol destroyed, image freed. `llm-pool` is back to `612K`, and state
   still lists only the original seven resources.

   🔴 **`--purge` deleted the token's permissions.** It was used here, and the
   rebuild then downloaded the image (now in state) and failed the VM create
   with `HTTP 403 - Permission check failed` — the same token had created 105
   without trouble before the crash. `qm destroy --purge` removes the VMID from
   *every* configuration that names it: backup and replication jobs, HA, **and
   the ACL entries on `/vms/105`**, so both `TofuVM` grants from A5 (user and
   token) were gone. Re-grant, and prove it before applying:

   ```bash
   pveum acl modify /vms/105 --users  tofu@pve       --roles PVEAuditor,TofuVM
   pveum acl modify /vms/105 --tokens 'tofu@pve!llm' --roles PVEAuditor,TofuVM
   pveum user permissions 'tofu@pve!llm' --path /vms/105   # VM.Allocate + VM.Config.* present
   ```

   General rule for this VMID: its write access is an ACL on a path named after
   the guest, so anything that "cleans up everything about VM 105" also
   revokes the only token allowed to recreate it.

   ✅ **Rebuilt through tofu 2026-09-16 ~09:25 UTC.** After the re-grant,
   `!llm --path /vms/105` again showed exactly `TofuVM`, and `!import` stayed
   audit-only. The plan was `1 to add` (the image was already in state, with
   `import_from = "local:import/noble-server-cloudimg-amd64.qcow2"`), and the
   apply reported `Creation complete after 37s [id=105]` with the host's
   `journalctl -kf` open throughout and no DMAR or lockup lines. State now holds
   `proxmox_virtual_environment_vm.llm`, and the new MAC `bc:24:11:e5:1f:57`
   answers on `.107` with sshd listening. **C2a is closed.**
   The VM is empty, so a clean rebuild costs about a minute and avoids an
   import with its generated diffs.

### C3. First boot and verify inside the guest

There is no installer to sit through: cloud-init grows the root disk, sets the
address from `llm_ipv4_address`, and seeds the `dev` account with your keys. SSH
in at `192.168.50.107` and watch it finish before judging anything.

From outside the LAN, reach it the way every other guest is reached: a
`ProxyJump` through the Tailscale gateway container. `.107` is on the same flat
`/24`, so the gateway needs no change, and the key that already opens `dev` is
one of the two cloud-init installed. In `~/.ssh/config` on the workstation:

```
Host llm
    HostName 192.168.50.107
    User dev
    IdentityFile ~/.ssh/id_ed25519
    ProxyJump tailscale-gateway
```

Then `ssh llm`:

```bash
cloud-init status --wait                   # done, not error
```

The cloud image ships the **6.8 GA kernel**, which predates this card. The HWE
kernel is what makes `xe` bind, so this step is mandatory, not hygiene — and
`qemu-guest-agent` is not in the image either, which is why
`agent { enabled = false }` is in the config for now:

```bash
sudo apt update && sudo apt install -y linux-generic-hwe-24.04 qemu-guest-agent && sudo reboot
uname -r                                   # >= 6.17
lspci -nnk | grep -A3 e223                 # Kernel driver in use: xe
ls -l /dev/dri                             # card*, renderD*
sudo dmesg | grep -iE 'xe .*(BAR|GuC|HuC)'
sudo lspci -vv -d 8086:e223 | grep Region  # 256M = small BAR, 32G = ReBAR working
```

✅ **Verified 2026-09-16 ~09:35 UTC**, after the HWE install and a guest reboot
(the host stayed up through the GPU reset; confirm no DMAR errors with
`journalctl -k --since '02:25' | grep -ciE 'Invalidation Time-out|Device-TLB|lockup'`, expecting 0):

```
uname -r                        7.0.0-31-generic     <- HWE has since moved past 6.17; still >= 6.17
lspci -nnk | grep -A3 e223      01:00.0 [8086:e223] ASRock [1849:6025], Kernel driver in use: xe
ls -l /dev/dri                  card0, card1, renderD128
dmesg                           xe 0000:01:00.0: [drm] Small BAR device
                                GuC 70.44.1 in use -- "70.54.0 is recommended"
                                HuC 8.2.10 (same as the host had)
lspci -vv Region                Region 0 [size=16M], Region 2 at 0x380000000000 [size=256M]
systemctl is-active qemu-guest-agent    inactive
```

- **The card works in the guest.** `xe` binds, and a render node exists. `card0` is
  presumably the VM's emulated display, and `card1` + `renderD128` the Arc.
- **GuC is older than the 7.0 kernel wants** (`70.44.1` loaded, `70.54.0`
  recommended). It works; the guest's `linux-firmware` lags the HWE kernel. Try
  `sudo apt install --only-upgrade linux-firmware` first. Not blocking.
- **`qemu-guest-agent` inactive is expected, not a failure.** The package is
  installed, but Ubuntu only starts it when the virtio-serial channel
  `org.qemu.guest_agent.0` exists, and VM 105 was created with
  `agent { enabled = false }`. Flipping that in tofu adds the channel, and the
  agent starts after the reboot the provider performs (`reboot_after_update`).
- Region 2 256M confirms the small BAR survives into the guest unchanged, as
  Phase D expects. OVMF placed the 64-bit window at 56 TiB, inside the 46-bit
  physical address width `cpu: host` passes through.

Models disk. Address it by id, and use **`nofail`** (the SAS disks' old fstab lines were missing it, and would have dropped the host to an emergency shell; `HARDWARE.md`):

```bash
M=/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi1
sudo mkfs.ext4 -L models "$M"
sudo mkdir -p /models
echo 'LABEL=models /models ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab
sudo mount -a && df -h /models
```

✅ **Done 2026-09-16.** `mkfs` built 367,001,600 × 4K blocks (exactly 1400 GiB),
and `df` shows `/dev/sdb 1.4T` on `/models`. Run `sudo systemctl daemon-reload`
after editing fstab, or `mount -a` warns that systemd still uses the old version.

> **Default `mkfs.ext4` wastes about 90 GiB on this disk.** It sizes for small
> files: one inode per 16 KiB gave 91.75 M inodes × 256 B ≈ **22 GiB of inode
> tables**, plus the **5% root reserve ≈ 70 GiB**, on a disk that holds a few
> dozen multi-GB weight files. For a models-only disk, format with
>
> ```bash
> sudo mkfs.ext4 -F -L models -T largefile4 -m 0 "$M"
> ```
>
> (one inode per 4 MiB, ~358 k inodes; no reserve). The reserve can be dropped
> later with `tune2fs -m 0`, but inode density is fixed at format time, so choose
> it while the disk is empty. The fstab line uses `LABEL=models`, so it survives
> a reformat unchanged.
>
> ✅ **Reformatted this way 2026-09-16, while still empty:** `358400 inodes`
> (was 91,750,400), and `df -h /models` shows `Avail 1.4T` (was `1.3T`).

Address **`192.168.50.107`** is set by cloud-init from `var.llm_ipv4_address`,
so nothing needs configuring inside the guest. `.107` is taken as decided (owner,
2026-09-16) — it was only ever reserved for the TrueNAS VM that was never built,
and **the homelab guests are the only static addresses on this network; everything
else is DHCP**. If something does answer on it, the fix is a router reset, not a
redesign.

> The residual risk is not another static host but the **DHCP pool overlapping
> `.102`–`.107`**. A lease handed out inside the static range collides silently
> and intermittently — the guest keeps its address and the DHCP client loses
> connectivity at random. Worth checking the pool's start address once, at the
> router, and reserving the low range if it overlaps.

The gateway
(`192.168.50.1`) is confirmed: `ip route show default` on `.103` reports
`default via 192.168.50.1 dev ens18`, on the same flat `/24` every guest uses.

✅ **Guest agent on, 2026-09-16** (PR #22). The apply rebooted VM 105; afterwards
`systemctl is-active qemu-guest-agent` → `active`, `/models` came back from fstab,
`xe` stayed bound, and `qm agent 105 ping` answered. It needed one more grant:
see the A5 correction (token needs `PVEAuditor,TofuVM` at `/vms/105`). Then
`tofu apply -refresh-only -target=proxmox_virtual_environment_vm.llm` recorded
`ipv4_addresses` `192.168.50.107` on `eth0` via the agent, and
`tofu plan -refresh=false` → **No changes**.

Once the guest agent is installed, flip `agent { enabled = true }` in
`tofu/proxmox-llm-vm.tf` and apply. That second diff is deliberate: enabling it
before the agent exists makes the provider wait on a guest that cannot answer.

---

## Phase D — the one ReBAR attempt left, then stop

> The owner already tried BIOS setup, IOMMU variations and GRUB parameters on
> 2026-09-15, with `xe` driving the card. Nothing worked, and this BIOS has no
> ReBAR option. **Phase D is one attempt under a condition none of that
> testing had: the card unbound, with `vfio-pci` holding it instead of `xe`.**
> A BAR cannot be resized while a driver is bound — the kernel returns `-EBUSY`
> — so every earlier attempt from a running host with `xe` loaded was refused
> before it reached the hardware. This is the only reason to try once more.
>
> **If it fails here, ReBAR is closed on this hardware.** Small BAR is then the
> permanent condition, and the "Living with a small BAR" section below is the
> answer. Do not reopen it without new firmware from Dell.

A guest can only get the BAR size the host has given the card. QEMU doesn't let the guest resize it.
So the resize happens **on the host, while nothing is bound to the card, before the VM starts.**

### D0. Preflight — read-only, safe with everything running

Four things learned since this phase was drafted change how it has to run:

1. **SR-IOV already claims 56 GiB of the card's window.** The B3-era boot log has
   `VF BAR 2 [mem 0x220000000000-0x220dffffffff 64bit pref]` (0xe00000000 = 56 GiB)
   plus the PF's 256M BAR 2, 16M BAR 0 and 112M VF BAR 0. So the prefetchable
   window above the card is at least ~56.4 GiB **before** any resize, and a 32 GiB
   BAR 2 on top needs ~88 GiB. `pci=noiov` was presumably meant to stop the VF
   reservation, but the kernel reports it as `Unknown option` (C2a). The outcome
   therefore hinges on whether the window can grow, or whether the kernel drops
   the optional VF resources to make room. D0 measures this instead of guessing.
2. **Unbinding `vfio-pci` while VM 105 runs blocks**, because vfio waits for QEMU
   to release the device. The procedure now refuses unless 105 is stopped.
3. **Rebinding with `drivers_probe` is nondeterministic.** Whichever matching
   driver probes first wins, and if `xe` is loaded on the host it could take the
   card. D now uses `driver_override` to bind `vfio-pci` explicitly.
4. **This host has hard-locked on PCI work before (C2a).** A resize reassigns
   bridge windows, so D0 also proves nothing but the GPU sits under its root
   port. If anything else does, stop the cluster before D.

```bash
# topology: the chain above the card, and everything below its root port
P=$(readlink -f /sys/bus/pci/devices/0000:53:00.0); echo "$P"
RP=$(echo "$P" | awk -F/ '{print $5}'); echo "root port: $RP"
find /sys/devices/*/"$RP" -maxdepth 4 -type d -name '0000:*' | awk -F/ '{print $NF}' \
  | grep -E '^0000:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9]$' | sort -u      # expect only 51,52,53,54 functions

# windows: each bridge, and the root bus aperture they must fit inside
for b in "$RP" 0000:51:00.0 0000:52:01.0 0000:52:02.0; do
  echo "== $b"; lspci -vv -s "$b" | grep -E 'behind bridge'; done
grep -iE 'PCI Bus 0000:5[0-4]' /proc/iomem

# the card: what it offers and what SR-IOV has reserved
cat /sys/bus/pci/devices/0000:53:00.0/resource2_resize           # expect 000000000000ff00
cat /sys/bus/pci/devices/0000:53:00.0/sriov_totalvfs /sys/bus/pci/devices/0000:53:00.0/sriov_numvfs
lspci -vvv -s 53:00.0 | sed -n '/SR-IOV/,/^\t[A-Z]/p' | grep -E 'VFs|Region'

# preconditions for D
lsmod | grep -wE 'xe|i915' || echo "no xe/i915 loaded on host"
qm status 105
```

What D0 decides:

- **Root bus aperture (the `PCI Bus 0000:5x` line wrapping the others) has
  ≥ ~90 GiB of prefetchable 64-bit space:** the window can grow, and D is worth
  running.
- **The root port's prefetchable window is only ~56–64 GiB and the aperture has no
  room above it:** D will almost certainly return `-ENOSPC`. It is still one cheap
  attempt, since the kernel may drop the optional VF BARs, but expect failure.
- **Anything other than the 51/52/53/54 functions under `$RP`:** stop the k3s
  guests with `homelab-shutdown.sh` (without `--poweroff-host`) before D.

✅ **D0 results, 2026-09-16:**

```
root port 0000:50:02.0   prefetchable 220000000000-2211ffffffff [size=72G]
switch    0000:51:00.0   prefetchable 220000000000-220fffffffff [size=64G]
port      0000:52:01.0   prefetchable 220000000000-220fffffffff [size=64G]   (-> 53:00.0, the GPU)
port      0000:52:02.0   prefetchable [disabled]; 1M non-prefetchable       (-> 54:00.0, audio)

/proc/iomem  220000000000-22ffffffffff : PCI Bus 0000:50      <- root bus 64-bit aperture: 1 TiB
               220000000000-2211ffffffff : PCI Bus 0000:51
                 220000000000-220fffffffff : PCI Bus 0000:52
                   220000000000-220fffffffff : PCI Bus 0000:53

resource2_resize  000000000000ff00
SR-IOV            Total VFs 7, Number of VFs 0; VF Region 2 at 220000000000 (7 x 8G = 56G)
sysfs             resource2_resize only -- no knob to shrink the VF BARs
lsmod             xe loaded, used by 0 (idle; vfio-pci owns the card)
```

- **Isolated:** only the GPU's own functions sit under root port `50:02.0`, so a
  window reassignment cannot disturb any other device. The cluster can stay up.
- **Room to grow:** the root bus aperture is 1 TiB and the root port uses 72G of
  it. Keeping the 56G of VF BARs and adding a 32G BAR 2 needs ~88G, which fits if
  the kernel grows the bridge windows up the chain (`pci=realloc` is live). If it
  instead drops the optional VF BARs, 32G fits in the existing 64G.
- **`xe` is loaded on the host**, so the rebind hazard is real. D sets
  `driver_override` **before** unbinding, so no stray probe can hand the card to `xe`.

### D. The attempt — host console, VM 105 stopped

A resize done this way **does not survive a host reboot**, so trying it is
reversible. That also means a small-BAR baseline load time can still be measured
later, after a reboot.

Run it as **separate short pastes**. Long pasted lines get hard-wrapped by the
terminal (which has split quotes and paths on this host), and a guard line in a
pasted block cannot stop the lines after it. So the steps that change state run
inside `( set -e ... )`, which halts at the first failure.

**D-1. Stop the VM:**

```bash
qm stop 105; qm status 105
```

**D-2. Unbind and resize.** It halts at the first failure. `No space left on
device` from the last line is the `-ENOSPC` outcome:

```bash
(
set -e
G=/sys/bus/pci/devices/0000:53:00.0
A=/sys/bus/pci/devices/0000:54:00.0
qm status 105 | grep -q stopped
echo vfio-pci > $G/driver_override
echo vfio-pci > $A/driver_override
echo 0000:53:00.0 > $G/driver/unbind
echo 0000:54:00.0 > $A/driver/unbind
cat $G/resource2_resize
echo 15 > $G/resource2_resize
echo RESIZE-WRITE-OK
)
```

**D-3. Always run this, success or not.** It shows the result and rebinds to
`vfio-pci`:

```bash
lspci -vv -s 53:00.0 | grep 'Region 2'
dmesg | tail -25
echo 0000:53:00.0 > /sys/bus/pci/drivers/vfio-pci/bind
echo 0000:54:00.0 > /sys/bus/pci/drivers/vfio-pci/bind
lspci -nnk -s 53:00.0 | grep 'in use'
lspci -nnk -s 54:00.0 | grep 'in use'
```

❌ **Ran 2026-09-16: `-ENOSPC`. 32 GiB ReBAR is closed on this hardware.**

```
cat resource2_resize        000000000000ff00
echo 15 > resource2_resize  -bash: echo: write error: No space left on device
after D-3                   Region 2 [size=256M] unchanged; 53:00.0 and 54:00.0 back on vfio-pci
```

The kernel neither grew the bridge windows into the 1 TiB root aperture nor dropped
the 56G of optional VF BARs to make room. `dmesg | tail` showed nothing useful:
it was entirely AppArmor `ALLOWED` audit lines from CT 100's `rsyslogd`, logged
every ~5 s, which push kernel PCI messages out of any short tail. Filter instead:
`dmesg | grep -iE '53:00|52:01|51:00|50:02|bridge window|resiz'`. That shows what
the kernel actually did:

```
pcieport 0000:50:02.0:   bridge window [mem 0x220000000000-0x2211ffffffff 64bit pref]   <- root port, left at 72G
pcieport 0000:51:00.0:   bridge window [mem size 0x1000000000 64bit pref]               <- re-sized to 64G
pcieport 0000:52:01.0:   bridge window [mem size 0x1000000000 64bit pref]               <- re-sized to 64G
pci 0000:53:00.0: VF BAR 2 [mem size 0xe00000000 64bit pref]: can't assign; no space
pci 0000:53:00.0: VF BAR 2 [mem size 0xe00000000 64bit pref]: failed to assign
```

So **the kernel did try.** It released and re-sized the switch and port windows,
but **would not grow the root port past its firmware-set 72G**, despite 1 TiB of
free aperture above it. That capped everything below at 64G. 32G BAR 2 plus 56G
VF BAR 2 doesn't fit in 64G, and the VF BAR's failure made the whole resize
return `-ENOSPC` and roll back (D-3 then showed VF Region 2 back at
`220000000000`). The kernel won't trade the optional VF BARs for the resize
~~either~~. ⚠️ **Partly corrected by the 4 GiB attempt below:** the kernel
*did* drop the VF BAR there. The root port's 72G window still held, but "the
kernel won't trade the VF BARs" was wrong.

✅ **4 GiB, 2026-09-16: the host-side resize succeeded.** Same D-1/D-2/D-3 with
`echo 12` (D-1 used `qm shutdown` now that the agent works):

```
echo 12 > resource2_resize    RESIZE-WRITE-OK
lspci Region 2                Memory at 220000000000 [size=4G]
SR-IOV Region 2               Memory at 0000000000000000        <- VF BAR 2 left UNASSIGNED
pcieport 0000:52:01.0: bridge window [mem 0x220000000000-0x22017fffffff 64bit pref]: assigned   (6G)
pci 0000:53:00.0: BAR 2 [mem 0x220000000000-0x2200ffffffff 64bit pref]: assigned
pci 0000:53:00.0: BAR 0 [mem 0x220100000000-0x220100ffffff 64bit pref]: assigned
pci 0000:53:00.0: VF BAR 0 [mem 0x220101000000-0x220107ffffff 64bit pref]: assigned
pcieport 0000:50:02.0: bridge window [mem 0x220000000000-0x2211ffffffff 64bit pref]   (root port still 72G)
both functions rebound to vfio-pci
```

**The kernel dropped VF BAR 2 (the 56G SR-IOV reservation) and shrank the switch
and port windows to 6G**, so the 4 GiB BAR did not fit *beside* the reservation,
as predicted above; the reservation went away. That costs nothing, because
whole-card passthrough never enables VFs. It also reopens 32 GiB: that attempt
failed while VF BAR 2 was still assigned, and with it unassigned, 32 GiB needs only
~32.1G, inside the existing windows. Untested hypothesis: why the kernel dropped
the VF BAR for 4 GiB but not for 32 GiB isn't known.

✅ **4 GiB verified end to end, 2026-09-16.** `qm start 105` with
`dmesg -wT | grep -iE 'dmar|vfio|lockup'` open on the host showed only the usual
three `vfio-pci` resets. In the guest:

```
xe: VRAM[0]: Actual physical size 0x800000000, usable size exclude stolen 0x7f9000000,
    CPU accessible size 0x0000000100000000                      <- 4 GiB, was 0x10000000
lspci: Region 2: Memory at 380000000000 (64-bit, prefetchable) [size=4G]
       Region 0: Memory at 380100000000 (64-bit, prefetchable) [size=16M]
```

The CPU-visible window is **16× larger** (256 MiB → 4 GiB), and usable VRAM is
unchanged at 31.89 GiB. OVMF placed the 4G BAR without any `X-PciMmio64Mb` or
`args`. **Not persistent yet:** a host reboot returns the card to 256M. Settle the
size (32 GiB retry below) before writing the boot-time unit, so it is written once.

✅ **32 GiB, 2026-09-16: the host-side resize succeeded, on the second try.**
Card at 4 GiB (VF BAR 2 already unassigned), same D-1/D-2/D-3 with `echo 15`:

```
echo 15 > resource2_resize    RESIZE-WRITE-OK
lspci Region 2                Memory at 220000000000 [size=32G]
SR-IOV Region 2               Memory at 0000000000000000          <- still unassigned
pci 0000:53:00.0: BAR 2 [mem 0x220000000000-0x2207ffffffff 64bit pref]: assigned
pcieport 0000:51:00.0 / 0000:52:01.0: bridge window [mem 0x220000000000-0x220bffffffff 64bit pref]  (48G)
pcieport 0000:50:02.0: bridge window [mem 0x220000000000-0x2211ffffffff 64bit pref]                 (root port still 72G)
both functions rebound to vfio-pci
```

**The 56G VF BAR reservation was the only obstacle,** and 32 GiB fit with room to
spare once it was gone. ⚠️ **Which step released it was misread at first.** It was
**not** the 4 GiB resize. The first boot test (D4) ran 4 GiB → 32 GiB from a fresh
boot: 4 GiB succeeded **with VF BAR 2 still assigned** (4 + 56 fits in 64), and
32 GiB then failed. What released the reservation in this session was the **failed
first 32 GiB attempt**, whose rollback left VF BAR 2 unassigned (`VF BAR 2 … failed
to assign`), a state the 4 GiB and second 32 GiB steps inherited. The sequence
that actually worked, and that the boot unit must replay, is **15 (ENOSPC) → 12 →
15**.

✅ **Full ReBAR verified in the guest, 2026-09-16.** `qm start 105` with the host
kernel log open showed only the usual `vfio-pci` resets. In VM 105:

```
xe: VRAM[0]: Actual physical size 0x800000000, usable size exclude stolen 0x7f9000000,
    CPU accessible size 0x00000007f9000000        <- equals usable: all 31.89 GiB CPU-visible
    (no "Small BAR device" line)
lspci: Region 2: Memory at 380000000000 (64-bit, prefetchable) [size=32G]
       Region 0: Memory at 380800000000 (64-bit, prefetchable) [size=16M]
```

OVMF placed the 32G BAR with no `X-PciMmio64Mb`/`args`, so that fallback is not
needed. **This overturns the phase's opening conclusion** ("If it fails here, ReBAR
is closed on this hardware"). The blocker was never the BIOS or the missing ReBAR
option; it was the card's 56G SR-IOV VF BAR reservation, which a failed 32 GiB attempt
releases (see the correction above). **Not yet persistent:** see "Make it survive a
host reboot" below.

> Watch the kernel log with `dmesg -wT | grep -iE 'dmar|vfio|lockup'`. It is
> short enough not to wrap when pasted, and it never opens a pager. A wrapped
> `journalctl` / `-kf …` paste on 2026-09-16 ran bare `journalctl` and dropped
> into `less` on the whole journal.

**One smaller size remained untried at the time, and it was the owner's call.** The GPU port's
existing 64G window holds ~56.4G today (56G VF BAR 2 + 256M BAR 2 + 16M BAR 0 +
112M VF BAR 0). A **4 GiB** BAR 2 (`echo 12`) needs ~60.4G, which fits without
growing any window. 8 GiB (~64.1G) does not. 4 GiB is not full ReBAR (`xe` still
reports a small BAR), but the CPU-visible window grows from 256 MiB to 4 GiB,
the part that throttles model loading. Same D-1/D-2/D-3, just as reversible.

Reading the result:

- **It works** (`Region 2 [size=32G]`): `qm start 105` with the host's
  `journalctl -kf | grep -iE 'DMAR|vfio|lockup'` open. Then in the guest,
  `sudo lspci -vv -d 8086:e223 | grep Region` must show `[size=32G]`, and `dmesg`
  should no longer say `Small BAR device`. A reset that lost the size would show
  here: the kernel is meant to restore ReBAR state after vfio's resets, and the
  guest reading is the proof. Only then make it persistent, and prefer a **systemd
  oneshot on the host** ordered before `pve-guests.service` over a hookscript.
  A hookscript is a VM option on a tofu-owned guest, so it would be drift for tofu
  to fight. Never persist an untested resize — a failed one at boot leaves the
  card with no usable BAR at all.
- **`No space left on device` / `-ENOSPC`:** the window on the PCIe port above
  `51:00.0` (find it with `lspci -tv`) can't fit 32 GiB. That is firmware's
  allocation, and with no ReBAR option in setup there is nothing left to try
  here. Go to "Living with a small BAR".
- **`-ENOENT` again, or the file doesn't exist:** the card isn't offering a
  resize the kernel can use in this topology. Same conclusion.
- **The guest sees 32G but `xe` fails to map it:** that one is fixable — OVMF's
  64-bit window is too small. Add `args: -fw_cfg
  name=opt/ovmf/X-PciMmio64Mb,string=65536` to the VM config. ⚠️ PVE lets only
  `root@pam` set `args`, so the `!llm` token can't manage it. It would be a
  root-set option on a tofu-owned VM, needing `lifecycle { ignore_changes }` for
  it in `proxmox-llm-vm.tf`. The guest's 256M BAR currently sits at
  `0x380000000000` (56 TiB, from C3), so OVMF already sizes a large window from
  the 46-bit `cpu: host` address width, and this may well not be needed.

### D4. Make it survive a host reboot

The resize is lost at every host boot, and the SR-IOV reservation comes back with
it, so the boot unit replays the whole sequence: `scripts/gpu-rebar.sh`, run by
`scripts/gpu-rebar.service`. It:

- exits immediately if BAR 2 is already 32 GiB (safe to re-run);
- refuses if VM 105 is running (its QEMU pid is alive) or `vfio-pci` is absent;
- sets `driver_override=vfio-pci` **before** unbinding, since `xe` is loaded on the host;
- tries 32 GiB directly (succeeds only if VF BAR 2 is somehow already unassigned),
  then 4 GiB, then 32 GiB, logging VF BAR 2's size before each step;
- **always** rebinds both functions to `vfio-pci` on exit (`trap`), and logs the
  final BAR size and drivers to the journal.

It orders itself `Before=pve-guests.service`, and nothing `Requires` it. A failed
resize leaves the card at 256 MiB or 4 GiB, still bound and still usable by VM 105,
and never blocks boot.

**Install.** Copy the files **from the workstation** with `scp -3`, which relays
through the local machine. Don't paste them (pastes wrap and mangle lines).

The host and the dev VM **cannot copy between each other directly**. On
2026-09-16, `scp dev@192.168.50.103:…` run on the host failed with
`Permission denied (publickey)`: the dev VM's sshd was reached, but it accepts
only the owner's GitHub keys, and root on the host holds none of them. The
workstation reaches both through its `ProxyJump tailscale-gateway` aliases.

On the workstation:

```bash
scp -3 dev:/home/dev/homelab/scripts/gpu-rebar.sh proxmox-host:/usr/local/sbin/gpu-rebar.sh
scp -3 dev:/home/dev/homelab/scripts/gpu-rebar.service proxmox-host:/etc/systemd/system/
```

Then on the host:

```bash
chmod 755 /usr/local/sbin/gpu-rebar.sh
systemctl daemon-reload && systemctl enable gpu-rebar.service
```

**Test without a reboot.** The card is already at 32 GiB, so a run should exit
through the no-op path:

```bash
systemctl start gpu-rebar.service
journalctl -u gpu-rebar -n 5 --no-pager        # "BAR 2 already 32 GiB; nothing to do"
```

✅ **Installed and enabled 2026-09-16 09:48 PDT.** `enable` created the
`multi-user.target.wants` symlink, and a manual start logged
`gpu-rebar: BAR 2 already 32 GiB; nothing to do`. Expected SHA-256 of the installed
copies (from the repo): `gpu-rebar.sh` `8d6f8110…`, `gpu-rebar.service`
`882228fa…`. The first `scp -3` left the `.service` in `/usr/local/sbin`, so
`enable` reported `Unit … does not exist` until it was moved to
`/etc/systemd/system`.

❌ **First reboot test, 2026-09-16 10:09 PDT: 32 GiB failed at boot; the card came
up at 4 GiB.** Other boot checks passed: `pci=noats` on the cmdline, all three pools
imported, smartd active.

```
gpu-rebar: BAR 2 is 256 MiB; resizing to 4 GiB, then 32 GiB
/usr/local/sbin/gpu-rebar.sh: line 81: echo: write error: No space left on device
gpu-rebar: 32 GiB step failed; BAR 2 stays at 4 GiB
gpu-rebar: BAR 2 is 4096 MiB
gpu-rebar: 0000:53:00.0 driver: vfio-pci        0000:54:00.0 driver: vfio-pci
lspci (after):  Region 2 [size=4G]; SR-IOV Region 2 at 0x220000000000   <- VF BAR 2 still assigned
```

Its failure handling worked as designed (card at 4 GiB, both functions rebound,
boot unaffected), but the sequence was wrong: see the correction in "32 GiB, on the
second try" above.

**The boot's own kernel log shows the mechanism**
(`dmesg | grep -iE '53:00|52:01|51:00|bridge window'`, at ~12.7 s):

```
pcieport 0000:51:00.0: bridge window [mem size 0x1608000000 64bit pref]: can't assign; no space   <- 64G + 24G optional > 72G root port
pcieport 0000:51:00.0: bridge window [mem 0x220000000000-0x220fffffffff 64bit pref]: assigned
pcieport 0000:52:01.0: bridge window [mem 0x220000000000-0x220bffffffff 64bit pref]: assigned
pci 0000:53:00.0: BAR 2 [mem 0x220000000000-0x2207ffffffff 64bit pref]: assigned                 <- 32G WAS placed
pci 0000:53:00.0: VF BAR 2 [mem size 0xe00000000 64bit pref]: can't assign; no space
pci 0000:53:00.0: VF BAR 2 [mem size 0xe00000000 64bit pref]: failed to assign
```

and the sysfs `resource` file afterwards (line N+1 = index N):

```
3:  0x0000220000000000 0x00002200ffffffff   BAR 2, back to 4G after the rollback
8:  0x0000220801000000 0x0000220807ffffff   VF BAR 0 (112M), which confirms the indexing
10: 0x0000000000000000 0x0000000000000000   VF BAR 2: UNASSIGNED
```

So during the 32 GiB step the kernel placed BAR 2 at 32G, could not also place the
56G VF BAR 2, **counted that single failure as failure of the whole resize**,
returned `-ENOSPC` and rolled BAR 2 back to 4G. **The rollback does not restore VF
BAR 2**, which is why every later resize succeeds. `lspci`'s SR-IOV
`Region 2: Memory at 0x220000000000` after boot was the card's stale register, not
an assignment; the sysfs `resource` file is the authority. The rule, from all four
attempts: **a resize fails whenever the kernel must place VF BAR 2 and can't; the
first 32 GiB attempt always fails but unassigns it.** Hence 15 (ENOSPC) → 12 → 15,
and why 4 GiB at boot (4 + 56 fits) left VF BAR 2 in place.

✅ **Fixed script installed and run, 2026-09-16 10:18 PDT** (SHA-256 `988b541b…`).
From the post-boot state it predicted exactly:

```
gpu-rebar: BAR 2 is 4096 MiB, VF BAR 2 0 GiB; trying 32 GiB directly
gpu-rebar: resize complete (32 GiB on the first try)
gpu-rebar: BAR 2 is 32768 MiB
gpu-rebar: 0000:53:00.0 driver: vfio-pci        0000:54:00.0 driver: vfio-pci
```

That exercised the early-success path only. **The full boot path (32 GiB refused →
`VF BAR 2 0 GiB` → 4 GiB → 32 GiB) is proven only by the next host reboot**; check
`journalctl -u gpu-rebar -b` before starting VM 105. The script now replays 15 (ENOSPC) → 12 → 15 and logs VF BAR 2
at each step. **Re-test: `systemctl restart gpu-rebar` with VM 105 stopped, then
another host reboot.**

**Real test: the next host reboot** (e.g. through `homelab-shutdown.sh`). Before
starting VM 105, check:

```bash
journalctl -u gpu-rebar -b --no-pager          # "resize complete", BAR 2 32768 MiB, both vfio-pci
lspci -vv -s 53:00.0 | grep 'Region 2'          # [size=32G]
```

### Living with a small BAR

> ℹ️ **Superseded on this host, 2026-09-16:** full 32 GiB ReBAR works (above). This
> section applies only if the boot-time resize fails and the card comes up at 256M,
> or at 4 GiB if only the second step fails.

**This is very likely the outcome, and the VM is still worth building.** What
small BAR does and doesn't cost, for LLM inference specifically:

- **VRAM capacity is unaffected.** All 32 GiB is allocatable by the GPU. The
  256 MiB is only the window the *CPU* sees at any moment; the driver moves that
  window as needed. A 30 GiB model still fits.
- **Inference speed is largely unaffected.** Once weights are resident in VRAM,
  token generation reads them with the card's own memory bandwidth and never
  crosses that window.
- **Loading a model is slower**, because every GiB of weights is copied through a
  window the kernel has to keep re-pointing. Expect load times to hurt, not
  tokens/sec. Load a model once and keep the server process resident rather than
  starting it per request.
- **Avoid zero-copy / unified-memory paths** that map VRAM straight into host
  address space. Explicit copies (what llama.cpp SYCL and vLLM-XPU do by
  default) are the right pattern here.

> ⚠️ Unverified: the size of that penalty on this card has not been measured.
> Time one model load in the guest and write the number down here — it is the
> only figure that settles whether small BAR actually matters for this workload.

---

## Phase F — the inference stack: llama.cpp server

**Decided 2026-09-16 (owner):** `llama.cpp`'s `llama-server`, serving an
OpenAI-compatible API to two consumers:

- **the owner's workstation**, over an SSH tunnel through the tailscale gateway
  (`ssh -N -L 8080:127.0.0.1:8080 llm`). No new exposure; it works whether or not
  the tailnet routes the LAN.
- **homelab apps** (k3s workloads, other VMs) at `http://192.168.50.107:8080/v1`,
  with an API key.

Not chosen: Ollama (runs Intel GPUs through Vulkan, with fewer knobs) and vLLM XPU
(pays off only with many concurrent users).

**Backend: build both SYCL and Vulkan, then benchmark.** SYCL (Intel oneAPI + Level
Zero) is usually faster on Arc but needs a multi-GB toolchain. Vulkan (Mesa ANV)
needs none. Measuring both on this card settles it, and the same run produces the
model-load timing Phase D asked for, now with a full 32 GiB BAR.

**All commands run in the guest (`ssh llm`),** as short separate pastes.

### F0. Preflight — read-only

```bash
df -h / /models
lsb_release -ds; uname -r; nproc; free -g
groups
ls -l /dev/dri/
apt policy intel-opencl-icd libze-intel-gpu1 libze1 mesa-vulkan-drivers 2>/dev/null | grep -E '^[a-z]|Installed'
```

What it decides:

- **Root disk space.** It is 32 GiB, and a full oneAPI Base Toolkit can use most of
  that. If `/` has less than ~15 GiB free, install only the two oneAPI parts
  llama.cpp's SYCL build needs (the DPC++ compiler and MKL), and build under
  `/models/src` rather than `~`.
- **Group membership.** `dev` must be in `render` (for `/dev/dri/renderD128`) to
  use the GPU without sudo.
- **What GPU user-space is already there.** Ubuntu 24.04's stock Level Zero /
  compute runtime may predate Battlemage support, in which case F1 installs a
  current one from Intel's repository.

✅ **Ran 2026-09-16.** `/` 27 GiB free of 30; `/models` 1.4 TiB, empty. Ubuntu
24.04.5, kernel `7.0.0-31-generic`, 8 vCPUs, 62 GiB RAM, no swap. `/dev/dri` has
`card0` (the emulated display), `card1` and `renderD128` (the B70). `dev` was in
neither `render` nor `video`: fixed with `sudo usermod -aG render,video dev` plus a
re-login, verified with `groups`. None of `intel-opencl-icd`, `libze-intel-gpu1`,
`libze1` or `mesa-vulkan-drivers` is installed.

Correction to the plan above: llama.cpp's SYCL build needs **oneDNN and oneDPL as
well**, not just the compiler and MKL (`docs/backend/SYCL.md`). Its recommended
bundle is **Intel Deep Learning Essentials**, which contains all four. Space is
no longer the deciding factor, so F1 installs that, at 2025.3 (see F1).

### F1–F6 (filled in as they run)

- **F1** GPU user-space: Level Zero + compute runtime (Intel's `kobuk-team/intel-graphics`
  PPA), Vulkan (Mesa ANV from `noble-updates`), oneAPI Deep Learning Essentials 2025.3. Verify with `sycl-ls` and `vulkaninfo --summary`.
  ✅ **Ran 2026-09-16.** Package versions were checked against Launchpad and Intel's
  apt index before installing.
  - **F1a** `ppa:kobuk-team/intel-graphics` → `libze-intel-gpu1 libze1 libze-dev
    intel-opencl-icd intel-ocloc intel-gsc intel-metrics-discovery clinfo`
    (compute runtime 26.31.39395.13, Level Zero 1.32.0). `clinfo -l`:
    `Intel(R) Arc(TM) Pro B70 Graphics`.
  - **F1b** `mesa-vulkan-drivers vulkan-tools libvulkan-dev glslc spirv-headers`
    from `noble-updates` (Mesa 25.2.8, no PPA needed). `vulkaninfo --summary`:
    `Intel(R) Graphics (BMG G31)` on the Mesa driver, plus `llvmpipe`.
  - **F1c** Intel oneAPI apt repo → `intel-deep-learning-essentials-2025.3`
    (llama.cpp's CI version; ~6.7 GiB vs 11 GiB for the Base Toolkit). After
    `source /opt/intel/oneapi/setvars.sh`, `sycl-ls` shows
    `[level_zero:gpu][level_zero:0] … Arc(TM) Pro B70 Graphics 20.2.0 [1.17.39395+13]`.
    `/` 18 GiB free afterwards.
  - The first F1c paste failed harmlessly: the `wget … .PUB \` line wrapped, and
    `set -e` stopped before anything was written. Long URLs go in variables.
- **F2** Build `llama.cpp` twice (`-DGGML_SYCL=ON` with `icx`/`icpx`, and
  `-DGGML_VULKAN=ON`), pinned to one release tag: **`v0.4.1`** (2026-09-14; the
  project now cuts semver releases alongside the per-commit `bNNNNN` prereleases).
  ✅ **Built 2026-09-16** in `/models/src/llama.cpp` (shallow clone of `v0.4.1`;
  reports `0.4.1-dev`, ggml 0.24.0 `b29c606`). Build tools: `build-essential cmake
  git ninja-build libssl-dev`.
  - `build-vulkan` (GCC 13.3, 747 steps): `--list-devices` →
    `Vulkan0: Intel(R) Graphics (BMG G31) (32656 MiB, 29368 MiB free)`.
  - `build-sycl` (icx/icpx 2025.3.3, `GGML_SYCL_F16=ON`, Level Zero API ON,
    oneDNN 3.9, MKL 2025.3): `--list-devices` →
    `SYCL0: Intel(R) Arc(TM) Pro B70 Graphics (32656 MiB, 32601 MiB free)`.
  - ⚠️ **Vulkan caveat for F4:** noble's `glslc` (2023.8) lacks
    `GL_EXT_integer_dot_product` and `GL_EXT_bfloat16`, so the Vulkan build is
    missing some shader paths that help quantized models on Intel. If Vulkan comes
    close to SYCL in F4, rebuild it with a current `glslc` (LunarG Vulkan SDK) before
    choosing.
  - Both builds embed the web UI from Hugging Face's `latest` bucket (the pinned
    `b1` checksum download returned an error), so the UI is not pinned with the tag.
- **F3** Model weights into `/models`: a small one to validate the builds, then
  the real one (up to ~28 GiB of weights plus KV cache within 31.89 GiB).
- **F4** `llama-bench` on both backends, plus a timed cold model load.
  ✅ **F3a 2026-09-16:** `/models/gguf/llama-2-7b.Q4_0.gguf` (TheBloke, 3.56 GiB,
  SHA-256 `78b8f977…` verified). Chosen because most published llama.cpp Vulkan/SYCL
  numbers use it. `/models` is root-owned: create subdirectories with `sudo mkdir`,
  then `chown dev:dev`.

  ✅ **F4 on the 7B, 2026-09-16** (`llama-bench -ngl 99`, 5 reps):

  | backend | pp512 t/s | tg128 t/s | load, cache dropped | load, warm |
  |---|---:|---:|---:|---:|
  | **SYCL** (F16, oneDNN, Level Zero) | **3256 ± 133** | **110.8 ± 0.2** | 9.8 s | 5.2 s |
  | Vulkan (Mesa 25.2.8, `int dot: 0`) | 1676 ± 19 | 95.7 ± 0.5 | 4.9 s | 1.9 s |

  Load time = `time llama-bench -p 0 -n 1 -r 1`, including process start. Only the
  guest's page cache was dropped; the host's ZFS ARC may still hold the blocks.

  **Decision: SYCL.** It is ~2× faster at prompt processing, which matters most for
  agents re-reading long contexts, and 16% faster at generation. Its ~3 s of extra
  startup is paid once by a resident server. The `glslc` rebuild for Vulkan is not
  worth doing: even a large prompt-processing gain would not close a 2× gap, and
  generation is limited by memory bandwidth. `build-vulkan` stays as a fallback.

  ✅ **F4 on the production models, 2026-09-16** (SYCL, `-fa on -p 512 -n 128
  -d 0,16384 -r 2`, each model alone, `ngl` auto = all layers):

  | model | size | pp512 | tg128 | pp512 @16K | tg128 @16K |
  |---|---:|---:|---:|---:|---:|
  | Qwen3.8-27B UD-Q6_K_XL | 23.55 GiB | 1050 | **18.7** | 608 | 16.6 |
  | Qwen3.6-35B-A3B UD-Q4_K_XL | 20.81 GiB | 1115 | **74.8** | 921 | 73.1 |
  | Llama 3.1 8B Q8_0 | 7.95 GiB | 3921 | **56.9** | 1103 | 37.3 |

  - The two Qwen models are hybrid (1 in 4 layers full attention) and barely slow down
    at 16K. Llama 3.1 has full attention in every layer and loses 35% of its
    generation speed. The MoE generates faster than the 8B, which is a point for
    re-examining the `fast` role later.
  - **Load of the 23.55 GiB Qwen3.8-27B (F4a):** 66.6 s with the guest page cache
    dropped, 20.3 s warm. The cold extra (~46 s ≈ 0.5 GiB/s) is the SATA SSD under
    `llm-pool`. The warm 20 s is SYCL start-up plus mmap/copy into VRAM, CPU-bound
    (`sys` 9 s), not BAR-bound. **Full ReBAR leaves nothing to fix on the load path.**
  - **Thermals during the runs:**
    - `sensors` (`xe-pci-0100`): package peaked ~63 °C (its `high` mark is 60 °C,
      `crit` 100 °C); VRAM 70–72 °C peak (`crit` 105 °C).
    - Fan 1522 RPM; card power cap 275 W.
    - `…/gt0/freq0/throttle/status` read `0` every time it was checked.
  - **Context fit (F4c)** — `llama-server` with `-c` unset, so `--fit` (default on,
    1024 MiB margin) shrinks context from 262K; 4 auto slots, unified KV, so
    `n_ctx_slot` is the whole pool:
    - Qwen3.8-27B Q6_K_XL alone, f16 KV: **116,480**
    - alone, q8_0 KV: **195,072** (≈6.3 GiB KV, ~34 KiB/token)
    - **beside Llama 3.1 8B** (`-c 8192`, ≈9.3 GiB), q8_0 KV: **4,096 = the fit
      minimum. ❌ The `qwen27` preset as planned does not fit.** ~22.6 GiB is left
      beside the 8B, less than the 23.55 GiB of weights alone.
    - **Change, decided 2026-09-16 (owner):** the `fast` role needs little reasoning
      (a text-only voice gag assistant with quips and a quick web search). It moves to
      **Qwen3.5-4B Q8_0** (`unsloth/Qwen3.5-4B-GGUF` @ `e87f1764`, 4.17 GiB, SHA-256
      `10cc391b…`). The 4B is hybrid (8 of 32 layers full attention), so its KV cache
      is tiny; expected ~4.7 GiB in use vs 9.3 GiB for the 8B, leaving an estimated
      ~45–60K context for Q6_K_XL beside it. UD-Q5_K_XL (19.44 GiB) is the fallback
      if the measured fit is under ~40K. **All downloaded models are kept** (owner),
      including Llama 3.1 8B.
    - ✅ **Measured with the 4B, 2026-09-16.**
      - `Qwen3.5-4B-Q8_0.gguf` downloaded, checksum OK. `llama-bench`: pp512 **5162**,
        tg128 **76.9**; at 16K, pp 2534, tg 64.8. Generation came in below my ">100"
        estimate; the linear-attention layers are the likely cost on SYCL.
      - Paired fit, with the 4B at `-c 8192` (4 slots) and Qwen3.8-27B Q6_K_XL at
        `-np 2 -ctk q8_0 -ctv q8_0`: `n_slots = 2, n_ctx_slot = 40960,
        kv_unified = 'false'`. That is **40,960 tokens per slot, 81,920 in total**,
        above the ~45–60K estimate. Fit kept context well above its 4096 floor, so no
        layers were moved off the GPU.
      - **The `qwen27` preset fits with Q6_K_XL; Q5_K_XL is not needed.**
  - `xpu-smi` 2.0.1 (from the PPA) sees the card and reports power, frequency and
    memory, but shows `N/A` for temperatures, fan and utilization. Use `sensors`.
    `intel_gpu_top` 1.28 (noble) is i915-only. The card idles at **48 W** at 650 MHz,
    possibly PCIe ASPM being off under passthrough; not investigated yet.

  📝 **F3b model set, decided 2026-09-16 (owner).** The router can swap models, so
  more can be added later. Hashes and repo revisions were read from the Hugging Face
  API, and each download is pinned to that revision:

  | Model | File | Size | Repo @ revision | SHA-256 |
  |---|---|---:|---|---|
  | Llama 3.1 8B Instruct | `Meta-Llama-3.1-8B-Instruct-Q8_0.gguf` | 7.95 GiB | `bartowski/…-GGUF` @ `bf5b95e9` | `9da71c45…` |
  | Qwen3.8-27B | `Qwen3.8-27B-UD-Q6_K_XL.gguf` | 23.56 GiB | `unsloth/Qwen3.8-27B-GGUF` @ `4ca72078` | `701d8fa9…` |
  | Qwen3.6-35B-A3B | `Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf` | 20.82 GiB | `unsloth/Qwen3.6-35B-A3B-GGUF` @ `a483e9e6` | `707a55a8…` |

  Total 52.3 GiB. ✅ **Downloaded 2026-09-16** to `/models/gguf`; byte sizes match
  the API and all three `sha256sum -c` checks passed. `/models`: 58 GiB used.

  Router presets planned for F5:
  - **`fast`**: Llama 3.1 8B, always loaded; quick API calls from LAN apps.
  - **`qwen27`**: Qwen3.8-27B beside `fast`, for everyday coding. Context is tight,
    roughly 0–25K (estimated); F4 measures it, with plain Q6_K (20.5 GiB) as the fallback.
  - **`qwen27-agent`**: the same file alone on the card, for long agent runs and
    architecture work. ~110K context at f16 KV, ~200K at q8_0 (estimated). Only 16 of
    the 64 layers use full attention, so the KV cache is ~64 KiB/token.
  - **`chat`**: Qwen3.6-35B-A3B beside `fast` (28.8 GiB).

  Considered and deferred (owner's earlier list):
  - Llama 3.1 70B Q4_K_M: 39.6 GiB, so ~20 GiB would run on the CPU; estimated 2–5 tok/s.
  - DeepSeek-R1-Distill-Qwen-32B: its reported GPQA 62.1 vs 89.2 for Qwen3.8-27B.
  - Devstral 2 123B Q4_K_M: 69.75 GiB, ~46–52 GiB on the CPU at 32–64K context,
    estimated 1–2 tok/s; needs VM 105 raised to ~96 GiB RAM.

  Any of these can be added later as a measured experiment. Qwen3.8-Flash-Next is not
  yet supported by llama.cpp `v0.4.1`.

- **F5** `llama-server` as a systemd service on the winning backend, bound to
  `0.0.0.0:8080`, with `--api-key` from a root-only env file.
  ✅ **F5 done 2026-09-16** (files in `scripts/llm/`, branch `feat/llm-server`).

  The router's LRU eviction counts instances, not VRAM, and it cannot pin a model
  (`server_lru_sched` in `tools/server/server-models.cpp` @ `v0.4.1`). So the
  always-on model is its own service, and the router holds one large model at a time:

  | Unit | Port | Serves | Notes |
  |---|---|---|---|
  | `llama-fast.service` | 8081 | Qwen3.5-4B as `fast`, `-c 8192`, auto slots | always on |
  | `llama-router.service` | 8080 | presets from `/etc/llama/models.ini`, `--models-max 1` | loads on first request, evicts the previous preset |

  | Preset | Model | Context (q8_0 KV, 1 slot) | Beside `fast`? |
  |---|---|---:|---|
  | `qwen27` | Qwen3.8-27B UD-Q6_K_XL | 81,920 | yes |
  | `chat` | Qwen3.6-35B-A3B UD-Q4_K_XL | **262,144** (full; fit chose it beside `fast`) | yes |
  | `qwen27-agent` | Qwen3.8-27B UD-Q6_K_XL | 195,072 | **no**: `sudo llm-mode agent` first |

  - Every preset pins `ctx-size` with `n-gpu-layers = all` and `fit = off`, so a
    preset that doesn't fit fails to load instead of shrinking or offloading silently.
  - Both units run as system user `llama` (`render`, `video`; home `/var/lib/llama`)
    via `/usr/local/bin/llama-oneapi`, which loads oneAPI. Binaries run from
    `/models/src/llama.cpp/build-sycl` (dev-owned; installing a pinned root-owned
    copy is a later hardening step).
  - API key: `/etc/llama/api-keys` (root:llama 640), generated on the VM with
    `openssl rand -hex 32`, never printed. Both ports bind `0.0.0.0` and answer 401
    without it.
  - `/usr/local/sbin/llm-mode agent|normal|status`: `agent` stops `llama-fast`;
    `normal` unloads `qwen27-agent`, starts `llama-fast` and waits for `/health`.

  **Install (F5a–b):**
  - Workstation: `scp -3 -r dev:/home/dev/homelab/scripts/llm llm:/tmp/`
  - On `llm`: `useradd --system … --groups render,video llama`; install the wrapper
    to `/usr/local/bin`, `llm-mode` to `/usr/local/sbin`, `models.ini` and the key to
    `/etc/llama` (dir 750 root:llama); `systemctl enable --now` both units.

  **Verified 2026-09-16:**
  - `fast` answered; unauthenticated `/v1/models` returned 401.
  - `chat` loaded on demand at 262,144; requesting `qwen27` logged
    `evicting idle LRU name=chat` and loaded it at 81,920.
  - `llm-mode agent` → `qwen27-agent` loaded at 195,072 with `llama-fast` inactive;
    `llm-mode normal` → agent unloaded, `fast` ready and answering.

  **Gotchas hit:**
  - `setvars.sh` parses the sourcing script's `"$@"` and uses a variable named
    `args`, so the wrapper clears `$@` and keeps the command in
    `_llama_oneapi_cmd`. Before that fix, `exec: SETVARS_CALL=1: not found`,
    exit 127.
  - The first start as the new `llama` user took **72 s**: an empty GPU compile
    cache. Later restarts take **8.2 s** (measured).
  - `curl` without `-f` treats `503 Loading model` as success; readiness checks
    must use `-f`.
  - Not yet tested: both units starting on their own after a VM reboot.

- **F6** Consumers. Scope changed 2026-09-16 (owner): **API from the LAN only**, and
  CLI use goes through `ssh llm`. The workstation tunnel is dropped, which also
  removes its port-8080 clash with `grafana-tunnel`. Remaining:
  - a CLI chat client on `llm` that talks to the local server;
  - coding agents on a LAN machine (e.g. the dev VM) pointed at `:8080`;
  - the key delivered to cluster apps (SOPS, since only the cluster reads it;
    `secrets_architecture`);
  - check whether the tailscale gateway's `192.168.50.0/24` route exposes `:8080`
    and `:8081` to tailnet devices;
  - `node_exporter` for GPU temperature/power in Grafana, plus `--metrics`
    scraping.

## Phase E — bring it under tofu, and update the docs

1. **The guest is already in tofu** if C2 went the intended way — authored, applied,
   `prevent_destroy` on. Only if the `qm` fallback was used does it need the import dance
   from `tofu/README.md` ("The sequence") with a short-lived `TofuDisk` grant.
   Either way, `tofu/README.md` needs a section on the A5 token: what it can write,
   what it deliberately cannot, and that plans for *this* resource refresh normally
   while the other four still need `-refresh=false`.
2. `HARDWARE.md`: set `sde` to `llm-pool`, change the GPU section from "not attached" to the VMID, record the
   audio IOMMU group and the Phase B/D outcomes, and add `llm-pool` to "Free capacity".
3. `README.md`: add the new row to the Guests table.
4. `SANOID.md`: add one line saying `llm-pool` is deliberately not snapshotted.
5. `HOST-MONITORING.md`: add `sde` (by-id) to `smartd` if disks are listed one by one.

## Appendix — Phases A and B as one console session

Everything above, flattened into the order you would actually type it, on the
Proxmox console at `192.168.50.101` as root. The phases above explain *why*;
this is the *what*. Roughly 20 minutes of typing plus one reboot.

**Four points stop and need a human decision.** They are marked 🛑.

```bash
### 0. Where am I, and is 105 still free
pvesh get /cluster/nextid                  # expect 105
qm list; pct list
nproc; lscpu | grep -E 'Model name|^Socket|^NUMA node\(s\)'
cat /sys/bus/pci/devices/0000:53:00.0/numa_node
readlink /sys/bus/pci/devices/0000:53:00.0/iommu_group   # must be 9, or fix step 3
readlink /sys/bus/pci/devices/0000:54:00.0/iommu_group
lspci -nnk -s 53:00.0; lspci -nnk -s 54:00.0
dmidecode -s system-product-name; dmidecode -s bios-version; pveversion
```

🛑 **Record that output somewhere before continuing** — socket count and the
GPU's NUMA node decide whether VM 105 wants CPU pinning, and none of it can be
re-derived from inside the cluster later.

> ✅ **Done 2026-09-16 — see A1 for what it printed.** One socket, one NUMA
> node, so no pinning; `nextid` is still 105; both functions are on their
> expected host drivers. Re-run it anyway if the host has rebooted since, for the
> IOMMU group numbers that step 3 depends on.

```bash
### 1. Prove sde is an orphan
D=/dev/disk/by-id/ata-HFS1T9G3H2X069N_ADB5N4365I150584Y
ls -l "$D"                                 # serial must end 584Y
zpool status archive-pool                  # 584Y must NOT appear
zpool import                               # must NOT offer a pool from this disk
zdb -l "${D}-part1"                        # old raidz2 label, not a live pool
```

🛑 **Read all four outputs before the next line.** The next command is
irreversible, and `archive-pool`'s members are three disks with nearly identical
serials. The `zdb` label also reports the name `archive-pool` — it is the *old*
raidz2's, and matching names are not evidence; compare the vdev shape (A2).

> ✅ **Done 2026-09-16.** All four proofs passed, `wipefs` completed. See A2 for
> what each one printed, including the `sas-pool` question `zpool import` raised.

```bash
### 2. Claim it  (re-set $D if this is a new shell -- an empty $D makes
###    zpool create guess at /dev/mapper/ instead of stopping)
test -b "$D" || { echo "REFUSING: '$D' is not a block device"; false; }
wipefs -a "$D"
zpool create -o ashift=12 -O compression=lz4 -O atime=off llm-pool "$D"
pvesm add zfspool llm-pool --pool llm-pool --content images --blocksize 64k
zpool status llm-pool; pvesm status | grep llm-pool
grep -A4 'zfspool: llm-pool' /etc/pve/storage.cfg   # blocksize 64k must be here

### 3. PCI mapping (lets a scoped token attach the GPU; raw paths need root@pam)
pvesh create /cluster/mapping/pci --id arc-b70 \
  --description "Intel Arc Pro B70 32GB (ASRock) - whole card, LLM VM" \
  --map node=pve,path=0000:53:00.0,id=8086:e223,subsystem-id=1849:6025,iommugroup=9
pvesh get /cluster/mapping/pci/arc-b70
readlink /sys/bus/pci/devices/0000:53:00.0/iommu_group   # MUST be 9, or fix the map above
# Reading the mapping back proves only that it was stored, not that it is right:
# PVE compares iommugroup against the hardware when the VM starts, not now.

### 4. Roles, token, ACLs
pveum role add TofuVM --privs "VM.Audit,VM.Allocate,VM.PowerMgmt,\
VM.Config.Disk,VM.Config.CPU,VM.Config.Memory,VM.Config.Network,\
VM.Config.Options,VM.Config.HWType,VM.Config.CDROM,VM.Config.Cloudinit"
pveum role add TofuStorage --privs "Datastore.Audit,Datastore.AllocateSpace,Datastore.AllocateTemplate"
pveum role add TofuMapping --privs "Mapping.Audit,Mapping.Use"

pveum user token add tofu@pve llm --privsep 1
```

🛑 **The secret prints once.** Into LastPass now, beside the age key, as
`tofu@pve!llm=<uuid>`. Losing it means deleting the token and making another.

```bash
T='tofu@pve!llm'
pveum acl modify /                             --tokens "$T" --roles PVEAuditor
pveum acl modify /vms/105                      --tokens "$T" --roles PVEAuditor,TofuVM
pveum acl modify /storage/local-lvm            --tokens "$T" --roles TofuStorage
pveum acl modify /storage/llm-pool             --tokens "$T" --roles TofuStorage
pveum acl modify /storage/local                --tokens "$T" --roles TofuStorage
pveum acl modify /mapping/pci/arc-b70          --tokens "$T" --roles TofuMapping
pveum acl modify /sdn/zones/localnetwork/vmbr0 --tokens "$T" --roles PVESDNUser
# The image download needs Sys.AccessNetwork on the node, not Sys.Modify (A5).
pveum role add TofuNet --privs "Sys.AccessNetwork"
pveum acl modify /nodes/pve --tokens "$T" --roles PVEAuditor,TofuNet
# NB: no --token flag -- the FULL token id is the userid. And do not grep by
# path: the table blanks that column on continuation rows, so a grep keeps only
# the first privilege of the block and hides the rest.
pveum acl list | grep -i tofu                            # expect 8 rows: 1 user + 7 token
pveum user permissions 'tofu@pve!llm' --path /vms/105    # write privileges here
pveum user permissions 'tofu@pve!llm' --path /vms/104    # read-only, nothing more
```

Expect write privileges under `/vms/105` and **nothing** under `/vms/104`. If
the `/sdn/...` path errors, see A5 — the bridge path varies by PVE version.

```bash
### 5. Hand the card to vfio-pci at boot (takes effect on the reboot below)
cat > /etc/modprobe.d/vfio-arc-b70.conf <<'EOF'
# Intel Arc Pro B70 (53:00.0) + its HDMI audio (54:00.0) -> vfio-pci, see homelab/GPU-VM.md
options vfio-pci ids=8086:e223,8086:e2f7
softdep xe pre: vfio-pci
softdep i915 pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
printf 'vfio\nvfio_iommu_type1\nvfio_pci\n' >> /etc/modules
update-initramfs -u -k all
proxmox-boot-tool refresh   # "no proxmox-boot-uuids" is expected: plain GRUB host
lsinitramfs /boot/initrd.img-6.17.2-1-pve | grep -E 'vfio|arc-b70'
```

🛑 **That last line must show `etc/modprobe.d/vfio-arc-b70.conf`.** If the file
is not inside the initramfs, `xe` will claim the card on the next boot regardless
of what `/etc/modprobe.d` says, and the reboot below is wasted.

🛑 **The next step takes the whole cluster down**, including the Postgres VM and
the tailnet gateway. The script wraps itself in tmux, so a dropped connection
costs you the view rather than the run — reattach with
`tmux attach -t homelab-shutdown`. The Proxmox console is still the calmest place
to watch it from.

```bash
### 6. Down, BIOS, up
bash homelab-shutdown.sh --dry-run
bash homelab-shutdown.sh --yes --poweroff-host
```

At POST, F2 → **System BIOS → Integrated Devices**: confirm *Memory Mapped I/O
above 4 GB* is Enabled (it was, 2026-09-16) and *Memory Mapped I/O Base* is the highest option
(56 TB on this machine; it was found at 12 TB)
offered. **Do not hunt for a Resizable BAR setting — this BIOS has none** (owner,
2026-09-15). Write down what the menu actually says. Then boot.

```bash
### 7. Verify, and learn whether Phase D is still needed
lspci -nnk -s 53:00.0 | grep 'in use'      # -> vfio-pci
lspci -nnk -s 54:00.0 | grep 'in use'      # -> vfio-pci
zpool list                                 # all THREE by name; -x cannot see an absent pool
zpool status -x                            # then health, incl. llm-pool
ls /sas-pool/data                          # not empty -> sas-pool really came back (B3)
lspci -vv -s 53:00.0 | grep 'Region 2'     # 32G -> skip Phase D. 256M -> Phase D.
```

Then start the guests as usual. **Next:** merge PR #20, export the three
variables from C1, and `tofu apply -refresh=false` from the dev VM.

## Checklist

- [x] A1 preflight read and recorded (2026-09-16) — except the GPU's own IOMMU group, still to read before A4
- [x] A2 `sde` proven orphan, wiped (2026-09-16)
- [x] A3 `llm-pool` created, in `pvesm status` (2026-09-16, 1.68 TiB usable, `blocksize 64k` confirmed)
- [x] A4 `arc-b70` mapping exists and `iommugroup=9` verified against the running kernel (2026-09-16)
- [x] A5 roles created, `tofu@pve!llm` created, secret in LastPass, seven token ACLs applied (2026-09-16)
- [x] A5 grants mirrored onto `tofu@pve`, `!import` moved to `--privsep 1` (2026-09-16)
- [x] A5 scoping verified: `VM.Allocate` on `/vms/105`, absent on `/vms/104`, `!import` still read-only
- [x] **Phase A complete 2026-09-16.** Next is B1, then the B2 cluster-wide reboot.
- [x] B1 vfio config written, initramfs regenerated (2026-09-16) — confirm `vfio-arc-b70.conf` is bundled with `lsinitramfs` before the B2 reboot
- [x] B2 clean shutdown, BIOS MMIO settings recorded (2026-09-16: above-4GB already Enabled; Base 12 TB → 56 TB)
- [x] B3 both functions on `vfio-pci`, **all three pools present in `zpool list`** and healthy, Region 2 = 256M, ReBAR cap advertises up to 32GB (2026-09-16)
- [x] **Phase B complete.** `sas-pool` survived the reboot — `zfs-import-scan` fix proven.
- [x] C2 VM created by `tofu apply` and in state (2026-09-16, after the C2a ATS lockup was fixed with `pci=noats`)
- [x] C3 guest on `xe` (kernel 7.0.0-31), `/models` mounted (2026-09-16); host showed 0 DMAR errors across three GPU resets. Follow-ups: GuC firmware 70.44.1 → 70.54.0; guest agent via PR #22
- [x] D one unbound resize attempt made (2026-09-16): 32 GiB → `-ENOSPC`, closed. 4 GiB (fits the existing window) untried, owner's call
- [x] D full 32 GiB ReBAR verified in the guest (2026-09-16), via 32 GiB (fails, releases the SR-IOV reservation) → 4 GiB → 32 GiB
- [x] D `gpu-rebar.service` installed and enabled on the host (2026-09-16), no-op path verified
- [ ] D boot-time resize verified across a real host reboot (first try 2026-09-16 failed at 32 GiB; sequence fixed in PR #24; expect `direct 32 GiB refused … VF BAR 2 0 GiB` then `resize complete`)
- [x] D model load time in the guest measured and written down (F4a, 2026-09-16: disk- and CPU-bound, not BAR-bound)
- [x] F0 preflight (2026-09-16): 27 GiB free on `/`, 62 GiB RAM, `dev` added to `render`/`video`, no GPU user-space installed
- [x] F1 GPU user-space (Level Zero, Vulkan, oneAPI) verified (2026-09-16): `clinfo`, `vulkaninfo` and `sycl-ls` all see the B70
- [x] F2 llama.cpp `v0.4.1` built, SYCL + Vulkan, both see the B70 (2026-09-16)
- [x] F3 models in `/models` (2026-09-16): 7B test model, plus Llama 3.1 8B Q8_0, Qwen3.8-27B UD-Q6_K_XL, Qwen3.6-35B-A3B UD-Q4_K_XL, all checksums verified
- [x] F4 benchmarks + cold load time recorded (2026-09-16): SYCL chosen; 27B cold 66.6 s / warm 20.3 s; `qwen27-agent` ~190K ctx alone (q8_0 KV); `qwen27` 2 × 40,960 beside Qwen3.5-4B
- [x] F5 `llama-fast` + `llama-router` services, presets `qwen27`/`chat`/`qwen27-agent`, `llm-mode` (2026-09-16)
- [ ] F6 LAN consumers: CLI client, agents, cluster API key (SOPS), tailnet exposure check, node_exporter
- [x] E VM 105 in tofu from creation (no import needed), `tofu plan` → No changes; README, SANOID, HOST-MONITORING, tofu/README updated, smartd monitoring `sde` on the host (2026-09-16).
