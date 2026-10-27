###############################################################################
# AWS Load Balancer Controller -- IAM only
#
# Required by k8s/apps/gateway.yaml. That Service carries
# `service.beta.kubernetes.io/aws-load-balancer-type: external`, which tells
# the legacy in-tree cloud provider to ignore the Service. With no controller
# installed, nothing reconciles it and the Service never leaves <pending>.
#
# Only the IAM role lives here. The controller itself is a Helm release
# installed by scripts/deploy-baseline.sh, deliberately NOT a
# `helm_release` resource:
#
#   - adding the helm provider makes every `terraform plan` require a
#     reachable Kubernetes API, which in this stack means the SSM tunnel must
#     be up before infrastructure can be planned (RUNBOOK.md section 4);
#   - a destroy then has to delete Kubernetes objects before the cluster,
#     which is the classic way to end up with a half-destroyed state file.
#
# Trade-off: the controller version is therefore not tracked in Terraform
# state. It is pinned in deploy-baseline.sh instead, and `terraform destroy`
# will not remove it -- delete the Helm release first, so the controller can
# clean up the load balancers it created.
###############################################################################

module "load_balancer_controller_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.60.0"

  role_name                              = "${var.cluster_name}-aws-lbc"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }

  tags = local.tags
}
