###############################################################################
# VPC
#
# Layout for vpc_cidr = 10.0.0.0/16, az_count = 2:
#
#   public   10.0.0.0/20    10.0.16.0/20    <- NAT GW, internet-facing LBs only
#   private  10.0.128.0/20  10.0.144.0/20   <- EKS nodes and control plane ENIs
#
# Nodes live only in private subnets and receive no public IP. Egress is via a
# single NAT Gateway when single_nat_gateway = true.
###############################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.21.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnet_cidrs
  private_subnets = local.private_subnet_cidrs

  # NAT: one gateway shared by every private subnet keeps dev cost down and
  # makes the NAT's AZ a single point of failure. See var.single_nat_gateway.
  enable_nat_gateway     = true
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # Required for EKS: nodes resolve the API server and ECR by DNS name.
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Nothing in a public subnet should get an address implicitly. The NAT
  # Gateway and any internet-facing load balancer assign their own EIPs.
  map_public_ip_on_launch = false

  # CIS 5.4 / AWS Usage Standard: the default security group permits
  # intra-group traffic implicitly. Strip it so nothing can accidentally
  # depend on it, and force every workload onto a named security group.
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  # Network audit trail.
  enable_flow_log                                 = var.enable_flow_logs
  create_flow_log_cloudwatch_log_group            = var.enable_flow_logs
  create_flow_log_cloudwatch_iam_role             = var.enable_flow_logs
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_days

  # Subnet tags drive AWS Load Balancer Controller auto-discovery.
  #   kubernetes.io/role/elb=1          -> internet-facing LBs land here
  #   kubernetes.io/role/internal-elb=1 -> internal LBs land here
  # The kubernetes.io/cluster/<name> tag is no longer required by the LB
  # controller for discovery but is still honoured and aids cost allocation.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    Tier                                        = "public"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    Tier                                        = "private"
  }

  tags = local.tags
}
