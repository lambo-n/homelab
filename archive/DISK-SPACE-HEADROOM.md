# Disk space — headroom for the dev VM and the k3s workers

> 📦 **Archived 2026-10-11.** The plan for storage headroom on the dev VM, the
> k3s workers and the Proxmox thin pool, as written, followed by what was done
> and where reality differed (see *Outcome* at the end). The recurring part, what
> to check and do when a disk fills, is the standing runbook
> [`../runbooks/DISK-SPACE.md`](../runbooks/DISK-SPACE.md). Phase C below was not
> needed and is kept for the day it is.

Who runs what: steps tagged **[host]** run as root on the Proxmox host
`192.168.50.101` and are the owner's (`zfs`, `qm`, `pvesm` administration — see
[`../AGENTS.md`](../AGENTS.md) rule 3). **[worker1]** is root on `k3s-worker1`
(`192.168.50.105`). **[dev]** is the dev VM. **[repo]** is a normal PR.

## Why these phases, in this order

| Finding | Source | Phase |
|---|---|---|
| Dev VM root LV is 15 GB on a 30 GB partition | `lsblk` on the dev VM | A |
| Worker1's 32 GB root disk is mostly container images (15 GB of 25 GB used), and old image versions pile up after each Renovate bump until kubelet garbage collection starts at 85% used | `du` of `/var/lib/rancher/k3s/agent`, `crictl images` | A |
| The TSDB, Grafana, Alertmanager and Home Assistant config share that root disk (2.8 GB) | `du` of `/var/lib/rancher/k3s/storage` | C |
| Nothing scrapes the dev VM, and the node-disk alerts fire only near the 5% eviction line | `observability/*/scrapeconfig.yaml` | B |
| Every VM root disk has `discard = "ignore"`, so freed blocks never return to the thin pool | `tofu/proxmox/proxmox-vms.tf` | E |
| Thin pool is 130 GiB, overcommitted, with 16 GiB unallocated in the VG and no autoextend | `host_lvm_thinpool_*` metrics | F |

Prometheus must stay on worker1 and must not share a filesystem with PGDATA —
the placement rule is in the header of
[`kube-prometheus-stack/app/helmrelease.yaml`](../kubernetes/apps/observability/kube-prometheus-stack/app/helmrelease.yaml).
That is why phase C gives worker1 its **own** data disk on `archive-pool`
instead of moving the TSDB to worker2. The TSDB cannot go on NFS either
(mmap and file locking), so a block device it is.

---

## Phase A — reclaim what is already allocated

**A1 [dev] — use the unallocated half of the dev VM's disk.**

```bash
sudo vgs
sudo lvs
```

`VFree` on `ubuntu-vg` should show roughly 15 GiB. Then:

```bash
sudo lvextend -r -l +100%FREE \
  /dev/ubuntu-vg/ubuntu-lv
df -h /
```

`-r` grows the ext4 filesystem in the same step. Expect `/` at about 30 GB.

**A2 [dev] — delete the leftover provider cache from before the tofu split.**
`tofu/` has no `.tf` files at its top level, so `tofu/.terraform` (850 MB) is
unused. Leave every `terraform.tfstate*` file alone: they are rollback history.

```bash
cd ~/homelab/tofu
ls *.tf
rm -rf .terraform
```

`ls *.tf` must fail with "No such file". If it lists anything, stop.

**A3 [worker1] — see what is on the node, then prune unused images.**

```bash
du -xh --max-depth=2 /var/lib/rancher \
  | sort -rh | head -12
du -xh --max-depth=1 /var/log | sort -rh | head -5
crictl images
```

Renovate bumps leave the previous image versions behind, and they pile up until
kubelet garbage collection starts at 85% used. Remove the ones nothing runs:

```bash
crictl --timeout 5m rmi --prune
df -h /
```

`--prune` only removes images no container uses. Repeat on `k3s-worker2` and
`k3s-control`.

> ⚠️ Without `--timeout`, large images fail with `DeadlineExceeded` after two
> seconds, but containerd keeps deleting in the background, so those errors do
> not mean the prune failed. Check `crictl images` and `df -h /` a minute later.
> A `du` run during the deletion prints `No such file or directory` for the same
> reason.

**A4 [worker1], [worker2] — make kubelet clean up earlier.** At the default 85%
threshold, garbage collection starts at about 27 GB used on worker1, which leaves
a few GB of room. At 65% it starts at about 21 GB and the stale versions remove
themselves. Do each worker in turn. First confirm nothing already sets kubelet
flags (this should print nothing), and that there is no config file yet:

```bash
systemctl cat k3s-agent | grep -i kubelet-arg
sudo cat /etc/rancher/k3s/config.yaml
```

The directory does not exist on these nodes, so create it, then the file:

```bash
sudo mkdir -p /etc/rancher/k3s
```

```bash
echo 'kubelet-arg:' \
  | sudo tee /etc/rancher/k3s/config.yaml
echo '  - image-gc-high-threshold=65' \
  | sudo tee -a /etc/rancher/k3s/config.yaml
echo '  - image-gc-low-threshold=55' \
  | sudo tee -a /etc/rancher/k3s/config.yaml
```

If a `config.yaml` or a `kubelet-arg:` key already exists, add the two items to
it instead of creating a second key. Restart the agent; running containers keep
going and the node may show `NotReady` for under a minute:

```bash
sudo systemctl restart k3s-agent
```

`k3s-control` is left alone: its images are under 1 GB, so the setting would do
nothing, and restarting the `k3s` server unit drops the API server briefly.

Check it from the dev VM (change the node name for each):

```bash
kubectl get --raw \
  /api/v1/nodes/k3s-worker1/proxy/configz \
  | jq '.kubeletconfig
    | {imageGCHighThresholdPercent,
       imageGCLowThresholdPercent}'
```

Expect `65` and `55`. The node config is not in git (Flux does not reach it), so
note the setting in `README.md` next to the other platform pieces outside
Kubernetes.

---

## Phase B — make the next fill-up visible

**B1 [dev] then [repo] — scrape the dev VM.** Install `node_exporter` on the dev
VM, allow `:9100` from the three k3s nodes in `ufw`, then add a `ScrapeConfig`
for `192.168.50.103:9100` modelled on
[`observability/llm-vm/app/scrapeconfig.yaml`](../kubernetes/apps/observability/llm-vm/app/scrapeconfig.yaml).
Add the dev VM to the README row for what runs on VM 101.

**B2 [repo] — warn earlier on node root disks.** Add a `PrometheusRule` that
warns when a node's `/` has under 20% free for 15 minutes. The default
`NodeFilesystem*` alerts fire close to kubelet's 5% eviction threshold, which is
too late to act. Exclude `tmpfs`, `overlay` and the ZFS mounts on the host.

---

## Phase C — a dedicated data disk for worker1 on `archive-pool`

> **Only if needed.** The volumes this phase moves are 2.8 GB of worker1's 16 GB
> used, and its root disk has about 45% free once old images are pruned. Do this
> phase if either of these happens:
>
> - the TSDB needs more than about 6 GiB (longer retention, or a Loki that wants
>   its own storage), since `retentionSize` is `5GiB` and the shared root disk is
>   why it is not larger;
> - worker1's `/` falls under 25% free again despite the kubelet image-GC
>   setting from step A4 (the `NodeRootDiskLow` alert fires at 20%).

Result: `/var/lib/rancher/k3s/storage` on worker1 is a 24 GiB zvol on
`archive-pool` (a 3-way mirror), the same pattern as worker2's PGDATA disk. Every
`local-path` volume on worker1 lands on it, with **zero Kubernetes changes**,
because that path is the cluster's `nodePathMap`.

> ⚠️ **The mount point is not empty on worker1.** Worker2's path was empty when
> its disk went in; worker1's holds the live Prometheus, Grafana, Alertmanager
> and Home Assistant volumes. A mount over a non-empty directory hides what is
> underneath and the data looks lost. Copy first, mount second, as below.

> ⚠️ **Pool rebuilds now stop worker1 as well as worker2.** Anything that
> destroys, exports or rebuilds `archive-pool` needs both VMs stopped first.

**C1 [host] — create and attach the zvol.**

```bash
qm config 103 | grep -E '^scsi'
```

Only `scsi0` should exist. Then:

```bash
qm set 103 \
  -scsi1 archive-pool:24,backup=0,discard=on,ssd=1
zfs list -t volume -r archive-pool
```

Expect a new `archive-pool/vm-103-disk-0`, thick (`refreservation` equal to the
size). 24 GiB is about 9× the current TSDB. `backup=0` keeps it out of `vzdump`.
Leave it **out of sanoid**: metrics are regenerable, and TSDB compaction rewrites
blocks constantly, so snapshots of it would only consume pool space.

**C2 [worker1] — format it.** The guest may need a bus rescan before the disk
shows up:

```bash
echo "- - -" | tee /sys/class/scsi_host/host0/scan
lsblk
```

The new, unpartitioned 24G device is almost certainly `/dev/sdb`. If it is not,
use the device `lsblk` shows for every command below.

```bash
mkfs.ext4 -L k3sdata /dev/sdb
tune2fs -m 0 /dev/sdb
blkid /dev/sdb
```

`tune2fs -m 0` drops ext4's 5% root reserve, which is pointless on a data volume.
No partition table: growing it later is `qm resize` plus `resize2fs`.

**C3 [worker1] — quiesce the node.** A drain stops every writer to the volumes;
pods pinned to this node by `nodeSelector` go `Pending` until it returns. The
cluster has no other place for them, so the monitoring stack, MinIO and Home
Assistant are down for the rest of this phase.

```bash
kubectl cordon k3s-worker1
kubectl drain k3s-worker1 \
  --ignore-daemonsets \
  --delete-emptydir-data
```

If a PodDisruptionBudget blocks the drain, add `--disable-eviction`. Then stop the
agent so nothing restarts underneath you:

```bash
systemctl stop k3s-agent
```

**C4 [worker1] — copy the existing volumes onto the new disk.**

```bash
mkdir -p /mnt/newdata
mount /dev/sdb /mnt/newdata
rsync -aHAX --info=progress2 \
  /var/lib/rancher/k3s/storage/ \
  /mnt/newdata/
```

The cluster keeps 15 days of metrics, which are cheap to lose. To start Prometheus
empty instead of copying its blocks, add this to the `rsync`:

```bash
  --exclude='*prometheus-kube-prometheus-stack-prometheus*'
```

Compare before you move anything:

```bash
du -sh /var/lib/rancher/k3s/storage /mnt/newdata
ls /mnt/newdata
```

The sizes should match (less the TSDB if you excluded it) and `ls` should list the
`pvc-…` directories. Then release the temporary mount:

```bash
umount /mnt/newdata
```

**C5 [worker1] — put the disk at the real path, with the guards.** These are the
same three layers as worker2's PGDATA disk: mount by UUID, make the bare mount
point immutable, and refuse to start k3s without the mount. Without them a failed
mount makes `local-path` write to the root disk silently.

Move the old data aside (it stays until phase C7) and recreate an empty mount
point:

```bash
mv /var/lib/rancher/k3s/storage \
  /var/lib/rancher/k3s/storage.old
mkdir /var/lib/rancher/k3s/storage
```

Make the bare directory immutable **while it is unmounted**, and prove it:

```bash
chattr +i /var/lib/rancher/k3s/storage
lsattr -d /var/lib/rancher/k3s/storage
touch /var/lib/rancher/k3s/storage/canary
```

`lsattr` must show an `i`, and the `touch` **must fail** with "Operation not
permitted". That failed `touch` is the only evidence the guard works; once the
volume is mounted the check cannot be repeated.

Mount by UUID:

```bash
printf 'UUID=%s %s ext4 %s 0 2\n' \
  "$(blkid -s UUID -o value /dev/sdb)" \
  /var/lib/rancher/k3s/storage \
  defaults,noatime,nofail \
  | tee -a /etc/fstab
mount -a
findmnt /var/lib/rancher/k3s/storage
```

Read the `fstab` line `tee` printed; it must contain a real UUID. `findmnt` must
show `/dev/sdb`.

Refuse to start k3s without the mount:

```bash
mkdir -p /etc/systemd/system/k3s-agent.service.d
cd /etc/systemd/system/k3s-agent.service.d
echo '[Unit]' | tee 10-data-mount.conf
echo 'RequiresMountsFor=/var/lib/rancher/k3s/storage' \
  | tee -a 10-data-mount.conf
cat 10-data-mount.conf
systemctl daemon-reload
```

`cat` must show both lines. Then prove systemd turned it into a dependency:

```bash
systemctl show k3s-agent -p Requires -p After \
  | tr ' ' '\n' | grep -i storage
```

Expect `var-lib-rancher-k3s-storage.mount`. Start the node back up:

```bash
systemctl start k3s-agent
```

```bash
kubectl uncordon k3s-worker1
kubectl get pods -A -o wide | grep worker1
```

**C6 [repo] — record the disk, raise the cap.**

- `tofu/proxmox/proxmox-vms.tf`: add a second `disk` block to VM 103 mirroring
  worker2's `scsi1` block (`datastore_id = "archive-pool"`, `size = 24`,
  `discard = "on"`, `ssd = true`, `backup = false`,
  `path_in_datastore = "vm-103-disk-0"`). The API token cannot write VM 103, so
  the host is the source of truth and the file follows it. `tofu plan` in
  `tofu/proxmox/` must report no changes.
- `kube-prometheus-stack/app/helmrelease.yaml`: rewrite the sizing comment for the
  new disk and raise `retentionSize` from `5GiB` to the size the new disk justifies
  (`8GiB` is about 3× the current steady state), with the PVC request to match.
- `README.md` storage table, `HARDWARE.md` zvol list, `SANOID.md` (the zvol is
  deliberately not snapshotted) and the `archive-pool` rebuild warning in
  `README.md`.

**C7 [worker1] — only after a day of healthy running:**

```bash
rm -rf /var/lib/rancher/k3s/storage.old
df -h /
```

That returns the TSDB, Grafana and Home Assistant space to the root disk.

---

## Phase D — decide whether the root disk still needs to grow

Re-measure after phase A (and C7, if you did phase C). If worker1's `/` has more
than about 25% free, stop here. Otherwise grow it.

```bash
df -h /
```

**[host]**

```bash
qm resize 103 scsi0 +8G
```

**[worker1]**

```bash
growpart /dev/sda 1
resize2fs /dev/sda1
```

Check the device and partition numbers with `lsblk` first. **[repo]** then set
`size` on the `scsi0` block of VM 103 to match. The thin pool takes the extra
space only as it is written, but it is already overcommitted, so do phase F first
or at the same time.

---

## Phase E — let freed space return to the thin pool

All four VM root disks are `discard = "ignore"`, so `fstrim` inside a guest
frees nothing in `local-lvm`. For each of VM 102, 103, 104 and 101 (dev VM last,
because restarting it ends your session):

**[host]** read the current disk line, then restate it with `discard=on` — `qm set`
replaces the whole option, so every existing flag has to be repeated:

```bash
qm config 103 | grep ^scsi0
```

```bash
qm set 103 \
  -scsi0 local-lvm:vm-103-disk-0,discard=on,iothread=1
```

Build the `qm set` line from what `qm config` printed (for example, keep `size=`).
The new setting applies at the next full stop and start:

```bash
qm shutdown 103
qm start 103
```

Do the k3s nodes one at a time, with `kubectl drain` first, and **[repo]** change
`discard = "ignore"` to `"on"` in `proxmox-vms.tf` for each as it is done. Then in
each guest:

```bash
fstrim -av
```

---

## Phase F — thin pool headroom on the host

**[host]**

```bash
pvesm status
vgs pve
lvs pve
```

- Settle the open question of whether the pool should grow into the VG on its own
  (`thin_pool_autoextend_threshold` in `/etc/lvm/lvm.conf`). The alternative is a
  one-off `lvextend -L +16G pve/data` when phase D needs the room.
- Correct the `local-lvm` free-space figure in `README.md` from the live output.

---

## Checking it

| Check | Command | Healthy |
|---|---|---|
| Dev VM root grew | `df -h /` on the dev VM | about 30 GB total |
| Worker1 mount present | `findmnt /var/lib/rancher/k3s/storage` | `/dev/sdb`, `ext4` |
| Guard works while unmounted | `touch` canary in C5 | `Operation not permitted` |
| k3s refuses without the mount | `systemctl show k3s-agent -p Requires` | lists `var-lib-rancher-k3s-storage.mount` |
| Workloads back | `kubectl get pods -A -o wide` | all `Running` on `k3s-worker1` |
| Prometheus intact | `prometheus_tsdb_storage_blocks_bytes` | non-zero and growing |
| Home Assistant config intact | open the UI | existing devices and automations present |
| Worker1 root headroom | kubelet summary: `.node.fs.availableBytes` | more than 25% free |
| TRIM reaches the pool | `host_lvm_thinpool_data_percent` after `fstrim -av` | falls |

Worker1's kubelet figures need no node shell:

```bash
kubectl get --raw \
  /api/v1/nodes/k3s-worker1/proxy/stats/summary \
  | jq '.node.fs'
```

## If it goes wrong

- **A pod `Pending` after the node returns:** its `local-path` volume has node
  affinity to worker1, so it needs the node `Ready` and uncordoned. Check
  `kubectl get nodes`.
- **Data seems missing after C5:** it was not lost. It is in
  `/var/lib/rancher/k3s/storage.old`, or the mount is not up (`findmnt`). Stop the
  agent, fix the mount, and copy again.
- **`rsync` ran out of space on the new disk:** `df -h /mnt/newdata`. The disk
  must exceed `du -sh` of the old directory.

---

## 2026-10-11 — outcome

The thin pool `local-lvm` went from **66.3% to 44.3% used** (about 86 GiB to 58
GiB of 130 GiB). Nothing was lost; the longest outage was about 8 minutes, on the
worker drains.

| Phase | Result |
|---|---|
| A. Reclaim | Dev VM root LV 15 → 30 GB (`lvextend -r`). `tofu/.terraform` (850 MB) deleted. Old images pruned on both workers: worker1 free 5.5 → 14.3 GB (17% → 45%), worker2 4.1 → 8.1 GB. Kubelet image GC set to 65/55 on both workers. `k3s-control` left alone |
| B. Visibility | PR #136: `dev-vm` scrape, `DevVmDown`, `NodeRootDiskLow` (any node's `/` under 20% free for 15 min). Verified: `dev` target up, rule returns a series for all six targets |
| C. Worker1 data disk | **Not done.** Worker1 had 45% free after A, and the data it would move was 2.8 GB. `retentionSize` was raised to `5GiB` on the root disk instead (PR #137). Do C if the TSDB needs more than ~6 GiB, or worker1's `/` falls under 25% free despite the GC setting |
| D. Root disk grow | Not needed |
| E. Discard | `discard=on` on all four root disks, applied by a full VM restart each. Per thin volume: control 62.4 → 35.7%, worker2 82.3 → 39.7%, worker1 85.2 → 47.6%, dev 49.0 → 30.2%. About 30 GiB returned. Recorded in tofu in PR #138 |
| F. Thin pool | `thin-autoextend` LVM profile on `pve/data` (90% threshold, +10%). The stale README free-space figure (82.1 GiB, actual ~44) was replaced with a pointer to where to read it |

### Why it happened

- Container images were 15 of the 25 GB used on worker1. Renovate bumps leave the
  previous versions behind until kubelet garbage collection starts at 85% used, and
  a 32 GB disk reaches pressure well before that. The 3 GB drop that raised the
  alarm was the latest chart bumps pulling new images.
- Nothing scraped the dev VM, so its disk filled unnoticed, and the default
  `NodeFilesystem*` alerts fire only near kubelet's 5% eviction line.
- All four root disks were `discard=ignore`, so space freed inside a guest never
  returned to the pool.

### Where the plan was wrong or incomplete

- **The monitoring data was not the main consumer.** The plan opened by moving the
  TSDB off worker1's root disk; `du` showed it was 2.8 GB of 25, and the images
  were the problem. That is why C was dropped.
- **Phase D's grow commands assumed a plain partition.** These guests use LVM on
  `sda3`: the sequence is `growpart /dev/sda 3`, `pvresize /dev/sda3`, then
  `lvextend -r -l +100%FREE /dev/ubuntu-vg/ubuntu-lv`. The standing runbook has
  the correct version.
- **`crictl rmi --prune` printed `DeadlineExceeded`** for large images after two
  seconds, while containerd kept deleting. Use `--timeout 5m`.
- **`fstrim -av` skipped `/` on worker2.** `fstrim -v /` returned 3.9 GiB that the
  `-a` run had not. Check that a `/` line appears.
- **CNPG recreates a pod under the same name** as soon as the old one exits, so
  "wait until the pod is gone" never finishes. Judge a drain by whether any
  non-DaemonSet pod is still scheduled on the node. Both CNPG primaries have a
  PodDisruptionBudget, so draining worker2 needed `--disable-eviction`.
- **`k3s-control` was skipped for the kubelet GC setting**: under 1 GB of images,
  and restarting the `k3s` server unit drops the API server briefly.
