#!/usr/bin/env bash
#
# install-kata.sh -- install Kata Containers with Cloud Hypervisor on this
# cluster's nodes, and verify the runtime is genuinely a VM rather than just a
# RuntimeClass object that exists.
#
# Usage:
#   scripts/install-kata.sh            # preflight + confirm + install + verify
#   scripts/install-kata.sh --check    # read-only preflight. Applies nothing.
#   scripts/install-kata.sh --render   # write the rendered chart for review
#   scripts/install-kata.sh --smoke    # only the VM proof test (needs install)
#   scripts/install-kata.sh --delete   # uninstall and revert the host changes
#
# Environment overrides:
#   NAMESPACE             kata-deploy namespace (default kube-system)
#   KATA_CHART_VERSION    chart + payload version (default 4.3.1)
#   KATA_CHART_REF        OCI chart reference
#   ROLLOUT_TIMEOUT       DaemonSet rollout wait, seconds (default 900)
#   SMOKE_TIMEOUT         Kata pod start wait, seconds (default 300)
#
# ---------------------------------------------------------------------------
# THIS RESTARTS containerd ON THE NODE
#
# kata-deploy writes /opt/kata, edits the host containerd config, then restarts
# containerd. This cluster has one node, so that restarts
# EVERY pod on it: both gateway replicas, the runner, CoreDNS, aws-node,
# metrics-server, the load balancer controller. The gateway's NLB targets go
# unhealthy and the endpoint stops answering until they pass health checks
# again -- 285s when first measured. The PodDisruptionBudget does not help;
# this is a runtime restart, not an eviction.
#
# The script prompts once, before that happens, and refuses to assume yes on a
# non-interactive stdin.
#
# ---------------------------------------------------------------------------
# WHY THE REQUESTED kubectl COMMANDS ARE NOT USED
#
# Both URLs in the task return HTTP 404 on `main`. Upstream deleted the raw
# kustomize manifests in the 4.x rewrite; they last existed at tag 3.21.0. The
# Helm chart is the only maintained path. See the header of
# k8s/kata/kata-setup.yaml for the evidence and for why 3.21.0 was not used
# instead.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KATA_DIR="${REPO_ROOT}/k8s/kata"
VALUES_FILE="${KATA_DIR}/kata-setup.yaml"
RUNTIMECLASS_FILE="${KATA_DIR}/runtimeclass-clh.yaml"
RENDER_DIR="${KATA_DIR}/rendered"

NAMESPACE="${NAMESPACE:-kube-system}"
# Matches terraform var.cluster_name. Override with CLUSTER_NAME if you changed it.
EXPECTED_CLUSTER="${CLUSTER_NAME:-secure-agent-sandbox}"
RELEASE="kata-deploy"
# PIN. The chart version also selects the payload image, because
# kata-setup.yaml leaves image.tag empty so the chart's appVersion is used.
# 4.3.1 was the newest release on 2026-10-23.
KATA_CHART_VERSION="${KATA_CHART_VERSION:-4.3.1}"
KATA_CHART_REF="${KATA_CHART_REF:-oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy}"
RUNTIME_CLASS="kata-clh"
KVM_NODE_LABEL="sandbox.io/kvm=true"
KATA_NODE_LABEL="katacontainers.io/kata-runtime=true"
ROLLOUT_TIMEOUT="${ROLLOUT_TIMEOUT:-900}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-300}"
SMOKE_POD="kata-smoke-$$"
# The smoke test's control: a Kata pod must NOT report this kernel.
HOST_KERNEL=""

MODE="install"

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

# Banner to stderr, never stdout, so run() on the left of a pipe cannot inject
# escapes into the next command's stdin.
run() {
  printf '%s    $ %s%s\n' "$C_DIM" "$*" "$C_OFF" >&2
  "$@"
}

confirm() {
  local prompt="$1" reply
  if [[ ! -t 0 ]]; then
    fail "${prompt} -- refusing to assume yes on a non-interactive stdin."
  fi
  read -r -p "  ${prompt} [y/N] " reply
  [[ "$reply" == "y" || "$reply" == "Y" ]]
}

kc() { kubectl -n "$NAMESPACE" "$@"; }

# First line of a stream.
#
# NOT `head -1`: head exits after one line, the upstream producer dies of
# SIGPIPE with status 141, and `set -o pipefail` then reports the whole
# pipeline as failed. Under `set -e` that kills the script with no message --
# which is exactly how this script failed its first run. `sed -n 1p` reads to
# EOF, so nothing upstream is ever signalled.
first_line() { sed -n '1p'; }

###############################################################################
# Run a command on a node's host filesystem via a privileged pod.
#
#   node_probe <node> <sh -c script>     # prints the pod's stdout
#
# The pod is created explicitly rather than with `kubectl debug node/...` so
# that its name is known up front. `kubectl debug` generates the name and
# prints it, and scraping that output is what broke the first version of this
# script. Explicit is also more auditable: the privileges taken are visible
# right here.
#
# It lands in `default`, which carries no Pod Security Standard labels. The
# same pod would be rejected in agent-sandbox, which enforces `restricted` --
# correctly, since this mounts the host root filesystem and runs privileged.
###############################################################################
PROBE_SEQ=0
node_probe() {
  local node="$1" script="$2" pod phase logs
  PROBE_SEQ=$((PROBE_SEQ + 1))
  pod="kataprobe-$$-${PROBE_SEQ}"

  # Built as YAML, not as `kubectl run --overrides`, because the probe scripts
  # are multi-line: embedding a literal newline in a JSON string is invalid
  # JSON, so the --overrides form silently failed to create the pod. A YAML
  # block scalar carries multi-line text natively.
  if ! printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: %s\n  labels:\n    app: kata-node-probe\nspec:\n  nodeName: %s\n  restartPolicy: Never\n  hostPID: true\n  automountServiceAccountToken: false\n  tolerations:\n    - operator: Exists\n  containers:\n    - name: probe\n      image: python:3.11-slim\n      command: ["/bin/sh", "-c"]\n      args:\n        - |\n%s\n      securityContext:\n        privileged: true\n      volumeMounts:\n        - name: host\n          mountPath: /host\n  volumes:\n    - name: host\n      hostPath:\n        path: /\n        type: Directory\n' \
        "$pod" "$node" "$(printf '%s\n' "$script" | sed 's/^/          /')" \
      | kubectl -n default apply -f - >/dev/null 2>&1; then
    return 1
  fi

  local deadline=$((SECONDS + 120))
  while [[ $SECONDS -lt $deadline ]]; do
    phase="$(kubectl -n default get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 3
  done
  logs="$(kubectl -n default logs "$pod" 2>/dev/null || true)"
  kubectl -n default delete pod "$pod" --ignore-not-found --wait=false >/dev/null 2>&1
  printf '%s\n' "$logs"
  return 0
}

cleanup() {
  local rc=$?
  set +e
  kubectl -n default delete pod "$SMOKE_POD" "${SMOKE_POD}-runc" \
    --ignore-not-found --wait=false >/dev/null 2>&1
  # Any probe pod still around if we died mid-probe.
  kubectl -n default delete pod -l app=kata-node-probe \
    --ignore-not-found --wait=false >/dev/null 2>&1
  for i in $(seq 1 "${PROBE_SEQ:-0}"); do
    kubectl -n default delete pod "kataprobe-$$-${i}" --ignore-not-found \
      --wait=false >/dev/null 2>&1
  done
  exit $rc
}
trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)   MODE="check" ;;
    --render)  MODE="render" ;;
    --smoke)   MODE="smoke" ;;
    --delete)  MODE="delete" ;;
    -h|--help) sed -n '3,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         fail "Unknown argument '$1'. Try --help." ;;
  esac
  shift
done

###############################################################################
# 1. Preflight
###############################################################################

step "Preflight"

for tool in kubectl helm; do
  command -v "$tool" >/dev/null 2>&1 || fail "'${tool}' not found on PATH. Kata 4.x installs via Helm only -- see the header of ${VALUES_FILE}."
done
ok "kubectl and helm are present ($(helm version --short 2>/dev/null))."

for f in "$VALUES_FILE" "$RUNTIMECLASS_FILE"; do
  [[ -f "$f" ]] || fail "Missing ${f}"
done

CTX="$(kubectl config current-context 2>/dev/null || true)"
case "$CTX" in
  *"$EXPECTED_CLUSTER"*) ok "Context targets ${EXPECTED_CLUSTER}." ;;
  "") fail "No current kubectl context. Run the update-kubeconfig command from terraform/RUNBOOK.md." ;;
  *)  fail "Current context is '${CTX}', which does not mention '${EXPECTED_CLUSTER}'. This script restarts containerd on every matching node -- refusing to run against an unexpected cluster." ;;
esac

# The context NAME being right says nothing about the API server being
# reachable. This cluster is private-only (no public endpoint), so kubectl
# talks to it through an SSM port-forward on localhost:8443 -- and when that
# tunnel dies, every later kubectl call emits five lines of client-go
# "memcache ... Unhandled Error" noise and the script fails somewhere in the
# middle with no indication of the real cause. Probe once, up front, and say
# what to do.
API_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
if ! kubectl version -o json >/dev/null 2>&1; then
  MSG="Cannot reach the Kubernetes API at ${API_SERVER:-unknown}."
  case "$API_SERVER" in
    *localhost*|*127.0.0.1*)
      PORT="${API_SERVER##*:}"
      fail "${MSG}
         That is the SSM port-forward tunnel, and nothing is listening on
         port ${PORT} -- the session has ended. This cluster has NO public
         endpoint (endpointPublicAccess=false), so the tunnel is
         the only route in and 'aws eks update-kubeconfig' will NOT fix it.

         Restart the tunnel and leave it running:

           AWS_PROFILE=sandbox aws ssm start-session --region us-east-1 \\
             --target \$(AWS_PROFILE=sandbox aws ec2 describe-instances --region us-east-1 \\
               --filters Name=tag:eks:cluster-name,Values=${EXPECTED_CLUSTER} \\
                         Name=instance-state-name,Values=running \\
               --query 'Reservations[].Instances[].InstanceId' --output text) \\
             --document-name AWS-StartPortForwardingSessionToRemoteHost \\
             --parameters '{\"host\":[\"<cluster-endpoint-host>\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"${PORT}\"]}'

         The endpoint host comes from:
           AWS_PROFILE=sandbox aws eks describe-cluster --name ${EXPECTED_CLUSTER} \\
             --region us-east-1 --query cluster.endpoint --output text

         Full procedure, including the --tls-server-name that keeps the
         certificate valid: terraform/RUNBOOK.md section 4." ;;
    *)
      fail "${MSG}
         Check credentials and connectivity:
           AWS_PROFILE=sandbox aws sts get-caller-identity
           AWS_PROFILE=sandbox aws eks describe-cluster --name ${EXPECTED_CLUSTER} --region us-east-1 --query cluster.status
         If the egress IP has rotated, see ISSUES-ENCOUNTERED.md issue 6." ;;
  esac
fi
ok "API server reachable at ${API_SERVER}."

###############################################################################
# 2. /dev/kvm -- the Kata prerequisite
#
# Two checks, because they answer different questions. The node label is what
# the SCHEDULER uses and what kata-setup.yaml selects on; the host inspection
# is whether /dev/kvm is actually there. A label can be wrong -- it is applied
# by terraform/eks.tf from the instance type, not by probing the device.
###############################################################################

step "Checking /dev/kvm"

NODES="$(kubectl get nodes -l "$KVM_NODE_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"
if [[ -z "$NODES" ]]; then
  fail "No node carries the label ${KVM_NODE_LABEL}, so kata-deploy would install nowhere.
         Kata needs hardware virtualisation, which on EC2 means a bare-metal
         instance type. Check what you have:
           kubectl get nodes -L node.kubernetes.io/instance-type,sandbox.io/kvm
         terraform/variables.tf rejects non-metal types for this reason."
fi
NODE_COUNT="$(printf '%s\n' "$NODES" | grep -c .)"
ok "${NODE_COUNT} node(s) labelled ${KVM_NODE_LABEL}:"
printf '%s\n' "$NODES" | sed 's/^/           /'

# Authoritative check: look at the device on the host. `kubectl debug node/`
# gives a pod in the `default` namespace with the host filesystem at /host and
# a privileged profile. `default` has no Pod Security Standard labels, so a
# privileged pod is admitted there; it would be rejected in agent-sandbox,
# which enforces `restricted`.
KVM_VERIFIED=0
for node in $NODES; do
  info "inspecting ${node} with a privileged pod"
  LOGS="$(node_probe "$node" '
    ls -l /host/dev/kvm 2>&1
    echo "KERNEL=$(uname -r)"
    echo "CTRD=$(chroot /host containerd --version 2>&1 | sed -n 1p)"
    echo "CFGVER=$(sed -n "/^version/{p;q;}" /host/etc/containerd/config.toml 2>&1)"
  ' || true)"

  if [[ -z "$LOGS" ]]; then
    warn "Could not read ${node} with a privileged pod; falling back to the node label only. That label is derived from the instance type, not from probing the device."
    continue
  fi

  if [[ "$LOGS" == *"/host/dev/kvm"* && "$LOGS" != *"No such file"* ]]; then
    ok "${node}: /dev/kvm present -- $(printf '%s\n' "$LOGS" | grep 'dev/kvm' | first_line)"
    KVM_VERIFIED=1
  else
    fail "${node} is labelled ${KVM_NODE_LABEL} but /dev/kvm was NOT found on the host.
         The label is derived from the instance type and is wrong, or the device
         is not exposed. Installing Kata here would succeed, label the node
         katacontainers.io/kata-runtime=true, and then every Kata pod would
         fail at VM start. Debug output:
${LOGS}"
  fi
  [[ -n "$HOST_KERNEL" ]] || HOST_KERNEL="$(printf '%s\n' "$LOGS" | sed -n 's/^KERNEL=//p' | first_line)"
  CTRD="$(printf '%s\n' "$LOGS" | sed -n 's/^CTRD=//p' | first_line)"
  CFGVER="$(printf '%s\n' "$LOGS" | sed -n 's/^CFGVER=//p' | first_line)"
  [[ -n "$CTRD" ]] && info "${node}: ${CTRD}"
  # containerd 2.x with `version = 3` renames the CRI plugin key, so an
  # installer that writes the 1.x key registers a handler containerd never
  # reads. 4.x handles this; 3.x shell-script installers are where this breaks.
  if [[ "$CFGVER" == *"version = 3"* ]]; then
    info "${node}: containerd config ${CFGVER} -- needs the containerd 2.x CRI plugin key, which chart ${KATA_CHART_VERSION} writes."
  elif [[ -n "$CFGVER" ]]; then
    info "${node}: containerd config ${CFGVER}"
  fi
done
[[ "$KVM_VERIFIED" -eq 1 ]] && ok "/dev/kvm confirmed on the host, not just inferred from a label." \
  || warn "/dev/kvm was not confirmed by host inspection on any node."

[[ -n "$HOST_KERNEL" ]] || HOST_KERNEL="$(kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kernelVersion}')"
info "host kernel: ${HOST_KERNEL} (the smoke test requires a Kata pod to differ from this)"

###############################################################################
# 3. Current state
###############################################################################

step "Current state"

# defaultShim must name one of the enabled shims. kata-deploy enforces this at
# startup and exits 1 -- `helm template` cannot catch it, because the check
# lives in the binary, not the chart. Without this preflight the symptom is a
# CrashLoopBackOff several minutes into an install, with the real message
# buried in pod logs. That is exactly how it failed on 2026-10-23.
DEFAULT_SHIM="$(helm template "$RELEASE" "$KATA_CHART_REF" \
  --version "$KATA_CHART_VERSION" --namespace "$NAMESPACE" --values "$VALUES_FILE" 2>/dev/null \
  | grep -A1 'name: DEFAULT_SHIM' | sed -n 's/.*value: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' | first_line || true)"
ENABLED_SHIMS="$(helm template "$RELEASE" "$KATA_CHART_REF" \
  --version "$KATA_CHART_VERSION" --namespace "$NAMESPACE" --values "$VALUES_FILE" 2>/dev/null \
  | grep -A1 'name: SHIMS_X86_64' | sed -n 's/.*value: *"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' | first_line || true)"
if [[ -n "$DEFAULT_SHIM" && -n "$ENABLED_SHIMS" ]]; then
  if [[ " ${ENABLED_SHIMS} " == *" ${DEFAULT_SHIM} "* ]]; then
    ok "defaultShim '${DEFAULT_SHIM}' is among the enabled shims [${ENABLED_SHIMS}]."
  else
    fail "defaultShim is '${DEFAULT_SHIM}' but the enabled shims are [${ENABLED_SHIMS}].
         kata-deploy will exit 1 at startup with
           Error: DEFAULT_SHIM '${DEFAULT_SHIM}' must be one of the configured SHIMS
         and the DaemonSet will CrashLoopBackOff. Set defaultShim.amd64 in
         ${VALUES_FILE} to one of [${ENABLED_SHIMS}]."
  fi
else
  warn "Could not read defaultShim/SHIMS out of the rendered chart; skipping that cross-check."
fi

if helm -n "$NAMESPACE" status "$RELEASE" >/dev/null 2>&1; then
  INSTALLED="$(helm -n "$NAMESPACE" list -f "^${RELEASE}\$" -o json \
    | python3 -I -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["chart"], r[0]["status"]) if r else print("none")' 2>/dev/null || echo unknown)"
  info "helm release ${RELEASE} already present: ${INSTALLED}"
  ALREADY=1
  # A release stuck in pending-install/pending-upgrade blocks every later
  # `helm upgrade --install` with "another operation is in progress". It is
  # what an interrupted or crash-looping first install leaves behind, and the
  # error does not say how to clear it.
  REL_STATUS="$(helm -n "$NAMESPACE" status "$RELEASE" -o json 2>/dev/null \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["info"]["status"])' 2>/dev/null || echo unknown)"
  case "$REL_STATUS" in
    deployed)
      ok "release status: deployed." ;;
    pending-install|pending-upgrade|pending-rollback|failed|unknown)
      warn "release ${RELEASE} is in status '${REL_STATUS}', not 'deployed'."
      warn "A pending or failed release blocks 'helm upgrade --install' with \"another operation (install/upgrade/rollback) is in progress\"."
      if [[ "$MODE" == "install" ]]; then
        CRASHING="$(kc get pods -l name=kata-deploy \
          -o jsonpath='{range .items[*]}{.metadata.name}={.status.containerStatuses[0].state.waiting.reason}{" "}{end}' 2>/dev/null || true)"
        [[ -n "$CRASHING" ]] && info "kata-deploy pods: ${CRASHING}"
        warn "Clearing it uninstalls the release. That is safe while the install has not completed -- but if it DID partially complete, the uninstall path restarts containerd."
        if confirm "Uninstall the stuck '${REL_STATUS}' release before retrying?"; then
          run helm -n "$NAMESPACE" uninstall "$RELEASE" --wait --timeout 5m || \
            warn "uninstall reported an error; continuing to the install attempt."
          ALREADY=0
          ok "stuck release cleared."
        else
          fail "Leaving the ${REL_STATUS} release in place. The install below would fail. Clear it with:
           helm -n ${NAMESPACE} uninstall ${RELEASE}"
        fi
      fi
      ;;
  esac
else
  info "helm release ${RELEASE} is not installed."
  ALREADY=0
fi

if kubectl get runtimeclass "$RUNTIME_CLASS" >/dev/null 2>&1; then
  info "RuntimeClass ${RUNTIME_CLASS} already exists."
else
  info "RuntimeClass ${RUNTIME_CLASS} does not exist yet."
fi
KATA_NODES="$(kubectl get nodes -l "$KATA_NODE_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
info "nodes with ${KATA_NODE_LABEL}: ${KATA_NODES}"

if [[ "$MODE" == "check" ]]; then
  step "Verdict"
  ok "Preflight complete. Nothing was applied."
  info "To see what would be created:  scripts/install-kata.sh --render"
  info "To install:                    scripts/install-kata.sh"
  exit 0
fi

###############################################################################
# 4. Render for review
###############################################################################

RENDER_OUT=""
render() {
  mkdir -p "$RENDER_DIR"
  local out="${RENDER_DIR}/kata-deploy-${KATA_CHART_VERSION}.yaml"
  run helm template "$RELEASE" "$KATA_CHART_REF" \
    --version "$KATA_CHART_VERSION" \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE" > "$out"
  ok "Rendered to ${out} ($(grep -c '^kind:' "$out") objects)."
  info "Objects:"
  grep -E '^kind:' "$out" | sort | uniq -c | sed 's/^/           /'
  info "Privileged containers in the render: $(grep -c 'privileged: true' "$out" || true)"
  RENDER_OUT="$out"
}

if [[ "$MODE" == "render" ]]; then
  step "Rendering chart ${KATA_CHART_VERSION} (nothing applied)"
  render
  step "Verdict"
  ok "Render complete. Review the file, then run scripts/install-kata.sh."
  exit 0
fi

###############################################################################
# 5. Uninstall
###############################################################################

if [[ "$MODE" == "delete" ]]; then
  step "Uninstall Kata"
  warn "This removes the RuntimeClass and uninstalls the Helm release."
  warn "In daemonset mode kata-deploy reverts the host changes as its pods terminate, which means containerd is restarted AGAIN -- every pod on the node restarts."
  confirm "Uninstall Kata and restart containerd?" || fail "Aborted by operator."

  run kubectl delete -f "$RUNTIMECLASS_FILE" --ignore-not-found
  if [[ "$ALREADY" -eq 1 ]]; then
    run helm -n "$NAMESPACE" uninstall "$RELEASE" --wait --timeout 10m
  else
    info "no helm release to uninstall."
  fi
  info "waiting for the kata-runtime node label to clear"
  for _ in $(seq 1 60); do
    [[ "$(kubectl get nodes -l "$KATA_NODE_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')" == "0" ]] && break
    sleep 5
  done
  LEFT="$(kubectl get nodes -l "$KATA_NODE_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$LEFT" == "0" ]]; then
    ok "Kata uninstalled and the node label cleared."
  else
    warn "${LEFT} node(s) still carry ${KATA_NODE_LABEL}. kata-deploy's revert may not have completed; check /opt/kata and the containerd config on the node (RUNBOOK.md section 4 has the SSM path)."
  fi
  exit 0
fi

###############################################################################
# 6. Install
###############################################################################

if [[ "$MODE" == "install" ]]; then
  step "Install plan"

  render
  info "chart:     ${KATA_CHART_REF} ${KATA_CHART_VERSION}"
  info "namespace: ${NAMESPACE}   release: ${RELEASE}"
  info "values:    ${VALUES_FILE}"
  info "shims:     clh only (disableAll: true)"

  printf '\n'
  warn "kata-deploy writes /opt/kata, edits the host containerd config, and restarts containerd. Its container is NOT privileged, but it mounts /etc/systemd/system and the systemd private socket writable, which is root-equivalent on the host. Run --render and read the file if you have not."
  warn "This cluster has ${NODE_COUNT} matching node. Restarting containerd restarts EVERY pod on it -- both gateway replicas, the runner, CoreDNS, aws-node, metrics-server and the load balancer controller."
  warn "The gateway's NLB targets will go unhealthy and the endpoint will stop answering until they pass health checks again (285s when first measured)."
  printf '\n'
  confirm "Install Kata and restart containerd on ${NODE_COUNT} node(s)?" \
    || fail "Aborted by operator. Nothing was applied."

  step "Installing chart ${KATA_CHART_VERSION}"
  run helm upgrade --install "$RELEASE" "$KATA_CHART_REF" \
    --version "$KATA_CHART_VERSION" \
    --namespace "$NAMESPACE" \
    --values "$VALUES_FILE" \
    --wait --timeout "${ROLLOUT_TIMEOUT}s"
  ok "Helm release applied."

  step "Waiting for kata-deploy to finish on every node"
  info "this is where containerd restarts; kubectl may briefly error"
  if run kubectl -n "$NAMESPACE" rollout status ds/kata-deploy \
       --timeout="${ROLLOUT_TIMEOUT}s"; then
    ok "kata-deploy DaemonSet rollout complete."
  else
    fail "kata-deploy rollout did not complete in ${ROLLOUT_TIMEOUT}s. Inspect it:
           kubectl -n ${NAMESPACE} get pods -l name=kata-deploy
           kubectl -n ${NAMESPACE} logs -l name=kata-deploy --tail=80 -c kube-kata"
  fi

  # Ready is not the same as installed: the pod reports Ready once its health
  # endpoint answers. The node label is kata-deploy's own last install step, so
  # it is the signal that the work actually finished.
  info "waiting for ${KATA_NODE_LABEL} (kata-deploy's final install step)"
  DEADLINE=$((SECONDS + ROLLOUT_TIMEOUT))
  while [[ $SECONDS -lt $DEADLINE ]]; do
    LABELLED="$(kubectl get nodes -l "$KATA_NODE_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$LABELLED" == "$NODE_COUNT" ]] && break
    info "t+$((SECONDS))s ${LABELLED}/${NODE_COUNT} node(s) labelled"
    sleep 10
  done
  LABELLED="$(kubectl get nodes -l "$KATA_NODE_LABEL" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$LABELLED" == "$NODE_COUNT" ]]; then
    ok "${LABELLED}/${NODE_COUNT} node(s) carry ${KATA_NODE_LABEL}."
  else
    fail "Only ${LABELLED}/${NODE_COUNT} node(s) carry ${KATA_NODE_LABEL} after ${ROLLOUT_TIMEOUT}s. The DaemonSet is running but the install did not complete. The RuntimeClass selects on this label, so Kata pods would stay Pending. Logs:
           kubectl -n ${NAMESPACE} logs -l name=kata-deploy --tail=120 -c kube-kata"
  fi

  step "Registering the RuntimeClass"
  run kubectl apply -f "$RUNTIMECLASS_FILE"
  ok "Applied ${RUNTIMECLASS_FILE}."
fi

###############################################################################
# 7. Verify
###############################################################################

step "Verifying ${RUNTIME_CLASS}"

# The task's explicit requirement: `kubectl get runtimeclass` outputs kata-clh.
RC_OUT="$(kubectl get runtimeclass 2>&1 || true)"
if printf '%s\n' "$RC_OUT" | grep -qE "^${RUNTIME_CLASS}[[:space:]]"; then
  ok "kubectl get runtimeclass lists ${RUNTIME_CLASS}:"
  printf '%s\n' "$RC_OUT" | sed 's/^/           /'
else
  fail "kubectl get runtimeclass does NOT list ${RUNTIME_CLASS}. Output was:
${RC_OUT}"
fi

RC_HANDLER="$(kubectl get runtimeclass "$RUNTIME_CLASS" -o jsonpath='{.handler}')"
if [[ "$RC_HANDLER" == "$RUNTIME_CLASS" ]]; then
  ok "handler is '${RC_HANDLER}'."
else
  warn "RuntimeClass ${RUNTIME_CLASS} has handler '${RC_HANDLER}', which does not match the shim name. Pods will fail with 'no runtime for \"${RC_HANDLER}\" is configured'."
fi

# The object existing proves nothing about the host. Check that kata-deploy
# actually installed the clh shim binary containerd will exec.
step "Verifying the shim exists on the node"
SHIM_OK=0
for node in $NODES; do
  LOGS="$(node_probe "$node" '
    ls /host/opt/kata/bin/ 2>&1
    echo "--- containerd config references ---"
    grep -rl "kata-clh" /host/etc/containerd/ 2>/dev/null
  ' || true)"
  [[ -z "$LOGS" ]] && { warn "could not inspect ${node}"; continue; }
  if printf '%s\n' "$LOGS" | grep -q 'containerd-shim-kata'; then
    ok "${node}: kata shim binaries present under /opt/kata/bin."
    SHIM_OK=1
  else
    warn "${node}: no kata shim binary found under /opt/kata/bin. Output:
${LOGS}"
  fi
  if printf '%s\n' "$LOGS" | grep -q 'kata-clh'; then
    ok "${node}: containerd config references the kata-clh handler."
  else
    warn "${node}: 'kata-clh' not found in the containerd config. containerd 2.x with 'version = 3' uses the io.containerd.cri.v1.runtime plugin key; if the installer wrote the 1.x key the handler is registered where containerd will not read it, and Kata pods will fail to start."
  fi
done
[[ "$SHIM_OK" -eq 1 ]] || warn "Could not confirm the shim on any node."

###############################################################################
# 8. Smoke test -- prove it is a VM, not just a RuntimeClass
#
# A RuntimeClass that exists and a pod that starts are both weak evidence. The
# claim being made is hardware isolation, and the observable consequence of
# that claim is a DIFFERENT KERNEL: a runc container shares the host kernel, a
# Kata pod boots its own. So the test compares both against the host.
###############################################################################

step "Smoke test: does a ${RUNTIME_CLASS} pod get its own kernel?"

SMOKE_OVERRIDES='{
  "spec":{
    "runtimeClassName":"'"$RUNTIME_CLASS"'",
    "automountServiceAccountToken":false,
    "containers":[{"name":"probe","image":"python:3.11-slim",
      "command":["sh","-c","uname -r; echo ---; cat /proc/1/cgroup 2>/dev/null | head -2"]}]}}'

info "starting a pod with runtimeClassName=${RUNTIME_CLASS}"
if ! kubectl -n default run "$SMOKE_POD" --image=python:3.11-slim --restart=Never \
     --overrides="$SMOKE_OVERRIDES" >/dev/null 2>&1; then
  fail "Could not create the smoke-test pod."
fi

SMOKE_PHASE=""
DEADLINE=$((SECONDS + SMOKE_TIMEOUT))
while [[ $SECONDS -lt $DEADLINE ]]; do
  SMOKE_PHASE="$(kubectl -n default get pod "$SMOKE_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  [[ "$SMOKE_PHASE" == "Succeeded" || "$SMOKE_PHASE" == "Failed" ]] && break
  sleep 5
done

SMOKE_LOGS="$(kubectl -n default logs "$SMOKE_POD" 2>/dev/null || true)"
KATA_KERNEL="$(printf '%s\n' "$SMOKE_LOGS" | first_line | tr -d "\r")"

if [[ "$SMOKE_PHASE" != "Succeeded" ]]; then
  REASON="$(kubectl -n default get pod "$SMOKE_POD" \
    -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}{" "}{.status.containerStatuses[0].state.waiting.message}' 2>/dev/null || true)"
  EVENTS="$(kubectl -n default get events --field-selector "involvedObject.name=${SMOKE_POD}" \
    -o custom-columns=REASON:.reason,MSG:.message --no-headers 2>/dev/null | tail -5 || true)"
  fail "The ${RUNTIME_CLASS} pod did not run (phase=${SMOKE_PHASE:-unknown}).
         Kata is NOT usable, whatever 'kubectl get runtimeclass' says.
         waiting: ${REASON}
         events:
${EVENTS}
         Most likely causes, in order:
           1. containerd does not know the handler -- see the config check above.
           2. /dev/kvm missing or not usable by the shim.
           3. The node is missing ${KATA_NODE_LABEL} so the pod never scheduled.
         Logs: kubectl -n ${NAMESPACE} logs -l name=kata-deploy -c kube-kata --tail=120"
fi

if [[ -z "$KATA_KERNEL" ]]; then
  warn "The pod succeeded but produced no kernel string; cannot compare. Raw output:
${SMOKE_LOGS}"
elif [[ "$KATA_KERNEL" == "$HOST_KERNEL" ]]; then
  fail "THE ${RUNTIME_CLASS} POD REPORTED THE HOST KERNEL (${KATA_KERNEL}).
         It ran, but it ran as an ordinary container sharing the host kernel --
         there is no VM boundary. A RuntimeClass whose pods silently fall back
         to runc is worse than no RuntimeClass: workloads believe they are
         isolated. Do not run untrusted code under ${RUNTIME_CLASS} until this
         is resolved. Check that the handler in the containerd config points at
         a kata shim and not at runc."
else
  ok "Kata pod kernel:  ${KATA_KERNEL}"
  ok "Host node kernel: ${HOST_KERNEL}"
  ok "They differ -- the pod booted its own kernel, so the VM boundary is real."
fi

# Control: the same image under the default runtime MUST report the host
# kernel. If it does not, the comparison above proves nothing, because
# "different from the host kernel" would be true for every pod.
info "control: same image under the default runtime (runc)"
if kubectl -n default run "${SMOKE_POD}-runc" --image=python:3.11-slim --restart=Never \
     --command -- sh -c 'uname -r' >/dev/null 2>&1; then
  DEADLINE=$((SECONDS + 120))
  while [[ $SECONDS -lt $DEADLINE ]]; do
    P="$(kubectl -n default get pod "${SMOKE_POD}-runc" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$P" == "Succeeded" || "$P" == "Failed" ]] && break
    sleep 3
  done
  RUNC_KERNEL="$(kubectl -n default logs "${SMOKE_POD}-runc" 2>/dev/null | first_line | tr -d "\r")"
  if [[ "$RUNC_KERNEL" == "$HOST_KERNEL" ]]; then
    ok "runc pod kernel: ${RUNC_KERNEL} -- matches the host, as it must. The comparison above is meaningful."
  else
    warn "The runc control reported '${RUNC_KERNEL}' but the host node reports '${HOST_KERNEL}'. The control did not behave as expected, so treat the Kata result above as unconfirmed."
  fi
else
  warn "Could not start the runc control pod; the Kata kernel comparison is unconfirmed."
fi

###############################################################################
# 9. Verdict
###############################################################################

step "Verdict"
ok "Kata Containers ${KATA_CHART_VERSION} with Cloud Hypervisor is installed and verified."
info "Run a workload in a VM by adding to its pod spec:"
info "    runtimeClassName: ${RUNTIME_CLASS}"
warn "k8s/apps/runner.yaml still has NO runtimeClassName, so the agent runner is still a runc container sharing the host kernel. Move it with: scripts/verify-microvm.sh --migrate"
info "Uninstall with: scripts/install-kata.sh --delete"
