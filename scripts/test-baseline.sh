#!/usr/bin/env bash
#
# test-baseline.sh -- verify k8s/security/runner-network-policy.yaml actually
# does what it claims, and that the HPA reacts to real CPU load.
#
# Three checks:
#   1. The gateway CAN reach the runner on 8080, and a pod that is not the
#      gateway CANNOT. (An ingress rule that allows everyone is decorative.)
#   2. The runner CANNOT reach the EC2 Instance Metadata Service or the public
#      internet, while cluster DNS still resolves.
#   3. Artificial CPU load in the runner makes the HPA scale replicas out.
#
# Usage:
#   scripts/test-baseline.sh                 # all three checks
#   scripts/test-baseline.sh --no-load       # skip check 3 (the deliberate
#                                            #   load test; takes ~8 min)
#   scripts/test-baseline.sh --load-only     # only check 3
#
# NOTE: even --no-load changes the replica count. Measured 2026-10-23: a
# --no-load run took the runner from 1 replica to 4. Nothing in checks 1 and 2
# touches the Deployment, but `kubectl exec python3` burns close to a full core
# while the interpreter starts, and the runner's CPU *request* is 100m -- so a
# few probes read as >1000% utilisation and the HPA reacts exactly as designed
# ("New size: 2 ... New size: 4; reason: cpu resource utilization above
# target"). It settles back to 1 on its own after the 300s scaleDown window.
# Do not read a replica count above 1 after this script as a failure.
#
# Environment overrides:
#   NAMESPACE              default agent-sandbox
#   PROBE_TIMEOUT          per-request timeout, seconds (default 4)
#   LOAD_SECONDS           how long to burn CPU (default 180)
#   SCALE_TIMEOUT_SECONDS  how long to wait for scale-out (default 180)
#
# WHY THERE IS NO curl HERE
#
# The task specified:
#   kubectl exec -it <runner-pod> -- curl -m 2 http://169.254.169.254/...
#
# `python:3.11-slim` ships no curl (verified 2026-10-23: `command -v curl` is
# empty in both the runner and gateway containers; there is also no nc and no
# pkill). That command exits 126/127 with "executable file not found", and a
# script that reads any non-zero exit as "the packet was dropped" reports a
# PASS without a single packet having been sent. The runner also has
# readOnlyRootFilesystem and -- once the policy is applied -- no egress, so
# installing curl is not an option either.
#
# Every probe below therefore runs `python3` (present at
# /usr/local/bin/python3) and prints ONE outcome token: HTTP:<code>, TIMEOUT,
# REFUSED, DNSFAIL, or ERROR:<detail>. The caller branches on the token. A
# timeout is never inferred from an exit status.
#
# `-it` is also dropped: `-t` allocates a TTY, which fails or mangles output
# when stdout is not a terminal (CI, or piping this script to a file).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
POLICY_FILE="${REPO_ROOT}/k8s/security/runner-network-policy.yaml"

NAMESPACE="${NAMESPACE:-agent-sandbox}"
# Matches terraform var.cluster_name. Override with CLUSTER_NAME if you changed it.
EXPECTED_CLUSTER="${CLUSTER_NAME:-secure-agent-sandbox}"
POLICY_NAME="agent-runner-isolation"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-4}"
LOAD_SECONDS="${LOAD_SECONDS:-180}"
SCALE_TIMEOUT_SECONDS="${SCALE_TIMEOUT_SECONDS:-180}"
PROBE_POD="netpol-probe-$$"

RUN_CONNECTIVITY=1
RUN_ISOLATION=1
RUN_LOAD=1
FAILURES=0

###############################################################################
# Output helpers (same conventions as scripts/deploy-baseline.sh)
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

# Soft failure: record it and keep going, so one broken check does not hide
# the other two.
bad() {
  printf '  %s[FAIL]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
  FAILURES=$((FAILURES + 1))
}

kc() { kubectl -n "$NAMESPACE" "$@"; }

###############################################################################
# Argument parsing
###############################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-load)   RUN_LOAD=0 ;;
    --load-only) RUN_CONNECTIVITY=0; RUN_ISOLATION=0 ;;
    -h|--help)   sed -n '3,32p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)           fail "Unknown argument '$1'. Try --help." ;;
  esac
  shift
done

###############################################################################
# The probe, as a here-doc fed to python3 inside a pod.
#
#   probe <pod> <url> [method]
#
# Prints exactly one token. Distinguishing TIMEOUT from REFUSED from HTTP:nnn
# is the whole point: a dropped packet (policy working) looks like TIMEOUT,
# whereas a reachable-but-unauthorised IMDS looks like HTTP:401, and those two
# must never be conflated.
###############################################################################

probe() {
  local pod="$1" url="$2" method="${3:-GET}"
  kc exec -i "$pod" -- python3 - "$url" "$PROBE_TIMEOUT" "$method" <<'PY' 2>/dev/null || echo "EXEC_FAILED"
import socket, sys, urllib.error, urllib.request

url, timeout, method = sys.argv[1], float(sys.argv[2]), sys.argv[3]
socket.setdefaulttimeout(timeout)

# IMDSv2 token minting is a PUT with an empty body; without data= urllib sends
# no Content-Length and IMDS waits for one, which looks like a timeout for the
# wrong reason.
data = b"" if method == "PUT" else None
req = urllib.request.Request(url, data=data, method=method,
                             headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
try:
    r = urllib.request.urlopen(req)
    r.read(64)
    print("HTTP:%d" % r.status)
except urllib.error.HTTPError as e:
    # An HTTP status, even 401/403, means packets arrived and were answered.
    print("HTTP:%d" % e.code)
except socket.timeout:
    print("TIMEOUT")
except urllib.error.URLError as e:
    reason = e.reason
    if isinstance(reason, socket.timeout):
        print("TIMEOUT")
    elif isinstance(reason, socket.gaierror):
        print("DNSFAIL")
    elif isinstance(reason, ConnectionRefusedError):
        print("REFUSED")
    else:
        print("ERROR:%s" % type(reason).__name__)
except Exception as e:  # noqa: BLE001 -- the token must still be single-line
    print("ERROR:%s" % type(e).__name__)
PY
}

# DNS lookup inside a pod. Used as the liveness control for the isolation
# checks: if DNS resolves, the pod's network stack and our python probe are
# both working, so a TIMEOUT to IMDS is a dropped packet rather than a broken
# harness.
probe_dns() {
  local pod="$1"
  kc exec -i "$pod" -- python3 - <<'PY' 2>/dev/null || echo "EXEC_FAILED"
import socket, sys
socket.setdefaulttimeout(5)
try:
    print("DNS_OK:%s" % socket.gethostbyname("kubernetes.default.svc.cluster.local"))
except Exception as e:
    print("DNS_BROKEN:%s" % type(e).__name__)
PY
}

###############################################################################
# Cleanup -- runs on every exit path, including Ctrl-C.
#
# Load generators are started under `timeout`, so even a SIGKILLed script
# cannot leave the runner burning CPU indefinitely. This is belt and braces.
###############################################################################

CLEANUP_RUNNER=""
cleanup() {
  local rc=$?
  set +e
  if [[ -n "$CLEANUP_RUNNER" ]]; then
    kc exec "$CLEANUP_RUNNER" -- sh -c '
      for f in /tmp/listener.pid /tmp/load.pids; do
        [ -f "$f" ] || continue
        while read -r pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done < "$f"
        rm -f "$f"
      done' >/dev/null 2>&1
  fi
  kubectl -n "$NAMESPACE" delete pod "$PROBE_POD" --ignore-not-found \
    --wait=false >/dev/null 2>&1
  exit $rc
}
trap cleanup EXIT INT TERM

###############################################################################
# 1. Preflight
###############################################################################

step "Preflight"

command -v kubectl >/dev/null 2>&1 || fail "'kubectl' not found on PATH."

CTX="$(kubectl config current-context 2>/dev/null || true)"
[[ -n "$CTX" ]] || fail "No current kubectl context. Run the update-kubeconfig command from terraform/RUNBOOK.md."
case "$CTX" in
  *"$EXPECTED_CLUSTER"*) ok "Context targets ${EXPECTED_CLUSTER}." ;;
  *) fail "Current context is '${CTX}', which does not mention '${EXPECTED_CLUSTER}'. This script generates CPU load and sends probes -- refusing to run against an unexpected cluster." ;;
esac

# The context NAME being right says nothing about the API server answering.
# This cluster is private-only, so kubectl reaches it through an SSM
# port-forward on localhost:8443. When that tunnel dies, every later kubectl
# call emits five lines of client-go "memcache ... Unhandled Error" noise and
# the script fails mid-run with no sign of the real cause. Probe once, up
# front.
API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
if ! kubectl version -o json >/dev/null 2>&1; then
  case "$API_SERVER" in
    *localhost*|*127.0.0.1*)
      fail "Cannot reach the Kubernetes API at ${API_SERVER}. That is the SSM port-forward tunnel and nothing is listening -- the session has ended. This cluster has NO public endpoint, so 'aws eks update-kubeconfig' will not fix it. Restart the tunnel: terraform/RUNBOOK.md section 4." ;;
    *)
      fail "Cannot reach the Kubernetes API at ${API_SERVER:-unknown}. Check credentials and connectivity; if the egress IP has rotated see terraform/ISSUES-ENCOUNTERED.md issue 6." ;;
  esac
fi
ok "API server reachable at ${API_SERVER}."

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || fail "Namespace '${NAMESPACE}' does not exist. Run scripts/deploy-baseline.sh first."

# Enforcement must actually be on. Without this flag the API server accepts
# the NetworkPolicy and drops nothing, so every isolation check below would
# fail for a reason that has nothing to do with the policy text.
NODEAGENT_ARGS="$(kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].args}' 2>/dev/null || true)"
if [[ "$NODEAGENT_ARGS" == *"--enable-network-policy=true"* ]]; then
  ok "VPC CNI network policy enforcement is ON."
else
  fail "The aws-node nodeagent is not running with --enable-network-policy=true. NetworkPolicy objects would be accepted and silently ignored. Enable it on the vpc-cni addon before trusting any result from this script."
fi

if [[ $RUN_ISOLATION -eq 1 || $RUN_CONNECTIVITY -eq 1 ]]; then
  if kc get networkpolicy "$POLICY_NAME" >/dev/null 2>&1; then
    ok "NetworkPolicy ${POLICY_NAME} exists."
  else
    fail "NetworkPolicy '${POLICY_NAME}' is not applied, so the runner currently has unrestricted egress. This is not a test failure -- there is nothing to test yet. Apply it first:
      kubectl apply -f ${POLICY_FILE}"
  fi
fi

kc wait --for=condition=Ready pod -l role=code-executor --timeout=120s >/dev/null \
  || fail "No Ready pod with label role=code-executor."
RUNNER="$(kc get pod -l role=code-executor -o jsonpath='{.items[0].metadata.name}')"
RUNNER_IP="$(kc get pod "$RUNNER" -o jsonpath='{.status.podIP}')"
CLEANUP_RUNNER="$RUNNER"

kc wait --for=condition=Ready pod -l app=control-plane-gateway --timeout=120s >/dev/null \
  || fail "No Ready pod with label app=control-plane-gateway."
GATEWAY="$(kc get pod -l app=control-plane-gateway -o jsonpath='{.items[0].metadata.name}')"

ok "runner=${RUNNER} (${RUNNER_IP})"
ok "gateway=${GATEWAY}"

# The selector the policy actually uses, cross-checked against the gateway's
# real labels. See the DEVIATION note at the top of the policy file: the task
# asked for `app: gateway`, which matches nothing here.
POLICY_SRC="$(kc get networkpolicy "$POLICY_NAME" \
  -o jsonpath='{.spec.ingress[0].from[0].podSelector.matchLabels}' 2>/dev/null || true)"
info "ingress source selector: ${POLICY_SRC:-<none>}"

###############################################################################
# 2. Gateway -> runner on 8080 is permitted
###############################################################################

if [[ $RUN_CONNECTIVITY -eq 1 ]]; then
  step "Check 1: the gateway can reach the runner on 8080"

  # Nothing in the runner listens on 8080 (it runs a sleep loop), so probing
  # the real workload would return REFUSED and tell us nothing about the
  # policy. Start a throwaway listener and record its PID for cleanup --
  # matching on cmdline instead would also match the `sh -c` doing the
  # matching, which kills the exec session itself.
  info "starting a temporary listener on 8080 inside the runner"
  # Captured into a variable rather than piped into `grep -q`: grep exits as
  # soon as it matches, kubectl then dies of SIGPIPE with status 141, and
  # `set -o pipefail` would report the whole pipeline as failed even though
  # the listener started.
  LISTENER_OUT="$(kc exec "$RUNNER" -- sh -c '
    cd /tmp
    nohup python3 -m http.server 8080 >/tmp/listener.log 2>&1 &
    echo $! > /tmp/listener.pid
    sleep 2
    kill -0 "$(cat /tmp/listener.pid)" 2>/dev/null && echo listener-up' 2>&1 || true)"
  [[ "$LISTENER_OUT" == *listener-up* ]] \
    || fail "Could not start the test listener inside ${RUNNER}: ${LISTENER_OUT}"
  ok "listener up on ${RUNNER_IP}:8080"

  RESULT="$(probe "$GATEWAY" "http://${RUNNER_IP}:8080/")"
  case "$RESULT" in
    HTTP:*)
      ok "gateway -> runner:8080 ALLOWED (${RESULT})." ;;
    TIMEOUT)
      bad "GATEWAY -> RUNNER:8080 IS BLOCKED (timed out).
         The ingress rule is not matching the gateway pods. Compare the
         policy's selector against the gateway's real labels:
           kubectl -n ${NAMESPACE} get pod ${GATEWAY} --show-labels
         A policy written for 'app: gateway' will do exactly this, because
         these pods are labelled 'app: control-plane-gateway'." ;;
    EXEC_FAILED)
      bad "Could not exec python3 in ${GATEWAY}; the probe never ran. This is a harness failure, not a policy result." ;;
    *)
      bad "gateway -> runner:8080 returned '${RESULT}', which was not expected." ;;
  esac

  # Negative control. An ingress rule that admits every pod in the namespace
  # is decorative; the only way to know it restricts is to be denied.
  #
  # The namespace enforces the `restricted` Pod Security Standard, so the
  # probe pod has to carry the full hardened securityContext or admission
  # rejects it outright.
  info "launching an unlabelled probe pod as a negative control"
  if kc run "$PROBE_POD" --image=python:3.11-slim --restart=Never \
      --labels="app=netpol-probe" \
      --overrides='{
        "spec":{
          "automountServiceAccountToken":false,
          "securityContext":{"runAsNonRoot":true,"runAsUser":10001,
            "seccompProfile":{"type":"RuntimeDefault"}},
          "containers":[{"name":"'"$PROBE_POD"'","image":"python:3.11-slim",
            "command":["sleep","300"],
            "securityContext":{"allowPrivilegeEscalation":false,
              "readOnlyRootFilesystem":true,
              "capabilities":{"drop":["ALL"]}}}]}}' >/dev/null 2>&1 \
     && kc wait --for=condition=Ready "pod/$PROBE_POD" --timeout=120s >/dev/null 2>&1; then

    RESULT="$(probe "$PROBE_POD" "http://${RUNNER_IP}:8080/")"
    case "$RESULT" in
      TIMEOUT)
        ok "non-gateway pod -> runner:8080 DENIED (timed out). The ingress rule restricts by source, it does not just exist." ;;
      HTTP:*)
        bad "A POD THAT IS NOT THE GATEWAY REACHED THE RUNNER ON 8080 (${RESULT}).
         The ingress rule is not restricting by source. Any pod in
         ${NAMESPACE} can drive the code executor. Do not run untrusted code
         in this runner until this is fixed." ;;
      EXEC_FAILED)
        warn "Could not exec in the probe pod; negative control skipped (not a policy result)." ;;
      *)
        warn "Negative control returned '${RESULT}'. Nothing was served, so this is not an exposure, but the result is not the expected TIMEOUT either." ;;
    esac
  else
    warn "Could not start the probe pod, so the negative control was skipped. The allow path above was still verified."
  fi

  info "stopping the temporary listener"
  kc exec "$RUNNER" -- sh -c \
    '[ -f /tmp/listener.pid ] && kill "$(cat /tmp/listener.pid)" 2>/dev/null; rm -f /tmp/listener.pid /tmp/listener.log; echo done' \
    >/dev/null 2>&1 || true
fi

###############################################################################
# 3. Runner egress is denied: IMDS and the public internet
###############################################################################

if [[ $RUN_ISOLATION -eq 1 ]]; then
  step "Check 2: the runner cannot reach IMDS or the internet"

  # Liveness control first. Without it, every TIMEOUT below is ambiguous --
  # it could equally mean the pod has no network at all, or that python is
  # missing, or that the exec failed.
  DNS="$(probe_dns "$RUNNER")"
  case "$DNS" in
    DNS_OK:*)
      ok "cluster DNS still resolves from the runner (${DNS}). The probe works and the DNS egress rule is correct." ;;
    DNS_BROKEN:*)
      bad "CLUSTER DNS IS BROKEN IN THE RUNNER (${DNS}).
         The egress rule is not matching CoreDNS. Every TIMEOUT below is
         therefore meaningless -- fix DNS first. Check that CoreDNS still
         carries k8s-app=kube-dns and that kube-system still has the
         kubernetes.io/metadata.name label:
           kubectl -n kube-system get pods -l k8s-app=kube-dns
           kubectl get ns kube-system -o jsonpath='{.metadata.labels}'" ;;
    *)
      bad "DNS control returned '${DNS}'; the probe harness is not working. Nothing below can be trusted." ;;
  esac

  # IMDS. Two probes, because they fail differently:
  #   - the unauthenticated GET is the one that proves reachability. Before
  #     the policy was applied it returned HTTP:401 in under 10ms -- IMDS
  #     itself answering. That is the signature of an open path.
  #   - the PUT is the one an attacker needs; it mints the IMDSv2 token that
  #     unlocks the node role credentials.
  for spec in "GET|http://169.254.169.254/latest/meta-data/" \
              "PUT|http://169.254.169.254/latest/api/token"; do
    METHOD="${spec%%|*}"; URL="${spec#*|}"
    RESULT="$(probe "$RUNNER" "$URL" "$METHOD")"
    case "$RESULT" in
      TIMEOUT)
        ok "IMDS ${METHOD} ${URL##*/} DROPPED (timed out) -- the egress policy is enforcing." ;;
      HTTP:401|HTTP:403)
        bad "IMDS ANSWERED THE RUNNER WITH ${RESULT} on a ${METHOD}.
         A status code means packets reached 169.254.169.254 and were
         replied to: the network path is OPEN and the only thing standing
         between this pod and the node role is IMDSv2's token requirement.
         This is exactly the pre-policy signature. Confirm the policy selects
         this pod:
           kubectl -n ${NAMESPACE} describe networkpolicy ${POLICY_NAME}
           kubectl -n ${NAMESPACE} get pod ${RUNNER} --show-labels" ;;
      HTTP:*)
        bad "IMDS RETURNED ${RESULT} TO THE RUNNER on a ${METHOD}. The metadata service is reachable AND serving. Treat the node role as exposed to anything running in this pod." ;;
      REFUSED)
        warn "IMDS ${METHOD} was refused rather than dropped. Nothing was served, so this is not an exposure, but a NetworkPolicy drop normally presents as a timeout -- something other than this policy is closing the path." ;;
      EXEC_FAILED)
        bad "Could not exec python3 in ${RUNNER}; the IMDS probe never ran. This is a harness failure -- it is NOT evidence that IMDS is blocked." ;;
      *)
        warn "IMDS ${METHOD} returned '${RESULT}'. Nothing was served, so this is not an exposure, but the outcome is not the expected TIMEOUT." ;;
    esac
  done

  # Public internet. Pre-policy this returned HTTP:200 with the NAT Gateway's
  # Elastic IP in the body.
  RESULT="$(probe "$RUNNER" "https://checkip.amazonaws.com")"
  case "$RESULT" in
    TIMEOUT)
      ok "public internet (checkip.amazonaws.com) DROPPED (timed out)." ;;
    DNSFAIL)
      ok "public internet unreachable: the name did not resolve. Expected -- CoreDNS can only answer from cache or upstream, and its own upstream lookup is unaffected, so treat this as blocked but re-run to confirm the TIMEOUT form." ;;
    HTTP:*)
      bad "THE RUNNER REACHED THE PUBLIC INTERNET (${RESULT}).
         Egress is not being denied. A pod meant to execute untrusted code
         can exfiltrate to any address on the internet through the NAT
         Gateway. Stop here and fix the policy." ;;
    EXEC_FAILED)
      bad "Could not exec python3 in ${RUNNER}; the internet probe never ran. Not evidence of a block." ;;
    *)
      warn "Internet probe returned '${RESULT}'. Nothing was served, so not an exposure, but not the expected TIMEOUT either." ;;
  esac
fi

###############################################################################
# 4. HPA reacts to real CPU load
###############################################################################

if [[ $RUN_LOAD -eq 1 ]]; then
  step "Check 3: CPU load makes the HPA scale out"

  kc get hpa agent-runner >/dev/null 2>&1 \
    || fail "HPA 'agent-runner' not found. Run scripts/deploy-baseline.sh first."

  if ! kc top pod "$RUNNER" >/dev/null 2>&1; then
    fail "'kubectl top' is not returning metrics, so the HPA has nothing to act on and this check cannot mean anything. Install metrics-server -- scripts/deploy-baseline.sh does it."
  fi

  START_REPLICAS="$(kc get deploy agent-runner -o jsonpath='{.spec.replicas}')"
  MAX_REPLICAS="$(kc get hpa agent-runner -o jsonpath='{.spec.maxReplicas}')"
  info "starting replicas=${START_REPLICAS}, maxReplicas=${MAX_REPLICAS}"
  info "HPA target is 50% of the runner's 100m CPU *request*, i.e. ~50m per pod -- not 50% of a core."

  # Two `dd` loops are plenty: the container's limit is 500m, so it is
  # throttled to half a core no matter how many we start, giving ~500%
  # utilisation against a 100m request. `timeout` bounds the burn so a
  # crashed script cannot leave the pod spinning.
  info "generating CPU load in ${RUNNER} for ${LOAD_SECONDS}s"
  LOAD_OUT="$(kc exec "$RUNNER" -- sh -c '
    : > /tmp/load.pids
    i=0
    while [ $i -lt 2 ]; do
      nohup timeout '"$LOAD_SECONDS"' dd if=/dev/zero of=/dev/null bs=1M >/dev/null 2>&1 &
      echo $! >> /tmp/load.pids
      i=$((i+1))
    done
    echo load-started' 2>&1 || true)"
  [[ "$LOAD_OUT" == *load-started* ]] \
    || fail "Could not start the load generator inside ${RUNNER}: ${LOAD_OUT}"
  ok "load generator running (bounded by timeout ${LOAD_SECONDS}s)"

  SCALED=0
  DEADLINE=$((SECONDS + SCALE_TIMEOUT_SECONDS))
  PEAK_CPU="unknown"
  while [[ $SECONDS -lt $DEADLINE ]]; do
    sleep 15
    CUR_CPU="$(kc top pod -l role=code-executor --no-headers 2>/dev/null | awk '{print $2}' | paste -sd, -)"
    DESIRED="$(kc get hpa agent-runner -o jsonpath='{.status.desiredReplicas}' 2>/dev/null || echo 0)"
    CURRENT="$(kc get hpa agent-runner -o jsonpath='{.status.currentReplicas}' 2>/dev/null || echo 0)"
    UTIL="$(kc get hpa agent-runner -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null || true)"
    [[ -n "$CUR_CPU" ]] && PEAK_CPU="$CUR_CPU"
    info "t+$((SECONDS))s cpu=[${CUR_CPU:-none}] utilisation=${UTIL:-?}% replicas=${CURRENT} desired=${DESIRED}"
    if [[ "${DESIRED:-0}" -gt "${START_REPLICAS}" ]]; then
      SCALED=1
      ok "HPA raised desiredReplicas to ${DESIRED} (from ${START_REPLICAS}) at utilisation ${UTIL:-?}%."
      break
    fi
  done

  if [[ $SCALED -eq 0 ]]; then
    bad "THE HPA DID NOT SCALE OUT within ${SCALE_TIMEOUT_SECONDS}s. Last CPU reading: [${PEAK_CPU}].
         If CPU stayed near 0m the load generator never ran; if CPU was high
         and desiredReplicas stayed at ${START_REPLICAS}, inspect the HPA's
         own view:
           kubectl -n ${NAMESPACE} describe hpa agent-runner
         Note the scaleUp stabilizationWindowSeconds in k8s/apps/hpa.yaml
         delays the decision by up to 60s on top of the 15s metrics
         resolution."
  else
    # Confirm the Deployment follows, not just the HPA's intent.
    if kc rollout status deploy/agent-runner --timeout=180s >/dev/null 2>&1; then
      ACTUAL="$(kc get deploy agent-runner -o jsonpath='{.status.readyReplicas}')"
      ok "Deployment now reports ${ACTUAL} ready replicas."
      [[ "${ACTUAL:-0}" -le "${MAX_REPLICAS}" ]] \
        || bad "Ready replicas ${ACTUAL} exceeds maxReplicas ${MAX_REPLICAS}."
    else
      warn "New replicas did not all become Ready in 180s. Check scheduling: the runner has nodeSelector workload=sandbox and this cluster has one node."
    fi
  fi

  info "stopping the load generator"
  kc exec "$RUNNER" -- sh -c \
    '[ -f /tmp/load.pids ] && while read -r p; do [ -n "$p" ] && kill "$p" 2>/dev/null; done < /tmp/load.pids; rm -f /tmp/load.pids; echo done' \
    >/dev/null 2>&1 || true
  ok "load stopped."
  warn "Scale-IN is NOT verified here. k8s/apps/hpa.yaml sets a 300s scaleDown stabilization window, so the Deployment will sit at its scaled-out size for at least 5 more minutes and the extra pods keep costing CPU reservations. Watch it settle with:
       kubectl -n ${NAMESPACE} get hpa agent-runner -w"
fi

###############################################################################
# 5. Verdict
###############################################################################

step "Verdict"

# Report the replica count either way: this script raises it as a side effect
# (see the NOTE in the header), and a reader who does not expect that will
# otherwise go looking for a phantom scale-out.
REPLICAS_NOW="$(kc get deploy agent-runner -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
if [[ "$REPLICAS_NOW" != "1" ]]; then
  info "agent-runner is at ${REPLICAS_NOW} replicas. The probes above are themselves CPU load against a 100m request, so the HPA scaled out. It returns to 1 after the 300s scaleDown window -- not a failure."
fi

if [[ $FAILURES -eq 0 ]]; then
  ok "All checks passed."
  exit 0
fi

fail "${FAILURES} check(s) failed. Nothing above was changed on your behalf except the runner's replica count, which the HPA will settle on its own."
