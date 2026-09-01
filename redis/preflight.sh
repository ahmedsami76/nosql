#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# preflight.sh — validates the host can run the Redis-on-K3s lab.
# Checks: OS, CPU/RAM/disk, kubectl + a reachable cluster, a default
#         StorageClass, NodePort availability, kernel params Redis cares
#         about, and outbound registry access.
# Safe to run BEFORE K3s is installed: missing cluster = WARN, not FAIL.
# Exit code 0 = ready. Non-zero = at least one hard failure.
# ---------------------------------------------------------------------------
set -uo pipefail

PASS=0; FAIL=0; WARN=0
ok()   { echo "  [ OK ]   $1"; PASS=$((PASS+1)); }
warn() { echo "  [ WARN ] $1"; WARN=$((WARN+1)); }
bad()  { echo "  [ FAIL ] $1"; FAIL=$((FAIL+1)); }
hdr()  { echo; echo "=== $1 ==="; }

hdr "1. Operating system"
# K3s is a Linux-native distribution: it needs a Linux kernel with cgroups.
# On macOS/Windows the supported path is k3d (K3s inside Docker) or a Linux VM.
OS="$(uname -s)"
case "$OS" in
  Linux)  ok "Linux detected ($(uname -r)) — native K3s is supported." ;;
  Darwin) warn "macOS detected — K3s needs Linux. Use k3d or a Multipass VM (see III.2)." ;;
  *)      warn "Unrecognized OS '$OS' — use k3d or a Linux VM." ;;
esac

hdr "2. Hardware capacity"
# Redis is an in-memory store: RAM is the binding constraint, not disk.
# The dataset is tiny, but K3s + Redis + RedisInsight + Jupyter together want ~4 GB.
CPUS=$( (command -v nproc >/dev/null && nproc) || sysctl -n hw.ncpu 2>/dev/null || echo 0)
[ "$CPUS" -ge 2 ] && ok "CPU cores: $CPUS (>= 2 required)" || bad "CPU cores: $CPUS (need >= 2)"

if [ "$OS" = "Linux" ]; then
  MEM_MB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 ))
else
  MEM_MB=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
fi
[ "$MEM_MB" -ge 4096 ] && ok "RAM: ${MEM_MB} MB (>= 4096 recommended)" \
                       || warn "RAM: ${MEM_MB} MB — tight; close other workloads."

# K3s itself, plus three container images, plus PVCs.
DISK_MB=$(df -Pm . | awk 'NR==2 {print $4}')
[ "$DISK_MB" -ge 10240 ] && ok "Free disk: ${DISK_MB} MB (>= 10 GB)" \
                         || bad "Free disk: ${DISK_MB} MB (need >= 10 GB for images + volumes)"

hdr "3. Kubernetes"
if command -v kubectl >/dev/null 2>&1; then
  ok "kubectl found: $(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/ {print $2; exit}')"
  if kubectl cluster-info >/dev/null 2>&1; then
    ok "A cluster is reachable."
    # A node stuck in NotReady is the classic 'my pods are Pending' cause.
    NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | grep -cv ' Ready ')
    [ "$NOT_READY" -eq 0 ] && ok "All nodes Ready." \
                           || bad "$NOT_READY node(s) NOT Ready — 'kubectl get nodes' for detail."
    # Our PVCs have no storageClassName fallback, so a default SC must exist.
    # K3s ships 'local-path' as the default; a stripped-down install may not.
    if kubectl get storageclass 2>/dev/null | grep -q '(default)'; then
      ok "Default StorageClass present: $(kubectl get sc -o name 2>/dev/null | head -1)"
    else
      warn "No default StorageClass — PVCs will stay Pending. K3s normally provides 'local-path'."
    fi
  else
    warn "kubectl present but no reachable cluster — install K3s in III.2."
  fi
else
  warn "kubectl not found — it ships with K3s; install it in III.2."
fi

hdr "4. NodePort availability on the host"
# NodePorts bind on the node. A conflict shows up as a Service that applies
# cleanly but never answers — the most confusing failure mode in this lab.
check_port () {
  local p=$1 svc=$2
  if command -v ss >/dev/null 2>&1;      then LISTEN=$(ss -ltn  2>/dev/null | grep -c ":$p ")
  elif command -v lsof >/dev/null 2>&1;  then LISTEN=$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | grep -c .)
  else LISTEN=0; fi
  [ "$LISTEN" -eq 0 ] && ok "Port $p free (for $svc)" \
                      || bad "Port $p ALREADY IN USE (needed by $svc). Free it or change the nodePort."
}
check_port 30079 "Redis NodePort"
check_port 30054 "RedisInsight NodePort"
check_port 30088 "JupyterLab NodePort"

hdr "5. Kernel parameters Redis cares about"
# These are NODE-level settings. In Kubernetes the pod shares the node kernel,
# so tuning them on the host is what actually takes effect.
if [ "$OS" = "Linux" ]; then
  # vm.overcommit_memory=1 lets the RDB fork() succeed even when RSS is large.
  # Without it, background saves fail with 'Cannot allocate memory'.
  OC=$(sysctl -n vm.overcommit_memory 2>/dev/null || echo "?")
  [ "$OC" = "1" ] && ok "vm.overcommit_memory=1" \
                  || warn "vm.overcommit_memory=$OC — set to 1 for reliable BGSAVE:
             sudo sysctl -w vm.overcommit_memory=1"

  # Transparent Huge Pages cause latency spikes during copy-on-write after fork().
  THP_PATH=/sys/kernel/mm/transparent_hugepage/enabled
  if [ -r "$THP_PATH" ]; then
    grep -q '\[never\]' "$THP_PATH" && ok "Transparent Huge Pages disabled" \
      || warn "THP enabled — causes latency spikes:
             echo never | sudo tee $THP_PATH"
  fi

  # net.core.somaxconn caps the TCP accept backlog; our redis.conf sets tcp-backlog 511.
  SMC=$(sysctl -n net.core.somaxconn 2>/dev/null || echo 0)
  [ "$SMC" -ge 511 ] && ok "net.core.somaxconn=$SMC" \
                     || warn "net.core.somaxconn=$SMC (< 511): sudo sysctl -w net.core.somaxconn=1024"
else
  warn "Skipped — not Linux. Tune inside the VM that actually runs K3s."
fi

hdr "6. Outbound connectivity to image registries"
# We pull redis + redisinsight from Docker Hub and Jupyter from Quay.
# A corporate proxy or air-gapped network is a common blocker.
for host in registry-1.docker.io quay.io; do
  if curl -fsS --max-time 8 -o /dev/null "https://$host/v2/" 2>/dev/null \
     || [ "$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' "https://$host/v2/")" = "401" ]; then
    ok "$host reachable."
  else
    warn "Could not reach $host — check proxy/VPN, or pre-import images with 'k3s ctr images import'."
  fi
done

echo
echo "==================== SUMMARY ===================="
echo "  Passed: $PASS   Warnings: $WARN   Failures: $FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "  RESULT: NOT READY — resolve the [FAIL] items above."
  exit 1
fi
echo "  RESULT: READY — proceed to III.2."
exit 0
