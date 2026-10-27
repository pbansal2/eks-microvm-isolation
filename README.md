# MicroVM Isolation for Amazon EKS

Run Kubernetes workloads in **hardware-isolated microVMs** on Amazon EKS,
using [Kata Containers](https://katacontainers.io/) with Cloud Hypervisor,
instead of as containers sharing the node's kernel. Terraform builds the
cluster, and scripts install the runtime and prove the isolation.

Moving a workload is one line, `runtimeClassName: kata-clh`, with no change to
the image. Each pod then boots its own Linux kernel in a lightweight VM, so a
compromise stays inside a disposable guest. The included example workload also
runs under default-deny networking: it can't reach the EC2 metadata service,
the internet, or the Kubernetes API.

It's useful wherever a container boundary isn't enough: multi-tenant
platforms, CI runners, user-supplied scripts, or AI agents executing generated
code. The example workload is named `agent-runner`, and the cluster defaults to
`secure-agent-sandbox`, for that last case.

```
                 your IP only (/32)
                        │
                        ▼
   ┌──────────────── NLB (internet-facing) ────────────────┐
   │                                                        │
   │  EKS 1.33 · one c5.metal node (bare metal, /dev/kvm)   │
   │                                                        │
   │   control-plane-gateway  ×2      runc                  │
   │     bearer-token auth, fails closed                    │
   │            │  TCP 8080 only                            │
   │            ▼                                           │
   │   agent-runner  (HPA 1–5)        kata-clh microVM      │
   │     own kernel · no IMDS · no internet · DNS only      │
   └────────────────────────────────────────────────────────┘
        private subnets · NAT egress · API endpoint public+/32 or private
```

> [!WARNING]
> **This costs about $4.25/hour (~$100/day)** while it exists, mostly the
> `c5.metal` node, which is the cheapest way to get `/dev/kvm` on EC2 with AWS
> provider `~> 5.0`. Destroy it when you're done ([Teardown](#teardown)).

---

## Prerequisites

**AWS**

- An account where you can create VPC, EKS, EC2, IAM, KMS, ELB and
  CloudWatch Logs resources. Use a sandbox/dev account, not production.
- **EC2 vCPU quota of at least 96** for on-demand standard instances in
  `us-east-1`, because `c5.metal` is 96 vCPUs. Many new accounts default lower,
  and the node group then fails to launch with no clear error in Terraform:
  ```bash
  aws service-quotas get-service-quota --region us-east-1 \
    --service-code ec2 --quota-code L-1216C47A --query Quota.Value
  ```
- Credentials as a **named profile that yields short-lived credentials**
  (IAM Identity Center / `aws sso login`, or a `credential_process` helper).
  The docs use `AWS_PROFILE=sandbox`; substitute your own name.
  See [RUNBOOK §3a](terraform/RUNBOOK.md#3a-credentials-use-a-short-lived-profile-not-static-keys).

**Local tools** (tested with the versions in brackets)

| Tool | Needed for | Tested |
|---|---|---|
| Terraform ≥ 1.5 | infrastructure | 1.7.0 |
| AWS CLI v2 | everything | 2.27 |
| kubectl, within one minor of 1.33 | workloads | 1.33.3 |
| Helm ≥ 3.8 (OCI chart support) | load balancer controller, Kata | 4.1.4 |
| curl, python3, openssl | scripts | — |
| [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) | **only** if you use a private API endpoint | 1.2.835 |

---

## Quick start

All commands run from the repository root. Every step that changes something
prints what it's about to do and asks before anything disruptive.

```bash
export AWS_PROFILE=sandbox          # your profile
```

### 1. Configure

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
curl -s https://checkip.amazonaws.com     # your egress IP
```

Edit `terraform/terraform.tfvars`:

- set `cluster_endpoint_public_access_cidrs = ["<that IP>/32"]`
- set `tags.Owner`
- choose how you'll reach the Kubernetes API (next section)

`terraform.tfvars` is git-ignored. Leave everything else at its default for a
first run.

#### Choose: public or private API endpoint

| | **Public, your /32 only** (default) | **Private only + SSM tunnel** |
|---|---|---|
| tfvars | `cluster_endpoint_public_access = true` | `cluster_endpoint_public_access = false` |
| How kubectl connects | Directly over the internet | Through a port-forward on `127.0.0.1:8443`, via a node, over SSM |
| Extra tool | none | [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) |
| Breaks when | Your egress IP changes (VPN, home ISP); kubectl just times out | The tunnel ends (terminal closed, laptop slept, session timeout) |
| Fix | Update the CIDR in tfvars and re-apply | Run `scripts/connect.sh` again |
| Exposure | Control plane reachable from one IP | No public control-plane listener at all |

**Recommended: start with public** if you're trying the project out from a
stable connection. It's the fewest moving parts.

**Use private + SSM** if any of these apply:

- **Your egress IP isn't stable.** A corporate VPN, a NAT pool or home DHCP
  will drift out of the allow-list. When it does, kubectl just hangs with no
  hint why, and a blocked network path looks exactly the same.
- **The cluster is long-lived or shared**, or holds anything resembling real
  data.
- **You want no public control-plane listener at all.**

With private mode there's nothing to keep in sync with your IP. The cost is
running `scripts/connect.sh` again whenever the tunnel drops.

For private mode, keep a `/32` in `cluster_endpoint_public_access_cidrs`
anyway rather than `[]`. It grants nothing while public access is off, and an
empty list causes a permanent phantom diff in every plan, because EKS keeps the
last value after public access is turned off.

### 2. Create the cluster (~15–20 min)

```bash
terraform -chdir=terraform init
terraform -chdir=terraform plan -out=tfplan     # read it
terraform -chdir=terraform apply tfplan
```

### 3. Connect kubectl

One command either way. `scripts/connect.sh` asks EKS which mode the cluster
is in, so you don't have to tell it.

#### Public endpoint

```bash
scripts/connect.sh
kubectl get nodes
```

This runs `aws eks update-kubeconfig` and checks that kubectl answers. If it
times out, the script prints your current IP next to the allowed list.
Usually your IP has changed: update `cluster_endpoint_public_access_cidrs` and
run `terraform -chdir=terraform apply`.

#### Private endpoint (SSM tunnel)

Run the tunnel in the background, which is easiest:

```bash
scripts/connect.sh --background    # opens the tunnel, then returns
kubectl get nodes                  # works in this and any other terminal

scripts/connect.sh --status        # is kubectl connected right now?
scripts/connect.sh --stop          # close the tunnel
```

Or in the foreground, holding a terminal:

```bash
scripts/connect.sh                 # terminal 1: leave it open; Ctrl-C closes the tunnel
kubectl get nodes                  # terminal 2
```

The script works out which node to tunnel through, waits until SSM reports it
Online, and starts the port-forward on `127.0.0.1:8443` (loopback only). It
then points your kubeconfig at that port, with `--tls-server-name` set to the
real endpoint so the certificate still validates. It doesn't use SSH, a
bastion, or any inbound security-group rule.

**When kubectl later says** `dial tcp 127.0.0.1:8443: connect: connection
refused`, the tunnel has ended, which is normal. Run
`scripts/connect.sh --background` again. Don't run
`aws eks update-kubeconfig` to "fix" it: that points kubectl at the private
address, which can't be reached from your laptop, and kubectl hangs.

Use `LOCAL_PORT=8444 scripts/connect.sh` if 8443 is already taken.

<details>
<summary>What connect.sh does, as manual commands</summary>

```bash
CLUSTER=secure-agent-sandbox; REGION=us-east-1
ENDPOINT=$(aws eks describe-cluster --region $REGION --name $CLUSTER \
  --query cluster.endpoint --output text | sed 's#https://##')
NODE=$(aws ec2 describe-instances --region $REGION \
  --filters Name=tag:eks:cluster-name,Values=$CLUSTER Name=instance-state-name,Values=running \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# terminal 1 -- the tunnel
aws ssm start-session --region $REGION --target $NODE \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters "{\"host\":[\"$ENDPOINT\"],\"portNumber\":[\"443\"],\"localPortNumber\":[\"8443\"]}"

# terminal 2 -- point kubectl at it
aws eks update-kubeconfig --region $REGION --name $CLUSTER
kubectl config set-cluster "$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')" \
  --server=https://localhost:8443 --tls-server-name=$ENDPOINT
kubectl get nodes
```
</details>

#### Switching an existing cluster between modes

Change `cluster_endpoint_public_access` in `terraform.tfvars`, then:

```bash
terraform -chdir=terraform plan -out=tfplan     # expect 1 in-place change to the cluster
terraform -chdir=terraform apply tfplan         # EKS takes several minutes for this
scripts/connect.sh --stop                       # if you're leaving private mode
scripts/connect.sh                              # re-detects the mode, rewrites kubeconfig
```

Workloads keep running throughout. Only the way you reach the API changes.
Switching to public reopens the API endpoint to the CIDRs in the list, so
check they're still yours first.

### 4. Deploy the baseline workloads

```bash
scripts/deploy-baseline.sh --install-lbc
```

This installs the AWS Load Balancer Controller and metrics-server, then
deploys:

- the gateway, behind an NLB that admits **only your IP**
- the runner, plus its HPA

It generates the gateway's bearer token into a Secret. Expect about 5 minutes
at the "authentication gate" step while the NLB health checks pass.

### 5. Lock down the runner's network

```bash
kubectl apply -f k8s/security/runner-network-policy.yaml
scripts/test-baseline.sh --no-load
```

The test proves:

- only the gateway can reach the runner
- the runner can't reach IMDS or the internet
- DNS still works

### 6. Install Kata Containers

```bash
scripts/install-kata.sh --check      # read-only: /dev/kvm, containerd, chart
scripts/install-kata.sh              # installs; asks first
```

> [!IMPORTANT]
> Installing Kata **restarts containerd on the node**, which restarts every pod
> on it. The gateway will be unreachable for a few minutes. The script says so
> and asks before doing it.

### 7. Move the runner into a microVM and prove it

```bash
scripts/verify-microvm.sh --migrate
```

Expected summary:

```
  Host kernel                  6.12.111-136.204.amzn2023.x86_64
  Guest kernel                 6.18.56
  Kernel isolation             DIFFERENT -- VM boundary confirmed
  MicroVM hypervisor           cloud-hypervisor
  NetworkPolicy                ENFORCING (IMDS + internet dropped, DNS allowed)
```

Re-check any time with `scripts/verify-microvm.sh`. Go back to `runc` with
`--rollback`.

---

## Using the gateway

```bash
NLB=$(kubectl -n agent-sandbox get svc control-plane-gateway \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
TOKEN=$(kubectl -n agent-sandbox get secret control-plane-gateway-auth \
  -o jsonpath='{.data.token}' | base64 -d)

curl -s http://$NLB/healthz                                  # 200, public by design
curl -s -o /dev/null -w '%{http_code}\n' http://$NLB/        # 401 without a token
curl -s -H "Authorization: Bearer $TOKEN" http://$NLB/       # 200
```

`POST /v1/dispatch` returns **501 on purpose**. The shared token proves *a*
caller is the operator, not that *this* caller may run code. Per-caller
identity and authorization are needed before that route does anything.

---

## Teardown

Order matters. Terraform doesn't know about the NLB or Kata's changes to the
node, so destroying the cluster first leaves a billing load balancer behind.

```bash
scripts/install-kata.sh --delete                    # optional; restarts containerd again
scripts/deploy-baseline.sh --delete                 # removes the NLB
helm -n kube-system uninstall aws-load-balancer-controller
terraform -chdir=terraform destroy

# confirm nothing is still billing
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-agentsan')].[LoadBalancerName,State.Code]"
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `dial tcp 127.0.0.1:8443: connect: connection refused` | Private endpoint; the SSM tunnel ended | `scripts/connect.sh` |
| kubectl hangs or times out (public endpoint) | Your egress IP rotated out of the allow-list | Update `cluster_endpoint_public_access_cidrs`, re-apply |
| `ExpiredToken` | Static or expired credentials | Re-login; use a refreshing profile ([§3a](terraform/RUNBOOK.md#3a-credentials-use-a-short-lived-profile-not-static-keys)) |
| Gateway returns `000` for ~5 min after deploy | NLB targets still passing health checks | Wait. `000` means *not connected*, not *exposed* |
| Gateway unreachable later | Your IP rotated out of the gateway allow-list | Re-run `scripts/deploy-baseline.sh` |
| Node group never launches | vCPU quota below 96 | Request a quota increase |
| `kata-deploy` in `CrashLoopBackOff` | See the log; usually a shim mismatch | [RUNBOOK §9](terraform/RUNBOOK.md#9-kata-containers--cloud-hypervisor-k8skata), "When the install crash-loops" |

Every failure in this table actually happened during development. The full
diagnosis for each is in
[`terraform/ISSUES-ENCOUNTERED.md`](terraform/ISSUES-ENCOUNTERED.md).

---

## Repository layout

```
terraform/            VPC, EKS, node group, IRSA roles      (vpc.tf, eks.tf, lbc.tf, ...)
  terraform.tfvars.example   copy to terraform.tfvars
  RUNBOOK.md          operator log: every command, its output, its failure modes
  ISSUES-ENCOUNTERED.md      what broke and how it was diagnosed
k8s/apps/             gateway, runner (runc + microVM variants), HPA
k8s/security/         runner NetworkPolicy (default-deny)
k8s/kata/             Kata Helm values, kata-clh RuntimeClass
scripts/              connect · deploy-baseline · test-baseline · install-kata · verify-microvm
```

Every script takes `--help`. Most have a mode that changes nothing:

- `deploy-baseline.sh --check`
- `install-kata.sh --check`
- `connect.sh --status`
- `verify-microvm.sh` with no arguments

All the cluster scripts check that kubectl points at `CLUSTER_NAME` (default
`secure-agent-sandbox`) before acting. Set `CLUSTER_NAME` if you renamed the
cluster in `terraform.tfvars`.

---

## Security model, and its limits

What is enforced and verified:

- **Runner in a microVM.** Own guest kernel. Verified by comparing guest and
  host kernels, with a runc pod as the control.
- **Runner network: default-deny in both directions.** Only gateway→runner:8080
  in, only CoreDNS out. IMDS and internet egress were verified blocked from
  inside the microVM. The Kubernetes API is blocked by the same default-deny,
  but that wasn't tested separately; the runner also mounts no service-account
  token.
- **Node metadata.** IMDSv2 required with hop limit 1.
- **Pod Security.** The `restricted` standard is enforced on the namespace.
  Containers run as non-root, read-only, with all capabilities dropped.
- **API endpoint.** Never `0.0.0.0/0`; enforced by validation and a
  precondition.
- **Gateway NLB.** Scoped to one CIDR. `0.0.0.0/0` is refused by the deploy
  script, and the manifest is a placeholder so a raw apply fails closed.
- **Gateway auth fails closed.** No token configured means 503, never open.
- **Secrets.** Encrypted with KMS. EKS audit logging is on.

What is **not** done. Read this before running anything untrusted:

- The gateway's auth is a shared bearer token, i.e. a stub. Replace it with
  real per-caller identity before exposing this to anyone but yourself.
- The gateway pods have no NetworkPolicy; their egress is unrestricted.
- There is one node, in one AZ, with no node-level redundancy.
- Terraform state is local. Move it to the S3 backend stubbed in `main.tf`
  before sharing the stack.

---
## License
Licensed under the [Apache License 2.0](LICENSE).
