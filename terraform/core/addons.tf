################################################################################
# AWS Load Balancer Controller (internal NLBs for brokers, MDS, SR)
################################################################################

module "aws_lb_controller_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${var.cluster_name}-aws-lbc"

  attach_aws_lb_controller_policy = true

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "aws-load-balancer-controller"
    }
  }
}

resource "helm_release" "aws_lb_controller" {
  name       = "aws-load-balancer-controller"
  namespace  = "kube-system"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.chart_versions.aws_load_balancer_controller

  values = [yamlencode({
    clusterName       = module.eks.cluster_name
    region            = var.region
    vpcId             = module.vpc.vpc_id
    defaultTargetType = "ip"
    serviceAccount = {
      create = true
      name   = "aws-load-balancer-controller"
    }
  })]

  depends_on = [
    module.eks,
    module.aws_lb_controller_pod_identity,
  ]
}

################################################################################
# ExternalDNS (private zone only)
################################################################################

module "external_dns_pod_identity" {
  source  = "terraform-aws-modules/eks-pod-identity/aws"
  version = "~> 2.0"

  name = "${var.cluster_name}-external-dns"

  attach_external_dns_policy    = true
  external_dns_hosted_zone_arns = [aws_route53_zone.internal.arn]

  associations = {
    this = {
      cluster_name    = module.eks.cluster_name
      namespace       = "kube-system"
      service_account = "external-dns"
    }
  }
}

resource "helm_release" "external_dns" {
  name       = "external-dns"
  namespace  = "kube-system"
  repository = "https://kubernetes-sigs.github.io/external-dns/"
  chart      = "external-dns"
  version    = var.chart_versions.external_dns

  values = [yamlencode({
    provider = { name = "aws" }
    env = [
      { name = "AWS_DEFAULT_REGION", value = var.region },
    ]
    serviceAccount = {
      create = true
      name   = "external-dns"
    }
    sources       = ["service"]
    policy        = "sync"
    registry      = "txt"
    txtOwnerId    = var.cluster_name
    domainFilters = [var.private_zone_name]
    extraArgs = [
      "--aws-zone-type=private",
      "--zone-id-filter=${aws_route53_zone.internal.zone_id}",
      # CFK still annotates its LoadBalancer services with external-dns.alpha.kubernetes.io/*.
      "--enable-legacy-annotation-prefix",
    ]
  })]

  depends_on = [
    module.eks,
    module.external_dns_pod_identity,
    helm_release.aws_lb_controller,
  ]
}

################################################################################
# cert-manager (private CA for CFK components)
################################################################################

resource "helm_release" "cert_manager" {
  name             = "cert-manager"
  namespace        = "cert-manager"
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.chart_versions.cert_manager

  values = [yamlencode({
    crds = { enabled = true }
  })]

  depends_on = [
    module.eks,
    helm_release.aws_lb_controller,
  ]
}
