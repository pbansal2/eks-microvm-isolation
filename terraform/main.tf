###############################################################################
# Providers & global wiring
#
# Credentials are NEVER declared here. Authentication is resolved from the
# ambient AWS credential chain (env vars, SSO cache, instance/role profile).
###############################################################################

terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State contains the cluster CA bundle and OIDC metadata. Keep it out of git
  # (see .gitignore) and migrate to a versioned, encrypted S3 backend before
  # this configuration is shared with anyone else:
  #
  # backend "s3" {
  #   bucket       = "<your-tf-state-bucket>"
  #   key          = "secure-agent-sandbox/terraform.tfstate"
  #   region       = "us-east-1"
  #   encrypt      = true
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = local.tags
  }
}

###############################################################################
# Discovery
###############################################################################

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

# c5.metal is not offered in every us-east-1 AZ (it is absent from us-east-1e).
# Intersecting the offerings with the available AZs keeps `apply` from failing
# late with an Unsupported/InsufficientInstanceCapacity error.
data "aws_ec2_instance_type_offerings" "node" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.node_instance_type]
  }
}

###############################################################################
# Locals
###############################################################################

locals {
  # AZs that both exist and can actually run the requested node instance type.
  candidate_azs = sort(tolist(setintersection(
    toset(data.aws_availability_zones.available.names),
    toset(data.aws_ec2_instance_type_offerings.node.locations),
  )))

  azs = slice(local.candidate_azs, 0, var.az_count)

  # 10.0.0.0/16 carved into /20s: public at the bottom, private at the top,
  # leaving the middle range free for future tiers (databases, VPC endpoints).
  public_subnet_cidrs  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  private_subnet_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i + 8)]

  tags = merge(
    {
      Project     = var.cluster_name
      Environment = var.environment
      ManagedBy   = "terraform"
    },
    var.tags,
  )
}

###############################################################################
# Guardrails
#
# These are preconditions, not `check` blocks: `check` assertions only emit
# warnings, and both of these conditions produce a cluster that looks healthy
# but cannot run Kata workloads. They must fail the plan outright.
###############################################################################

data "aws_ec2_instance_type" "node" {
  instance_type = var.node_instance_type
}

resource "terraform_data" "preflight" {
  input = {
    instance_type = var.node_instance_type
    bare_metal    = data.aws_ec2_instance_type.node.bare_metal
    azs           = local.azs
  }

  lifecycle {
    # Kata Containers requires /dev/kvm. That means either a bare metal
    # instance (VT-x exposed natively) or a virtual instance with nested
    # virtualization enabled -- and nested virtualization cannot be set from
    # AWS provider 5.x, whose aws_launch_template.cpu_options has no
    # `nested_virtualization` argument (verified against v5.100.0). On this
    # provider pin, bare metal is the only viable option.
    precondition {
      condition = data.aws_ec2_instance_type.node.bare_metal
      error_message = join(" ", [
        "node_instance_type '${var.node_instance_type}' is not a bare metal instance,",
        "so /dev/kvm will not be present and Kata Containers cannot start VMs.",
        "Either use a *.metal type, or move to AWS provider ~> 6.0 and set",
        "cpu_options.nested_virtualization = \"enabled\" on a c8i/m8i/r8i type.",
      ])
    }

    precondition {
      condition = length(local.candidate_azs) >= var.az_count
      error_message = join(" ", [
        "Only ${length(local.candidate_azs)} availability zone(s) in ${var.region}",
        "offer ${var.node_instance_type}, but az_count = ${var.az_count}.",
      ])
    }

    # A public endpoint with an empty allow-list is a misconfiguration, not a
    # lockdown: EKS treats an empty public_access_cidrs list as 0.0.0.0/0.
    precondition {
      condition = (
        !var.cluster_endpoint_public_access ||
        length(var.cluster_endpoint_public_access_cidrs) > 0
      )
      error_message = join(" ", [
        "cluster_endpoint_public_access is true but",
        "cluster_endpoint_public_access_cidrs is empty, which EKS interprets as",
        "0.0.0.0/0. Set the allow-list (curl -s https://checkip.amazonaws.com)",
        "or set cluster_endpoint_public_access = false.",
      ])
    }
  }
}
