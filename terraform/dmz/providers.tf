provider "aws" {
  region  = var.region
  profile = var.aws_profile == "" ? null : var.aws_profile

  default_tags {
    tags = local.tags
  }
}

locals {
  eks_exec_args = concat(
    ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region],
    var.aws_profile == "" ? [] : ["--profile", var.aws_profile],
  )
  gateway_domain     = "kafka.gateway.${var.public_zone_name}"
  sr_public_hostname = "sr.${var.public_zone_name}"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = local.eks_exec_args
  }
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = local.eks_exec_args
    }
  }
}

# The core stack (terraform/core) must be applied first; the DMZ reads its VPC, route tables and private zone.
data "terraform_remote_state" "core" {
  backend = "local"
  config = {
    path = var.core_state_path
  }
}
