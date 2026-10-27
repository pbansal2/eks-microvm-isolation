#!/usr/bin/env bash
#
# connect.sh -- point kubectl at the cluster, whichever way it is reachable.
#
# Usage:
#   scripts/connect.sh                # connect (tunnel runs in the foreground)
#   scripts/connect.sh --background   # private endpoint: tunnel in the background
#   scripts/connect.sh --status       # is kubectl able to reach the API right now?
#   scripts/connect.sh --stop         # stop a background tunnel
#
# Environment overrides:
#   CLUSTER_NAME   default secure-agent-sandbox  (terraform var.cluster_name)
#   CLUSTER_REGION default: terraform output `region`, else us-east-1.
#                  AWS_REGION / AWS_DEFAULT_REGION are deliberately IGNORED --
#                  an ambient region from another project would otherwise
#                  send every call to the wrong region.
#   AWS_PROFILE    passed through to aws and written into the kubeconfig
#   LOCAL_PORT     tunnel port on 127.0.0.1 (default 8443)
#
# What it does depends on how the cluster's API endpoint is exposed, which it
# reads from EKS rather than assuming:
#
#   public endpoint   `aws eks update-kubeconfig`, then verifies kubectl. If
#                     that times out, your egress IP is almost certainly not
#                     in cluster_endpoint_public_access_cidrs.
#
#   private endpoint  There is no route from a laptop to a private endpoint.
#                     It finds a running node, opens an SSM port-forward from
#                     127.0.0.1:LOCAL_PORT to the endpoint through that node,
#                     and rewrites the kubeconfig to use it -- keeping
#                     tls-server-name set to the real hostname so the
#                     certificate still validates. No SSH, no bastion, no
#                     inbound security-group rule.
#
# The tunnel ENDS when its terminal closes, its session times out, or the
# laptop sleeps. When kubectl then fails with
#   "dial tcp 127.0.0.1:8443: connect: connection refused"
# just run this script again. Nothing is wrong with the cluster.
#
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-secure-agent-sandbox}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Not AWS_REGION: a shell exporting AWS_REGION=us-west-2 for unrelated work
# made the first version of this script look for the cluster in the wrong
# region and report it missing.
if [[ -n "${CLUSTER_REGION:-}" ]]; then
  REGION="$CLUSTER_REGION"
elif command -v terraform >/dev/null 2>&1 \
     && TF_REGION="$(terraform -chdir="${REPO_ROOT}/terraform" output -raw region 2>/dev/null)" \
     && [[ "$TF_REGION" =~ ^[a-z]{2}-[a-z]+-[0-9]$ ]]; then
  REGION="$TF_REGION"
else
  REGION="us-east-1"
fi
LOCAL_PORT="${LOCAL_PORT:-8443}"
STATE_DIR="${TMPDIR:-/tmp}"
PID_FILE="${STATE_DIR%/}/sas-tunnel-${CLUSTER_NAME}.pid"
LOG_FILE="${STATE_DIR%/}/sas-tunnel-${CLUSTER_NAME}.log"

MODE="connect"
BACKGROUND=0

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --background) BACKGROUND=1 ;;
    --status)     MODE="status" ;;
    --stop)       MODE="stop" ;;
    -h|--help)    sed -n '3,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)            fail "Unknown argument '$1'. Try --help." ;;
  esac
  shift
done

# Base aws command as an array, so it can be both called and exec'd.
AWS_BASE=(aws --region "$REGION")
[[ -n "${AWS_PROFILE:-}" ]] && AWS_BASE+=(--profile "$AWS_PROFILE")
aws_() { "${AWS_BASE[@]}" "$@"; }

# True if something accepts TCP connections on 127.0.0.1:$1. Uses bash's
# /dev/tcp so it needs neither lsof (macOS) nor ss (Linux).
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

api_ok() { kubectl version --request-timeout=8s -o json >/dev/null 2>&1; }

stop_tunnel() {
  if [[ -f "$PID_FILE" ]]; then
    local pid; pid="$(cat "$PID_FILE")"
    # aws spawns session-manager-plugin as a child; stop it too, or the port
    # stays held by an orphan.
    pkill -P "$pid" 2>/dev/null || true
    kill "$pid" 2>/dev/null || true
    rm -f "$PID_FILE"
    ok "Stopped background tunnel (pid ${pid})."
  else
    info "No background tunnel recorded at ${PID_FILE}."
  fi
}

###############################################################################

if [[ "$MODE" == "stop" ]]; then
  stop_tunnel
  exit 0
fi

if [[ "$MODE" == "status" ]]; then
  SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  info "kubectl context: $(kubectl config current-context 2>/dev/null || echo '<none>')"
  info "API server:      ${SERVER:-<none>}"
  if api_ok; then ok "kubectl can reach the API."; exit 0; fi
  case "$SERVER" in
    *localhost*|*127.0.0.1*) fail "Not reachable. The SSM tunnel is down -- run scripts/connect.sh again." ;;
    *)                       fail "Not reachable. Run scripts/connect.sh." ;;
  esac
fi

step "Preflight"
for tool in aws kubectl; do
  command -v "$tool" >/dev/null 2>&1 || fail "'${tool}' not found on PATH. See README.md, Prerequisites."
done
IDENTITY="$(aws_ sts get-caller-identity --query Arn --output text 2>&1)" \
  || fail "AWS credentials are not usable: ${IDENTITY}
         Configure them (aws configure / aws sso login / set AWS_PROFILE) and retry."
ok "AWS identity: ${IDENTITY}"

CLUSTER_JSON="$(aws_ eks describe-cluster --name "$CLUSTER_NAME" \
  --query 'cluster.{status:status,endpoint:endpoint,public:resourcesVpcConfig.endpointPublicAccess,private:resourcesVpcConfig.endpointPrivateAccess}' \
  --output json 2>&1)" \
  || fail "Cannot describe cluster '${CLUSTER_NAME}' in ${REGION}: ${CLUSTER_JSON}
         Has 'terraform apply' finished? Is CLUSTER_NAME / AWS_REGION right?"
field() { printf '%s' "$CLUSTER_JSON" | python3 -I -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
STATUS="$(field status)"; ENDPOINT="$(field endpoint)"; PUBLIC="$(field public)"
ENDPOINT_HOST="${ENDPOINT#https://}"
[[ "$STATUS" == "ACTIVE" ]] || fail "Cluster ${CLUSTER_NAME} is ${STATUS}, not ACTIVE."
ok "Cluster ${CLUSTER_NAME} is ACTIVE; public endpoint: ${PUBLIC}."

KUBECONFIG_ARGS=(eks update-kubeconfig --name "$CLUSTER_NAME")

###############################################################################
# Public endpoint
###############################################################################

if [[ "$PUBLIC" == "True" || "$PUBLIC" == "true" ]]; then
  step "Public endpoint: updating kubeconfig"
  aws_ "${KUBECONFIG_ARGS[@]}" >/dev/null
  if api_ok; then
    ok "kubectl is connected:"
    kubectl get nodes 2>&1 | sed 's/^/      /'
    exit 0
  fi
  EGRESS="$(curl -s --max-time 8 https://checkip.amazonaws.com 2>/dev/null | tr -d '[:space:]' || true)"
  ALLOWED="$(aws_ eks describe-cluster --name "$CLUSTER_NAME" \
    --query 'cluster.resourcesVpcConfig.publicAccessCidrs' --output text 2>/dev/null || true)"
  fail "kubeconfig updated, but the API did not answer.
         Your egress IP:    ${EGRESS:-unknown}
         Allowed by EKS:    ${ALLOWED:-unknown}
         If your IP is not in that list, add it to
         cluster_endpoint_public_access_cidrs in terraform/terraform.tfvars and
         re-apply -- egress IPs rotate (terraform/ISSUES-ENCOUNTERED.md issue 6)."
fi

###############################################################################
# Private endpoint -- SSM port-forward through a node
###############################################################################

step "Private endpoint: SSM port-forward"

command -v session-manager-plugin >/dev/null 2>&1 \
  || fail "The private endpoint needs the AWS Session Manager plugin, which is not installed:
         https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html"

INSTANCE="$(aws_ ec2 describe-instances \
  --filters "Name=tag:eks:cluster-name,Values=${CLUSTER_NAME}" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null | awk '{print $1}')"
[[ -n "$INSTANCE" && "$INSTANCE" != "None" ]] \
  || fail "No running node found for ${CLUSTER_NAME}. The tunnel goes through a node, so one must be running."
PING="$(aws_ ssm describe-instance-information --filters "Key=InstanceIds,Values=${INSTANCE}" \
  --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null || true)"
[[ "$PING" == "Online" ]] \
  || fail "Node ${INSTANCE} is not Online in SSM (status: ${PING:-unknown}). It may still be booting."
ok "Tunnelling via node ${INSTANCE} (SSM Online)."

# Kubeconfig first: update-kubeconfig writes the user/exec credentials, then
# the cluster entry is pointed at the local end of the tunnel.
aws_ "${KUBECONFIG_ARGS[@]}" >/dev/null
CLUSTER_ENTRY="$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')"
kubectl config set-cluster "$CLUSTER_ENTRY" \
  --server="https://localhost:${LOCAL_PORT}" \
  --tls-server-name="$ENDPOINT_HOST" >/dev/null
ok "kubeconfig points at https://localhost:${LOCAL_PORT} (TLS name ${ENDPOINT_HOST})."

if port_open "$LOCAL_PORT"; then
  if api_ok; then
    ok "A tunnel is already up on 127.0.0.1:${LOCAL_PORT} and kubectl is connected."
    exit 0
  fi
  fail "Something else is listening on 127.0.0.1:${LOCAL_PORT}. Stop it, or pick another port with LOCAL_PORT=8444."
fi

SSM_ARGS=(ssm start-session --target "$INSTANCE"
  --document-name AWS-StartPortForwardingSessionToRemoteHost
  --parameters "{\"host\":[\"${ENDPOINT_HOST}\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"${LOCAL_PORT}\"]}")

if [[ "$BACKGROUND" -eq 0 ]]; then
  info "Starting the tunnel in the FOREGROUND. Leave this terminal open; use another for kubectl."
  info "Ctrl-C stops it. Use --background to run it detached instead."
  exec "${AWS_BASE[@]}" "${SSM_ARGS[@]}"
fi

# Background: detach stdin and record the pid so --stop can find it.
nohup "${AWS_BASE[@]}" "${SSM_ARGS[@]}" >"$LOG_FILE" 2>&1 </dev/null &
echo $! > "$PID_FILE"
disown 2>/dev/null || true

for _ in $(seq 1 20); do
  sleep 1
  port_open "$LOCAL_PORT" && break
done
port_open "$LOCAL_PORT" || { cat "$LOG_FILE" >&2; fail "Tunnel did not open within 20s. Log above."; }

for _ in $(seq 1 10); do api_ok && break; sleep 1; done
api_ok || fail "Tunnel is listening but kubectl cannot reach the API. Log: ${LOG_FILE}"

ok "Tunnel up in the background (pid $(cat "$PID_FILE"), log ${LOG_FILE})."
kubectl get nodes 2>&1 | sed 's/^/      /'
info "Stop it with: scripts/connect.sh --stop"
