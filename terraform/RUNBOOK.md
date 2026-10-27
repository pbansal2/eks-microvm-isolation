# Runbook / command log

> **Setting this up yourself? Start with the top-level `README.md`.** This file
> is the operator log of the original deployment: what was run, in what order,
> what it printed, and what went wrong. It is kept because the failure modes
> and their fixes are the most useful part of the project.
>
> Account IDs, IP addresses, instance IDs and endpoint IDs in this file are
> **documentation placeholders** (`111122223333`, `203.0.113.x`,
> `198.51.100.x`, `i-0123456789abcdef0`, `<ENDPOINT_ID>`), not real values.
> The scripts discover the real ones; you should not need to copy any of them.
> "Status" notes describe the original deployment, not your cluster.

Session date: **2026-10-22**. Region `us-east-1`, account `111122223333`,
principal `arn:aws:sts::111122223333:assumed-role/Admin/<session>`.

> Status: the infrastructure **has been applied** and is running. Cluster
> `secure-agent-sandbox` is ACTIVE on Kubernetes 1.33 with one `c5.metal`
> node. **It is billing ~$4.23/hr (~$98/day)** -- see "Cost while running".
>
> The baseline workloads in `k8s/apps/` are **deployed and verified** as of
> 2026-10-23: gateway 2/2, runner 1/1, metrics-server 1/1, HPA reading
> `cpu: 0%/50%`, and the auth gate confirmed denying anonymous callers
> through the NLB. Section 7 has the detail.
>
> A `terraform plan` reports **No changes** -- nothing left to apply on the
> infrastructure side.
>
> The runner NetworkPolicy in `k8s/security/` is **applied and verified** as
> of 2026-10-23 (section 8): the runner can no longer reach IMDS or the public
> internet, cluster DNS still resolves, and only the gateway can reach it on
> 8080. The HPA load test is the one thing in this runbook not yet run.
>
> Kata Containers with Cloud Hypervisor (section 9) is **written; the first
> install attempt failed and was fixed, and has not been retried.** The
> cluster is still Kata-capable, not Kata-enabled: no shims on the host, no
> RuntimeClass, and the agent runner is still a `runc` container sharing the
> host kernel. A crash-looping `kata-deploy` pod and a stuck
> `pending-install` release are still to clear -- `install-kata.sh` prompts to
> do it. Installing restarts containerd on the only node, which restarts
> every pod on it.

---

## 1. The short version

```bash
cd <repo-root>/terraform
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com        # -> cluster_endpoint_public_access_cidrs, append /32
./scripts/apply-and-verify.sh                # fmt + init + validate + plan, read-only
terraform apply tfplan                       # your call
./scripts/apply-and-verify.sh verify         # kubeconfig, nodes Ready, addons, /dev/kvm probe

# then the baseline workloads (section 7)
cd ..
AWS_PROFILE=sandbox terraform -chdir=terraform apply          # LBC IAM role
AWS_PROFILE=sandbox scripts/deploy-baseline.sh --install-lbc  # workloads

# then network isolation (section 8)
kubectl apply -f k8s/security/runner-network-policy.yaml      # RUN 2026-10-23
./scripts/test-baseline.sh --no-load                          # RUN, exit 0
./scripts/test-baseline.sh --load-only   # HPA scale-out, ~8 min  <- NOT YET RUN

# then Kata + Cloud Hypervisor (section 9)   <<< NOT YET APPLIED >>>
./scripts/install-kata.sh --check        # read-only; /dev/kvm + containerd. RUN, passes
./scripts/install-kata.sh --render       # write the chart for review. RUN
./scripts/install-kata.sh                # installs; RESTARTS containerd
                                         #   ATTEMPTED 2026-10-23, FAILED on a
                                         #   defaultShim mismatch. Fixed; not
                                         #   retried.  <- NOT YET RUN
```

Everything above has been **run** except the HPA load test and the Kata
install itself. To re-verify the running stack without changing anything, use
`scripts/deploy-baseline.sh --check`, `scripts/test-baseline.sh --no-load` and
`scripts/install-kata.sh --check`; all three are safe to repeat.

Note the `AWS_PROFILE=sandbox` prefix -- the `[default]` profile still holds
expired static keys, so commands without it fail with `ExpiredToken`. See
section 3a.

---

## 2. Already executed

### 2.1 Account / capability discovery (read-only)

```bash
aws sts get-caller-identity
# -> account 111122223333, assumed-role/Admin/<session>

aws eks describe-addon-versions --addon-name vpc-cni --region us-east-1 \
  --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion'
# -> 1.31 .. 1.37. NOTE: 1.29 and 1.30 are EOL and cannot be created.
#    This is why kubernetes_version defaults to 1.33, not 1.29.

aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=c5.metal" --region us-east-1 \
  --query 'InstanceTypeOfferings[].Location' --output text
# -> us-east-1a b c d f   (absent from us-east-1e)

aws ec2 describe-instance-types --instance-types c5.metal --region us-east-1 \
  --query 'InstanceTypes[0].{vcpu:VCpuInfo.DefaultVCpus,bare:BareMetal}'
# -> 96 vCPU, BareMetal: true  => /dev/kvm available for Kata
```

### 2.2 Provider capability probe

The reason this stack uses `c5.metal` and not `c8i.xlarge`:

```bash
# Provider 5.x: cpu_options has NO nested_virtualization argument
mkdir -p /tmp/tfprobe && cd /tmp/tfprobe
printf 'terraform {\n  required_providers {\n    aws = {\n      source = "hashicorp/aws"\n      version = "~> 5.0"\n    }\n  }\n}\n' > p.tf
terraform init && terraform providers schema -json \
  | jq '.provider_schemas["registry.terraform.io/hashicorp/aws"].resource_schemas.aws_launch_template.block.block_types.cpu_options.block.attributes | keys'
# ~> 5.0 (v5.100.0) -> ["amd_sev_snp","core_count","threads_per_core"]
# ~> 6.0 (v6.70.0)  -> ["amd_sev_snp","core_count","nested_virtualization","threads_per_core"]
```

Conclusion: nested virtualization on `c8i.xlarge` requires AWS provider
`>= 6.0`. This project pins `~> 5.0`, so bare metal is the only path to
`/dev/kvm`. Decision recorded: keep `~> 5.0` + `c5.metal`.

### 2.3 Configuration written

`main.tf`, `variables.tf`, `vpc.tf`, `eks.tf`, `outputs.tf`,
`scripts/apply-and-verify.sh`, `terraform.tfvars.example`, `../.gitignore`.

Pinned versions (latest compatible with provider `~> 5.0`):

| Module | Version |
|---|---|
| `terraform-aws-modules/vpc/aws` | `5.21.0` |
| `terraform-aws-modules/eks/aws` | `20.37.2` |
| `terraform-aws-modules/iam/aws` | `5.60.0` |

### 2.4 Validation (read-only)

Run directly, **not** via `apply-and-verify.sh` — that script was never
executed in this session:

```bash
cd <repo-root>/terraform
terraform fmt -recursive          # reformatted outputs.tf, vpc.tf, variables.tf
terraform init -input=false       # ok
terraform validate                # Success! The configuration is valid.

terraform plan -input=false \
  -var='cluster_endpoint_public_access_cidrs=["203.0.113.4/32"]' \
  -out=/tmp/throwaway.tfplan
```

First plan **failed** and caught a real bug:

```
Error: expected length of name_prefix to be in the range (1 - 38),
       got secure-agent-sandbox-ng-eks-node-group-
```

Fix: dropped the explicit `name = "${var.cluster_name}-ng"` from the node
group so the map key `sandbox` is used instead, and tightened
`cluster_name` validation to 40 chars. Re-planned clean.

### 2.5 Spec conformance, read back out of the plan JSON

```bash
terraform show -json /tmp/throwaway.tfplan > /tmp/plan.json
# inspected planned_values recursively
```

| Checked | Result |
|---|---|
| Subnets | 4 (2 public / 2 private) across `us-east-1a`, `us-east-1b` |
| Public subnet tags | `kubernetes.io/role/elb = 1` |
| Private subnet tags | `kubernetes.io/role/internal-elb = 1` |
| NAT Gateways | 1 |
| Addons | 4: `vpc-cni`, `kube-proxy`, `coredns`, `aws-ebs-csi-driver` |
| `vpc-cni` config | `{"enableNetworkPolicy":"true"}` |
| Control plane | `1.33`, all 5 log types, secrets KMS-encrypted |
| Endpoint | private `true`, public `true` scoped to 1 CIDR |
| Node group | `c5.metal`, `AL2023_x86_64_STANDARD`, 1/1/1 |
| Root volume | `/dev/xvda`, 50 GiB, `gp3`, `encrypted = true` |
| IMDS | `http_tokens = required`, hop limit `1` |

### 2.6 Guardrails proven to reject bad input

Each of these was run and confirmed to fail:

```bash
# 1. 0.0.0.0/0 on the public endpoint -> variable validation error
terraform plan -var='cluster_endpoint_public_access_cidrs=["0.0.0.0/0"]'

# 2. public access on with an empty allow-list -> precondition failure
terraform plan -var='cluster_endpoint_public_access_cidrs=[]'

# 3. non-metal instance type -> validation: no /dev/kvm for Kata
terraform plan -var='cluster_endpoint_public_access_cidrs=["203.0.113.4/32"]' \
               -var='node_instance_type=c8i.xlarge'

# 4. EOL Kubernetes version -> validation error
terraform plan -var='cluster_endpoint_public_access_cidrs=["203.0.113.4/32"]' \
               -var='kubernetes_version=1.24'
```

### 2.7 Security sweep

```bash
cd <repo-root>
grep -rnE '0\.0\.0\.0|::/0|\[::\]|listen\(|--host|bind-address' --include='*.tf' --include='*.sh' .
grep -rnE 'Principal.*\*|AllUsers|AuthenticatedUsers|acl *= *"public' --include='*.tf' .
grep -rniE 'access_key|secret_key|AKIA|password *=' --include='*.tf' --include='*.sh' .
bash -n terraform/scripts/apply-and-verify.sh
```

Clean. Every `0.0.0.0` hit is a private RFC1918 CIDR, a comment, or the
rejection logic itself. No wildcard binds, no public grants, no credentials.

> ARCC was **not** queried this session: the `search_arcc` MCP tool was not
> registered. Standard BSC / `builder-security` defaults were applied instead.

### 2.8 tfvars

`terraform.tfvars` was created from the example (by you, in the IDE).

```bash
curl -s https://checkip.amazonaws.com
# -> 198.51.100.20
```

Line 21 was then corrected from `["198.51.100.20"]` to
`["198.51.100.20/32"]` — the bare address fails the `cidrhost()`
validation, since the variable takes CIDR blocks.

Re-planned with the real tfvars: **75 to add, 0 to change, 0 to destroy**,
`public_access_cidrs = ["198.51.100.20/32"]`. (74 -> 75 because
`enable_flow_logs` adds a flow-log IAM role once a concrete tfvars is used.)

---

## 3. The apply itself (executed 2026-10-22)

> This has since been **run**, and the cluster is live. Kept as the record of
> what was executed, and as the sequence to repeat after a `terraform
> destroy`. A plan run today reports `No changes` for the infrastructure --
> the only pending work is the load balancer controller IAM role in section 7.

The stale `/tmp` plans were deleted, so regenerate before applying.

```bash
cd <repo-root>/terraform

# 1. Fresh plan. Read it.
terraform plan -out=tfplan

# 2. Apply. Creates real, billable infrastructure. ~15-20 min for EKS.
terraform apply tfplan

# 3. Verify connectivity, addons and /dev/kvm
./scripts/apply-and-verify.sh verify
```

Or let the script drive both, with a typed confirmation before apply:

```bash
./scripts/apply-and-verify.sh apply
```

---

## 3a. Credentials: use a short-lived profile, not static keys

Every command in this runbook is written as `AWS_PROFILE=sandbox <command>`.
`sandbox` is just the profile name used here -- substitute your own. What
matters is that the profile yields **short-lived** credentials rather than
static keys in `~/.aws/credentials`, because static keys either expire
mid-session (the `ExpiredToken` failures in `ISSUES-ENCOUNTERED.md`) or, worse,
do not expire at all.

Either of the standard forms works. IAM Identity Center (SSO):

```ini
# ~/.aws/config
[profile sandbox]
sso_session    = my-sso
sso_account_id = 111122223333
sso_role_name  = AdministratorAccess
region         = us-east-1
```

```bash
aws sso login --profile sandbox
```

Or a `credential_process` helper, if your organisation issues credentials
through one. The CLI, the SDKs and Terraform all run the helper on demand and
cache the result until its `Expiration`, so nothing is written to disk:

```ini
[profile sandbox]
credential_process = <credential-helper> --account 111122223333 --role Admin
region = us-east-1
```

The original deployment used the `credential_process` form.

Pin the profile into the kubeconfig so `kubectl` needs no environment
variable. `scripts/connect.sh` does this for you when `AWS_PROFILE` is set:

```bash
aws eks update-kubeconfig --region us-east-1 --name secure-agent-sandbox --profile sandbox
# writes  env: [{name: AWS_PROFILE, value: sandbox}]  into the exec block
```

Usage:

```bash
kubectl get nodes                              # just works
AWS_PROFILE=sandbox terraform plan             # or export AWS_PROFILE once per shell
```

**Region.** The Terraform code targets `us-east-1`. If your shell exports
`AWS_REGION` for other work, `aws` commands without `--region` will look in
the wrong place. Every command here passes `--region` explicitly, and
`scripts/connect.sh` ignores `AWS_REGION` on purpose.

> Clean out any stale static keys in `~/.aws/credentials`. A `[default]`
> profile holding expired keys turns every command that forgets
> `AWS_PROFILE` into an `ExpiredToken` error that looks like a real outage.

---

## 4. Node access over SSM, and checking `/dev/kvm`

The node is in a private subnet with **no public IP, no port 22 open, and no
key pair**. Access is via SSM Session Manager: the agent on the node dials
*out* through the NAT Gateway, and the session rides back down that tunnel.
Authorization is IAM, and every session is logged in CloudTrail.

This works because the node IAM role carries
`AmazonSSMManagedInstanceCore` (set in `eks.tf` via
`iam_role_additional_policies`).

### Resolve the instance ID

Do not hardcode it -- the node is replaced on any launch template change.
Note also that the node group's real name carries a timestamp suffix, so
resolve that too.

```bash
cd <repo-root>/terraform

NG=$(aws eks list-nodegroups --cluster-name secure-agent-sandbox \
  --region us-east-1 --query 'nodegroups[0]' --output text)

ASG=$(aws eks describe-nodegroup --cluster-name secure-agent-sandbox \
  --nodegroup-name "$NG" --region us-east-1 \
  --query 'nodegroup.resources.autoScalingGroups[0].name' --output text)

INSTANCE=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG" --region us-east-1 \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

echo "$INSTANCE"
```

As of 2026-10-22 this resolved to `i-0123456789abcdef0`.

### Preconditions

```bash
# node must be registered and Online with SSM
aws ssm describe-instance-information --region us-east-1 \
  --filters "Key=InstanceIds,Values=$INSTANCE" \
  --query 'InstanceInformationList[].{ping:PingStatus,agent:AgentVersion}'
# -> Online, 3.3.5390.0

# local plugin is required for start-session
command -v session-manager-plugin     # -> 1.2.835.0
```

If `session-manager-plugin` is missing, install it:
<https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html>

### Interactive shell on the node

```bash
aws ssm start-session --region us-east-1 --target "$INSTANCE"
```

Lands you as `ssm-user`; use `sudo` for root. `exit` to leave.

### Check `/dev/kvm` (the Kata prerequisite)

Once in the session:

```bash
ls -l /dev/kvm /dev/vhost-vsock
lsmod | grep -E '^kvm'
sudo dmesg | grep -i -m5 'kvm'
```

Expected, and confirmed on 2026-10-22:

```
crw-rw-rw- 1 root 36  10, 232  /dev/kvm
crw-rw-rw- 1 root 36  10, 241  /dev/vhost-vsock
```

`vhost-vsock` matters as well as `kvm`: Kata uses vsock for host-to-guest
agent communication.

Non-interactive equivalent, no session needed:

```bash
aws ssm send-command --region us-east-1 \
  --instance-ids "$INSTANCE" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["ls -l /dev/kvm /dev/vhost-vsock"]' \
  --query 'Command.CommandId' --output text
# then, with the returned id:
aws ssm get-command-invocation --region us-east-1 \
  --instance-id "$INSTANCE" --command-id <id> \
  --query 'StandardOutputContent' --output text
```

Or from inside Kubernetes, without touching the node at all:

```bash
kubectl debug node/$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}') \
  --image=public.ecr.aws/docker/library/busybox:1.36 -it -- ls -l /host/dev/kvm
```

`./scripts/apply-and-verify.sh verify` runs the Job-based version of this
check automatically.

### Port-forward the Kubernetes API over SSM

**Use `scripts/connect.sh`.** It reads the endpoint mode from EKS, finds a
running node, starts the port-forward on `127.0.0.1:8443`, and rewrites the
kubeconfig with the right `--tls-server-name` -- everything below, with no
IDs to copy:

```bash
AWS_PROFILE=sandbox scripts/connect.sh --background   # tunnel detached
scripts/connect.sh --status                           # is kubectl connected?
scripts/connect.sh --stop
```

The manual procedure it automates follows, for when you need to see the
moving parts. `<ENDPOINT_ID>` comes from
`aws eks describe-cluster --name secure-agent-sandbox --query cluster.endpoint`.

Use this when the public endpoint is unreachable -- a blocked corporate
egress path, or a rotated egress IP that is no longer in
`cluster_endpoint_public_access_cidrs`. See issue 6 in
`ISSUES-ENCOUNTERED.md`. It reaches the **private** endpoint, so the public
allow-list is irrelevant.

Terminal 1, leave running:

```bash
aws ssm start-session \
  --region us-east-1 \
  --target "$INSTANCE" \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<ENDPOINT_ID>.gr7.us-east-1.eks.amazonaws.com"],"portNumber":["443"],"localPortNumber":["8443"]}'
```

Terminal 2. `--tls-server-name` is required so the certificate still
validates against the real hostname:

```bash
kubectl config set-cluster arn:aws:eks:us-east-1:111122223333:cluster/secure-agent-sandbox \
  --server=https://localhost:8443 \
  --tls-server-name=<ENDPOINT_ID>.gr7.us-east-1.eks.amazonaws.com

kubectl get nodes -o wide
```

### The tunnel dying is the normal failure mode

The SSM session ends when the terminal closes or after an idle timeout, and
the kubeconfig keeps pointing at `https://localhost:8443`. The next `kubectl`
call then produces five lines of client-go noise and one useful line:

```
E1023 20:55:06.012123 memcache.go:265] "Unhandled Error" err="couldn't get
  current server API group list: Get \"https://localhost:8443/api?timeout=32s\":
  dial tcp 127.0.0.1:8443: connect: connection refused"
The connection to the server localhost:8443 was refused
```

Nothing is wrong with the cluster. Confirm and restart:

```bash
lsof -nP -iTCP:8443 -sTCP:LISTEN     # empty => the tunnel is gone
AWS_PROFILE=sandbox aws ssm describe-instance-information --region us-east-1 \
  --filters Key=InstanceIds,Values=i-0123456789abcdef0 \
  --query 'InstanceInformationList[].PingStatus' --output text   # -> Online
```

Then re-run the `start-session` command above. It is ready when the log says
`Waiting for connections...` and the listener appears on **`127.0.0.1:8443`**
-- loopback, not `0.0.0.0`; a tunnel bound to all interfaces would expose the
cluster's API to the local network.

To leave it running in the background instead of holding a terminal:

```bash
AWS_PROFILE=sandbox nohup aws ssm start-session --region us-east-1 \
  --target i-0123456789abcdef0 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<ENDPOINT_ID>.gr7.us-east-1.eks.amazonaws.com"],"portNumber":["443"],"localPortNumber":["8443"]}' \
  > /tmp/ssm-tunnel.log 2>&1 &
```

All three of `deploy-baseline.sh`, `test-baseline.sh` and `install-kata.sh`
now fail in preflight with a message naming the tunnel, instead of part-way
through with client-go noise.

### Do NOT "revert to the direct endpoint"

```bash
# WRONG for this cluster. Previously documented here; it does not work.
aws eks update-kubeconfig --region us-east-1 --name secure-agent-sandbox
```

That rewrites the server to the real endpoint, which this cluster publishes
**privately only**:

```bash
AWS_PROFILE=sandbox aws eks describe-cluster --name secure-agent-sandbox \
  --region us-east-1 \
  --query 'cluster.resourcesVpcConfig.{public:endpointPublicAccess,private:endpointPrivateAccess,cidrs:publicAccessCidrs}'
# -> public: false, private: true, cidrs: ["203.0.113.10/32"]
```

`endpointPublicAccess: false` means the hostname resolves to
addresses reachable only from inside the VPC, so `kubectl` would hang rather
than connect. The `publicAccessCidrs` entry is an inert value kept
deliberately, because EKS retains the last value after public access is turned
off -- it is not a sign that public access works. The tunnel
is the only route in from a laptop; use `update-kubeconfig` only after setting
`cluster_endpoint_public_access = true` in `terraform.tfvars` and applying.

---

## 5. What is and is not in place for Kata Containers

Worth being explicit, because the cluster is Kata-**capable**, not
Kata-**enabled**. Nothing in this stack installs Kata.

### In place -- the platform prerequisite only

| Where | What |
|---|---|
| `variables.tf:163` | `node_instance_type` defaults to `c5.metal` |
| `variables.tf:166` | validation: must end in `.metal`, else no `/dev/kvm` |
| `variables.tf:196` | validation: disk >= 30 GiB, headroom for Kata rootfs images |
| `main.tf:103` | `data.aws_ec2_instance_type.node` reads `bare_metal` |
| `main.tf:120-127` | precondition fails the plan if the type is not bare metal |
| `eks.tf:191` | node label `sandbox.io/kvm = "true"` |
| `outputs.tf:94` | `node_group_is_bare_metal` output |
| `scripts/apply-and-verify.sh:244` | `verify_kvm()` -- the `/dev/kvm` probe Job |

That is the whole of it: a node that exposes `/dev/kvm` and
`/dev/vhost-vsock`, plus guardrails and verification proving it does.

### NOT in place -- Kata itself

Verified absent: no `user_data`, `pre_bootstrap_user_data`, `RuntimeClass`,
containerd config, or `kata-deploy` anywhere in our `.tf` or `.sh` files.
(Searching for these terms hits only vendored code under
`.terraform/modules/`.)

Still required before a single VM-isolated pod can run:

1. **Kata runtime on the node** -- `kata-containers` binaries plus a
   hypervisor (QEMU or Cloud Hypervisor / Firecracker).
2. **containerd shim wiring** -- a `containerd` config snippet registering
   the `io.containerd.kata.v2` runtime handler, then a containerd restart.
3. **A `RuntimeClass`** -- e.g. `handler: kata`, so pods can opt in with
   `spec.runtimeClassName: kata`.
4. **Scheduling** -- target the KVM-capable nodes via
   `nodeSelector: { sandbox.io/kvm: "true" }` (the label is already applied).

The usual mechanism is the upstream `kata-deploy` DaemonSet, which installs
items 1-3 onto labelled nodes.

> **Superseded as of 2026-10-23.** Items 1-4 above are now implemented in
> `k8s/kata/` and `scripts/install-kata.sh` -- **written and validated, not yet
> applied**, because installing restarts containerd on the only node. See
> **section 9**. This section is kept because the "In place" table is still an
> accurate description of what *Terraform* provides: Terraform still installs
> no Kata, and still only guarantees a node that exposes `/dev/kvm`.
>
> Two details in the list above turned out to be wrong when it was built, and
> section 9 has the corrected versions: the handler is `kata-clh`, not
> `io.containerd.kata.v2` (that is the shim binary's name, not the
> RuntimeClass handler), and the RuntimeClass must select on
> `katacontainers.io/kata-runtime=true` -- the label kata-deploy sets after a
> successful install -- rather than on `sandbox.io/kvm=true`.

---

---

## 6. Decision: how to reach the Kubernetes API

**Decided 2026-10-22.** Three ways to reach the API server. This records which
we use, and why `0.0.0.0/0` is rejected outright rather than merely
discouraged.

| Mode | Verdict | Use when |
|---|---|---|
| Public + allow-listed CIDR | **project default** | stable egress IP, solo dev |
| Private-only + SSM tunnel | **hardened; chosen for this cluster** | restricted corporate network, shared or longer-lived cluster, anything near real data |
| Public + `0.0.0.0/0` | **never** | - |

### Why `0.0.0.0/0` is rejected

The usual defence is "the endpoint is still IAM/SigV4-authenticated, so it
isn't really open." That is true, and it is not sufficient:

1. **A leaked credential becomes globally usable.** With an allow-list, a
   stolen kubeconfig or IAM key is useless from an unlisted network. With
   `0.0.0.0/0` it works from anywhere, immediately.
2. **Authentication becomes the only control.** The network layer is deleted,
   so there is no defence in depth. Any future pre-auth or auth-bypass defect
   in the API server is internet-reachable the day it is disclosed, with no
   mitigation window.
3. **Unauthenticated traffic still reaches the API server** to be rejected at
   the TLS/auth layer, rather than being dropped at the security group.
4. **It poisons the audit trail.** `kube-apiserver-audit` is what we used to
   reconstruct the probe Job (see `ISSUES-ENCOUNTERED.md`). An open endpoint
   fills that log with internet scanner noise, which is precisely what you do
   not want while investigating a real incident.

It also contradicts this repo's own code. `cluster_endpoint_public_access_cidrs`
rejects `0.0.0.0/0` by variable validation, and
`cluster_endpoint_public_access = true` with an empty list fails a
precondition in `main.tf` (EKS silently reads an empty list as `0.0.0.0/0`).
Choosing it means deleting a guardrail -- treat that as a signal, not an
inconvenience.

Policy basis: AWS Usage Standard 5.2.7 and the internal `builder-security`
guidance both prohibit `0.0.0.0/0` on a service or administrative port, and
hold that datastores and control planes are not internet-exposed even when
authenticated.

### Honest downsides of the SSM tunnel

Recorded so the trade-off is not rediscovered later:

| | |
|---|---|
| Setup | requires `session-manager-plugin` locally and `ssm:StartSession` IAM |
| Ergonomics | two terminals, a long-running process, `--tls-server-name` needed |
| **Depends on a running node** | the tunnel terminates *on a node*. If the node group scales to 0, or the node is replaced and the instance ID changes, API access is lost entirely |
| Latency | marginally higher than direct |

The node dependency is the real catch and it is not hypothetical: a
private-only cluster with zero nodes is unreachable. A VPN or a dedicated
bastion does not have this coupling. **Keep `node_min_size >= 1` so you never
strand yourself.**

### Recommendation for a new user of this project

Leave the **project default** as-is: public endpoint enabled, allow-list
mandatory, `0.0.0.0/0` rejected. It is the best balance of ergonomics and
safety, and it forces a deliberate decision at plan time instead of shipping
an open default.

Switch to **private-only + SSM** when any of the following is true: your
egress IP is not stable (corporate VPN, NAT pool, home DHCP), the cluster is
shared or long-lived, or it is anywhere near real data.

One caveat that makes the default safe to hand to someone else: **IP
allow-listing fails silently and confusingly.** A blocked corporate egress
path and a stale allow-list produce a byte-identical
`connect=0.000000s` timeout (issue 6), and separating the two took real work.
A new user hitting that gets a cryptic hang with no hint as to why. Section 4
and the SSM fallback are therefore not optional polish -- they are the escape
hatch.

### Applying the hardened mode

```hcl
# terraform.tfvars
cluster_endpoint_public_access       = false
cluster_endpoint_public_access_cidrs = []
```

**Order matters.** Verify the SSM tunnel works *before* removing public
access, not after -- otherwise a broken tunnel leaves no way in. Section 4 has
the tunnel commands.

```bash
# 1. prove the tunnel works while the public endpoint still functions
# 2. only then:
terraform plan -out=tfplan     # expect 1 to change, 0 to destroy
terraform apply tfplan
```

This is an in-place update of the cluster's `vpc_config`; it does not replace
the cluster.

---

## 7. Baseline application deployment (`k8s/apps/`)

Three manifests plus a driver script. **Applied and verified 2026-10-23.**

| File | What it is |
|---|---|
| `k8s/apps/gateway.yaml` | Namespace, gateway source, Deployment (2 replicas), PDB, NLB Service |
| `k8s/apps/runner.yaml` | `agent-runner` Deployment, default `runc` runtime |
| `k8s/apps/hpa.yaml` | HPA on `agent-runner`, 50% CPU, 1-5 replicas |
| `scripts/deploy-baseline.sh` | Applies all three, installs prerequisites, verifies |

### Two prerequisites that are not obvious

**1. The AWS Load Balancer Controller is not installed.** The gateway Service
is annotated `aws-load-balancer-type: external`, which tells the legacy
in-tree cloud provider to *ignore* the Service. With no controller to pick it
up, the Service stays `<pending>` forever and emits **no event saying why**.
There is also no EKS managed addon for it:

```bash
aws eks describe-addon-versions --region us-east-1 \
  --query "addons[?contains(addonName,'load-balancer')]" --output json
# -> []   (must come from Helm)
```

`terraform/lbc.tf` creates its IRSA role; the chart is installed by the
script, so Terraform never needs a reachable Kubernetes API to plan.

**2. There is no metrics-server.** EKS ships none, so an HPA with a CPU target
resolves no metrics, reports `FailedGetResourceMetric` and silently holds at
`minReplicas`. The script installs the official upstream manifest.

### The commands

```bash
# --- IAM for the load balancer controller.  EXECUTED 2026-10-22 23:50 ------
#
# This is NOT a re-run of the cluster apply. terraform/lbc.tf was added after
# that apply, so these three IAM objects did not exist yet. Note the
# "0 to change, 0 to destroy" -- the VPC, cluster and node were never in
# scope.
#
# `terraform init` is required because lbc.tf adds a new *module block*. It
# is a third instance of iam-role-for-service-accounts-eks 5.60.0, already
# used by vpc_cni_irsa and ebs_csi_irsa, so nothing is downloaded -- but each
# instance needs its own entry in .terraform/modules/modules.json. Skipping
# it fails with "Error: Module not installed ... on lbc.tf line 25". A new
# `resource` block would not need init; a new `module` block does.
cd <repo-root>/terraform
AWS_PROFILE=sandbox terraform init          # installs the new IRSA module
AWS_PROFILE=sandbox terraform validate
AWS_PROFILE=sandbox terraform plan -out=tfplan
# -> Plan: 3 to add, 0 to change, 0 to destroy
#      module.load_balancer_controller_irsa.aws_iam_policy.load_balancer_controller[0]
#      module.load_balancer_controller_irsa.aws_iam_role.this[0]
#      module.load_balancer_controller_irsa.aws_iam_role_policy_attachment...[0]
AWS_PROFILE=sandbox terraform apply tfplan
# -> role secure-agent-sandbox-aws-lbc created 2026-10-22T21:50:40Z
# -> a plan afterwards reports "No changes". Nothing further to apply.

# --- read-only preflight.  Safe to re-run any time -------------------------
cd <repo-root>
AWS_PROFILE=sandbox scripts/deploy-baseline.sh --check
# Applies nothing. Exits 1 until the controller exists -- that is the gate,
# not a failure.

# --- install the controller, then deploy.  EXECUTED 2026-10-23 -------------
# Idempotent: re-running reuses the existing Secret and re-applies in place.
AWS_PROFILE=sandbox scripts/deploy-baseline.sh --install-lbc
#
# The gateway NLB admits only GATEWAY_ALLOWED_CIDR, which defaults to your own
# egress IP as a /32 (discovered via checkip.amazonaws.com). Override it for an
# office or VPN range; 0.0.0.0/0 is refused:
#   GATEWAY_ALLOWED_CIDR=198.51.100.0/24 AWS_PROFILE=sandbox scripts/deploy-baseline.sh
# gateway.yaml holds a placeholder, so `kubectl apply -f k8s/apps/gateway.yaml`
# on its own is rejected by the API server. That is deliberate.
#
# Safe to re-run after the Kata migration (section 9): it keeps the runner on
# the runtime it is already using. Force one with RUNNER_RUNTIME=runc|kata.
#
# What this actually installed, read back from the cluster:
#   aws-load-balancer-controller  chart 3.6.1, app v3.6.1   (Helm, kube-system)
#   metrics-server                v0.9.0                    (upstream `latest`)
#   NLB  k8s-agentsan-controlp-0123456789-0123456789abcdef.elb.us-east-1.amazonaws.com
#
# metrics-server needed NO --kubelet-insecure-tls patch. `kubectl top` works
# against the stock upstream args on this cluster, so do not apply that patch
# pre-emptively: it stops metrics-server verifying what it scrapes.
#
# Expect to wait ~5 min at "Verifying the authentication gate": the Service
# gets its address in well under a minute, but the NLB targets took 285s to
# pass their first health checks. 000 during that window is normal.
# Prompts once before installing the Helm chart (it will create and delete
# real load balancers). Everything after that is unattended.
```

The API server must be reachable first. With the hardened mode in
`terraform.tfvars` that means the **SSM tunnel from section 4 has to be up**,
or every `kubectl` call in the script times out.

### What the script does, in order

1. Preflight: tools, manifests, API `/readyz`, at least one Ready node.
2. Hard gate on the load balancer controller.
3. Generates a random 32-byte bearer token into the
   `control-plane-gateway-auth` Secret. **Before** applying the Deployment --
   the container reads the token into an env var at start, so a Secret created
   afterwards never reaches a running pod.
4. Applies `gateway.yaml` and `runner.yaml`, then patches a
   `checksum/src-configmap` annotation with the manifest's sha256 so editing
   the gateway source actually rolls the pods.
5. Installs metrics-server, waits for the `metrics.k8s.io` APIService.
6. Applies `hpa.yaml`.
7. Waits up to 5 min for the NLB address.
8. Verifies the auth gate through the NLB -- **checks that an anonymous
   request is denied**, not that an authenticated one succeeds.
9. Waits for `kubectl top pods` to return non-zero CPU.

### Calling the gateway

```bash
NLB=$(kubectl -n agent-sandbox get svc control-plane-gateway \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
TOKEN=$(kubectl -n agent-sandbox get secret control-plane-gateway-auth \
          -o jsonpath='{.data.token}' | base64 -d)

curl -sS -o /dev/null -w '%{http_code}\n' "http://${NLB}/healthz"   # 200, unauth by design
curl -sS -o /dev/null -w '%{http_code}\n' "http://${NLB}/"          # 401, must be denied
curl -sS -H "Authorization: Bearer ${TOKEN}" "http://${NLB}/"       # 200 + JSON
```

An anonymous `200` on `/` means the gate is not working. Stop and fix it
before using the endpoint.

### When the gateway stops responding

The Service is `internet-facing` restricted to a single `/32`
(`203.0.113.10/32`, captured 2026-10-22). That fails exactly like the API
endpoint allow-list does -- as a **silent connection timeout**, not a refusal
(see issue 6). Diagnose in this order:

**`000` is not an exposure.** `curl` writes `000` when it could not connect
at all, which means nothing was served. An earlier version of
`deploy-baseline.sh` classified it as "the gateway is serving anonymous
callers" and told the operator to delete the Service -- which they did, to a
working Service. See `ISSUES-ENCOUNTERED.md` issue 12. Only a **2xx or 3xx**
response to an unauthenticated request is a real gate failure.

```bash
curl -s https://checkip.amazonaws.com        # has your egress address rotated?

# simplest: re-run the deploy, which re-discovers your address
AWS_PROFILE=sandbox scripts/deploy-baseline.sh
# or patch just the Service:
kubectl -n agent-sandbox patch svc control-plane-gateway --type=merge \
  -p '{"spec":{"loadBalancerSourceRanges":["<NEW_IP>/32"]}}'

# if that is not it:
kubectl -n agent-sandbox describe svc control-plane-gateway
kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50
kubectl -n agent-sandbox get pods -o wide
```

### Inspecting the HPA and metrics

```bash
kubectl top nodes
kubectl top pods -n agent-sandbox
kubectl get hpa -n agent-sandbox
kubectl describe hpa agent-runner -n agent-sandbox      # scaling events

# drive load to watch it scale out (runner requests 100m, target is 50%)
kubectl -n agent-sandbox exec deploy/agent-runner -- \
  sh -c 'timeout 180 sh -c "while :; do :; done"' &

# `watch` is not installed on macOS by default, so poll instead
while sleep 15; do kubectl get hpa,pods -n agent-sandbox; echo; done
```

If `kubectl top` fails with an x509 error, metrics-server cannot verify the
kubelet's serving certificate. The script prints the `--kubelet-insecure-tls`
patch but **does not apply it**: that flag stops metrics-server verifying what
it scrapes, so a pod able to impersonate a kubelet address could feed it false
metrics that the HPA then acts on. Operator's call.

### Tearing the baseline down

```bash
AWS_PROFILE=sandbox scripts/deploy-baseline.sh --delete
# Deletes the Service first, so the controller can deprovision the NLB before
# its namespace disappears underneath it. Leaves metrics-server and the
# controller in place.
#
# This also removes the section 8 NetworkPolicy, because `gateway.yaml`
# carries the Namespace and deleting it takes every object inside with it.
# Re-apply k8s/security/runner-network-policy.yaml after any redeploy.

# confirm no orphaned load balancer is still billing
aws elbv2 describe-load-balancers --region us-east-1 \
  --query "LoadBalancers[?contains(LoadBalancerName,'k8s-agentsan')].[LoadBalancerName,State.Code,Scheme]" \
  --output table
# An orphan showing "active / internet-facing" is still reachable and still
# billing. Expect an empty table after a successful --delete.
```

---

## 8. Network isolation (`k8s/security/`)

> Status: **applied and verified 2026-10-23.** `test-baseline.sh --no-load`
> exits 0 with all six checks passing. Before it was applied the runner had
> unrestricted egress -- a pod in that Deployment reached
> `https://checkip.amazonaws.com` and got a 200 back through the NAT Gateway.
>
> The HPA load test (`--load-only`) has **not** been run.

| File | What it is |
|---|---|
| `k8s/security/runner-network-policy.yaml` | Default-deny ingress **and** egress for `role: code-executor`. Permits only gateway->runner:8080 and runner->CoreDNS:53. |
| `scripts/test-baseline.sh` | Proves the policy enforces, and that the HPA reacts to real CPU load. |

The header of `runner-network-policy.yaml` explains why the block is
`policyTypes` rather than an `ipBlock`/`except` rule, and why the selector
names the gateway's real label. The header of `test-baseline.sh` explains why
the probes are Python rather than `curl`.

### Confirm nothing has drifted first

Everything below assumes the section 7 baseline is still up. These are all
read-only; this exact sequence was run 2026-10-23 and found nothing to repair.

```bash
AWS_PROFILE=sandbox aws sts get-caller-identity --query Arn --output text
kubectl config current-context
AWS_PROFILE=sandbox terraform -chdir=terraform plan -input=false | tail -3
kubectl -n agent-sandbox get deploy,svc,hpa,netpol,secret
kubectl -n kube-system get deploy metrics-server aws-load-balancer-controller

# the two allow-lists that rot (section 7, "When the gateway stops responding")
curl -s https://checkip.amazonaws.com
kubectl -n agent-sandbox get svc control-plane-gateway \
  -o jsonpath='{.spec.loadBalancerSourceRanges}{"\n"}'
grep public_access_cidrs terraform/terraform.tfvars
```

Expected, and what was actually observed on 2026-10-23:

```
terraform plan  -> No changes. Your infrastructure matches the configuration.
node            -> ip-10-0-152-183  Ready  v1.33.13-eks
gateway         -> 2/2    runner -> 1/1    metrics-server -> 1/1    LBC -> 2/2
hpa             -> cpu: 1%/50%   1  5  1
netpol          -> agent-runner-isolation  role=code-executor
egress IP       -> 203.0.113.10, matches both allow-lists
NLB /healthz    -> 200        NLB anonymous / -> 401
```

Nothing needed repairing. If `netpol` reports `No resources found`, the policy
has been deleted or the namespace was recreated -- re-apply it (see "The
commands" below).

### Prerequisite: enforcement must actually be on

```bash
kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].args}{"\n"}'
# -> must contain "--enable-network-policy=true"
```

Without that flag the API server **accepts the NetworkPolicy and enforces
nothing**. `test-baseline.sh` checks it in preflight and aborts rather than
reporting misleading results.

### The commands

```bash
cd <repo-root>

# 1. Apply the policy.  EXECUTED 2026-10-23
#    kubectl/RBAC only -- no AWS write, so this needs no admin credentials
#    and no AWS_PROFILE prefix.
kubectl apply -f k8s/security/runner-network-policy.yaml

# 2. Prove it enforces.  EXECUTED 2026-10-23, exit 0, all six checks passed.
#    ~30s. Safe to re-run any time.
#
#    It DOES raise the replica count, even though nothing in it touches the
#    Deployment: `kubectl exec python3` burns close to a full core while the
#    interpreter starts, and the runner's CPU *request* is 100m, so a handful
#    of probes read as >1000% utilisation. The 2026-10-23 run took the runner
#    from 1 replica to 4 ("New size: 2 ... New size: 4; reason: cpu resource
#    utilization above target"). It settles back to 1 after the 300s
#    scaleDown window. Not a failure -- and incidentally the first evidence
#    that the HPA reacts to real load at all.
./scripts/test-baseline.sh --no-load

# 3. The HPA load test.  NOT YET RUN.
#    Scales the Deployment to 5 and holds there for ~5 min afterwards
#    (300s scaleDown window). ~8 min total.
./scripts/test-baseline.sh --load-only
```

Observed output of step 2:

```
[ ok ] VPC CNI network policy enforcement is ON.
[ ok ] gateway -> runner:8080 ALLOWED (HTTP:200).
[ ok ] non-gateway pod -> runner:8080 DENIED (timed out).
[ ok ] cluster DNS still resolves from the runner (DNS_OK:172.20.0.1).
[ ok ] IMDS GET  DROPPED (timed out) -- the egress policy is enforcing.
[ ok ] IMDS PUT token DROPPED (timed out) -- the egress policy is enforcing.
[ ok ] public internet (checkip.amazonaws.com) DROPPED (timed out).
```

Run before step 1 and the script exits 1 with *"the runner currently has
unrestricted egress ... there is nothing to test yet"*. That is the preflight
gate, not a test failure -- the same distinction as `deploy-baseline.sh
--check`.

### What step 2 proves, and what it cannot

The decisive line is IMDS flipping from `HTTP:401` to `TIMEOUT`. Baseline,
measured from the runner **before** the policy:

| Probe from the runner, no policy | Result | Meaning |
|---|---|---|
| `https://checkip.amazonaws.com` | HTTP 200, body `198.51.100.30` | full internet egress via the NAT Gateway |
| IMDS `GET /latest/meta-data/` | **HTTP 401 in <10ms** | IMDS itself answered: the network path is open |
| IMDS `PUT /latest/api/token` | timeout | node is `HttpTokens=required`, `HopLimit=1` |
| node role credentials | **not** obtainable | hop limit holds today |

So IMDS was reachable but not exploitable. The policy closes the path as
defence in depth. An `HTTP:401` *after* applying is the pre-policy signature
and means the policy is not selecting the pod -- the script names that case
explicitly instead of printing a bare failure.

DNS is the control. If `cluster DNS still resolves` does not appear, every
`TIMEOUT` below it is meaningless (no network at all, or a broken probe) and
the script says so rather than claiming a pass.

**Settled 2026-10-23:** the VPC CNI policy agent **does** drop link-local
traffic to `169.254.169.254`. That was the one unverified assumption in the
design -- enforcement being on did not guarantee it covered link-local. The
runner now times out on both the IMDS GET and the IMDSv2 token PUT, having
previously received an HTTP 401 from IMDS itself.

The negative control is the other result worth keeping: an unlabelled probe
pod in the same namespace **times out** against `runner:8080`, so the ingress
rule restricts by source rather than merely existing.

### Two things in the manifest that differ from the obvious reading

`app: gateway` matches no pod in this cluster -- the gateway Deployment labels
its pods `app=control-plane-gateway`. Because the policy is default-deny, a
rule written for `app: gateway` would select nothing and silently cut the
gateway off from the runner: an outage with no error event. The rule uses the
real label and deliberately does **not** also allow `app: gateway`, since an
allow for an unused label is a standing hole.

There is **no explicit deny for `169.254.169.254`**, and that is correct.
NetworkPolicy has no deny rule; listing `Egress` in `policyTypes` denies
everything except the one DNS rule. The tempting alternative --
`ipBlock: 0.0.0.0/0` with `except: 169.254.169.254/32` -- is an *allow* for the
entire internet minus IMDS, i.e. the opposite of the intent. Do not "fix" the
policy that way.

### Why the probes are Python and not `curl`

`python:3.11-slim` ships no `curl`, no `nc`, and no `pkill` (verified in both
the runner and gateway containers, 2026-10-23). The obvious test --

```bash
kubectl exec -it <runner-pod> -- curl -m 2 http://169.254.169.254/latest/meta-data/
```

-- exits 127 with *"executable file not found"*, and a script that reads any
non-zero exit as "the packet was dropped" reports a **pass without sending a
packet**. The runner also has `readOnlyRootFilesystem` and, once the policy is
applied, no egress, so installing `curl` is not an option either.

Every probe therefore runs `python3` and prints one outcome token --
`HTTP:<code>`, `TIMEOUT`, `REFUSED`, `DNSFAIL`, `EXEC_FAILED` -- and the caller
branches on the token. A timeout is never inferred from an exit status. This is
the same class of defect as `ISSUES-ENCOUNTERED.md` issue 12. `-it` is dropped
too: `-t` mangles output when stdout is not a terminal.

### Consequences, by design

- **No package installs in the runner.** `pip`, `apt-get`, and all outbound
  HTTP fail. The image must already contain what the workload needs.
- **No AWS API calls** from the runner, including S3 and STS. If one becomes
  legitimate, add a VPC endpoint and an explicit egress rule to its prefix
  list -- do not widen to `0.0.0.0/0`.
- **No Kubernetes API access.** Costs nothing today; the runner's
  ServiceAccount token is already not mounted.
- **Kubelet probes are not exempted.** The runner declares none. Add a
  `livenessProbe` later and this ingress rule drops it -- probes come from the
  node IP -- leaving pods permanently unready. Add an explicit node-CIDR
  ingress rule at that point.

NetworkPolicies are additive: a second policy selecting these pods can only
**widen** what is permitted. Check what any new policy grants the runner.

### Rollback

```bash
kubectl delete -f k8s/security/runner-network-policy.yaml
```

Egress returns to unrestricted immediately. Nothing else is affected -- the
policy selects only `role: code-executor`. The gateway is untouched.

---

## 9. Kata Containers + Cloud Hypervisor (`k8s/kata/`)

> Status as of 2026-10-23: **first install attempt FAILED and was fixed; not
> yet retried.** A `helm install` at 01:44 left the release in
> `pending-install` with the DaemonSet in `CrashLoopBackOff` -- cause and fix
> in "When the install crash-loops" below. The host was **not** damaged and
> containerd was **never restarted** (`/opt/kata` was created but empty, 0 kata
> references in the containerd config, gateway pods kept their uptime).
>
> Current state: `kubectl get runtimeclass` -> `No resources found`; 0 nodes
> with `katacontainers.io/kata-runtime=true`; one crash-looping
> `kata-deploy` pod and a stuck `pending-install` release still to clear.
> Section 5 describes the Terraform-side prerequisite this builds on.

| File | What it is |
|---|---|
| `k8s/kata/kata-setup.yaml` | Helm values pinning the whole install. Not a kubectl manifest -- see below. |
| `k8s/kata/runtimeclass-clh.yaml` | The `kata-clh` RuntimeClass, hand-owned. |
| `scripts/install-kata.sh` | preflight / render / install / verify / delete. |
| `k8s/kata/rendered/` | Generated by `--render` for review before installing. Git-ignored -- regenerate it rather than trusting a stale copy. |

Rationale and trade-offs live in the headers of `k8s/kata/kata-setup.yaml` and
`k8s/kata/runtimeclass-clh.yaml` -- the 404 evidence, why Cloud-Hypervisor-only,
why `deploymentMode: daemonset` over the chart's `job` default, and why the
RuntimeClass is hand-owned rather than chart-managed.

### The requested `kubectl apply` commands return HTTP 404

The task specified:

```bash
# BOTH OF THESE 404. Do not retry them.
kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/main/tools/packaging/kata-deploy/kata-rbac/base/kata-rbac.yaml
kubectl apply -f https://raw.githubusercontent.com/kata-containers/kata-containers/main/tools/packaging/kata-deploy/kata-deploy/base/kata-deploy.yaml
```

Upstream deleted the raw kustomize manifests in the **4.x** rewrite, where
`kata-deploy` became a Rust binary driven by a Helm chart. Confirmed by
diffing the git trees of the two tags (2026-10-23):

```
tag 3.21.0   kata-deploy/base/kata-deploy.yaml   PRESENT
             kata-rbac/base/kata-rbac.yaml       PRESENT
tag 4.3.1    kata-deploy/base/kata-deploy.yaml   ABSENT
             kata-rbac/base/kata-rbac.yaml        ABSENT
             helm-chart/kata-deploy/Chart.yaml   PRESENT
```

The chart still renders the RBAC and the DaemonSet the task asked for. The
3.21.0 manifests remain an option and would match the requested commands
literally; they are not used because they are the removed interface.

### Why the version is not a cosmetic choice

This node runs **containerd 2.3.5** with `/etc/containerd/config.toml` at
**`version = 3`**, and no `/etc/containerd/config.d/` drop-in directory.
containerd 2.x renamed the CRI plugin key from `io.containerd.grpc.v1.cri` to
`io.containerd.cri.v1.runtime`, and a `version = 3` file is **not**
auto-migrated.

An installer that writes the 1.x key registers a runtime handler containerd
never reads. The failure is nasty: `kubectl get runtimeclass` shows `kata-clh`,
the object looks correct, and every pod using it fails at container creation.
Kata 4.x handles this in typed code
(`binary/src/utils/containerd_config_version.rs`); 3.x does it in a 951-line
shell script. Hence the 4.3.1 pin.

### Step 1: verify `/dev/kvm` (read-only, applies nothing)

```bash
cd <repo-root>
./scripts/install-kata.sh --check
```

Two checks, because they answer different questions. The `sandbox.io/kvm`
label is what the **scheduler** uses and what `kata-setup.yaml` selects on, but
it is derived from the instance type in `eks.tf` -- it never probes the device.
The second check reads the device on the host through a privileged pod in
`default` (which carries no Pod Security Standard labels; the same pod is
correctly rejected in `agent-sandbox`, which enforces `restricted`).

A node labelled but without the device would install Kata **successfully**,
get labelled `katacontainers.io/kata-runtime=true`, and then fail every Kata
pod at VM start -- far from the cause.

Observed 2026-10-23:

```
[ ok ] 1 node(s) labelled sandbox.io/kvm=true
       ip-10-0-152-183.ec2.internal
[ ok ] /dev/kvm present -- crw-rw-rw-. 1 root 36 10, 232 Oct 22 18:42
[info] containerd github.com/containerd/containerd/v2 2.3.5+unknown
[info] containerd config version = 3 -- needs the containerd 2.x CRI plugin key
[ ok ] /dev/kvm confirmed on the host, not just inferred from a label
[info] host kernel: 6.12.111-136.204.amzn2023.x86_64
```

The one-liner form, if you only want the scheduler's view:

```bash
kubectl get nodes -L node.kubernetes.io/instance-type,sandbox.io/kvm
kubectl get nodes -l sandbox.io/kvm=true
```

### Step 2: render the chart and read it before applying

```bash
./scripts/install-kata.sh --render
# -> k8s/kata/rendered/kata-deploy-4.3.1.yaml
```

Observed: 9 objects -- 2 ClusterRole, 2 ClusterRoleBinding, 2 ServiceAccount,
1 ConfigMap, 1 DaemonSet (`kata-deploy`), 1 post-delete cleanup Job.
`SHIMS_X86_64 = "clh"`, `nodeSelector: sandbox.io/kvm: "true"`, and
**0 RuntimeClass objects** -- the chart's own RuntimeClass rendering is turned
off so `runtimeclass-clh.yaml` is the single owner.

### Blast radius -- read before step 3

kata-deploy writes `/opt/kata`, edits the host containerd config, and then
restarts containerd (`binary/src/runtime/lifecycle.rs`, `restart_runtime`).

**This cluster has one node.** Restarting containerd restarts **every pod on
it**: both gateway replicas, the agent runner, CoreDNS, aws-node,
metrics-server and the load balancer controller. The gateway's NLB targets go
unhealthy and the endpoint stops answering until they pass health checks again
-- 285s when first measured (section 7). The PodDisruptionBudget does not
help; this is a runtime restart, not an eviction.

What kata-deploy takes to do that, read off the render rather than assumed:

| | |
|---|---|
| `securityContext.privileged` | **false** -- 0 privileged containers |
| RBAC | `nodes` get/patch, `nodes/proxy` get, `daemonsets` get/list/watch. Nothing else. |
| Host mounts, read-only | `/usr/bin` `/usr/sbin` `/usr/local/{bin,sbin}` `/bin` `/sbin` `/boot` `/etc/machine-id` |
| Host mounts, **writable** | `/etc/containerd/` `/opt/kata` `/etc/systemd/system` `/run/systemd/private` `/etc/crio/` `/run/lock` |

Do not read "not privileged" as "not powerful". Writable
`/etc/systemd/system` plus the systemd private D-Bus socket at
`/run/systemd/private` is how it restarts containerd without privilege, and it
is root-equivalent on the host: anything that can ask PID 1 to start a unit
runs arbitrary code as root. The gain over 3.x -- a fully privileged container
-- is that the surface is narrow and enumerable, not that it is small.

### Step 3: install

```bash
./scripts/install-kata.sh
```

Prompts once, before the restart, and refuses to assume yes on a
non-interactive stdin. Then, in order:

1. Preflight and the `/dev/kvm` checks from step 1.
2. Render the chart to `k8s/kata/rendered/`.
3. `helm upgrade --install kata-deploy oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy --version 4.3.1 -n kube-system -f k8s/kata/kata-setup.yaml --wait --timeout 900s`
4. `kubectl -n kube-system rollout status ds/kata-deploy`
5. Wait for `katacontainers.io/kata-runtime=true` on every matching node.
   **Ready is not installed:** the pod reports Ready once its health endpoint
   answers, whereas this label is kata-deploy's own final install step. The
   RuntimeClass selects on it, so Kata pods stay Pending without it.
6. `kubectl apply -f k8s/kata/runtimeclass-clh.yaml` -- last, deliberately.
   Applying it first is accepted by the API server and pods then fail with
   `no runtime for "kata-clh" is configured`.
7. Verify (below).

### Step 4: what "verified" means here

`kubectl get runtimeclass` listing `kata-clh` was the task's requirement. It is
necessary and weak -- the object can exist with nothing behind it. The script
checks four things:

```bash
kubectl get runtimeclass                                    # lists kata-clh
kubectl get runtimeclass kata-clh -o jsonpath='{.handler}'  # == kata-clh
# shim binary actually on the host, and the handler in the containerd config
# (both read through a privileged pod)
# then the one that matters:
```

The decisive check is a **kernel comparison**. A runc container shares the
host kernel; a Kata pod boots its own. So the script runs a pod with
`runtimeClassName: kata-clh` and compares `uname -r` against the node's
`6.12.111-136.204.amzn2023.x86_64`. They must **differ**. If they match, the
pod silently fell back to runc and the script fails hard -- a RuntimeClass
whose pods quietly share the host kernel is worse than none, because workloads
believe they are isolated.

A runc control pod runs the same image under the default runtime and must
report the host kernel. Without it, "different from the host kernel" would be
unfalsifiable.

Run the verification alone, after an install:

```bash
./scripts/install-kata.sh --smoke
```

Before installing, that exits 1 with `kubectl get runtimeclass does NOT list
kata-clh` -- a preflight refusal, not a test failure.

### Running a workload in a VM

```bash
kubectl -n agent-sandbox patch deploy agent-runner --type=merge \
  -p '{"spec":{"template":{"spec":{"runtimeClassName":"kata-clh"}}}}'
```

**Not done, and not implied by installing Kata.** `k8s/apps/runner.yaml` still
has no `runtimeClassName`, so the agent runner remains a runc container
sharing the host kernel. That is deliberate: `runner.yaml` is kept as the runc
baseline and rollback target. Two things to expect when it is switched:

- The runner's effective resource request becomes **350m / 258Mi** (its own
  100m/128Mi plus the RuntimeClass's 130Mi/250m overhead), which changes how
  the scheduler packs the node.
- The NetworkPolicy from section 8 still applies -- policy enforcement is on
  the pod's network namespace, which Kata still has.

### When the install crash-loops

Hit for real on 2026-10-23, first install attempt.

```bash
kubectl -n kube-system get pods -l name=kata-deploy
# -> kata-deploy-87l5p  0/1  CrashLoopBackOff  5

kubectl -n kube-system logs -l name=kata-deploy -c kube-kata --tail=20
# -> Error: DEFAULT_SHIM 'qemu-runtime-rs' must be one of the configured
#           SHIMS for this architecture: [clh]
```

**Cause.** `kata-setup.yaml` sets `shims.disableAll: true` and enables only
`clh`, but `defaultShim.amd64` was left at the chart's default
`qemu-runtime-rs` -- a shim that is no longer installed. kata-deploy validates
that pairing at startup and exits 1.

**Why nothing caught it earlier.** The check lives in the kata-deploy binary,
not in the chart. `helm template` renders a clean 9-object manifest and
`install-kata.sh --render` reported no problem, because rendering never runs
the installer. Any "the manifest is valid" check is blind to this class of
error.

**Fixed** by adding to `kata-setup.yaml`:

```yaml
defaultShim:
  amd64: clh
```

and `install-kata.sh` now cross-checks `DEFAULT_SHIM` against `SHIMS_X86_64`
in the rendered chart during preflight, so the next occurrence is a one-line
refusal before anything is applied:

```
[ ok ] defaultShim 'clh' is among the enabled shims [clh].
```

**Clearing the stuck release.** A release in `pending-install` blocks every
later `helm upgrade --install` with `another operation (install/upgrade/
rollback) is in progress`, and the error does not say how to recover:

```bash
helm -n kube-system status kata-deploy          # -> pending-install
helm -n kube-system uninstall kata-deploy       # clears it
```

`install-kata.sh` now detects a non-`deployed` status and offers to clear it
before retrying. Safe **while the install has not completed** -- as here,
where the host was untouched. If an install *had* partially completed, the
uninstall path restarts containerd, so it is prompted rather than automatic.

To confirm the host was not touched before clearing anything:

```bash
# via a privileged pod, or the SSM path in section 4
ls -d /opt/kata; ls /opt/kata/bin          # dir may exist but must be EMPTY
grep -c kata /etc/containerd/config.toml   # must be 0
kubectl -n agent-sandbox get pods          # uptimes unchanged => no restart
```

### Uninstall

```bash
./scripts/install-kata.sh --delete
```

Prompts, then deletes the RuntimeClass and `helm uninstall`s the release. In
`daemonset` mode kata-deploy reverts the host changes as its pods terminate,
which means **containerd restarts again** -- every pod on the node restarts a
second time. The script waits for `katacontainers.io/kata-runtime` to clear and
warns if it does not, which would mean the revert did not finish and `/opt/kata`
plus the containerd config need checking by hand (section 4 has the SSM path).

Ordering with the rest of the teardown: uninstall Kata **before**
`terraform destroy`, for the same reason as the NLB in section 10 -- Terraform
does not know these host changes exist.

---

## 10. Cost, teardown and follow-ups

### Cost while running

| Item | Approx. on-demand, us-east-1 |
|---|---|
| `c5.metal` node x1 | ~$4.08 / hr (~$98 / day) |
| EKS control plane | ~$0.10 / hr |
| NAT Gateway | ~$0.045 / hr + data |
| NLB (gateway, running since 2026-10-23) | ~$0.0225 / hr + LCU |

**Tear down when idle:**

```bash
# ORDER MATTERS once the baseline is deployed. Delete the Kubernetes objects
# first so the load balancer controller can deprovision the NLB it created.
# Terraform does not know the NLB exists, so destroying the cluster first
# leaves the load balancer and its security group rules orphaned and billing.
AWS_PROFILE=sandbox scripts/deploy-baseline.sh --delete
AWS_PROFILE=sandbox helm -n kube-system uninstall aws-load-balancer-controller

cd terraform
AWS_PROFILE=sandbox terraform destroy    # destructive. Cluster, VPC and NAT.
```

### Known follow-ups

- `198.51.100.20` is an AWS-owned range, so you are egressing via a VPN or
  proxy whose address can rotate. If `kubectl` starts timing out, re-run the
  curl and update `terraform.tfvars`. Widen to the gateway's documented range
  if needed — never to `0.0.0.0/0`, which validation rejects.
- `scripts/apply-and-verify.sh:120` hardcodes `c5.metal` and `$4.08/hour` in
  its confirmation prompt instead of reading `var.node_instance_type`, so that
  warning goes stale if you override the instance type.
- Kata is **written but not installed**. `k8s/kata/` and
  `scripts/install-kata.sh` cover the runtime, the containerd wiring and the
  `kata-clh` RuntimeClass (section 9), and `--check` / `--render` pass against
  the live node -- but `./scripts/install-kata.sh` has not been run, because it
  restarts containerd on the only node. Terraform still installs no Kata and
  still only guarantees a node exposing `/dev/kvm`.
- Even after installing Kata, `k8s/apps/runner.yaml` has no
  `runtimeClassName`, so the agent runner stays a `runc` container sharing the
  host kernel. Switch it with `scripts/verify-microvm.sh --migrate`.
- State is local. Migrate to the encrypted, versioned S3 backend stubbed in
  `main.tf` before sharing this stack.
- The runner NetworkPolicy is applied and verified (section 8), but the
  **gateway** pods still have no policy of their own: their egress is
  unrestricted. Narrowing it risks breaking the NLB health checks, so it was
  left out of scope.
- `scripts/test-baseline.sh --load-only` has never been run, so the HPA has
  only been observed at idle (`cpu: 0%/50%`). Scale-out under real load is
  still unverified.
- The gateway's `/32` allow-list in `k8s/apps/gateway.yaml` is a **second**
  IP allow-list, separate from `cluster_endpoint_public_access_cidrs` in
  `terraform.tfvars`. Nothing keeps them in sync and both go stale together.
- `POST /v1/dispatch` on the gateway returns 501 on purpose. The shared bearer
  token authenticates but does not authorize; per-caller identity is needed
  before that route does anything.
- The `[default]` AWS profile still holds expired static keys, so every
  command here needs `AWS_PROFILE=sandbox`. Clean out
  `~/.aws/credentials` so the working profile is the default.
