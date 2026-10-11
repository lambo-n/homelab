# Disk filling up — what to check and do

> 🔁 **Standing runbook.** Start here when `NodeRootDiskLow` fires (a node's `/`
> under 20% free), a guest reports "no space left on device", or
> `HostThinPoolDataHigh` fires. The history of the cleanup that produced it, and
> the one procedure not yet needed (a dedicated data disk for worker1), are in
> [`../archive/DISK-SPACE-HEADROOM.md`](../archive/DISK-SPACE-HEADROOM.md).

`sudo` steps run on the machine named. Steps on the Proxmox host
`192.168.50.101` (`qm`, `lvm`, `zfs`) are the owner's, as root — see
[`../AGENTS.md`](../AGENTS.md) rule 3.

## Where the space goes

| Machine | Disk | What fills it |
|---|---|---|
| `k3s-control` (102), `k3s-worker1` (103), `k3s-worker2` (104) | root LV, 10–32 GB | Container images first. Then `local-path` volumes: on worker1 Prometheus, Grafana, Alertmanager and Home Assistant's config; worker2's PGDATA is on its own zvol |
| dev VM (101) | root LV, 30 GB | Tool caches (`~/.cache`, mise installs, npm) and `tofu/*/.terraform` |
| Proxmox `local-lvm` | one thin pool shared by every guest root disk | Blocks a guest wrote once and never gave back. Needs `discard=on` and `fstrim` |

## 1. See how bad it is

From the dev VM, any node's root filesystem, with no shell on the node:

```bash
kubectl get --raw \
  /api/v1/nodes/k3s-worker1/proxy/stats/summary \
  | jq '.node.fs, .node.runtime.imageFs'
```

Change the node name for the others. `availableBytes` against `capacityBytes` is
the free fraction; `imageFs.usedBytes` is the image store.

## 2. Reclaim on a k3s node

On the node, find what is big. `agent/containerd` is images, `storage` is the
`local-path` volumes:

```bash
sudo du -xh --max-depth=2 /var/lib/rancher \
  | sort -rh | head -12
```

Renovate bumps leave the previous image versions behind. Remove the ones no
container uses:

```bash
sudo crictl --timeout 5m rmi --prune
df -h /
```

> ⚠️ Without `--timeout`, large images fail with `DeadlineExceeded` after two
> seconds, but containerd keeps deleting, so the errors do not mean it failed.
> `df -h /` a minute later is the check. A `du` run during the deletion prints
> `No such file or directory` for the same reason.

The workers also clean up on their own: kubelet starts image garbage collection at
65% used and clears to 55% (`image-gc-high-threshold=65`,
`image-gc-low-threshold=55` in `/etc/rancher/k3s/config.yaml`; `k3s-control` has
the default 85%). Check from the dev VM that a worker has them:

```bash
kubectl get --raw \
  /api/v1/nodes/k3s-worker1/proxy/configz \
  | jq '.kubeletconfig
    | {imageGCHighThresholdPercent,
       imageGCLowThresholdPercent}'
```

Expect `65` and `55`. If a node lost its `config.yaml`, recreate it:

```bash
sudo mkdir -p /etc/rancher/k3s
echo 'kubelet-arg:' \
  | sudo tee /etc/rancher/k3s/config.yaml
echo '  - image-gc-high-threshold=65' \
  | sudo tee -a /etc/rancher/k3s/config.yaml
echo '  - image-gc-low-threshold=55' \
  | sudo tee -a /etc/rancher/k3s/config.yaml
sudo systemctl restart k3s-agent
```

Restarting the agent does not stop running containers; the node may show
`NotReady` for under a minute.

## 3. Reclaim on any guest

Hand freed blocks back to the thin pool, then read the output:

```bash
sudo fstrim -av
```

> ⚠️ `fstrim -a` can skip `/`. The output must contain a `/` line; if it does
> not, run `sudo fstrim -v /`.

This only returns space if the disk has `discard=on`. On the host (change the VM
ID for the others):

```bash
qm config 103 | grep ^scsi0
```

Changing `discard` takes effect only at the next full restart, `qm reboot`; a
reboot from inside the guest does not apply it. For a k3s node, cordon and drain it
first. A CNPG primary has a PodDisruptionBudget, so draining `k3s-worker2` needs
`--disable-eviction`. Judge a drain finished by whether any non-DaemonSet pod is
still scheduled on the node; CNPG recreates its pod under the same name, so
waiting for the name to disappear never ends.

On the dev VM, the caches regenerate and are the usual culprits:

```bash
mise prune --yes
uv cache clean
npm cache clean --force
```

`tofu/proxmox/.terraform` and `tofu/cloudflare/.terraform` come back with
`tofu init`.

## 4. Grow a disk

A guest's root LV may already have free space in its volume group. In the guest:

```bash
sudo vgs
```

If `VFree` is not zero:

```bash
sudo lvextend -r -l +100%FREE \
  /dev/ubuntu-vg/ubuntu-lv
```

Otherwise grow the virtual disk on the host (the owner's), then the partition, PV
and filesystem in the guest. These guests use LVM on `sda3`; confirm with `lsblk`.

```bash
qm resize 103 scsi0 +8G
```

```bash
sudo growpart /dev/sda 3
sudo pvresize /dev/sda3
sudo lvextend -r -l +100%FREE \
  /dev/ubuntu-vg/ubuntu-lv
```

Then set `size` for that disk in `tofu/proxmox/proxmox-vms.tf` to match; the file
follows the host, because the API token cannot write these VMs.

## 5. The thin pool (host)

`local-lvm` is overcommitted by design, so a full pool breaks every guest disk.
`HostThinPoolDataHigh` and `Critical` fire at 80% and 90%
([`../HOST-MONITORING.md`](../HOST-MONITORING.md)).

```bash
lvs -o lv_name,data_percent,lv_profile pve
vgs pve
```

A guest's thin volume that is much fuller than the guest's own `df` is the
candidate for step 3. The pool grows by itself too: the `thin-autoextend` profile
on `pve/data` extends it by 10% when it reaches 90%, bounded by the volume
group's `VFree`. Check that it is attached and monitored:

```bash
lvs -o lv_name,lv_profile,seg_monitor pve/data
```

Expect `thin-autoextend` and `monitored`. To extend by hand:

```bash
lvextend -L +10G pve/data
```

## Checking it

| Check | Command | Healthy |
|---|---|---|
| Guest has room | `df -h /` in the guest | at least 25% free |
| Node alert quiet | `NodeRootDiskLow` in Prometheus | inactive |
| Trim reached the pool | `lvs -o lv_name,data_percent pve` | the guest's volume falls after `fstrim` |
| Pool trend | `host_lvm_thinpool_data_percent` | below 80%; the host script refreshes it every 5 minutes |
