#!/usr/bin/env bash
# Graceful full shutdown of the homelab, in dependency order.
#
# RUN ON THE PROXMOX HOST (192.168.50.101) AS ROOT.
# Copy it there FROM THE WORKSTATION -- the host cannot scp from the dev VM
# (dev accepts only the owner's GitHub keys; root@pve holds none):
#   scp -3 dev:/home/dev/homelab/scripts/homelab-shutdown.sh proxmox-host:/root/
# then on the host:  bash homelab-shutdown.sh
#
# Why the order matters more than usual here: 192.168.50.101 is BOTH the
# hypervisor AND the NFS server backing the cluster's only two stateful
# services. `minio-pv` -> /archive-pool/minio-data and `postgres-pv` ->
# /archive-pool/postgres-data are NFS mounts held by the guests. Stop the NFS
# server (or the host) while a guest still has those mounts and you get hung
# I/O on the client and a Postgres that never checkpoints — the "database
# system was not properly shut down; automatic recovery in progress" path.
# So: every guest goes down first, host last, and nothing touches the pool or
# the exports until the guest list is empty.
#
# Nothing here forces anything off. `qm shutdown` / `pct shutdown` is an ACPI
# request the guest services; systemd stops k3s, k3s stops the pods, containerd
# signals Postgres, Postgres checkpoints and exits. If a guest will not go down
# in time the script STOPS rather than hard-killing it — a hard stop on the
# database VM is exactly the unclean shutdown this ordering exists to avoid.
# Use --force-after only when you have looked at the guest and decided.
#
# >> IF YOU ARE CONNECTED OVER SSH OR TAILSCALE <<
# 192.168.50.102 is the Tailscale entry container and is therefore the LAST
# guest stopped. If you are reaching this host through it, your session dies at
# that step -- and a shutdown that dies halfway is the bad outcome this whole
# ordering exists to avoid.
#
# So the script now re-runs ITSELF inside tmux, on the host, and attaches you to
# it. Nothing to remember and nothing to type: if the connection drops, the run
# keeps going without you. Reattach when you can reach the host again:
#
#   tmux attach -t homelab-shutdown
#
# Running inside tmux also downgrades the Tailscale self-disconnect refusal to a
# warning, because the reason for that refusal -- the script dying with your
# session -- no longer applies. --allow-self-disconnect is then unnecessary.
#
# Pass --no-tmux to stay in the current session (useful from the Proxmox console,
# where there is nothing to disconnect).
#
# Usage:
#   bash homelab-shutdown.sh [--dry-run] [--poweroff-host] [--yes]
#                            [--timeout N] [--force-after]
#                            [--allow-self-disconnect] [--no-tmux]

set -euo pipefail

# Kept verbatim so the tmux re-exec below can replay this invocation exactly.
ORIG_ARGS=("$@")

TMUX_SESSION=homelab-shutdown
USE_TMUX=1
TIMEOUT=180          # per-guest seconds to wait for a clean stop
POWEROFF_HOST=0      # off by default: the host is also the NFS server
DRY_RUN=0
ASSUME_YES=0
FORCE_AFTER=0
ALLOW_SELF_DISCONNECT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)                DRY_RUN=1 ;;
    --poweroff-host)          POWEROFF_HOST=1 ;;
    --yes|-y)                 ASSUME_YES=1 ;;
    --force-after)            FORCE_AFTER=1 ;;
    --allow-self-disconnect)  ALLOW_SELF_DISCONNECT=1 ;;
    --no-tmux)                USE_TMUX=0 ;;
    --timeout)                TIMEOUT="${2:?--timeout needs a value}"; shift ;;
    -h|--help)                sed -n '2,49p' "$0"; exit 0 ;;
    *)                        echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

die()  { echo "ERROR: $*" >&2; exit 1; }
note() { echo "     $*"; }

# ---------------------------------------------------------------- preflight
[[ $EUID -eq 0 ]] || die "must run as root"
command -v qm  >/dev/null || die "qm not found — this is not the Proxmox host"
command -v pct >/dev/null || die "pct not found — this is not the Proxmox host"
[[ $(hostname) == pve ]] || echo "WARNING: hostname is '$(hostname)', expected 'pve'"

# ------------------------------------------------------------ tmux re-exec
# Done AFTER the preflight above, so "must run as root" or "not the Proxmox
# host" appears in the terminal you typed into rather than in a pane that
# vanishes. Skipped when already inside tmux, when --no-tmux is given, and when
# there is no terminal to attach to (cron, a pipe, a non-interactive SSH -c).
if [[ $USE_TMUX -eq 1 && -z "${TMUX:-}" && -t 0 && -t 1 ]]; then
  if command -v tmux >/dev/null; then
    self="$(readlink -f "$0")"
    # printf %q on every element: paths and values reach the new shell intact.
    argv=("$(printf '%q' "$self")" --no-tmux)
    for a in ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}; do argv+=("$(printf '%q' "$a")"); done
    echo "==> Re-running inside tmux session '$TMUX_SESSION'."
    echo "    A dropped connection can no longer kill the shutdown."
    echo "    Reattach with:  tmux attach -t $TMUX_SESSION"
    echo
    # -A: attach if the session already exists, so a reconnect that re-runs the
    # command joins the run in progress instead of starting a second one.
    # The trailing read keeps the pane alive after exit, so the result is still
    # there to read when you reattach.
    exec tmux new-session -A -s "$TMUX_SESSION" \
      "bash ${argv[*]}; ec=\$?; echo; echo \"[homelab-shutdown exited \$ec] press Enter to close\"; read -r"
  else
    echo "WARNING: tmux is not installed — running in this session instead."
    echo "     If this connection drops mid-run, the shutdown stops partway,"
    echo "     which is the failure the ordering in this script exists to avoid."
    echo "     Fix with:  apt install -y tmux     (or pass --no-tmux to silence)"
    echo
  fi
fi

# The shutdown order. Earlier entries stop first.
#   ip | guest name | type | what it runs
#
#   .105 worker1   cloudflared (the tunnel) lives here, so this closes the
#                  front door first and no new request can arrive mid-shutdown.
#                  MinIO goes with it.
#   .106 worker2   Postgres + PostgREST. Deliberately after the ingress and
#                  after MinIO, so the database is the quietest thing on the
#                  network when it checkpoints. PostgREST holds a 10-connection
#                  pool and dies alongside it, which is what lets Postgres
#                  finish instead of waiting on live clients.
#   .104 control   Nothing stateful; it just needs to outlive the kubelets so
#                  their shutdown is recorded rather than looking like a crash.
#   .103 dev       The kubectl/deploy box.
#   .102 tailscale The VPN entry point, and the way in from outside. Last, so
#                  remote access outlives everything it might be needed to
#                  watch. Stopping it earlier would cut the operator off
#                  mid-shutdown — the one ordering mistake that leaves you
#                  unable to fix the others.
declare -a ORDER=(
  "192.168.50.105|k3s-worker1|vm|MinIO + cloudflared tunnel"
  "192.168.50.106|k3s-worker2|vm|PostgreSQL + PostgREST"
  "192.168.50.104|k3s-control|vm|k3s control plane"
  "192.168.50.103|dev|vm|dev / deploy VM"
  "192.168.50.102|tailscale|lxc|Tailscale VPN entry — LAST, it is your way in"
)

# ------------------------------------------------------- type-aware helpers
g_status() {  # <type> <id>
  case "$1" in
    vm)  qm  status "$2" 2>/dev/null | awk '{print $2}' ;;
    lxc) pct status "$2" 2>/dev/null | awk '{print $2}' ;;
  esac
}
g_shutdown() { case "$1" in vm) qm  shutdown "$2" --timeout "$3" ;; lxc) pct shutdown "$2" --timeout "$3" ;; esac; }
g_stop()     { case "$1" in vm) qm  stop "$2"     ;; lxc) pct stop "$2"     ;; esac; }
g_list_ids() { case "$1" in vm) qm list | awk 'NR>1 {print $1}' ;; lxc) pct list | awk 'NR>1 {print $1}' ;; esac; }
g_name() {
  case "$1" in
    vm)  qm  config "$2" 2>/dev/null | awk -F': ' '/^name:/{print $2}' ;;
    lxc) pct config "$2" 2>/dev/null | awk -F': ' '/^hostname:/{print $2}' ;;
  esac
}

# Resolve an id from the guest's LAN address, falling back to its name. IP
# first: it reports what the machine actually is, while the name is only a
# label someone typed and can disagree with the guest.
vm_ip_matches() {
  qm guest cmd "$1" network-get-interfaces 2>/dev/null | grep -qF "\"$2\""
}
lxc_ip_matches() {
  pct config "$1" 2>/dev/null | grep -qF "$2" && return 0
  pct exec "$1" -- ip -4 -o addr show 2>/dev/null | grep -qF "$2"
}

resolve_id() {  # <type> <ip> <name>  -> id on stdout
  local type="$1" want_ip="$2" want_name="$3" id
  for id in $(g_list_ids "$type"); do
    case "$type" in
      vm)  vm_ip_matches  "$id" "$want_ip" && { echo "$id"; return 0; } ;;
      lxc) lxc_ip_matches "$id" "$want_ip" && { echo "$id"; return 0; } ;;
    esac
  done
  for id in $(g_list_ids "$type"); do
    [[ "$(g_name "$type" "$id")" == "$want_name" ]] && { echo "$id"; return 0; }
  done
  return 1
}

# --------------------------------------------------------------- inventory
echo "==> Reading guest inventory"
declare -A RES_ID=() RES_TYPE=() RES_LABEL=() RES_ROLE=()
declare -a RES_KEYS=()
for entry in "${ORDER[@]}"; do
  IFS='|' read -r ip name type role <<<"$entry"
  if id=$(resolve_id "$type" "$ip" "$name"); then
    RES_KEYS+=("$ip")
    RES_ID["$ip"]="$id"; RES_TYPE["$ip"]="$type"
    RES_LABEL["$ip"]="$name ($ip)"; RES_ROLE["$ip"]="$role"
  else
    echo "WARNING: could not resolve a ${type} for $name ($ip) — it will be skipped."
    note "If it is running under a different name, stop it by hand."
  fi
done
[[ ${#RES_KEYS[@]} -gt 0 ]] || die "resolved no guests at all — wrong host?"

# Anything running that we did not account for. Unknown guests go FIRST: they
# may be consuming the cluster or the NFS export and nothing here knows what
# they need. The Tailscale container is explicitly NOT in this bucket.
declare -a UNKNOWN=()
for type in vm lxc; do
  for id in $(g_list_ids "$type"); do
    claimed=0
    for k in "${RES_KEYS[@]}"; do
      [[ "${RES_TYPE[$k]}" == "$type" && "${RES_ID[$k]}" == "$id" ]] && claimed=1
    done
    [[ $claimed -eq 0 && "$(g_status "$type" "$id")" == "running" ]] && UNKNOWN+=("$type:$id")
  done
done

# --------------------------------------------- am I about to cut myself off?
TAILSCALE_KEY="192.168.50.102"
SELF_VIA_TAILSCALE=0
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  client_ip="${SSH_CONNECTION%% *}"
  # Tailscale hands out 100.64.0.0/10 (CGNAT). Also catch the container itself.
  if [[ "$client_ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\. ]] || [[ "$client_ip" == "$TAILSCALE_KEY" ]]; then
    SELF_VIA_TAILSCALE=1
  fi
fi

# ------------------------------------------------------------------- plan
echo
echo "==> Shutdown plan"
step=1
for tid in "${UNKNOWN[@]}"; do
  type="${tid%%:*}"; id="${tid##*:}"
  printf '  %d. %-4s %-5s %-28s %s\n' "$step" "$type" "$id" "$(g_name "$type" "$id")" "UNKNOWN guest — stopped first"
  step=$((step+1))
done
for k in "${RES_KEYS[@]}"; do
  st="$(g_status "${RES_TYPE[$k]}" "${RES_ID[$k]}")"
  printf '  %d. %-4s %-5s %-28s %s\n' "$step" "${RES_TYPE[$k]}" "${RES_ID[$k]}" "${RES_LABEL[$k]}" "${RES_ROLE[$k]}${st:+  [$st]}"
  step=$((step+1))
done
if [[ $POWEROFF_HOST -eq 1 ]]; then
  printf '  %d. %-39s %s\n' "$step" "THIS HOST ($(hostname))" "poweroff, after all guests are down"
else
  echo
  note "Host stays UP (no --poweroff-host). /archive-pool and its NFS exports"
  note "are left alone; power it off from the console when you are ready."
fi

echo
echo "     Per-guest wait: ${TIMEOUT}s. On timeout this script $( [[ $FORCE_AFTER -eq 1 ]] && echo 'HARD-STOPS the guest (--force-after)' || echo 'stops and leaves the guest alone' )."

if [[ $SELF_VIA_TAILSCALE -eq 1 ]]; then
  echo
  echo "!!! This session arrives over Tailscale (client ${client_ip})."
  echo "!!! Stopping guest ${RES_ID[$TAILSCALE_KEY]:-?} cuts this connection and kills this script."
  if [[ -n "${TMUX:-}" ]]; then
    sess="$(tmux display-message -p '#S' 2>/dev/null || echo "$TMUX_SESSION")"
    note "Running inside tmux ('$sess'), so the drop costs you the view, not the run."
    note "The shutdown continues on the host. Reattach once you can reach it:"
    note "    tmux attach -t $sess"
  elif [[ $ALLOW_SELF_DISCONNECT -ne 1 ]]; then
    echo
    die "refusing to cut your own link. Run from the Proxmox console, or let the
       script wrap itself in tmux (the default — you appear to have passed
       --no-tmux), or pass --allow-self-disconnect if you accept losing the
       session and the run along with it."
  else
    note "--allow-self-disconnect given: continuing. Expect the session to drop."
  fi
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "==> --dry-run: nothing was changed."
  exit 0
fi

if [[ $ASSUME_YES -ne 1 ]]; then
  echo
  read -rp "Type SHUTDOWN to proceed: " ans
  [[ "$ans" == SHUTDOWN ]] || die "aborted"
fi

# --------------------------------------------------------------- shutdown
stop_guest() {  # <type> <id> <label>
  local type="$1" id="$2" label="$3" st waited
  st="$(g_status "$type" "$id")"
  if [[ "$st" != "running" ]]; then
    echo "--> $label is already '$st' — skipping."
    return 0
  fi

  echo "--> Shutting down $label ($type $id)"
  # Ask, then poll ourselves. `--timeout` would also wait, but it exits
  # non-zero on expiry and we want to decide what that means, not die.
  g_shutdown "$type" "$id" "$TIMEOUT" >/dev/null 2>&1 || true

  waited=0
  while [[ $waited -lt $TIMEOUT ]]; do
    st="$(g_status "$type" "$id")"
    [[ "$st" == "stopped" ]] && { echo "    stopped cleanly after ${waited}s"; return 0; }
    sleep 3; waited=$((waited+3))
    (( waited % 30 == 0 )) && note "still '$st' after ${waited}s..."
  done

  echo
  echo "!!! $label did not stop within ${TIMEOUT}s (status: $(g_status "$type" "$id"))."
  if [[ $FORCE_AFTER -eq 1 ]]; then
    echo "!!! --force-after given: issuing a HARD stop. Expect an unclean guest."
    g_stop "$type" "$id" || die "hard stop of $label failed"
    sleep 5
    [[ "$(g_status "$type" "$id")" == "stopped" ]] || die "$label still not stopped"
    echo "    hard-stopped"
    return 0
  fi
  echo "!!! Stopping here rather than forcing it. A hard stop on the database VM"
  echo "!!! is the unclean shutdown this ordering exists to prevent."
  note "Look at the guest console, then re-run, or re-run with --force-after."
  exit 1
}

if [[ ${#UNKNOWN[@]} -gt 0 ]]; then
  echo
  echo "==> Phase 0: unidentified guests"
  for tid in "${UNKNOWN[@]}"; do
    type="${tid%%:*}"; id="${tid##*:}"
    stop_guest "$type" "$id" "$type $id ($(g_name "$type" "$id"))"
  done
fi

echo
echo "==> Phase 1: known guests, in dependency order"
for k in "${RES_KEYS[@]}"; do
  [[ "$k" == "$TAILSCALE_KEY" ]] && continue   # handled last, on its own
  stop_guest "${RES_TYPE[$k]}" "${RES_ID[$k]}" "${RES_LABEL[$k]}"
done

if [[ -n "${RES_ID[$TAILSCALE_KEY]:-}" ]]; then
  echo
  echo "==> Phase 2: Tailscale entry point (last — this is remote access)"
  stop_guest "${RES_TYPE[$TAILSCALE_KEY]}" "${RES_ID[$TAILSCALE_KEY]}" "${RES_LABEL[$TAILSCALE_KEY]}"
fi

# ------------------------------------------------------------ verification
echo
echo "==> Verifying every guest is down"
still="$( { qm list  | awk 'NR>1 && $3=="running" {print "  vm  "$1" ("$2")"}';
            pct list | awk 'NR>1 && $2=="running" {print "  lxc "$1" ("$3")"}'; } )"
if [[ -n "$still" ]]; then
  echo "!!! Still running:"; echo "$still"
  die "not all guests are down — refusing to go further"
fi
echo "     all VMs and containers stopped"

# With no guests left there should be no NFS clients on the export. A lingering
# connection means something outside this host still holds the mount, and
# powering off would strand it.
if command -v ss >/dev/null; then
  clients=$(ss -Htn state established '( sport = :2049 )' 2>/dev/null | awk '{print $4" <- "$5}' || true)
  if [[ -n "$clients" ]]; then
    echo "WARNING: NFS (2049) connections still established:"
    echo "$clients" | sed 's/^/     /'
    note "Something off-host still has /archive-pool mounted."
    [[ $POWEROFF_HOST -eq 1 ]] && die "refusing to power off with live NFS clients"
  else
    echo "     no NFS clients remain on 2049"
  fi
fi

# --------------------------------------------------------------- the host
if [[ $POWEROFF_HOST -eq 1 ]]; then
  echo
  echo "==> Powering off $(hostname)"
  note "The pool is left imported; a normal poweroff unmounts and syncs it."
  note "Bring the host back BEFORE the guests — it serves their NFS."
  if [[ $ASSUME_YES -ne 1 ]]; then
    read -rp "Type POWEROFF to confirm: " ans2
    [[ "$ans2" == POWEROFF ]] || die "aborted before host poweroff — guests are already down"
  fi
  sync
  systemctl poweroff
else
  echo
  echo "==> Done. All guests are down; $(hostname) is still up."
  note "Storage untouched: /archive-pool imported, exports still configured."
  note "Power the host off from the console, or re-run with --poweroff-host."
fi
