#!/usr/bin/env bash
#
# verify-microvm.sh -- prove the agent-runner really is running in a
# hardware-isolated microVM, and that the NetworkPolicy still enforces inside
# it.
#
# Usage:
#   scripts/verify-microvm.sh              # verify (does not change anything)
#   scripts/verify-microvm.sh --migrate    # apply runner-microvm.yaml, then verify
#   scripts/verify-microvm.sh --rollback   # back to runner.yaml (runc), then report
#
# Environment overrides:
#   NAMESPACE        default agent-sandbox
#   ROLLOUT_TIMEOUT  seconds to wait for the microVM pod (default 300)
#   PROBE_TIMEOUT    per-network-probe timeout, seconds (default 4)
#
# ---------------------------------------------------------------------------
# WHAT COUNTS AS PROOF
#
# "The pod is Running with runtimeClassName: kata-clh" is not proof. The
# RuntimeClass is a lookup key; if the handler behind it resolves to runc, the
# pod starts happily and shares the host kernel. The claim being made is
# hardware isolation, and its observable consequence is a DIFFERENT KERNEL. So
# the decisive assertion is:
#
#     guest `uname -r`  !=  host `uname -r`
#
# with the host figure taken two independent ways (the node's own
# .status.nodeInfo.kernelVersion, and `uname -r` run on the host) and
# cross-checked, so a wrong host value cannot manufacture a pass.
#
# A guest kernel equal to the host kernel is a HARD FAILURE, not a warning: a
# RuntimeClass whose pods silently fall back to runc is worse than no
# RuntimeClass, because the workload believes it is isolated.
#
# ---------------------------------------------------------------------------
# NOTES ON THE REQUESTED COMMANDS
#
# The task specified `kubectl exec -it <runner-pod> -- uname -r`. `-t` is
# dropped throughout: it allocates a TTY, which mangles output or fails when
# stdout is not a terminal, and the captured string is then compared against
# the host kernel. A stray \r is enough to turn a correct match into a
# mismatch. `-i` alone is used where stdin is piped.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNC_MANIFEST="${REPO_ROOT}/k8s/apps/runner.yaml"
MICROVM_MANIFEST="${REPO_ROOT}/k8s/apps/runner-microvm.yaml"
NETPOL_FILE="${REPO_ROOT}/k8s/security/runner-network-policy.yaml"

NAMESPACE="${NAMESPACE:-agent-sandbox}"
# Matches terraform var.cluster_name. Override with CLUSTER_NAME if you changed it.
EXPECTED_CLUSTER="${CLUSTER_NAME:-secure-agent-sandbox}"
RUNTIME_CLASS="kata-clh"
POLICY_NAME="agent-runner-isolation"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-300}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-4}"

MODE="verify"
FAILURES=0

HOST_KERNEL_NODEINFO=""
HOST_KERNEL_UNAME=""
GUEST_KERNEL=""
VMM_PROCESS=""
NETPOL_VERDICT="not checked"

###############################################################################
# Output helpers (same conventions as the other scripts in scripts/)
###############################################################################

if [[ -t 1 ]]; then
  C_DIM=$'\033[2m'; C_RED=$'\033[31m'; C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLD=""; C_OFF=""
fi

step() { printf '\n%s==> %s%s\n' "$C_BLD" "$*" "$C_OFF"; }
info() { printf '  %s[info]%s %s\n' "$C_DIM" "$C_OFF" "$*"; }
ok()   { printf '  %s[ ok ]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '  %s[warn]%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
fail() { printf '  %s[fail]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
bad()  { printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; FAILURES=$((FAILURES + 1)); }

run() { printf '%s    $ %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2; "$@"; }
kc()  { kubectl -n "$NAMESPACE" "$@"; }

# First line of a stream. NOT `head -1`, which exits early and kills the
# upstream producer with SIGPIPE; under `set -o pipefail` that fails the whole
# pipeline and `set -e` then exits with no message.
first_line() { sed -n '1p'; }

confirm() {
  local prompt="$1" reply
  [[ -t 0 ]] || fail "${prompt} -- refusing to assume yes on a non-interactive stdin."
  read -r -p "  ${prompt} [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

###############################################################################
# Privileged pod on the node's host namespace.
#
# hostPID is required for the hypervisor-visibility check: the Cloud
# Hypervisor process belongs to the host, so without the host PID namespace
# there is nothing to see. Lands in `default`, which carries no Pod Security
# Standard labels; the same pod is correctly rejected in agent-sandbox, which
# enforces `restricted`.
#
# Built as YAML rather than `kubectl run --overrides` because the probe
# scripts are multi-line, and a literal newline inside a JSON string is
# invalid JSON.
###############################################################################
PROBE_SEQ=0
host_probe() {
  local node="$1" script="$2" pod phase logs
  PROBE_SEQ=$((PROBE_SEQ + 1))
  pod="uvmprobe-$$-${PROBE_SEQ}"

  printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  labels:\n    app: microvm-host-probe\nspec:\n  nodeName: %s\n  restartPolicy: Never\n  hostPID: true\n  automountServiceAccountToken: false\n  tolerations:\n    - operator: Exists\n  containers:\n    - name: probe\n      image: python:3.11-slim\n      command: ["/bin/sh", "-c"]\n      args:\n        - |\n%s\n      securityContext:\n        privileged: true\n      volumeMounts:\n        - name: host\n          mountPath: /host\n  volumes:\n    - name: host\n      hostPath:\n        path: /\n        type: Directory\n' \
    "$pod" "$node" "$(printf '%s\n' "$script" | sed 's/^/          /')" \
    | kubectl -n default apply -f - >/dev/null 2>&1 || return 1

  local deadline=$((SECONDS + 150))
  while [[ $SECONDS -lt $deadline ]]; do
    phase="$(kubectl -n default get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 3
  done
  logs="$(kubectl -n default logs "$pod" 2>/dev/null || true)"
  kubectl -n default delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1
  printf '%s\n' "$logs"
}

# Network probe from inside the runner pod. Prints ONE outcome token so a
# dropped packet (TIMEOUT) can never be confused with a reachable-but-refused
# service (HTTP:401) -- see ISSUES-ENCOUNTERED.md issue 12.
pod_probe() {
  local pod="$1" url="$2" method="${3:-GET}"
  kc exec -i "$pod" -- python3 - "$url" "$PROBE_TIMEOUT" "$method" <<'PY' 2>/dev/null || echo "EXEC_FAILED"
import socket, sys, urllib.error, urllib.request
url, timeout, method = sys.argv[1], float(sys.argv[2]), sys.argv[3]
socket.setdefaulttimeout(timeout)
data = b"" if method == "PUT" else None
req = urllib.request.Request(url, data=data, method=method,
                             headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
try:
    r = urllib.request.urlopen(req); r.read(64); print("HTTP:%d" % r.status)
except urllib.error.HTTPError as e:
    print("HTTP:%d" % e.code)
except socket.timeout:
    print("TIMEOUT")
except urllib.error.URLError as e:
    reason = e.reason
    if isinstance(reason, socket.timeout):     print("TIMEOUT")
    elif isinstance(reason, socket.gaierror):  print("DNSFAIL")
    elif isinstance(reason, ConnectionRefusedError): print("REFUSED")
    else: print("ERROR:%s" % type(reason).__name__)
except Exception as e:
    print("ERROR:%s" % type(e).__name__)
PY
}

cleanup() {
  local rc=$?
  set +e
  kubectl -n default delete pod -l app=microvm-host-probe \
    --ignore-not-found --wait=false >/dev/null 2>&1
  for i in $(seq 1 "${PROBE_SEQ:-0}"); do
    kubectl -n default delete pod "uvmprobe-$$-${i}" --ignore-not-found \
      --wait=false >/dev/null 2>&1
  done
  exit $rc
}
trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --migrate)  MODE="migrate" ;;
    --rollback) MODE="rollback" ;;
    -h|--help)  sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)          fail "Unknown argument '$1'. Try --help." ;;
  esac
  shift
done

###############################################################################
# 1. Preflight
###############################################################################

step "Preflight"

command -v kubectl >/dev/null 2>&1 || fail "'kubectl' not found on PATH."
for f in "$RUNC_MANIFEST" "$MICROVM_MANIFEST"; do
  [[ -f "$f" ]] || fail "Missing ${f}"
done

CTX="$(kubectl config current-context 2>/dev/null || true)"
case "$CTX" in
  *"$EXPECTED_CLUSTER"*) ok "Context targets ${EXPECTED_CLUSTER}." ;;
  "") fail "No current kubectl context. See terraform/RUNBOOK.md." ;;
  *)  fail "Current context is '${CTX}', which does not mention '${EXPECTED_CLUSTER}'. Refusing to run." ;;
esac

# The context name being right says nothing about the API answering. This
# cluster is private-only and reached through an SSM port-forward; when that
# tunnel dies every later kubectl call emits client-go "memcache" noise and
# the script fails mid-run with no sign of the cause.
API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
if ! kubectl version -o json >/dev/null 2>&1; then
  case "$API_SERVER" in
    *localhost*|*127.0.0.1*)
      fail "Cannot reach the Kubernetes API at ${API_SERVER}. That is the SSM port-forward tunnel and nothing is listening -- the session has ended. This cluster has NO public endpoint, so 'aws eks update-kubeconfig' will not fix it. Restart the tunnel: terraform/RUNBOOK.md section 4." ;;
    *)
      fail "Cannot reach the Kubernetes API at ${API_SERVER:-unknown}. See terraform/RUNBOOK.md section 4." ;;
  esac
fi
ok "API server reachable at ${API_SERVER}."

# Kata must be installed. Without this the migration is not a failing test --
# there is nothing to test, and the distinction matters because the remedy is
# completely different.
if ! kubectl get runtimeclass "$RUNTIME_CLASS" >/dev/null 2>&1; then
  fail "RuntimeClass '${RUNTIME_CLASS}' does not exist, so nothing can run in a microVM yet. This is a missing prerequisite, not a test failure. Install Kata first:
         scripts/install-kata.sh
       (terraform/RUNBOOK.md section 9)"
fi
RC_HANDLER="$(kubectl get runtimeclass "$RUNTIME_CLASS" -o jsonpath='{.handler}')"
ok "RuntimeClass ${RUNTIME_CLASS} exists (handler '${RC_HANDLER}')."

KATA_NODES="$(kubectl get nodes -l katacontainers.io/kata-runtime=true \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)"
if [[ -z "$KATA_NODES" ]]; then
  fail "No node carries katacontainers.io/kata-runtime=true, which is the RuntimeClass's scheduling.nodeSelector. A microVM pod would stay Pending forever. kata-deploy sets that label as its final install step -- check:
         kubectl -n kube-system get pods -l name=kata-deploy
         kubectl -n kube-system logs -l name=kata-deploy -c kube-kata --tail=60"
fi
ok "Kata-enabled node(s): $(printf '%s ' $KATA_NODES)"

###############################################################################
# 2. Drift check between the two manifests
#
# runner-microvm.yaml is a copy of runner.yaml plus runtimeClassName. A copy
# drifts. The NetworkPolicy selects on `role: code-executor`, the HPA targets
# Deployment/agent-runner, and the HPA's 50% target is a percentage of the
# 100m request -- all three break quietly if the copy falls behind.
###############################################################################

step "Checking runner.yaml and runner-microvm.yaml have not diverged"

compare_manifests() {
  python3 -I - "$RUNC_MANIFEST" "$MICROVM_MANIFEST" <<'PY'
import re, sys

def load(path):
    """Extract the fields other objects depend on, without a YAML library.

    pyyaml is not guaranteed present on this machine, and the comparison only
    needs a handful of scalar fields.
    """
    txt = open(path).read()
    # Strip comment-only lines so prose differences never register as drift.
    body = "\n".join(l for l in txt.split("\n") if not l.lstrip().startswith("#"))
    def grab(pat, default=None):
        m = re.search(pat, body, re.M)
        return m.group(1).strip() if m else default
    return {
        "deployment name": grab(r"^  name: (agent-runner)$"),
        "labels app":      grab(r"^    app: (agent-runner)$"),
        "labels role":     grab(r"^    role: (code-executor)$"),
        "replicas":        grab(r"^  replicas: (\d+)$"),
        "nodeSelector":    grab(r"^        workload: (\S+)$"),
        "serviceAccount":  grab(r"^      serviceAccountName: (\S+)$"),
        "request cpu":     grab(r"^              cpu: (\S+)$"),
        "request memory":  grab(r"^              memory: (\S+)$"),
        "limit cpu":       grab(r"^              cpu: (\S+)\s*$", None) or "",
        "runAsUser":       grab(r"^        runAsUser: (\d+)$"),
        "readOnlyRootFS":  grab(r"^            readOnlyRootFilesystem: (\S+)$"),
        "sizeLimit":       grab(r"^            sizeLimit: (\S+)$"),
        "image":           grab(r"^          image: (\S+)$"),
    }

a, b = load(sys.argv[1]), load(sys.argv[2])
# Both resource blocks list cpu twice (requests then limits); compare the
# full ordered list instead of a single regex hit.
def res(path):
    body = "\n".join(l for l in open(path).read().split("\n")
                     if not l.lstrip().startswith("#"))
    return re.findall(r"^\s+(cpu|memory): (\S+)$", body, re.M)
a["resources"], b["resources"] = res(sys.argv[1]), res(sys.argv[2])

drift = [k for k in a if a[k] != b[k]]
if drift:
    print("DRIFT")
    for k in drift:
        print("  %-16s runner.yaml=%r  runner-microvm.yaml=%r" % (k, a[k], b[k]))
else:
    print("IDENTICAL")
PY
}

DRIFT_OUT="$(compare_manifests 2>&1 || true)"
if [[ "$DRIFT_OUT" == IDENTICAL* ]]; then
  ok "Every dependent field matches (labels, replicas, nodeSelector, resources, securityContext, image)."
else
  warn "The two manifests have diverged on fields other objects depend on:"
  printf '%s\n' "$DRIFT_OUT" | sed 's/^/         /' >&2
  bad "MANIFEST DRIFT between runner.yaml and runner-microvm.yaml. Fix both files before trusting anything below -- the NetworkPolicy selector, the HPA target and the HPA's CPU percentage all read these fields."
fi

# And the one field that must differ.
if grep -qE '^\s+runtimeClassName:\s*kata-clh\s*$' "$MICROVM_MANIFEST"; then
  ok "runner-microvm.yaml sets runtimeClassName: ${RUNTIME_CLASS}."
else
  bad "runner-microvm.yaml does NOT set runtimeClassName: ${RUNTIME_CLASS}. It is identical to the runc manifest and would change nothing."
fi
if grep -qE '^\s+runtimeClassName:' "$RUNC_MANIFEST"; then
  bad "runner.yaml now sets a runtimeClassName. It is meant to stay the runc baseline this script compares against."
else
  ok "runner.yaml remains the runc baseline (no runtimeClassName)."
fi

###############################################################################
# 3. Migrate / rollback
###############################################################################

if [[ "$MODE" == "migrate" ]]; then
  step "Migrating agent-runner to ${RUNTIME_CLASS}"
  CUR_RC="$(kc get deploy agent-runner -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || true)"
  info "current runtimeClassName: ${CUR_RC:-<none, runc>}"
  warn "This replaces every agent-runner pod. The HPA currently owns the replica count; rolling pods will briefly reduce capacity."
  confirm "Apply ${MICROVM_MANIFEST##*/}?" || fail "Aborted by operator. Nothing was applied."

  run kubectl apply -f "$MICROVM_MANIFEST"
  if run kc rollout status deploy/agent-runner --timeout="${ROLLOUT_TIMEOUT}s"; then
    ok "Rollout complete."
  else
    PENDING="$(kc get pods -l app=agent-runner \
      -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase}{" "}{end}' 2>/dev/null || true)"
    EV="$(kc get events --field-selector involvedObject.kind=Pod \
      -o custom-columns=REASON:.reason,MSG:.message --no-headers 2>/dev/null | tail -6 || true)"
    fail "Rollout did not complete in ${ROLLOUT_TIMEOUT}s. pods: ${PENDING}
       Most likely, in order:
         1. Pods Pending -- the node lacks katacontainers.io/kata-runtime=true.
         2. Pods ContainerCreating then failing -- /dev/kvm missing or the
            kata-clh handler is not in the node's containerd config.
         3. Admission rejected -- RuntimeClass ${RUNTIME_CLASS} not found.
       recent events:
${EV}"
  fi
elif [[ "$MODE" == "rollback" ]]; then
  step "Rolling back agent-runner to runc"
  warn "This returns the runner to sharing the host kernel. Do not run untrusted code in it afterwards."
  confirm "Apply ${RUNC_MANIFEST##*/} (runc)?" || fail "Aborted by operator."
  run kubectl apply -f "$RUNC_MANIFEST"
  # Whether that apply removed runtimeClassName depends on HOW it was added.
  # Added by `kubectl apply -f runner-microvm.yaml` -> it is in last-applied,
  # so the apply above removes it. Added by `kubectl patch` -> it is not in
  # last-applied, and apply leaves it in place. Strip it explicitly so the
  # rollback is correct in both cases.
  run kc patch deploy agent-runner --type=json \
    -p '[{"op":"remove","path":"/spec/template/spec/runtimeClassName"}]' 2>/dev/null \
    || info "runtimeClassName was already absent."
  run kc rollout status deploy/agent-runner --timeout="${ROLLOUT_TIMEOUT}s" || true
  STILL="$(kc get deploy agent-runner -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || true)"
  if [[ -z "$STILL" ]]; then
    ok "agent-runner is back on the default runtime (runc)."
  else
    fail "agent-runner still has runtimeClassName='${STILL}' after rollback."
  fi
  exit 0
fi

###############################################################################
# 4. Is the live Deployment actually using the RuntimeClass?
###############################################################################

step "Live state"

LIVE_RC="$(kc get deploy agent-runner -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || true)"
if [[ "$LIVE_RC" != "$RUNTIME_CLASS" ]]; then
  fail "The live agent-runner Deployment has runtimeClassName='${LIVE_RC:-<none>}', not '${RUNTIME_CLASS}'. Nothing is running in a microVM, so there is nothing to verify. Migrate first:
         scripts/verify-microvm.sh --migrate
       (or: kubectl apply -f ${MICROVM_MANIFEST})"
fi
ok "Deployment spec requests runtimeClassName=${RUNTIME_CLASS}."

kc wait --for=condition=Ready pod -l app=agent-runner --timeout=180s >/dev/null 2>&1 \
  || fail "No Ready agent-runner pod. $(kc get pods -l app=agent-runner --no-headers 2>&1 | tr '\n' ';')"
RUNNER_POD="$(kc get pod -l app=agent-runner -o jsonpath='{.items[0].metadata.name}')"
POD_RC="$(kc get pod "$RUNNER_POD" -o jsonpath='{.spec.runtimeClassName}' 2>/dev/null || true)"
NODE="$(kc get pod "$RUNNER_POD" -o jsonpath='{.spec.nodeName}')"
ok "pod ${RUNNER_POD} Ready on ${NODE}, runtimeClassName=${POD_RC:-<none>}"
[[ "$POD_RC" == "$RUNTIME_CLASS" ]] \
  || bad "The POD has runtimeClassName='${POD_RC:-<none>}' even though the Deployment spec asks for ${RUNTIME_CLASS}. An old ReplicaSet's pod is still serving."

###############################################################################
# 5. Host kernel -- two independent readings
###############################################################################

step "Host kernel"

HOST_KERNEL_NODEINFO="$(kubectl get node "$NODE" -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null || true)"
info "node .status.nodeInfo.kernelVersion = ${HOST_KERNEL_NODEINFO:-<unknown>}"

HOST_OUT="$(host_probe "$NODE" 'echo "UNAME=$(uname -r)"' || true)"
HOST_KERNEL_UNAME="$(printf '%s\n' "$HOST_OUT" | sed -n 's/^UNAME=//p' | first_line)"
if [[ -n "$HOST_KERNEL_UNAME" ]]; then
  ok "uname -r on the node host = ${HOST_KERNEL_UNAME}"
else
  warn "Could not run uname -r on the host; falling back to nodeInfo only."
  HOST_KERNEL_UNAME="$HOST_KERNEL_NODEINFO"
fi

# Cross-check, so a wrong host reading cannot manufacture a pass below.
if [[ -n "$HOST_KERNEL_NODEINFO" && "$HOST_KERNEL_NODEINFO" != "$HOST_KERNEL_UNAME" ]]; then
  warn "The two host readings disagree: nodeInfo='${HOST_KERNEL_NODEINFO}' vs uname='${HOST_KERNEL_UNAME}'. Using the uname value; investigate before trusting the comparison."
fi
HOST_KERNEL="$HOST_KERNEL_UNAME"
[[ -n "$HOST_KERNEL" ]] || fail "Could not determine the host kernel by either method; the comparison below would be meaningless."

###############################################################################
# 6. Guest kernel -- the decisive assertion
###############################################################################

step "Guest kernel inside the microVM"

GUEST_KERNEL="$(kc exec "$RUNNER_POD" -- uname -r 2>/dev/null | tr -d '\r' | first_line || true)"
if [[ -z "$GUEST_KERNEL" ]]; then
  bad "Could not read 'uname -r' from ${RUNNER_POD}. This is a harness failure -- it is NOT evidence of isolation either way."
elif [[ "$GUEST_KERNEL" == "$HOST_KERNEL" ]]; then
  bad "THE POD REPORTS THE HOST KERNEL (${GUEST_KERNEL}).
         runtimeClassName is set and the pod is Running, but it is sharing the
         node's kernel -- there is no VM boundary. The handler behind
         '${RUNTIME_CLASS}' is resolving to runc, or the shim silently fell
         back. A RuntimeClass whose pods quietly share the host kernel is
         worse than none, because the workload believes it is isolated.
         DO NOT run untrusted code in this pod. Check:
           kubectl get runtimeclass ${RUNTIME_CLASS} -o yaml
           kubectl -n kube-system logs -l name=kata-deploy -c kube-kata --tail=60"
else
  ok "guest kernel = ${GUEST_KERNEL}"
  ok "host kernel  = ${HOST_KERNEL}"
  ok "They DIFFER -- the pod booted its own kernel, so the VM boundary is real."
fi

# Control: a runc pod on the same node must report the host kernel. Without
# it, "differs from the host kernel" is unfalsifiable -- it would also be true
# if the host reading were simply wrong.
step "Control: a runc pod on the same node"
CONTROL_OUT="$(host_probe "$NODE" 'echo "CTRL=$(uname -r)"' || true)"
CONTROL_KERNEL="$(printf '%s\n' "$CONTROL_OUT" | sed -n 's/^CTRL=//p' | first_line)"
if [[ -z "$CONTROL_KERNEL" ]]; then
  warn "Control pod produced no kernel string; the comparison above is unconfirmed."
elif [[ "$CONTROL_KERNEL" == "$HOST_KERNEL" ]]; then
  ok "runc pod on ${NODE} reports ${CONTROL_KERNEL} -- matches the host, as it must. The comparison is meaningful."
else
  warn "The runc control reported '${CONTROL_KERNEL}' but the host reports '${HOST_KERNEL}'. The control did not behave as expected, so treat the guest-kernel result as unconfirmed."
fi

###############################################################################
# 7. Hypervisor process visible on the host
#
# Corroborating, not decisive: a VMM process proves a VM was started, the
# kernel difference proves this pod is in one.
###############################################################################

step "Cloud Hypervisor process on the host"

# Skips its own PID and parent: this probe's `sh -c` cmdline contains the very
# strings it greps for, so without the exclusion it reports itself as a
# hypervisor. Same self-match trap as matching `pkill -f` against a pattern
# the matching process also carries.
VMM_OUT="$(host_probe "$NODE" '
  me=$$; parent=$PPID
  echo "--- VMM processes ---"
  for p in /proc/[0-9]*; do
    pid="${p#/proc/}"
    [ "$pid" = "$me" ] && continue
    [ "$pid" = "$parent" ] && continue
    [ -r "$p/cmdline" ] || continue
    c=$(tr "\0" " " < "$p/cmdline" 2>/dev/null)
    # Match the EXECUTABLE only (argv[0]), never the whole command line: this
    # probe is itself `/bin/sh -c <script>` and the script text contains every
    # pattern below, so matching the full cmdline reports the probe as a
    # hypervisor. Excluding $$ is not enough -- the shell kubectl starts is a
    # different pid.
    exe=${c%% *}
    case "$exe" in
      */cloud-hypervisor)      echo "VMM clh $pid $c" ;;
      */containerd-shim-kata-v2) echo "VMM shim $pid $c" ;;
      */qemu-system-*)         echo "VMM qemu $pid $c" ;;
    esac
  done
  echo "--- shim binaries ---"
  ls /host/opt/kata/bin 2>/dev/null
' || true)"

# Match only the "VMM <kind> <pid> <cmdline>" lines the probe emits for real
# processes. Grepping for the bare string would also match the probe's own
# cmdline, which contains every pattern it searches for -- and that would be a
# false positive, not just untidy output.
if printf '%s\n' "$VMM_OUT" | grep -qE '^VMM clh [0-9]+ '; then
  VMM_PROCESS="cloud-hypervisor"
  ok "cloud-hypervisor is running on ${NODE}:"
  printf '%s\n' "$VMM_OUT" | sed -n 's/^VMM [a-z]* //p' \
    | cut -c1-140 | sed 's/^/           /'
elif printf '%s\n' "$VMM_OUT" | grep -qE '^VMM shim [0-9]+ '; then
  VMM_PROCESS="kata shim only"
  warn "A kata shim is running but no cloud-hypervisor process is visible. The kernel comparison above is the authoritative result; this may mean a different VMM is in use, or the process name differs in this build."
elif printf '%s\n' "$VMM_OUT" | grep -qE '^VMM qemu [0-9]+ '; then
  VMM_PROCESS="qemu (NOT cloud-hypervisor)"
  warn "QEMU is running, not Cloud Hypervisor. The pod is still VM-isolated, but not by the VMM this project configured -- check that kata-setup.yaml's clh shim is the one in use."
else
  VMM_PROCESS="not visible"
  warn "No VMM process visible on the host. If the kernel comparison passed, the VM exists and this check simply could not see it (the probe needs hostPID, which it requests). Treat the kernel result as authoritative."
fi

###############################################################################
# 8. The NetworkPolicy must still enforce inside the microVM
#
# Not assumed. Enforcement is eBPF on the pod's host-side interface, and the
# runtime changed underneath it. "The policy object still exists" is not
# evidence that it still drops packets for a VM-backed pod.
###############################################################################

step "NetworkPolicy enforcement inside the microVM"

if ! kc get networkpolicy "$POLICY_NAME" >/dev/null 2>&1; then
  bad "NetworkPolicy '${POLICY_NAME}' is not applied, so the microVM has unrestricted egress. Apply it:
           kubectl apply -f ${NETPOL_FILE}"
  NETPOL_VERDICT="policy absent"
else
  ok "NetworkPolicy ${POLICY_NAME} exists."

  # Liveness control first: if DNS resolves, the pod's network stack and our
  # probe both work, so a TIMEOUT below is a dropped packet rather than a
  # broken harness or a pod with no network at all.
  DNS="$(kc exec -i "$RUNNER_POD" -- python3 -c \
    'import socket;socket.setdefaulttimeout(5);print("DNS_OK:"+socket.gethostbyname("kubernetes.default.svc.cluster.local"))' \
    2>/dev/null || echo "DNS_BROKEN")"
  case "$DNS" in
    DNS_OK:*) ok "cluster DNS resolves from inside the microVM (${DNS}); the DNS egress rule survived the runtime change." ;;
    *)        bad "DNS DOES NOT RESOLVE inside the microVM (${DNS}). Every TIMEOUT below is therefore meaningless. The egress rule is not matching CoreDNS for a VM-backed pod." ;;
  esac

  NETPOL_PASS=1
  for spec in "IMDS GET|GET|http://169.254.169.254/latest/meta-data/" \
              "IMDS token PUT|PUT|http://169.254.169.254/latest/api/token" \
              "public internet|GET|https://checkip.amazonaws.com"; do
    LABEL="${spec%%|*}"; REST="${spec#*|}"; METHOD="${REST%%|*}"; URL="${REST#*|}"
    RESULT="$(pod_probe "$RUNNER_POD" "$URL" "$METHOD")"
    case "$RESULT" in
      TIMEOUT)
        ok "${LABEL} DROPPED (timed out) -- policy still enforcing under ${RUNTIME_CLASS}." ;;
      DNSFAIL)
        ok "${LABEL} unreachable: name did not resolve. Blocked, though a policy drop normally presents as a timeout." ;;
      HTTP:*)
        NETPOL_PASS=0
        bad "${LABEL} ANSWERED THE MICROVM WITH ${RESULT}.
         A status code means packets reached the destination and were replied
         to. The NetworkPolicy is NOT enforcing for a ${RUNTIME_CLASS} pod,
         even though the policy object exists and worked under runc. This is
         the specific regression this check exists to catch." ;;
      EXEC_FAILED)
        NETPOL_PASS=0
        bad "Could not exec python3 in ${RUNNER_POD} for the ${LABEL} probe. Harness failure -- NOT evidence of a block." ;;
      *)
        warn "${LABEL} returned '${RESULT}'. Nothing was served, so not an exposure, but not the expected TIMEOUT either." ;;
    esac
  done
  if [[ "$NETPOL_PASS" -eq 1 && "$DNS" == DNS_OK:* ]]; then
    NETPOL_VERDICT="ENFORCING (IMDS + internet dropped, DNS allowed)"
  else
    NETPOL_VERDICT="NOT CONFIRMED -- see failures above"
  fi
fi

###############################################################################
# 9. Summary
###############################################################################

step "Summary"

printf '\n'
printf '  %sMicroVM isolation report%s\n' "$C_BLD" "$C_OFF"
printf '  %s\n' "--------------------------------------------------------------"
printf '  %-28s %s\n' "Pod"                 "${RUNNER_POD}"
printf '  %-28s %s\n' "Node"                "${NODE}"
printf '  %-28s %s\n' "RuntimeClass"        "${POD_RC:-<none>}"
printf '  %s\n' "--------------------------------------------------------------"
printf '  %-28s %s\n' "Host kernel"         "${HOST_KERNEL}"
printf '  %-28s %s\n' "Guest kernel"        "${GUEST_KERNEL:-<unreadable>}"
if [[ -n "$GUEST_KERNEL" && "$GUEST_KERNEL" != "$HOST_KERNEL" ]]; then
  printf '  %-28s %sDIFFERENT -- VM boundary confirmed%s\n' "Kernel isolation" "$C_GRN" "$C_OFF"
else
  printf '  %-28s %sSAME -- NO VM BOUNDARY%s\n' "Kernel isolation" "$C_RED" "$C_OFF"
fi
printf '  %s\n' "--------------------------------------------------------------"
printf '  %-28s %s\n' "MicroVM hypervisor"  "${VMM_PROCESS}"
printf '  %-28s %s\n' "NetworkPolicy"       "${NETPOL_VERDICT}"
printf '  %s\n' "--------------------------------------------------------------"
printf '\n'

if [[ "$FAILURES" -eq 0 ]]; then
  ok "All checks passed. agent-runner runs in a Cloud Hypervisor microVM with its own kernel, and egress is still denied."
  info "Roll back with: scripts/verify-microvm.sh --rollback"
  exit 0
fi

fail "${FAILURES} check(s) failed. Read the [FAIL] lines above before treating this runner as isolated."
