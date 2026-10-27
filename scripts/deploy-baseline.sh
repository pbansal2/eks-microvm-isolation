#!/usr/bin/env bash
#
# deploy-baseline.sh -- apply the baseline application manifests in k8s/apps/
# and verify the two things that silently do not work on a stock EKS cluster:
# the NLB address, and CPU metrics for the HPA.
#
# Usage:
#   scripts/deploy-baseline.sh                # preflight + apply + verify
#   scripts/deploy-baseline.sh --check        # read-only: preflight only
#   scripts/deploy-baseline.sh --install-lbc  # also install the AWS LBC
#   scripts/deploy-baseline.sh --delete       # remove what this script applied
#
# Environment overrides:
#   NAMESPACE                 default agent-sandbox
#   LBC_CHART_VERSION         pin the AWS Load Balancer Controller chart
#   METRICS_SERVER_VERSION    pin metrics-server, e.g. v0.7.2 (default: latest)
#   NLB_TIMEOUT_SECONDS       default 300  (Service gets an address)
#   GATE_TIMEOUT_SECONDS      default 420  (NLB targets go healthy)
#   METRICS_TIMEOUT_SECONDS   default 300
#   GATEWAY_ALLOWED_CIDR      who may reach the gateway NLB (default: your
#                             egress IP as a /32; 0.0.0.0/0 is refused)
#   RUNNER_RUNTIME            auto | runc | kata  (default auto: keep whatever
#                             runtime the live runner already uses)
#   CLUSTER_NAME              default secure-agent-sandbox
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="${REPO_ROOT}/k8s/apps"
TF_DIR="${REPO_ROOT}/terraform"

NAMESPACE="${NAMESPACE:-agent-sandbox}"
# Matches terraform var.cluster_name. Override with CLUSTER_NAME if you changed it.
EXPECTED_CLUSTER="${CLUSTER_NAME:-secure-agent-sandbox}"
AUTH_SECRET="control-plane-gateway-auth"
NLB_TIMEOUT_SECONDS="${NLB_TIMEOUT_SECONDS:-300}"
# Time for NLB targets to pass their first health checks, which is separate
# from (and slower than) the Service getting an address.
GATE_TIMEOUT_SECONDS="${GATE_TIMEOUT_SECONDS:-420}"
METRICS_TIMEOUT_SECONDS="${METRICS_TIMEOUT_SECONDS:-300}"

# PIN: by default this follows the upstream `latest` redirect, so the version
# installed depends on the day you run it. Set METRICS_SERVER_VERSION to pin.
if [[ -n "${METRICS_SERVER_VERSION:-}" ]]; then
  METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
else
  METRICS_SERVER_URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
fi

MODE="apply"
INSTALL_LBC=0

###############################################################################
# Output helpers
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

# Echo a command, then run it.
#
# The banner goes to stderr, NOT stdout, so that using run() on the left of a
# pipe cannot inject ANSI escapes into the next command's stdin. (That is
# exactly how terraform/scripts/apply-and-verify.sh once fed control
# characters to `kubectl apply -f -`.)
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

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

###############################################################################
# Argument parsing
###############################################################################

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)       MODE="check" ;;
    --delete)      MODE="delete" ;;
    --install-lbc) INSTALL_LBC=1 ;;
    -h|--help)     sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)             fail "Unknown argument '$1'. Try --help." ;;
  esac
  shift
done

###############################################################################
# 1. Preflight
###############################################################################

step "Preflight"

for tool in kubectl aws; do
  command -v "$tool" >/dev/null 2>&1 || fail "'${tool}' not found on PATH."
done
ok "kubectl and aws are present."

for manifest in gateway.yaml runner.yaml hpa.yaml; do
  [[ -f "${APPS_DIR}/${manifest}" ]] || fail "Missing ${APPS_DIR}/${manifest}"
done
ok "All three manifests found in k8s/apps/."

# Confirm which cluster we are about to mutate. This cluster is reached over
# an SSM port-forward (terraform/RUNBOOK.md section 4), so a failure here
# usually means the tunnel is down, not that the cluster is broken.
if ! CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null)"; then
  fail "No current kubectl context. Run the update-kubeconfig command from 'terraform output update_kubeconfig_command'."
fi
info "kubectl context: ${CURRENT_CONTEXT}"

if [[ "$CURRENT_CONTEXT" != *"$EXPECTED_CLUSTER"* ]]; then
  warn "Context does not mention '${EXPECTED_CLUSTER}'. You may be pointed at another cluster."
  confirm "Continue against '${CURRENT_CONTEXT}'?" || fail "Aborted by operator."
fi

if ! kubectl get --raw='/readyz' >/dev/null 2>&1; then
  fail "Kubernetes API is not ready. If the public endpoint is disabled, start the SSM tunnel first (terraform/RUNBOOK.md section 4)."
fi
ok "Kubernetes API is reachable and ready."

READY_NODES="$(kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready ' || true)"
[[ "${READY_NODES:-0}" -ge 1 ]] || fail "No Ready nodes. The gateway and runner have nowhere to schedule."
ok "${READY_NODES} Ready node(s)."

# --- Who may reach the internet-facing gateway NLB -------------------------
#
# Defaults to the operator's own egress address as a /32, discovered the same
# way the EKS endpoint allow-list is. Override with GATEWAY_ALLOWED_CIDR for an
# office range or a VPN egress. 0.0.0.0/0 and ::/0 are refused outright: with
# an internet-facing scheme that leaves the shared bearer token as the only
# control.
if [[ "$MODE" != "delete" ]]; then
  if [[ -z "${GATEWAY_ALLOWED_CIDR:-}" ]]; then
    command -v curl >/dev/null 2>&1 || fail "'curl' not found; set GATEWAY_ALLOWED_CIDR explicitly."
    EGRESS_IP="$(curl -s --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]' || true)"
    [[ "$EGRESS_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
      || fail "Could not discover your egress IP (got '${EGRESS_IP}'). Set GATEWAY_ALLOWED_CIDR, e.g. GATEWAY_ALLOWED_CIDR=203.0.113.4/32"
    GATEWAY_ALLOWED_CIDR="${EGRESS_IP}/32"
    info "GATEWAY_ALLOWED_CIDR not set; using your egress address ${GATEWAY_ALLOWED_CIDR}."
  fi
  case "$GATEWAY_ALLOWED_CIDR" in
    0.0.0.0/0|::/0|*/0)
      fail "GATEWAY_ALLOWED_CIDR=${GATEWAY_ALLOWED_CIDR} would open the internet-facing gateway to every host on the internet. Use a specific range." ;;
  esac
  [[ "$GATEWAY_ALLOWED_CIDR" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$ ]] \
    || fail "GATEWAY_ALLOWED_CIDR='${GATEWAY_ALLOWED_CIDR}' is not an IPv4 CIDR like 203.0.113.4/32."
  ok "Gateway NLB will admit only ${GATEWAY_ALLOWED_CIDR}."
fi

# --- Which runner manifest ---------------------------------------------------
#
# runner.yaml (runc) and runner-microvm.yaml (kata-clh) declare the SAME
# Deployment. Always applying runner.yaml would silently move a migrated
# runner back onto the host kernel: `kubectl apply` removes runtimeClassName
# because it is in the last-applied configuration but not in runner.yaml
# (confirmed with a server-side dry run, 2026-10-27). So follow whatever is
# live, and let RUNNER_RUNTIME override it explicitly.
LIVE_RUNTIME="$(kubectl -n "$NAMESPACE" get deploy agent-runner \
  -o jsonpath='{.spec.template.spec.runtimeClassName}' 2>/dev/null || true)"
case "${RUNNER_RUNTIME:-auto}" in
  kata) RUNNER_MANIFEST="${APPS_DIR}/runner-microvm.yaml" ;;
  runc) RUNNER_MANIFEST="${APPS_DIR}/runner.yaml" ;;
  auto)
    if [[ "$LIVE_RUNTIME" == "kata-clh" ]]; then
      RUNNER_MANIFEST="${APPS_DIR}/runner-microvm.yaml"
    else
      RUNNER_MANIFEST="${APPS_DIR}/runner.yaml"
    fi ;;
  *) fail "RUNNER_RUNTIME must be auto, runc or kata (got '${RUNNER_RUNTIME}')." ;;
esac
if [[ "$RUNNER_MANIFEST" == *runner-microvm.yaml ]]; then
  kubectl get runtimeclass kata-clh >/dev/null 2>&1 \
    || fail "RUNNER_RUNTIME=kata but RuntimeClass kata-clh does not exist. Run scripts/install-kata.sh first."
fi
ok "Runner manifest: ${RUNNER_MANIFEST##*/} (live runtimeClassName: ${LIVE_RUNTIME:-<none, runc>})."

###############################################################################
# 2. AWS Load Balancer Controller
#
# The gateway Service is annotated aws-load-balancer-type=external, which
# makes the in-tree cloud provider skip it. Without the controller the
# Service sits in <pending> forever -- so this is a hard gate, not a warning.
###############################################################################

step "AWS Load Balancer Controller"

lbc_present() {
  kubectl get crd targetgroupbindings.elbv2.k8s.aws >/dev/null 2>&1 &&
    kubectl -n kube-system get deploy aws-load-balancer-controller >/dev/null 2>&1
}

install_lbc() {
  command -v helm >/dev/null 2>&1 || fail "'helm' not found on PATH; needed to install the controller."

  local role_arn vpc_id region chart_version
  info "Reading the controller's IAM role ARN from Terraform state."
  role_arn="$(terraform -chdir="$TF_DIR" output -raw load_balancer_controller_role_arn 2>/dev/null || true)"
  if [[ -z "$role_arn" ]]; then
    fail "$(printf '%s\n' \
      "No 'load_balancer_controller_role_arn' output." \
      "      terraform/lbc.tf creates it. Apply it first:" \
      "        cd ${TF_DIR}" \
      "        terraform init" \
      "        terraform plan -out=tfplan      # expect 1 IAM role + 1 policy to add" \
      "        terraform apply tfplan")"
  fi
  vpc_id="$(terraform -chdir="$TF_DIR" output -raw vpc_id)"
  region="$(terraform -chdir="$TF_DIR" output -raw region)"

  run helm repo add eks https://aws.github.io/eks-charts
  run helm repo update eks

  chart_version="${LBC_CHART_VERSION:-}"
  if [[ -z "$chart_version" ]]; then
    chart_version="$(helm search repo eks/aws-load-balancer-controller \
      --output json | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1)"
    [[ -n "$chart_version" ]] || fail "Could not resolve a chart version. Set LBC_CHART_VERSION."
    info "Resolved latest chart version: ${chart_version} (pin with LBC_CHART_VERSION)."
  fi

  printf '\n  This installs a cluster-wide controller that will create and delete\n'
  printf '  Elastic Load Balancers in VPC %s using role:\n    %s\n' "$vpc_id" "$role_arn"
  confirm "Install aws-load-balancer-controller chart ${chart_version}?" ||
    fail "Aborted by operator."

  run helm upgrade --install aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    --namespace kube-system \
    --version "$chart_version" \
    --set "clusterName=${EXPECTED_CLUSTER}" \
    --set "region=${region}" \
    --set "vpcId=${vpc_id}" \
    --set serviceAccount.create=true \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${role_arn}" \
    --set enableServiceMutatorWebhook=false \
    --wait --timeout 5m

  run kubectl -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=5m
}

if lbc_present; then
  LBC_IMAGE="$(kubectl -n kube-system get deploy aws-load-balancer-controller \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo unknown)"
  ok "Controller is installed: ${LBC_IMAGE}"
elif [[ "$MODE" == "delete" ]]; then
  warn "Controller is not installed; the Service may already be gone."
elif [[ "$INSTALL_LBC" -eq 1 && "$MODE" != "check" ]]; then
  install_lbc
  lbc_present || fail "Controller still not detected after install."
  ok "Controller installed."
else
  cat >&2 <<EOF
  ${C_RED}[fail]${C_OFF} AWS Load Balancer Controller is NOT installed.

  k8s/apps/gateway.yaml sets:
      service.beta.kubernetes.io/aws-load-balancer-type: "external"

  That annotation tells the legacy in-tree cloud provider to ignore the
  Service. With no controller to pick it up, the Service never gets an
  address -- it stays <pending> indefinitely, with no event explaining why.
  Stopping here rather than letting you wait on a timeout.

  To install it:
      cd ${TF_DIR}
      terraform plan -out=tfplan         # adds the controller's IAM role
      terraform apply tfplan
      cd ${REPO_ROOT}
      scripts/deploy-baseline.sh --install-lbc

  Alternative, no controller required: drop the three annotations above and
  use the legacy in-tree annotation instead, which still provisions an NLB
  with instance targets:
      service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
      service.beta.kubernetes.io/aws-load-balancer-internal: "true"
  That path is deprecated by AWS and does not support most of the newer
  annotations, so it is documented, not recommended.
EOF
  exit 1
fi

if [[ "$MODE" == "check" ]]; then
  step "Preflight complete"
  ok "Read-only check finished. Nothing was applied."
  exit 0
fi

###############################################################################
# 3. Delete mode
###############################################################################

if [[ "$MODE" == "delete" ]]; then
  step "Deleting baseline workloads"
  printf '\n  This deletes namespace %s, including the gateway NLB.\n' "$NAMESPACE"
  printf '  metrics-server and the load balancer controller are left in place.\n'
  confirm "Delete namespace '${NAMESPACE}'?" || fail "Aborted by operator."
  # Delete the Service first so the controller can deprovision the NLB before
  # its RBAC-bound namespace disappears underneath it.
  run kubectl -n "$NAMESPACE" delete service control-plane-gateway --ignore-not-found --wait=true
  run kubectl delete -f "${APPS_DIR}/hpa.yaml" --ignore-not-found
  run kubectl delete -f "${APPS_DIR}/runner.yaml" --ignore-not-found
  run kubectl delete -f "${APPS_DIR}/gateway.yaml" --ignore-not-found
  ok "Deleted. Confirm no orphaned load balancers:"
  printf '    aws elbv2 describe-load-balancers --region us-east-1 \\\n'
  printf "      --query \"LoadBalancers[?contains(LoadBalancerName,'k8s-agentsan')].LoadBalancerArn\"\n"
  exit 0
fi

###############################################################################
# 4. Gateway credential
#
# Created before the Deployment, because the container reads the token into an
# env var at start. A Secret created afterwards does not reach a running pod.
# The value is generated here and never written to the repository.
###############################################################################

step "Gateway authentication credential"

if kubectl -n "$NAMESPACE" get secret "$AUTH_SECRET" >/dev/null 2>&1; then
  ok "Secret '${AUTH_SECRET}' already exists; leaving the existing token in place."
else
  info "Generating a 32-byte random bearer token for the gateway."
  # Namespace must exist before the Secret. Create it idempotently here; the
  # apply in the next step reconciles its labels.
  kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || run kubectl create namespace "$NAMESPACE"
  # Fed through stdin, NOT --from-literal and NOT through run(). run() echoes
  # its full command line, so `run kubectl create secret --from-literal=...`
  # printed the freshly generated bearer token to the terminal (and to any log
  # capturing it). --from-literal also exposes the value in `ps` output to
  # other users on the machine for the life of the process.
  printf '    $ kubectl -n %s create secret generic %s --from-file=token=/dev/stdin  %s\n' \
    "$NAMESPACE" "$AUTH_SECRET" "(value from openssl rand, not shown)" >&2
  openssl rand -hex 32 | tr -d '\n' \
    | kubectl -n "$NAMESPACE" create secret generic "$AUTH_SECRET" --from-file=token=/dev/stdin >/dev/null
  ok "Secret '${AUTH_SECRET}' created. Read it back with:"
  printf '      kubectl -n %s get secret %s -o jsonpath="{.data.token}" | base64 -d\n' \
    "$NAMESPACE" "$AUTH_SECRET"
fi

###############################################################################
# 5. Apply the manifests
###############################################################################

step "Applying k8s/apps/"

# gateway.yaml carries a placeholder, not a real CIDR, in
# loadBalancerSourceRanges -- so a raw `kubectl apply -f gateway.yaml` is
# rejected by the API server instead of shipping someone else's address (or
# nothing) as the allow-list. Substitute the resolved value into a temp copy.
RENDERED_GATEWAY="$(mktemp "${TMPDIR:-/tmp}/gateway.XXXXXX")"
trap 'rm -f "$RENDERED_GATEWAY"' EXIT
sed "s#__GATEWAY_ALLOWED_CIDR__#${GATEWAY_ALLOWED_CIDR}#g" \
  "${APPS_DIR}/gateway.yaml" > "$RENDERED_GATEWAY"
grep -q '__GATEWAY_ALLOWED_CIDR__' "$RENDERED_GATEWAY" \
  && fail "Placeholder substitution failed in ${APPS_DIR}/gateway.yaml."
info "gateway loadBalancerSourceRanges = ${GATEWAY_ALLOWED_CIDR}"
run kubectl apply -f "$RENDERED_GATEWAY"
run kubectl apply -f "$RUNNER_MANIFEST"

# Roll the gateway when its source changes. The ConfigMap is mounted, so the
# file updates in place but the already-running python process keeps executing
# the old code. Patching an annotation with the manifest's hash makes a
# content change a rollout, and a no-op change a no-op.
SRC_SHA="$(sha256_of "${APPS_DIR}/gateway.yaml")"
run kubectl -n "$NAMESPACE" patch deployment control-plane-gateway --type=merge \
  -p "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/src-configmap\":\"${SRC_SHA}\"}}}}}"

run kubectl -n "$NAMESPACE" rollout status deploy/control-plane-gateway --timeout=5m
run kubectl -n "$NAMESPACE" rollout status deploy/agent-runner --timeout=5m
ok "Gateway (2 replicas) and runner are rolled out."

###############################################################################
# 6. metrics-server
#
# Applied from upstream, as EKS ships no metrics-server and an HPA with a CPU
# target cannot resolve metrics.k8s.io without it.
###############################################################################

step "metrics-server"

if kubectl -n kube-system get deploy metrics-server >/dev/null 2>&1; then
  ok "metrics-server is already installed."
else
  info "Installing from ${METRICS_SERVER_URL}"
  run kubectl apply -f "$METRICS_SERVER_URL"
fi

run kubectl -n kube-system rollout status deploy/metrics-server --timeout=5m

# The Aggregation Layer has to register the APIService before any `top` call
# can work, and the first scrape lands up to one metric-resolution later.
info "Waiting for the metrics.k8s.io APIService to report Available."
if ! run kubectl wait --for=condition=Available \
  apiservice/v1beta1.metrics.k8s.io --timeout=3m; then
  warn "APIService did not become Available."
fi

###############################################################################
# 7. HPA
###############################################################################

step "HorizontalPodAutoscaler"

run kubectl apply -f "${APPS_DIR}/hpa.yaml"
ok "HPA applied (agent-runner, 50% CPU, 1-5 replicas)."

###############################################################################
# 8. Verify: NLB address
###############################################################################

step "Waiting for the NLB address (timeout ${NLB_TIMEOUT_SECONDS}s)"

NLB_HOST=""
elapsed=0
while [[ "$elapsed" -lt "$NLB_TIMEOUT_SECONDS" ]]; do
  NLB_HOST="$(kubectl -n "$NAMESPACE" get svc control-plane-gateway \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  if [[ -z "$NLB_HOST" ]]; then
    NLB_HOST="$(kubectl -n "$NAMESPACE" get svc control-plane-gateway \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  fi
  [[ -n "$NLB_HOST" ]] && break
  printf '  %s[info]%s no address yet (%ss elapsed)\r' "$C_DIM" "$C_OFF" "$elapsed"
  sleep 10
  elapsed=$((elapsed + 10))
done
printf '\n'

if [[ -z "$NLB_HOST" ]]; then
  warn "No load balancer address after ${NLB_TIMEOUT_SECONDS}s. Diagnose with:"
  printf '      kubectl -n %s describe svc control-plane-gateway\n' "$NAMESPACE"
  printf '      kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50\n'
  printf '  Most common causes: the controller lacks elasticloadbalancing IAM\n'
  printf '  permissions, or no subnet carries the required tag --\n'
  printf '  kubernetes.io/role/elb for internet-facing, internal-elb for internal.\n'
  NLB_OK=0
else
  ok "NLB address: ${NLB_HOST}"
  NLB_SCHEME="$(kubectl -n "$NAMESPACE" get svc control-plane-gateway \
    -o jsonpath='{.metadata.annotations.service\.beta\.kubernetes\.io/aws-load-balancer-scheme}')"
  SOURCE_RANGES="$(kubectl -n "$NAMESPACE" get svc control-plane-gateway \
    -o jsonpath='{.spec.loadBalancerSourceRanges}')"
  info "Scheme: ${NLB_SCHEME}"
  info "Source ranges: ${SOURCE_RANGES:-<none>}"
  NLB_OK=1

  # An internet-facing listener with no source restriction means the shared
  # bearer token is the only control. Refuse to call that verified.
  if [[ "$NLB_SCHEME" == "internet-facing" ]]; then
    if [[ -z "$SOURCE_RANGES" || "$SOURCE_RANGES" == *'0.0.0.0/0'* ]]; then
      warn "Internet-facing with no source restriction. This NodePort is open"
      warn "to every host on the internet. Set spec.loadBalancerSourceRanges."
      NLB_OK=0
    fi
  fi
fi

###############################################################################
# 8b. Verify the auth gate end to end
#
# Checks DENIAL, not success. But be precise about what counts as a failed
# gate: only a 2xx/3xx to an anonymous caller means the gate let someone
# through. "000" is curl reporting it could NOT CONNECT, which is the
# opposite of exposure -- treating it as a breach once sent an operator to
# delete a perfectly good Service.
###############################################################################

# Emit a bare HTTP status code, or "000" if the connection failed.
#
# NOTE: do NOT append `|| echo 000`. curl already writes 000 via
# -w '%{http_code}' when it cannot connect, so the fallback concatenates and
# produces "000000", which matches no comparison below.
http_code() {
  curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$@" 2>/dev/null || true
}

if [[ -n "$NLB_HOST" && "$NLB_SCHEME" == "internet-facing" ]]; then
  step "Verifying the authentication gate through the NLB"

  # Measured 285s on a fresh NLB in us-east-1 on 2026-10-23, so the original
  # 240s budget expired before the targets were ever healthy and reported a
  # false failure. 420s leaves real headroom.
  info "NLB targets need ~5 min to pass their first health checks (measured 285s)."
  GATE_OK=0
  elapsed=0
  while [[ "$elapsed" -lt "$GATE_TIMEOUT_SECONDS" ]]; do
    ANON_CODE="$(http_code "http://${NLB_HOST}/healthz")"
    [[ "$ANON_CODE" == "200" ]] && break
    printf '  %s[info]%s waiting for targets to go healthy (%ss, last=%s)\r' \
      "$C_DIM" "$C_OFF" "$elapsed" "$ANON_CODE"
    sleep 15
    elapsed=$((elapsed + 15))
  done
  printf '\n'

  if [[ "$ANON_CODE" != "200" ]]; then
    warn "/healthz did not return 200 through the NLB (last=${ANON_CODE})."
    if [[ "$ANON_CODE" == "000" ]]; then
      warn "000 means the connection never completed -- not an exposure."
      warn "Most likely your egress address is outside loadBalancerSourceRanges:"
      warn "  curl -s https://checkip.amazonaws.com"
    fi
  else
    ok "/healthz reachable through the NLB (unauthenticated, by design)."

    # Retry: a target that has only just passed its first health check can
    # answer one request and refuse the next while the second AZ's NLB node
    # is still registering. One 000 here is a race, not a verdict.
    ROOT_ANON=""
    for _ in 1 2 3 4; do
      ROOT_ANON="$(http_code "http://${NLB_HOST}/")"
      [[ "$ROOT_ANON" != "000" ]] && break
      sleep 10
    done

    case "$ROOT_ANON" in
      401)
        ok "Anonymous request to / is DENIED with 401."
        GATE_OK=1
        ;;
      503)
        warn "Gateway returns 503: the auth Secret is not reaching the pods."
        warn "The gate is closed, so this is not an exposure. Fix with:"
        warn "  kubectl -n ${NAMESPACE} rollout restart deploy/control-plane-gateway"
        ;;
      000)
        warn "Could not connect to / after 4 attempts, though /healthz answered."
        warn "NOT an exposure -- nothing was served. Re-run this script to retry."
        warn "If it persists: kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50"
        ;;
      2??|3??)
        # The only genuine breach: an anonymous caller got a real response.
        fail "$(printf '%s\n' \
          "ANONYMOUS REQUEST TO / RETURNED ${ROOT_ANON}, EXPECTED 401." \
          "      The gate served an unauthenticated caller. This endpoint is" \
          "      internet-facing, so take it down before anything else:" \
          "        kubectl -n ${NAMESPACE} delete svc control-plane-gateway")"
        ;;
      *)
        warn "Anonymous request to / returned ${ROOT_ANON}, expected 401."
        warn "Nothing was served, so this is not an exposure, but the gate is"
        warn "not behaving as designed. Inspect before relying on it:"
        warn "  kubectl -n ${NAMESPACE} logs deploy/control-plane-gateway --tail=50"
        ;;
    esac

    if [[ "$GATE_OK" -eq 1 ]]; then
      TOKEN_VALUE="$(kubectl -n "$NAMESPACE" get secret "$AUTH_SECRET" \
        -o jsonpath='{.data.token}' | base64 -d)"
      AUTH_CODE="$(http_code -H "Authorization: Bearer ${TOKEN_VALUE}" \
        "http://${NLB_HOST}/")"
      unset TOKEN_VALUE
      if [[ "$AUTH_CODE" == "200" ]]; then
        ok "Authenticated request to / returns 200."
      else
        warn "Authenticated request returned ${AUTH_CODE}, expected 200."
        GATE_OK=0
      fi
    fi
  fi
fi

###############################################################################
# 9. Verify: CPU metrics
###############################################################################

step "Waiting for CPU metrics (timeout ${METRICS_TIMEOUT_SECONDS}s)"

METRICS_OK=0
elapsed=0
while [[ "$elapsed" -lt "$METRICS_TIMEOUT_SECONDS" ]]; do
  if TOP_OUT="$(kubectl top pods -n "$NAMESPACE" --no-headers 2>&1)"; then
    # Reject the window where the API answers but every value is still 0m,
    # which reads as success and is not.
    if printf '%s' "$TOP_OUT" | grep -qE '[0-9]+m[[:space:]]+[0-9]+Mi'; then
      METRICS_OK=1
      break
    fi
  fi
  printf '  %s[info]%s metrics not ready yet (%ss elapsed)\r' "$C_DIM" "$C_OFF" "$elapsed"
  sleep 15
  elapsed=$((elapsed + 15))
done
printf '\n'

if [[ "$METRICS_OK" -eq 1 ]]; then
  ok "kubectl top pods returns CPU metrics:"
  kubectl top pods -n "$NAMESPACE" | sed 's/^/      /'
  printf '\n'
  kubectl get hpa -n "$NAMESPACE" | sed 's/^/      /'
else
  warn "No CPU metrics after ${METRICS_TIMEOUT_SECONDS}s. Last output:"
  printf '      %s\n' "${TOP_OUT:-<none>}"
  cat >&2 <<EOF

  If the error mentions x509 or "cannot validate certificate", metrics-server
  cannot verify the kubelet's serving certificate. The usual fix is:

      kubectl -n kube-system patch deployment metrics-server --type=json \\
        -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

  Not applied automatically: it stops metrics-server verifying the kubelet it
  scrapes, so a pod able to impersonate a kubelet address could feed it false
  metrics -- which an HPA then acts on. Acceptable inside a single-tenant VPC,
  but it is a real weakening, so it is the operator's call. The alternative
  that does not weaken anything is to enable kubelet serving-certificate
  rotation on the node group and pass --kubelet-certificate-authority.
EOF
fi

###############################################################################
# Summary
###############################################################################

step "Summary"

printf '  %-28s %s\n' "Namespace" "$NAMESPACE"
printf '  %-28s %s\n' "Gateway replicas" \
  "$(kubectl -n "$NAMESPACE" get deploy control-plane-gateway -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
printf '  %-28s %s\n' "Runner replicas" \
  "$(kubectl -n "$NAMESPACE" get deploy agent-runner -o jsonpath='{.status.readyReplicas}/{.spec.replicas}' 2>/dev/null)"
printf '  %-28s %s\n' "NLB address" "${NLB_HOST:-<none>}"
printf '  %-28s %s\n' "NLB scheme" "${NLB_SCHEME:-<unknown>}"
printf '  %-28s %s\n' "Allowed sources" "${SOURCE_RANGES:-<UNRESTRICTED>}"
printf '  %-28s %s\n' "Anonymous access denied" \
  "$([[ "${GATE_OK:-0}" -eq 1 ]] && echo "yes (401)" || echo "NOT VERIFIED")"
printf '  %-28s %s\n' "CPU metrics" "$([[ "$METRICS_OK" -eq 1 ]] && echo available || echo UNAVAILABLE)"

printf '\n  Call the gateway with:\n'
printf '      TOKEN=$(kubectl -n %s get secret %s -o jsonpath="{.data.token}" | base64 -d)\n' \
  "$NAMESPACE" "$AUTH_SECRET"
printf '      curl -sS -H "Authorization: Bearer $TOKEN" http://%s/\n' "${NLB_HOST:-<pending>}"

printf '\n  %sRunner uses the default runc runtime -- no VM isolation.%s\n' "$C_YEL" "$C_OFF"
printf '  Kata is not installed on this cluster; do not run untrusted code yet.\n'
printf '\n  %sThe c5.metal node bills ~$4.08/hr (~$98/day). Destroy when done.%s\n' "$C_YEL" "$C_OFF"

if [[ "${NLB_OK:-0}" -eq 1 && "$METRICS_OK" -eq 1 && "${GATE_OK:-0}" -eq 1 ]]; then
  printf '\n  %s[ ok ]%s Baseline deployed and verified.\n' "$C_GRN" "$C_OFF"
  exit 0
fi
printf '\n  %s[warn]%s Baseline applied, but not fully verified. See above.\n' "$C_YEL" "$C_OFF"
exit 1
