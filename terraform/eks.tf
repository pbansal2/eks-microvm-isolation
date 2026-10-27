###############################################################################
# IRSA roles for the managed addons
#
# vpc-cni and aws-ebs-csi-driver get their own scoped IAM roles bound to their
# service accounts, rather than inheriting broad permissions from the node
# instance profile. Combined with the IMDS hop limit of 1 on the nodes, a
# compromised pod cannot borrow the node role.
###############################################################################

module "vpc_cni_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name             = "${var.cluster_name}-vpc-cni"
  attach_vpc_cni_policy = true
  vpc_cni_enable_ipv4   = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-node"]
    }
  }

  tags = local.tags
}

module "ebs_csi_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name             = "${var.cluster_name}-ebs-csi"
  attach_ebs_csi_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }

  tags = local.tags
}

###############################################################################
# EKS cluster
###############################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.37.2"

  cluster_name    = var.cluster_name
  cluster_version = var.kubernetes_version

  vpc_id = module.vpc.vpc_id

  # Nodes and the control plane's cross-account ENIs both land in private
  # subnets. Public subnets carry only the NAT Gateway and load balancers.
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.private_subnets

  # --- API server exposure -------------------------------------------------
  # The private endpoint is always on. The public endpoint is allow-listed by
  # source CIDR; main.tf refuses to plan if it is enabled with an empty list,
  # because EKS reads an empty list as 0.0.0.0/0.
  cluster_endpoint_private_access      = true
  cluster_endpoint_public_access       = var.cluster_endpoint_public_access
  cluster_endpoint_public_access_cidrs = var.cluster_endpoint_public_access_cidrs

  # --- Authentication / authorization --------------------------------------
  # Access entries (the v20 API) rather than the legacy aws-auth ConfigMap.
  # API_AND_CONFIG_MAP keeps the ConfigMap readable for addons that still
  # expect it. The identity running `terraform apply` becomes cluster admin,
  # which is what makes `aws eks update-kubeconfig` + kubectl work immediately.
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true
  enable_irsa                              = true

  # --- Audit and encryption ------------------------------------------------
  cluster_enabled_log_types = [
    "api",
    "audit",
    "authenticator",
    "controllerManager",
    "scheduler",
  ]
  cloudwatch_log_group_retention_in_days = var.cluster_log_retention_days

  # Envelope-encrypt Kubernetes Secrets with a dedicated customer-managed KMS
  # key (the module creates and rotates it).
  create_kms_key = true
  cluster_encryption_config = {
    resources = ["secrets"]
  }

  # --- Addons --------------------------------------------------------------
  #
  # Versions are pinned explicitly rather than `most_recent = true`. With
  # most_recent, the addon version is unknown at plan time, so every plan
  # reports four pending changes and ANY unrelated apply silently upgrades
  # all four addons. Pinning keeps plans clean and makes upgrades deliberate.
  #
  # Trade-off: pinned versions do not pick up security patches on their own.
  # See var.addon_versions for the command that checks for newer releases.
  cluster_addons = {
    # Installed before the node group exists so that the first node to join
    # already has network policy enforcement and the right CNI config.
    vpc-cni = {
      addon_version            = var.addon_versions["vpc-cni"]
      before_compute           = true
      service_account_role_arn = module.vpc_cni_irsa.iam_role_arn

      # Turns on the eBPF network policy agent, so Kubernetes
      # NetworkPolicy objects are actually enforced. Without this, policies
      # are accepted by the API server and silently ignored -- the single
      # most common false sense of isolation in an EKS sandbox.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }

    kube-proxy = {
      addon_version = var.addon_versions["kube-proxy"]
    }

    coredns = {
      addon_version = var.addon_versions["coredns"]
    }

    aws-ebs-csi-driver = {
      addon_version            = var.addon_versions["aws-ebs-csi-driver"]
      service_account_role_arn = module.ebs_csi_irsa.iam_role_arn
    }
  }

  # --- Managed node group --------------------------------------------------
  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"
  }

  eks_managed_node_groups = {
    # The map key is the node group name. Keep it short: the module derives the
    # node IAM role from it as name_prefix "<name>-eks-node-group-", and IAM
    # caps name_prefix at 38 characters. Prefixing this with cluster_name
    # overflows that limit, and node group names are already scoped per cluster.
    sandbox = {
      # Standard Amazon Linux 2023 EKS-optimized AMI. Leaving ami_id unset
      # lets EKS resolve the current AL2023 release, so nodes pick up kernel
      # and CVE patches on replacement instead of pinning to a stale image.
      ami_type = "AL2023_x86_64_STANDARD"

      instance_types = [var.node_instance_type]
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size

      subnet_ids = module.vpc.private_subnets

      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = var.node_disk_size
            volume_type           = "gp3"
            iops                  = 3000
            throughput            = 125
            encrypted             = true
            delete_on_termination = true
          }
        }
      }

      # IMDSv2 only, and a hop limit of 1 so containers cannot reach the
      # instance metadata service and assume the node's IAM role. The CNI
      # runs with hostNetwork and is unaffected; addons that need AWS
      # permissions use IRSA above.
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
        instance_metadata_tags      = "disabled"
      }

      enable_monitoring = true

      # Access is via SSM Session Manager. No key pair, no SSH ingress,
      # no bastion host.
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      labels = {
        "workload" = "sandbox"
        # Signals to schedulers that this node can host Kata / VM-isolated
        # pods, because it is bare metal and therefore exposes /dev/kvm.
        "sandbox.io/kvm" = "true"
      }

      tags = local.tags
    }
  }

  tags = local.tags

  depends_on = [terraform_data.preflight]
}
