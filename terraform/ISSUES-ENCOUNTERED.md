# Issues encountered

Session date: **2026-10-22**. Cluster `secure-agent-sandbox`, region
`us-east-1`, account `111122223333`.

Ordered roughly as they were hit. Issue 6 is the substantial one — the
API-server connectivity problem and its two distinct VPN-dependent causes.

**Status at time of writing:** cluster `ACTIVE`, node `Healthy`, `kubectl`
still unverified. Blocked on expired AWS credentials (issue 7).

---

## 1. `c8i.xlarge` + nested virtualization is impossible on AWS provider 5.x

**Symptom.** Spec asked for `c8i.xlarge` with nested virtualization / KVM for
Kata Containers, under the project's pin of AWS provider `~> 5.0`.

**Finding.** `c8i` *does* support nested virtualization, but enabling it
requires `cpu_options.nested_virtualization`, which does not exist in the
provider 5.x schema. Probed both:

```bash
mkdir -p /tmp/tfprobe && cd /tmp/tfprobe
printf 'terraform {\n  required_providers {\n    aws = {\n      source = "hashicorp/aws"\n      version = "~> 5.0"\n    }\n  }\n}\n' > p.tf
terraform init && terraform providers schema -json \
  | jq '.provider_schemas["registry.terraform.io/hashicorp/aws"].resource_schemas.aws_launch_template.block.block_types.cpu_options.block.attributes | keys'
```

| Provider | `cpu_options` attributes |
|---|---|
| `~> 5.0` (v5.100.0) | `amd_sev_snp`, `core_count`, `threads_per_core` |
| `~> 6.0` (v6.70.0) | `amd_sev_snp`, `core_count`, **`nested_virtualization`**, `threads_per_core` |

Also: EKS module v21 and VPC module v6 both require provider `>= 6.0`.

**Resolution.** Kept provider `~> 5.0` and used `c5.metal` — bare metal
exposes VT-x natively, so no `cpu_options` flag is needed. Pinned EKS
`20.37.2` / VPC `5.21.0` / IAM `5.60.0`.

**Trade-off accepted.** `c5.metal` is ~$4.08/hr vs ~$0.20/hr for
`c8i.xlarge` — roughly 20x. The alternative was bumping the provider to 6.x.

**Guard added.** A `terraform_data` precondition in `main.tf` fails the plan
if `node_instance_type` is not bare metal, plus an `endswith(..., ".metal")`
variable validation. Deliberately *not* a `check` block: those only emit
warnings, and a Kata-incapable cluster that looks healthy is worse than a
failed plan.

---

## 2. EKS 1.29 and 1.30 no longer exist

**Symptom.** Spec said "EKS Kubernetes version 1.29+".

**Finding.**

```bash
aws eks describe-addon-versions --addon-name vpc-cni --region us-east-1 \
  --query 'addons[0].addonVersions[0].compatibilities[].clusterVersion'
# -> 1.31 .. 1.37
```

1.29 and 1.30 are past end of life and cannot be created.

**Resolution.** Defaulted `kubernetes_version = "1.33"`, with validation
rejecting anything below 1.29 so the stated floor is still enforced.

---

## 3. Node group IAM role name exceeded the `name_prefix` limit

**Symptom.** First `terraform plan` failed:

```
Error: expected length of name_prefix to be in the range (1 - 38),
       got secure-agent-sandbox-ng-eks-node-group-
```

**Cause.** The EKS module derives the node IAM role from the node group name
as `name_prefix = "<name>-eks-node-group-"`. With
`name = "${var.cluster_name}-ng"` that is 39 characters against a 38 cap.

**Resolution.** Dropped the explicit `name` so the map key `sandbox` is used
(23 chars). Tightened `cluster_name` validation to 40 characters to leave
headroom for all derived prefixes.

**Lesson.** `terraform validate` passes this — it only checks syntax. Only a
real `plan` catches provider-side constraint violations.

---

## 4. Bare IP address rejected by CIDR validation

**Symptom.** `curl -s https://checkip.amazonaws.com` returns
`198.51.100.20`; pasting it directly produced a validation error.

**Cause.** `cluster_endpoint_public_access_cidrs` takes CIDR *blocks*. The
`can(cidrhost(c, 0))` validation rejects a bare address.

**Resolution.** Append `/32`: `["198.51.100.20/32"]`.

---

## 5. `terraform apply tfplan` started with no confirmation prompt

**Symptom.** Believed `plan` was still running; it was actually `apply`, four
minutes in and creating billable resources.

**Cause.** Applying a *saved* plan file implies `-auto-approve`. Terraform
considers the review of the plan to be the approval, so it never asks.

| | `terraform apply` | `terraform apply tfplan` |
|---|---|---|
| Re-plans | yes | no |
| Prompts `yes` | **yes** | **no — starts immediately** |
| Reads tfvars | yes | no, values are baked in |

**Resolution.** Let it finish. Interrupting mid-apply (a second Ctrl-C
hard-kills) can create resources in AWS that never land in state — orphans
that must be found and deleted by hand, and an untracked EKS control plane
bills indefinitely.

Apply completed cleanly: exit 0, 75 resources, lock released.

**Mitigation available.** `./scripts/apply-and-verify.sh apply` requires you
to retype the cluster name and prints a cost warning first. Or use bare
`terraform apply`, which prompts.

---

## 6. `kubectl` cannot reach the API server — two different causes

**Symptom, identical in both cases:**

```
[fail] API server unreachable after 5m
Unable to connect to the server: dial tcp 32.197.108.232:443: i/o timeout
```

```bash
curl -k https://<endpoint>/version
# curl: (28) Connection timed out    connect=0.000000s
```

`connect=0.000000s` means packets were **silently dropped**, never refused.
This is the important detail: both a corporate egress block and a
non-allow-listed source IP drop traffic silently, so **the symptom cannot
distinguish them.** The EKS security group does not send RSTs to
non-allow-listed sources.

Throughout, the cluster itself was fine — `status: ACTIVE`, node group
`health.issues: []`, node `InService / Healthy`.

### Diagnostic sequence that separates the causes

```bash
# 1. Is DNS correct, or intercepted? Check the resolved IPs against AWS ranges.
dig +short <cluster-endpoint>
curl -s https://ip-ranges.amazonaws.com/ip-ranges.json -o /tmp/awsip.json
python3 -c "
import json,ipaddress
d=json.load(open('/tmp/awsip.json'))
ip=ipaddress.ip_address('<resolved-ip>')
print([(p['ip_prefix'],p['region'],p['service']) for p in d['prefixes']
       if ip in ipaddress.ip_network(p['ip_prefix'])])"

# 2. Is general AWS egress working, or only this endpoint blocked?
curl -sS -o /dev/null -w "%{http_code} connect=%{time_connect}s\n" \
  https://eks.us-east-1.amazonaws.com/        # 403 == reachable

# 3. Is external DNS reachable? A blocked public resolver means a locked network.
dig +short +time=5 @1.1.1.1 checkip.amazonaws.com

# 4. Does the live allow-list match the live egress IP?
aws eks describe-cluster --name secure-agent-sandbox --region us-east-1 \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs'
curl -s https://checkip.amazonaws.com
```

### Case A — VPN **on** (Amazon corporate network)

Observed:

| Probe | Result |
|---|---|
| Resolvers in use | `11.176.64.4`, `172.16.173.64`, `172.18.193.221` — Amazon internal |
| `dig @8.8.8.8` / `@1.1.1.1` | **timed out — public resolvers blocked** |
| Endpoint IPs | `184.197.60.218`, `32.197.108.232` |
| Those IPs vs `ip-ranges.json` | `184.192.0.0/12`, `32.192.0.0/13` — genuine us-east-1 **EC2** |
| `eks.us-east-1.amazonaws.com` | `403`, connect `0.175s` — **reachable** |
| Cluster endpoint :443 | **timeout**, connect `0.000000s` |
| `checkip` egress | `198.51.100.20` |
| That IP vs `ip-ranges.json` | `54.240.197.0/24`, listed **eu-west-1** |

DNS was *correct*, not hijacked. The AWS *service* API worked while the
*per-cluster* endpoint on an EC2-range IP did not.

**Two contributing causes, both plausible:**

1. Corporate egress filtering blocks direct 443 to arbitrary EC2 public IPs.
2. Corporate NAT is a **pool**. `checkip` reported an address in an
   **eu-west-1** range while the target was us-east-1 — strong evidence the
   observed egress IP is a shared proxy's, not the one used for the actual
   flow. Pinning a single `/32` was never going to be reliable here.

#### Workaround for case A — SSM port-forward to the private endpoint

Needs no security weakening and no new infrastructure. Works because the
tunnel terminates *on the node*, so the endpoint resolves to the private ENI
IPs inside the VPC. The AWS APIs SSM needs are reachable on the corporate
network. This is why the node role carries `AmazonSSMManagedInstanceCore`
and there is no SSH key or bastion.

Preconditions (both verified):

```bash
aws ssm describe-instance-information --region us-east-1 \
  --filters "Key=InstanceIds,Values=i-0123456789abcdef0" \
  --query 'InstanceInformationList[].{ping:PingStatus,agent:AgentVersion}'
# -> Online, 3.3.5390.0
command -v session-manager-plugin     # -> 1.2.835.0
```

Terminal 1 — open the tunnel, leave it running:

```bash
aws ssm start-session \
  --region us-east-1 \
  --target i-0123456789abcdef0 \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<ENDPOINT_ID>.gr7.us-east-1.eks.amazonaws.com"],"portNumber":["443"],"localPortNumber":["8443"]}'
```

Terminal 2 — repoint kubectl. `--tls-server-name` is required so the
certificate still validates against the real hostname:

```bash
kubectl config set-cluster arn:aws:eks:us-east-1:111122223333:cluster/secure-agent-sandbox \
  --server=https://localhost:8443 \
  --tls-server-name=<ENDPOINT_ID>.gr7.us-east-1.eks.amazonaws.com

kubectl get nodes -o wide
```

To revert to the direct endpoint later:

```bash
aws eks update-kubeconfig --region us-east-1 --name secure-agent-sandbox
```

### Case B — VPN **off** (home / ISP network)

Disconnecting changed the picture but did **not** fix it.

| Probe | Result |
|---|---|
| `dig @1.1.1.1` | **works** — `52.16.217.12`. Egress filtering gone. |
| `checkip` egress | `203.0.113.10` (was `198.51.100.20`) |
| Cluster allow-list | still `198.51.100.20/32` — **stale** |
| Cluster endpoint :443 | **timeout**, connect `0.000000s` |

With egress filtering eliminated, cause 1 is ruled out and cause 2 is
isolated: the allow-list no longer contains the current source IP, so the
EKS security group drops the packets.

#### Workaround for case B — update the allow-list

```bash
cd <repo-root>/terraform
curl -s https://checkip.amazonaws.com                  # get current IP
# set terraform.tfvars: cluster_endpoint_public_access_cidrs = ["<IP>/32"]
terraform plan -out=tfplan                             # expect 1 to change, 0 to destroy
terraform apply tfplan
```

This is an **in-place update** to the cluster's `vpc_config`. It does not
replace the cluster. Takes ~2 minutes.

Fragile: a home/ISP address changes on lease renewal or router reboot, and
reconnecting to the VPN makes it stale again.

### Recommended end state

Both cases share one root problem: authenticating to AWS from a network whose
egress identity you do not control. The durable fix removes the public
endpoint from the equation:

```hcl
# terraform.tfvars
cluster_endpoint_public_access       = false
cluster_endpoint_public_access_cidrs = []
```

Then reach the API over the SSM tunnel above. Strictly tighter posture, no
loss of access, and no more chasing IPs. The private endpoint is always
enabled, so nothing else changes.

> Note: `0.0.0.0/0` is rejected by variable validation, and
> `cluster_endpoint_public_access = true` with an empty list fails a
> precondition — EKS silently reads an empty list as `0.0.0.0/0`.

---

## 7. AWS credentials expired on VPN disconnect

**Symptom.**

```
Error: operation error STS: GetCallerIdentity, StatusCode: 403,
api error ExpiredToken: The security token included in the request is expired
```

**Cause.** Disconnecting the VPN ended the federated credential session.

**Resolution.**

Re-authenticate with whatever issues your credentials, then confirm:

```bash
aws sso login --profile sandbox        # or re-run your credential helper
aws sts get-caller-identity --profile sandbox
```

The durable fix was a profile that refreshes itself instead of one-shot
static keys -- `RUNBOOK.md` section 3a.

**Note.** This is a real tension with the case-B workaround: staying off VPN
keeps the direct endpoint usable but can complicate credential refresh. The
case-A/SSM approach does not have this problem.

---

## 8. Node group name is not what you set

**Symptom.** `aws eks describe-nodegroup --nodegroup-name sandbox` returned
`ResourceNotFoundException`.

**Cause.** The EKS module uses `name_prefix`, so the real name carries a
timestamp suffix: `sandbox-2026102218394302210000001d`.

**Resolution.** Resolve it rather than hardcoding:

```bash
NG=$(aws eks list-nodegroups --cluster-name secure-agent-sandbox \
  --region us-east-1 --query 'nodegroups[0]' --output text)
```

---

## 9. Network-policy verification gave a false negative (fixed)

**Symptom.** The `verify` step's NetworkPolicy check reported "does NOT look
enforced" on a cluster where enforcement was in fact active.

**Cause.** Two wrong assumptions about how the addon's
`{"enableNetworkPolicy":"true"}` surfaces on the cluster:

| Checked | Reality |
|---|---|
| `ENABLE_NETWORK_POLICY` env on `aws-node` | **never set** — returns empty |
| container named `aws-eks-nag` | actual name is **`aws-eks-nodeagent`** (and `aws-eks-nag` is not a substring of it, so the grep failed) |

**The actual signals**, confirmed on the live cluster:

```bash
# 1. the agent container's args -- the authoritative signal
kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].args}'
# -> ... --enable-network-policy=true ...

# 2. enforcing mode on the aws-node container
kubectl -n kube-system get ds aws-node \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-node")].env[?(@.name=="NETWORK_POLICY_ENFORCING_MODE")].value}'
# -> standard

# 3. the CRD the agent installs
kubectl get crd policyendpoints.networking.k8s.aws
# -> present

# 4. what EKS reports for the addon
aws eks describe-addon --cluster-name secure-agent-sandbox --addon-name vpc-cni \
  --region us-east-1 --query 'addon.configurationValues'
# -> {"enableNetworkPolicy":"true"}
```

**Resolution.** `scripts/apply-and-verify.sh` now keys off
`--enable-network-policy=true` in the `aws-eks-nodeagent` args and reports
the enforcing mode and CRD alongside. Re-run against the live cluster:
`NetworkPolicy is enforced, enforcing mode: standard`.

**Lesson.** A verification that can only fail open is worse than none — it
trains you to ignore it. This one failed *closed* (false alarm), which is the
safer direction, but still sent diagnosis the wrong way.

---

## 10. Probe Job failed: `run()` piped ANSI escapes into `kubectl apply` (fixed)

**Symptom.**

```
Apply this probe Job? [y/N] y
error: error parsing STDIN: error converting YAML to JSON:
       yaml: control characters are not allowed
```

**Cause.** The script's `run()` helper echoes the command it is about to
execute, and that banner went to **stdout**:

```bash
run() {
  printf '\033[2m    $ %s\033[0m\n' "$*"   # <- stdout
  "$@"
}
```

It was then used on the left of a pipe:

```bash
run kubectl create namespace "$PROBE_NS" --dry-run=client -o yaml \
  | kubectl apply -f -
```

So `kubectl apply` received the dim-grey banner — `\033[2m...\033[0m` — as the
first line of its stdin. Those escapes are control characters, which YAML
forbids. The namespace was never created.

**Resolution, two parts:**

1. The instance — replaced the `create --dry-run | apply` pipeline with an
   idempotent `get || create`, keeping pipelines out of `run()` entirely.
2. The class — `run()` now writes its banner to **stderr**, so using it in a
   pipeline can no longer corrupt the next command's stdin.

**Lesson.** A helper that writes decoration to stdout is unsafe in any
pipeline. Diagnostic output belongs on stderr.

---

## 11. `/dev/kvm` confirmed present — Kata prerequisite satisfied

Not a defect; recording the result, since this was the one claim the AWS API
cannot verify and the whole reason for choosing bare metal.

```
crw-rw-rw-    1 root  36   10, 232  /dev/kvm
crw-rw-rw-    1 root  36   10, 241  /dev/vhost-vsock
```

Character devices `10,232` (`/dev/kvm`) and `10,241` (`/dev/vhost-vsock`) are
both present on the `c5.metal` node. `vhost-vsock` matters too: Kata uses
vsock for agent communication between host and guest VM.

This closes the chain that issue 1 opened — bare metal was selected
specifically because provider 5.x cannot enable nested virtualization, and
the node does in fact expose the devices Kata needs.

---

## 12. Auth-gate check called a connection failure an "exposure" (fixed)

**My bug, and the worst kind: it produced a false security alarm whose
remediation was destructive. The operator followed it and deleted a working
Service.**

Observed during the first real run of `scripts/deploy-baseline.sh`:

```
[info] waiting for targets to go healthy (105s, last=000000)
[ ok ] /healthz reachable through the NLB (unauthenticated, by design).
[fail] ANONYMOUS REQUEST RETURNED 000000, EXPECTED 401.
    An internet-facing gateway that serves unauthenticated callers is
    not deployed, it is exposed. Fix before using this endpoint:
      kubectl -n agent-sandbox delete svc control-plane-gateway
```

The Service was deleted. It had been working.

### Two independent defects

**1. `000000` is not an HTTP status.** The code was:

```bash
# WRONG
CODE="$(curl -s -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null || echo 000)"
```

`curl` **already** writes `000` via `-w '%{http_code}'` when it cannot
connect, *and* exits non-zero. So the `|| echo 000` fallback appends a second
`000` and the variable becomes `000000` -- a value that matches no comparison
in the script. Fixed by removing the fallback and centralising it:

```bash
http_code() {
  curl -s -o /dev/null --max-time 10 -w '%{http_code}' "$@" 2>/dev/null || true
}
```

**2. "Could not connect" was classified as "serving anonymous callers."** The
logic was `if 401 -> ok; elif 503 -> warn; else -> FAIL(exposed)`. `000` fell
into `else`. But `000` means **nothing was served at all**, which is the
*opposite* of an exposure. The check inverted its own semantics in exactly
the case it was most likely to hit.

Only a 2xx/3xx to an anonymous caller is a breach. Rewritten as a `case`:

| Anonymous response | Verdict |
|---|---|
| `401` | gate working |
| `503` | gate closed, Secret not reaching pods -- not an exposure |
| `000` | never connected -- not an exposure, retry |
| `2xx` / `3xx` | **genuine breach**, hard fail |
| anything else | unexpected, warn only |

The retry matters too: a target that has only just gone healthy can answer one
request and refuse the next while the second AZ's NLB node is still
registering. One `000` is a race, not a verdict, so `/` is now retried four
times before any conclusion.

### A third defect found while fixing it

The health-check budget was **240s**. Measured time for a fresh NLB's targets
to go healthy in us-east-1 on 2026-10-23: **285s**. So the check would have
timed out and reported failure even with the `000` bug fixed. Raised to 420s
via `GATE_TIMEOUT_SECONDS`, and the "~2-3 min" hint corrected to ~5 min.

### Verified after the fix

The gate itself was never wrong. Tested from inside the cluster against a pod
IP, and then end to end through the rebuilt NLB:

| Request | Code |
|---|---|
| `/healthz` anonymous | 200 |
| `/` anonymous | **401** |
| `/` wrong token | **401** |
| `/` correct token | 200 |
| `POST /v1/dispatch` correct token | 501 |

### Lesson

A security check that fails closed on its *own* failure is not fail-safe --
it is a denial-of-service against the operator, and it trains them to ignore
the alarm. Distinguish **"I observed something bad"** from **"I could not
observe anything"**; they are different states and only the first justifies a
destructive remediation. The `fail` path should never have named a `delete`
command for a condition it had not actually confirmed.

Noted separately: the in-cluster probe needed an explicit `securityContext`
override because the `agent-sandbox` namespace enforces the `restricted` Pod
Security Standard, which rejects a bare `kubectl run`. That part worked as
intended.

---

## 13. `test-baseline.sh --no-load` silently scaled the runner 1 -> 4 (fixed)

2026-10-23. The script's own documentation said `--no-load` "does not touch
replica count". It does.

**Observed.** A `--no-load` run finished with all six checks passing, and the
Deployment at **4 replicas**:

```
$ kubectl -n agent-sandbox describe hpa agent-runner
  Normal  SuccessfulRescale  2m5s  New size: 2; reason: cpu resource utilization above target
  Normal  SuccessfulRescale  95s   New size: 4; reason: cpu resource utilization above target
```

**Cause.** Nothing in checks 1 and 2 touches the Deployment. But every probe
is a `kubectl exec python3`, and a CPython interpreter start burns close to a
full core for a fraction of a second. The runner's CPU **request** is `100m`,
and the HPA target is 50% *of the request* -- so a handful of probes land in a
15s metrics window as >1000% utilisation and the autoscaler does precisely
what it was configured to do. The temporary `python3 -m http.server` listener
from check 1 contributes as well.

**Why it mattered.** Not harmful -- it settles back to 1 after the 300s
scaleDown window -- but the claim was false, and a reader who trusts a
"read-only" label will go hunting for a phantom scale-out, or worse, assume
something else caused it. The false claim is the defect, not the behaviour.

**Fixed.** The header NOTE, `--help`, and `RUNBOOK.md` section 8 all now state
the side effect with the measured numbers, and the script prints the replica
count in its verdict when it is above 1, explaining why.

**Worth keeping:** this was the first evidence that the HPA reacts to real CPU
load at all, obtained by accident. `--load-only` still has not been run, so
deliberate scale-out to `maxReplicas` remains unverified.

**Lesson.** "This check is read-only" is a claim about the whole system, not
about the lines of code you wrote. Observing a cluster costs CPU, and a
cluster configured to react to CPU will react to being observed.

## Known defects in this repo

- `scripts/apply-and-verify.sh:160` — the unreachable-API failure message
  blames a rotated egress IP. That is only one of the causes (see issue 6)
  and it sent diagnosis down the wrong path initially. It should also check
  general AWS reachability and whether public resolvers are blocked.
- `scripts/apply-and-verify.sh:120` — hardcodes `c5.metal` and `$4.08/hour`
  in the confirmation prompt instead of reading `var.node_instance_type`, so
  the cost warning goes stale if the instance type is overridden.
- The script's `plan` and `apply` modes have still never been executed.
  `verify` has now run end to end against a live cluster, after the fixes in
  issues 9 and 10.
- The **gateway** pods still have no NetworkPolicy; their egress is
  unrestricted. The runner is covered as of 2026-10-23 (`RUNBOOK.md` section 8).
- The runner policy is not in Terraform state, so `terraform plan` reports no
  drift if it is deleted, and `deploy-baseline.sh --delete` removes it as
  collateral with the Namespace.
- Four of the five shipped script bugs so far (issues 9, 10, 12 and 13) were
  in **verification** code, not in the infrastructure it checks. Verification
  logic is the least-tested code in this repo and has caused the most damage;
  issue 12 is the only one that triggered a destructive action, and issue 13
  is the only one where the code was right and the documentation was wrong.

## Cost reminder

~$4.23/hr while running (~$98/day), dominated by the `c5.metal` node.

```bash
terraform destroy
```
