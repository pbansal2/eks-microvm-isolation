#!/usr/bin/env bash
#
# apply-and-verify.sh -- drive the secure-agent-sandbox Terraform stack.
#
# Modes:
#   ./apply-and-verify.sh            fmt + init + validate + plan   (default, read-only)
#   ./apply-and-verify.sh plan       same as above
#   ./apply-and-verify.sh apply      plan, then apply after explicit confirmation
#   ./apply-and-verify.sh verify     verify an already-applied cluster
#
# Every mutating command is echoed before it runs, and `apply` requires you to
# type the cluster name to confirm. Nothing is destroyed by this script.

set -euo pipefail

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-plan}"
PLAN_FILE="${TF_DIR}/tfplan"
PROBE_NS="kvm-preflight"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '\033[1;32m[ ok ]\033[0m %s\n' "$*"; }

# Echo a command, then run it.
#
# The echo goes to stderr, NOT stdout. If it went to stdout, using run() on the
# left of a pipe would inject the banner and its ANSI escapes into the next
# command's stdin -- which is exactly how the probe Job once failed with
# "error converting YAML to JSON: yaml: control characters are not allowed".
run() {
  printf '\033[2m    $ %s\033[0m\n' "$*" >&2
  "$@"
}

###############################################################################
# Preflight
###############################################################################

preflight() {
  info "Checking tooling"
  for bin in terraform aws kubectl jq; do
    command -v "$bin" >/dev/null 2>&1 || fail "'$bin' not found on PATH."
  done

  local tf_version
  tf_version="$(terraform version -json | jq -r .terraform_version)"
  ok "terraform ${tf_version}, aws $(aws --version 2>&1 | cut -d' ' -f1 | cut -d/ -f2)"

  info "Checking AWS identity"
  local ident
  ident="$(aws sts get-caller-identity --output json)" \
    || fail "No usable AWS credentials. Refresh your session and retry."

  local account arn
  account="$(jq -r .Account <<<"$ident")"
  arn="$(jq -r .Arn <<<"$ident")"
  ok "account ${account}"
  ok "principal ${arn}"

  # This identity becomes cluster admin via enable_cluster_creator_admin_permissions.
  if grep -qiE 'admin|poweruser' <<<"$arn"; then
    warn "This is a broadly-privileged principal. It will be recorded as the"
    warn "cluster's admin access entry. Prefer a least-privilege role if the"
    warn "cluster will outlive this session."
  fi

  if grep -qiE 'prod' <<<"$arn$account"; then
    fail "Principal or account looks production. Refusing to continue automatically."
  fi

  # Nudge the operator toward a scoped API allow-list.
  if [[ ! -f "${TF_DIR}/terraform.tfvars" ]]; then
    warn "No terraform.tfvars found. cluster_endpoint_public_access_cidrs has no"
    warn "default and the plan will fail closed until you set it. Your current"
    warn "egress address is: $(curl -fsS --max-time 5 https://checkip.amazonaws.com 2>/dev/null || echo '<lookup failed>')"
    warn "Copy terraform.tfvars.example to terraform.tfvars and fill it in."
  fi
}

###############################################################################
# Plan
###############################################################################

do_plan() {
  cd "$TF_DIR"

  info "Formatting"
  run terraform fmt -recursive

  info "Initializing"
  run terraform init -input=false -upgrade

  info "Validating"
  run terraform validate

  ok "Configuration is valid."

  info "Planning"
  run terraform plan -input=false -out="$PLAN_FILE"

  bold ""
  bold "Plan written to ${PLAN_FILE}"
  bold "Review it, then apply with either:"
  bold "    cd ${TF_DIR} && terraform apply tfplan"
  bold "    ${BASH_SOURCE[0]} apply"
}

###############################################################################
# Apply
###############################################################################

do_apply() {
  cd "$TF_DIR"
  do_plan

  local cluster
  cluster="$(terraform console <<<'var.cluster_name' 2>/dev/null | tr -d '"' || echo 'secure-agent-sandbox')"

  bold ""
  warn "About to CREATE real AWS infrastructure: a VPC, a NAT Gateway, an EKS"
  warn "control plane, and a ${cluster} node group on a bare metal instance."
  warn "A c5.metal node is roughly \$4.08/hour on-demand in us-east-1, plus"
  warn "~\$0.10/hour for the EKS control plane and ~\$0.045/hour for the NAT."
  bold ""
  read -r -p "Type the cluster name '${cluster}' to proceed: " answer
  [[ "$answer" == "$cluster" ]] || fail "Confirmation did not match. Nothing applied."

  info "Applying"
  run terraform apply -input=false "$PLAN_FILE"

  ok "Apply complete."
  do_verify
}

###############################################################################
# Verify
###############################################################################

do_verify() {
  cd "$TF_DIR"

  local region cluster
  region="$(terraform output -raw region 2>/dev/null || echo 'us-east-1')"
  cluster="$(terraform output -raw cluster_name)" \
    || fail "No cluster in state. Run '$0 apply' first."

  info "Writing kubeconfig"
  run aws eks update-kubeconfig --region "$region" --name "$cluster"

  info "Cluster endpoint"
  run terraform output -raw cluster_endpoint
  printf '\n'

  info "Waiting for the API server to answer"
  local i
  for i in $(seq 1 30); do
    if kubectl version -o json >/dev/null 2>&1; then
      ok "API server reachable."
      break
    fi
    [[ "$i" -eq 30 ]] && fail "API server unreachable after 5m. If the public
      endpoint is enabled, confirm your address is still inside
      cluster_endpoint_public_access_cidrs (your egress IP may have changed)."
    sleep 10
  done

  run kubectl cluster-info

  info "Waiting for nodes to register and become Ready"
  for i in $(seq 1 60); do
    local count
    count="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    [[ "$count" -gt 0 ]] && break
    [[ "$i" -eq 60 ]] && fail "No nodes registered after 10m. Check the node group's
      Auto Scaling activity history for capacity or subnet errors."
    sleep 10
  done
  run kubectl wait --for=condition=Ready node --all --timeout=10m
  run kubectl get nodes -o wide

  info "Core workloads"
  run kubectl -n kube-system get pods -o wide

  info "Addon status"
  local addon status
  for addon in vpc-cni kube-proxy coredns aws-ebs-csi-driver; do
    status="$(aws eks describe-addon --region "$region" --cluster-name "$cluster" \
      --addon-name "$addon" --query 'addon.status' --output text 2>/dev/null || echo 'MISSING')"
    if [[ "$status" == "ACTIVE" ]]; then
      ok "${addon}: ${status}"
    else
      warn "${addon}: ${status}"
    fi
  done

  info "Network policy enforcement"

  # The enableNetworkPolicy addon setting does NOT surface as an
  # ENABLE_NETWORK_POLICY env var on the aws-node container. It surfaces as:
  #   - a second container named 'aws-eks-nodeagent' in the aws-node DaemonSet
  #   - '--enable-network-policy=true' in that container's args
  #   - NETWORK_POLICY_ENFORCING_MODE on the aws-node container
  #   - the policyendpoints.networking.k8s.aws CRD
  # Checking the env var instead produces a false negative.
  local np_args np_mode np_containers np_crd
  np_containers="$(kubectl -n kube-system get ds aws-node \
    -o jsonpath='{.spec.template.spec.containers[*].name}' 2>/dev/null || true)"
  np_args="$(kubectl -n kube-system get ds aws-node \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].args}' 2>/dev/null || true)"
  np_mode="$(kubectl -n kube-system get ds aws-node \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-node")].env[?(@.name=="NETWORK_POLICY_ENFORCING_MODE")].value}' 2>/dev/null || true)"
  np_crd="$(kubectl get crd policyendpoints.networking.k8s.aws -o name 2>/dev/null || true)"

  if grep -q -- '--enable-network-policy=true' <<<"$np_args"; then
    ok "NetworkPolicy is enforced."
    ok "  agent container : aws-eks-nodeagent (--enable-network-policy=true)"
    ok "  enforcing mode  : ${np_mode:-<unset, defaults to standard>}"
    ok "  CRD             : ${np_crd:-<missing>}"
  else
    warn "NetworkPolicy does NOT look enforced."
    warn "  aws-node containers : ${np_containers}"
    warn "  nodeagent args      : ${np_args:-<none>}"
    warn "  enforcing mode      : ${np_mode:-<unset>}"
    warn "  policyendpoints CRD : ${np_crd:-<missing>}"
    warn "  Without the node agent, NetworkPolicy objects are accepted by the"
    warn "  API server and silently ignored."
    warn "  Check the addon config:"
    warn "    aws eks describe-addon --cluster-name ${cluster} --addon-name vpc-cni \\"
    warn "      --region ${region} --query 'addon.configurationValues'"
  fi

  verify_kvm "$region" "$cluster"

  bold ""
  ok "Cluster '${cluster}' is up and reachable."
  bold "kubeconfig context: $(kubectl config current-context)"
}

# Confirm /dev/kvm exists on the node, which is the actual prerequisite for
# Kata Containers. A Ready node proves nothing about virtualization support.
verify_kvm() {
  local region="$1" cluster="$2"

  info "Checking /dev/kvm on the node (Kata Containers prerequisite)"
  bold "    This applies a short-lived probe Job in namespace '${PROBE_NS}'."
  bold "    Manifest:"
  cat <<'MANIFEST'
    ---
    apiVersion: batch/v1
    kind: Job
    metadata: { name: kvm-probe }
    spec:
      backoffLimit: 1
      template:
        spec:
          restartPolicy: Never
          containers:
            - name: probe
              image: public.ecr.aws/docker/library/busybox:1.36
              command: ["sh","-c","ls -l /hostdev/kvm"]
              volumeMounts:
                - { name: hostdev, mountPath: /hostdev, readOnly: true }
          volumes:
            - { name: hostdev, hostPath: { path: /dev } }
MANIFEST

  if [[ -t 0 ]]; then
    read -r -p "    Apply this probe Job? [y/N] " reply
    if [[ ! "$reply" =~ ^[Yy]$ ]]; then
      warn "Skipped. Verify manually with:"
      warn "  kubectl debug node/\$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') \\"
      warn "    --image=public.ecr.aws/docker/library/busybox:1.36 -it -- ls -l /host/dev/kvm"
      return 0
    fi
  fi

  # Deliberately not `kubectl create ... -o yaml | kubectl apply -f -`:
  # run() echoes to stderr, but keeping a pipeline out of run() entirely is
  # clearer, and a plain idempotent get/create needs no apply round-trip.
  if kubectl get namespace "$PROBE_NS" >/dev/null 2>&1; then
    info "Namespace '${PROBE_NS}' already exists, reusing it."
  else
    run kubectl create namespace "$PROBE_NS"
  fi

  kubectl -n "$PROBE_NS" delete job kvm-probe --ignore-not-found >/dev/null 2>&1 || true

  kubectl -n "$PROBE_NS" apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: kvm-probe
spec:
  backoffLimit: 1
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: public.ecr.aws/docker/library/busybox:1.36
          command: ["sh", "-c", "ls -l /hostdev/kvm"]
          volumeMounts:
            - name: hostdev
              mountPath: /hostdev
              readOnly: true
      volumes:
        - name: hostdev
          hostPath:
            path: /dev
EOF

  if kubectl -n "$PROBE_NS" wait --for=condition=complete job/kvm-probe --timeout=180s >/dev/null 2>&1; then
    local out
    out="$(kubectl -n "$PROBE_NS" logs job/kvm-probe 2>/dev/null || true)"
    if grep -q 'kvm' <<<"$out"; then
      ok "/dev/kvm present: ${out}"
      ok "Node can host Kata Containers / VM-isolated pods."
    else
      warn "Probe completed but /dev/kvm was not found: ${out}"
    fi
  else
    warn "/dev/kvm probe did not complete. Pod state:"
    kubectl -n "$PROBE_NS" get pods -l job-name=kvm-probe -o wide || true
    kubectl -n "$PROBE_NS" logs job/kvm-probe 2>/dev/null || true
    warn "If /dev/kvm is missing, the node is not bare metal and Kata cannot run."
  fi

  info "Cleaning up the probe namespace"
  run kubectl delete namespace "$PROBE_NS" --wait=false
}

###############################################################################

case "$MODE" in
  plan)   preflight; do_plan   ;;
  apply)  preflight; do_apply  ;;
  verify) do_verify            ;;
  *)      fail "Unknown mode '${MODE}'. Use: plan | apply | verify" ;;
esac
