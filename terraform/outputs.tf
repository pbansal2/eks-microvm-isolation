###############################################################################
# Cluster identity
###############################################################################

output "region" {
  description = "AWS region the cluster was deployed into."
  value       = var.region
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint of the Kubernetes API server."
  value       = module.eks.cluster_endpoint
}

output "cluster_version" {
  description = "Kubernetes minor version running on the control plane."
  value       = module.eks.cluster_version
}

output "cluster_oidc_issuer_url" {
  description = "OIDC issuer URL, used to bind IAM roles to service accounts."
  value       = module.eks.cluster_oidc_issuer_url
}

output "oidc_provider_arn" {
  description = "ARN of the IAM OIDC provider for IRSA."
  value       = module.eks.oidc_provider_arn
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA bundle for the API server. Not secret, but noisy; read with `terraform output -raw`."
  value       = module.eks.cluster_certificate_authority_data
  sensitive   = true
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS control plane ENIs."
  value       = module.eks.cluster_security_group_id
}

output "node_security_group_id" {
  description = "Security group ID shared by the managed node group."
  value       = module.eks.node_security_group_id
}

output "kms_key_arn" {
  description = "ARN of the KMS key encrypting Kubernetes Secrets at rest."
  value       = module.eks.kms_key_arn
}

###############################################################################
# Networking
###############################################################################

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "availability_zones" {
  description = "Availability zones actually used (filtered to those offering the node instance type)."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnet IDs, tagged kubernetes.io/role/elb=1."
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "Private subnet IDs, tagged kubernetes.io/role/internal-elb=1."
  value       = module.vpc.private_subnets
}

output "nat_public_ips" {
  description = "Elastic IPs of the NAT Gateway(s); the cluster's egress addresses."
  value       = module.vpc.nat_public_ips
}

###############################################################################
# Node group
###############################################################################

output "node_group_instance_type" {
  description = "Instance type backing the managed node group."
  value       = var.node_instance_type
}

output "node_group_is_bare_metal" {
  description = "Whether the node instance type is bare metal, i.e. exposes /dev/kvm for Kata Containers."
  value       = data.aws_ec2_instance_type.node.bare_metal
}

output "eks_managed_node_groups" {
  description = "Managed node group attributes keyed by node group name."
  value       = module.eks.eks_managed_node_groups
}

###############################################################################
# Operator commands
###############################################################################

output "update_kubeconfig_command" {
  description = "Exact command to point kubectl at this cluster."
  value = format(
    "aws eks update-kubeconfig --region %s --name %s",
    var.region,
    module.eks.cluster_name,
  )
}

output "verify_commands" {
  description = "Copy-paste sequence to verify connectivity and Kata readiness after apply."
  value       = <<-EOT
    # 1. Point kubectl at the cluster
    aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}

    # 2. Control plane reachable, node registered and Ready
    kubectl cluster-info
    kubectl get nodes -o wide
    kubectl wait --for=condition=Ready node --all --timeout=10m

    # 3. All four addons ACTIVE
    aws eks list-addons --region ${var.region} --cluster-name ${module.eks.cluster_name}

    # 4. Network policy enforcement is actually on.
    #    Note: there is no ENABLE_NETWORK_POLICY env var -- the addon's
    #    configuration_values surface as a flag on the node agent container.
    #    Expect "--enable-network-policy=true" in the args:
    kubectl -n kube-system get ds aws-node \
      -o jsonpath='{.spec.template.spec.containers[?(@.name=="aws-eks-nodeagent")].args}{"\n"}'
    #    And the CRD the agent reconciles:
    kubectl get crd policyendpoints.networking.k8s.aws

    # 5. /dev/kvm present on the node (prerequisite for Kata Containers)
    kubectl get nodes -l sandbox.io/kvm=true

    # 6. Shell onto a node without SSH, if needed
    aws ssm start-session --region ${var.region} --target <instance-id>
  EOT
}

###############################################################################
# AWS Load Balancer Controller
###############################################################################

output "load_balancer_controller_role_arn" {
  description = <<-EOT
    IAM role ARN for the AWS Load Balancer Controller service account.
    Consumed by scripts/deploy-baseline.sh, which passes it to the Helm chart
    as serviceAccount.annotations."eks\.amazonaws\.com/role-arn".
  EOT
  value       = module.load_balancer_controller_irsa.iam_role_arn
}
