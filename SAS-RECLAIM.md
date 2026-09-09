# Reclaiming the SAS disks — retiring ext4, and rehoming the SSH recordings

**Everything here runs on the Proxmox host `192.168.50.101` as root**, except
§5, which runs on the dev VM. The dev VM has no SSH key on `.101` and no route
to the pool (`STORAGE.md:4-5`), so none of §1–4 can be run from there.

The goal is to free `sdg`, `sdh` and `sdi` — three 3.84 TB SAS SSDs, 10.47 TiB
raw — from the three bare ext4 filesystems they carry today, so the PERC H355
can be passed through whole to a TrueNAS guest. See
[`HARDWARE.md`](HARDWARE.md) for what those disks are and why the controller
topology makes this clean.

---

## ⚠️ Order matters, and the obvious order is wrong

The instinct is "delete the logs, unmount, wipe". **Do not start there.**

CTID 100 bind-mounts `/mnt/sas1/tailscale-gateway-logs` into the container at
`/var/log/ts-ssh-records`. Unmount `/mnt/sas1` while that is still the
container's configured source and one of two things happens:

- the container **fails to start**, because the bind source no longer exists; or
- worse, the directory gets recreated and now resolves to **`pve-root` on the
  boot device** — silently. Recording continues, onto the 65.6 GiB OS
  filesystem, which is the exact outcome these disks were provisioned to avoid.

So the recordings get a new home **first**. Retiring ext4 is §3, not §1.

> The old recordings are **not** being migrated. Confirmed safe to delete
> 2026-09-09 after review — 88 KB, and the ACL and ownership are the only things
> worth carrying forward. If that is not true when you read this, copy them with
> `cp -a` or `rsync -aAX`, never plain `cp`.

---

## 1. Capture what has to be reproduced

The bind mount works today because of an ACL and a UID mapping, not because of
ordinary permissions. Record both before anything changes.

```bash
pct config 100                                    # note the mpN key -- likely mp0
getfacl /mnt/sas1/tailscale-gateway-logs          # SAVE THIS OUTPUT
ls -lan /mnt/sas1/tailscale-gateway-logs
stat -c '%u %g %a' /mnt/sas1/tailscale-gateway-logs
```

**As found 2026-09-09** — and note the ACL grants a *different* UID than the one
owning the directory, which is why §2 copies it rather than retyping it:

```
# owner: 100102                 <- container uid 102
# group: 100004                 <- container gid 4
user::rwx
user:100104:rwx                 <- container uid 104, NOT 102
group::r-x
mask::rwx
other::---
default:user::rwx
default:user:100104:rwx
default:group::r-x
default:mask::rwx
default:other::---
```

The mount point key is **`mp0`**, the only one on this container. The mode is
really `0750` — `ls` renders `drwxrwx---+` because with an ACL present the group
triad shows the *mask*, not `group::`. **Reproduce owner, group and ACL, or
recording stops silently.**

> ⚠️ **The directory holds one file: `sshd-verbose.log`** — 79 KB, still being
> written 2026-09-09. Not per-session recordings. Tailscale SSH session
> recording writes one file per session, so `STORAGE.md`'s description of this
> directory as an access-evidence trail may be optimistic; worth confirming
> whether session recording is configured at all. It changes no step here — the
> directory moves either way.

Then confirm nothing else on the host uses these three filesystems:

```bash
grep -rnE '/mnt/sas[123]' /etc/pve/ /etc/systemd/ /etc/exports /etc/cron* 2>/dev/null
grep -nE 'sas[123]' /etc/fstab
pvesm status                       # they should NOT appear as PVE storages
fuser -vm /mnt/sas1 /mnt/sas2 /mnt/sas3 2>&1 | head
```

Only CTID 100's `mp0` should reference `/mnt/sas1`. Anything else that turns up
is a consumer this repo does not know about — stop and work out what it is.

## 2. Build the new home on `archive-pool`

`archive-pool` is the right destination: three-way mirrored, already under
sanoid, and 96% empty. **Not** inside TrueNAS — that would make the
access-evidence trail depend on a VM administered over the very access path the
recordings exist to audit.

```bash
zfs create -o acltype=posixacl -o xattr=sa archive-pool/ts-ssh-records
```

> ⚠️ **`acltype=posixacl` is not optional and not the default.** OpenZFS ships
> `acltype=off`, and `setfacl` on such a dataset fails with *Operation not
> supported*. Setting it at creation avoids a confusing failure three commands
> later. `xattr=sa` stores the ACL in the inode rather than a hidden directory,
> which is the recommended pairing.

Reproduce the ownership and the ACL. **Copy the ACL, do not retype it** — the
named entry is `100104` while the owner is `100102`, and that is exactly the
kind of difference a hand-written `setfacl` gets wrong:

```bash
getfacl --absolute-names /mnt/sas1/tailscale-gateway-logs > /root/ts-ssh-records.acl

chown 100102:100004 /archive-pool/ts-ssh-records
setfacl --set-file=/root/ts-ssh-records.acl /archive-pool/ts-ssh-records
```

`--set-file` applies the access **and** default entries in one go, including the
`default:` lines that make new files inherit the ACL. Without those the
directory is writable but files created inside it are not.

Verify the two match before continuing — this is a diff, not a glance:

```bash
diff <(getfacl --absolute-names /mnt/sas1/tailscale-gateway-logs | grep -v '^# file:') \
     <(getfacl --absolute-names /archive-pool/ts-ssh-records     | grep -v '^# file:')
# no output = identical
```

## 3. Repoint CTID 100

> **This cannot be done in OpenTofu.** `mount_point.volume` is ForceNew in
> bpg/proxmox, so changing it plans a **destroy and recreate** of the container,
> which `prevent_destroy` refuses:
>
> ```
> ~ volume = "/mnt/sas1/..." -> "/archive-pool/ts-ssh-records" # forces replacement
> Error: Resource instance cannot be destroyed
> ```
>
> Verified 2026-09-09 with `tofu plan -refresh=false` against a scratch copy of
> the state. So the change is made on the host and the config is reconciled
> afterwards (§5) — the same config-follows-reality shape as the 2026-09-04
> import, and the reason `prevent_destroy` is doing its job rather than being in
> the way.

Bind mounts are not hot-pluggable; stop the container first.

> ⚠️ **`pct stop 100` severs all remote access.** CTID 100 is the only tailnet
> member — it is the exit node, advertises the only approved `192.168.50.0/24`
> subnet route, and is the `ProxyJump` host for every `~/.ssh/config` entry
> including `proxmox-host`. Stopping it removes the only path to the machine
> that can start it again. **Establish a second path before running this
> command** — either a temporary k3s-hosted subnet router (see
> `kubernetes/apps/tailscale-recovery/` in git history, commit 77f6962) or a
> Cloudflare tunnel route. If you are SSH'd in through Tailscale when you run
> this, you will be locked out.

```bash
pct stop 100
pct set 100 -mp0 /archive-pool/ts-ssh-records,mp=/var/log/ts-ssh-records
pct config 100 | grep -E '^mp0'          # confirm before starting
pct start 100
```

> **✅ Completed 2026-09-09.** `pct stop 100` locked out the remote session as
> described above. Access was regained via a temporary k3s-hosted Tailscale
> subnet router (`tailscale-recovery` namespace). The bind mount was repointed
> and the container restarted from the Proxmox host once the recovery route was
> live. The recovery router was torn down immediately after.

`mp0` is confirmed as the only mount point on this container (`pct config 100`,
2026-09-09), so there is no index to substitute.

**Verify recording actually works before going further.** This is the whole
point of the exercise, and a silent failure here is invisible until someone
needs the evidence:

```bash
pct exec 100 -- findmnt /var/log/ts-ssh-records
pct exec 100 -- touch /var/log/ts-ssh-records/.write-test
ls -la /archive-pool/ts-ssh-records/.write-test    # must appear ON THE HOST
pct exec 100 -- rm /var/log/ts-ssh-records/.write-test
```

Then open a real Tailscale SSH session to a guest and confirm a recording lands
in `/archive-pool/ts-ssh-records`. A `touch` proves the mount; only a session
proves the control.

## 4. Retire ext4

Only now. Nothing should reference `/mnt/sas1` any more.

```bash
fuser -vm /mnt/sas1 /mnt/sas2 /mnt/sas3 2>&1 | head   # expect nothing
umount /mnt/sas1 /mnt/sas2 /mnt/sas3
```

**Remove the three lines from `/etc/fstab`** — lines 6, 7 and 8 as found
2026-09-09:

```bash
cp /etc/fstab /etc/fstab.bak-$(date +%F)
nano /etc/fstab
```

Delete these three:

```
UUID=76d1c54b-47a2-486d-bd36-eb0678090b70 /mnt/sas1 ext4 defaults 0 2
UUID=6db19b6a-3eeb-427f-bec5-fda18c5450ae /mnt/sas2 ext4 defaults 0 2
UUID=5a93d776-ed8e-44d6-adc3-0cc75fe473e7 /mnt/sas3 ext4 defaults 0 2
```

> ⚠️ **This step is why the whole runbook exists.** Those entries are
> `defaults 0 2` with **no `nofail`**. The devices disappear from the host the
> moment the PERC is passed through — and a missing non-`nofail` mount does not
> boot past it: systemd waits on the device, times out, and drops to an
> **emergency shell**. `.101` accepts no SSH key from the dev VM, so recovery
> needs iDRAC or a physical console. `STORAGE.md` §5c guards the PGDATA mount
> against exactly this, which is why `nofail` is on that line.

```bash
systemctl daemon-reload
mount -a                        # must be silent; no attempt to mount /mnt/sas*
rmdir /mnt/sas1 /mnt/sas2 /mnt/sas3
```

**Reboot and confirm the host comes back before touching the controller.**
This is the cheap rehearsal for the passthrough; do not skip it.

```bash
reboot
# ...then, from the dev VM:
kubectl get nodes               # all three Ready
```

Back on the host, confirm the container survived and is still recording:

```bash
pct status 100
findmnt /archive-pool/ts-ssh-records
pct exec 100 -- findmnt /var/log/ts-ssh-records
```

Then wipe the ZFS-visible and ext4 signatures, **by `by-id`, never `sdX`**:

```bash
wipefs -a /dev/disk/by-id/scsi-35002538a48872950   # sdg, S3D9NX0K803377
wipefs -a /dev/disk/by-id/scsi-35002538a48872700   # sdh, S3D9NX0K803346
wipefs -a /dev/disk/by-id/scsi-35002538a48872be0   # sdi, S3D9NX0K803418
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT | grep -E 'sd[ghi]'   # no FSTYPE, no mount
```

`sdX` names reorder when a disk is added or the controller enumerates
differently (`STORAGE.md:189-190`). Paste the `by-id` path; do not type it.
`wipefs` on the wrong device is unrecoverable.

> **✅ Completed 2026-09-09.** fstab entries removed, backup at
> `/etc/fstab.bak-2026-09-09`. Host rebooted cleanly — no emergency shell, all
> three k3s nodes Ready, CT 100 running with bind mount intact. All three ext4
> superblock signatures wiped (`wipefs -a` by `by-id`). Mount points removed.
> `blkid` cache may show stale FSTYPE until next probe — on-disk signatures are
> gone.

## 5. Reconcile OpenTofu — on the dev VM, on a branch

The host is now ahead of the config. Bring the config to it and prove the plan
is clean:

```bash
cd ~/homelab && git checkout -b fix/ts-ssh-records-on-archive-pool
nano tofu/proxmox-container.tf
#   mount_point.volume -> "/archive-pool/ts-ssh-records"
```

```bash
cd tofu && tofu plan
```

**`0 to add, 0 to change, 0 to destroy` is the only acceptable result.** A plan
that still proposes replacement means the host change did not take, or the
`mpN` index differs — go back to §3 rather than forcing it. `prevent_destroy`
stays on.

> **✅ Completed 2026-09-09.** `tofu plan -target=proxmox_virtual_environment_container.tailscale_gateway`
> confirmed 0 changes. Branch `fix/ts-ssh-records-on-archive-pool` merged to
> main and deleted. Proxmox API token regenerated (`tofu@pve!import`); Cloudflare
> provider was skipped with `-target` since only the container resource changed.

## 6. Put the new dataset under sanoid

The recordings have never been snapshotted (`STORAGE.md` appendix). They are now
on a pool that can. Add beside the existing three (`SANOID.md`):

```ini
[archive-pool/ts-ssh-records]
	use_template = archival
	recursive = no
```

```bash
systemctl restart sanoid.timer
sanoid --monitor-snapshots
```

> **✅ Completed 2026-09-09.** Stanza added to `/etc/sanoid/sanoid.conf` (tab
> indentation verified, 15 tab-indented lines). First snapshots taken —
> monthly, daily, hourly — all at 108K REFER. `sanoid.timer` restarted.

---

## What this unblocks

Three empty SAS SSDs on a controller carrying nothing else, and a host whose
`/etc/fstab` no longer references them. That is the precondition for passing
`c3:00.0` through to a TrueNAS guest — all three SAS disks had SMART read and
verified clean on 2026-09-09 (see `HARDWARE.md`). All preconditions for
passthrough are now satisfied.

`sde` and `sdf` are deliberately **not** part of this. They stay on the host as
cold spares for `archive-pool`: identical model to two of its three mirror
members, same batch, and that pool holds PGDATA and MinIO.

## Related

- [`HARDWARE.md`](HARDWARE.md) — what these disks are, the controller topology,
  and the SMART readings
- [`STORAGE.md`](STORAGE.md) — the PGDATA zvol; §5c is the `nofail` lesson this
  runbook inherits, and the appendix is the original note on `/mnt/sas1`
- [`SANOID.md`](SANOID.md) — snapshot templates
- `tofu/proxmox-container.tf` — CTID 100, and the `prevent_destroy` that makes
  §3 a host-side change
