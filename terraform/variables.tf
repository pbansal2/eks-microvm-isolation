variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Environment name, used in tags."
  type        = string
  default     = "dev"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the resource name prefix."
  type        = string
  default     = "secure-agent-sandbox"

  validation {
    condition = can(regex("^[a-zA-Z0-9][a-zA-Z0-9-]{0,39}$", var.cluster_name))
    error_message = join(" ", [
      "cluster_name must be 1-40 alphanumeric/hyphen characters starting with an",
      "alphanumeric. The 40-char ceiling leaves room for the derived IAM role,",
      "security group and log group name prefixes.",
    ])
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    EKS control plane minor version. EKS standard support currently covers
    1.31 through 1.37; 1.29 and 1.30 have reached end of life and can no
    longer be created. Check `aws eks describe-addon-versions` before bumping.
  EOT
  type        = string
  default     = "1.33"

  validation {
    condition     = can(regex("^1\\.(2[9]|3[0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be 1.29 or newer, in '1.NN' form."
  }
}

###############################################################################
# Networking
###############################################################################

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid CIDR of /20 or larger to fit the subnet layout."
  }
}

variable "az_count" {
  description = "Number of availability zones to spread subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4 (EKS requires at least 2)."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Use one NAT Gateway for all private subnets instead of one per AZ.
    true is a dev cost optimization (~$32/mo instead of ~$64/mo) and makes the
    NAT's AZ a single point of failure. Set false for production.
  EOT
  type        = bool
  default     = true
}

variable "enable_flow_logs" {
  description = "Emit VPC Flow Logs to CloudWatch Logs for network audit."
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch Logs retention for VPC Flow Logs."
  type        = number
  default     = 7
}

###############################################################################
# Cluster endpoint exposure
###############################################################################

variable "cluster_endpoint_public_access" {
  description = <<-EOT
    Expose the Kubernetes API server endpoint to the internet, restricted to
    cluster_endpoint_public_access_cidrs. The private endpoint is always on.
    Set false and reach the API over VPN/bastion/SSM for the tightest posture.
  EOT
  type        = bool
  default     = true
}

# Defaults to an EMPTY list, which is not a usable value: with public access on
# (the default), a precondition in main.tf fails the plan until an operator
# states who may reach the API server. Empty cannot be allowed through,
# because EKS reads an empty list as 0.0.0.0/0. The endpoint is
# IAM/SigV4-authenticated, but an unrestricted public endpoint still exposes
# the control plane to credential-stuffing and CVE scanning from the whole
# internet.
variable "cluster_endpoint_public_access_cidrs" {
  description = <<-EOT
    Source CIDRs allowed to reach the public API server endpoint.
    Use your own address, e.g. ["203.0.113.4/32"]. Discover it with:
      curl -s https://checkip.amazonaws.com
    0.0.0.0/0 is rejected.
  EOT
  type        = list(string)
  default     = []

  # Note: "non-empty when public access is enabled" is enforced as a
  # precondition in main.tf, not here. Variable validation blocks cannot
  # reference another variable before Terraform 1.9, and this module targets
  # >= 1.5.

  validation {
    condition = !anytrue([
      for c in var.cluster_endpoint_public_access_cidrs :
      contains(["0.0.0.0/0", "::/0"], trimspace(c))
    ])
    error_message = join(" ", [
      "0.0.0.0/0/::/0 is not allowed on the EKS public endpoint.",
      "Scope it to your egress address (curl -s https://checkip.amazonaws.com),",
      "your corporate ranges, or set cluster_endpoint_public_access = false.",
    ])
  }

  validation {
    condition = alltrue([
      for c in var.cluster_endpoint_public_access_cidrs : can(cidrhost(c, 0))
    ])
    error_message = "Every entry must be a valid CIDR block."
  }
}

variable "addon_versions" {
  description = <<-EOT
    Pinned EKS addon versions. Pinned rather than `most_recent = true` so
    that plans stay clean and upgrades are deliberate -- see eks.tf.

    These must be compatible with var.kubernetes_version. After bumping that,
    re-check these. List what is available:

      for a in vpc-cni kube-proxy coredns aws-ebs-csi-driver; do
        aws eks describe-addon-versions --addon-name $a \
          --kubernetes-version 1.33 --region us-east-1 \
          --query "addons[0].addonVersions[0].addonVersion" --output text
      done

    Values below were the latest available for Kubernetes 1.33 as of
    2026-10-22. Because they are pinned, security patches are NOT picked up
    automatically; re-run the command above periodically.
  EOT
  type        = map(string)

  default = {
    vpc-cni            = "v1.23.2-eksbuild.3"
    kube-proxy         = "v1.33.10-eksbuild.52"
    coredns            = "v1.13.2-eksbuild.51"
    aws-ebs-csi-driver = "v1.67.1-eksbuild.1"
  }

  validation {
    condition = alltrue([
      for a in ["vpc-cni", "kube-proxy", "coredns", "aws-ebs-csi-driver"] :
      can(var.addon_versions[a])
    ])
    error_message = "addon_versions must contain keys: vpc-cni, kube-proxy, coredns, aws-ebs-csi-driver."
  }
}

variable "cluster_log_retention_days" {
  description = "CloudWatch Logs retention for EKS control plane logs."
  type        = number
  default     = 30
}

###############################################################################
# Node group
###############################################################################

variable "node_instance_type" {
  description = <<-EOT
    Instance type for the managed node group. Must be a bare metal type on
    AWS provider ~> 5.0: Kata Containers needs /dev/kvm, and the alternative
    (nested virtualization on c8i/m8i/r8i) requires
    cpu_options.nested_virtualization, which only exists in provider >= 6.0.
    c5.metal: 96 vCPU / 192 GiB, ~$4.08/hr on-demand in us-east-1.
  EOT
  type        = string
  default     = "c5.metal"

  validation {
    condition     = endswith(var.node_instance_type, ".metal")
    error_message = "node_instance_type must be a *.metal type to expose /dev/kvm for Kata Containers."
  }
}

variable "node_desired_size" {
  description = "Desired number of nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_min_size" {
  description = "Minimum number of nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_max_size" {
  description = "Maximum number of nodes in the managed node group."
  type        = number
  default     = 1
}

variable "node_disk_size" {
  description = "Root EBS volume size in GiB for each node."
  type        = number
  default     = 50

  validation {
    condition     = var.node_disk_size >= 30
    error_message = "node_disk_size must be at least 30 GiB to hold the AL2023 image plus Kata rootfs images."
  }
}

variable "tags" {
  description = "Additional tags applied to every resource."
  type        = map(string)
  default     = {}
}
