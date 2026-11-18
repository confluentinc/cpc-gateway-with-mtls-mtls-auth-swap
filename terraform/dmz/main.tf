data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)
  core = data.terraform_remote_state.core.outputs

  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]
  public_subnets  = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  tags = merge({
    Project   = var.cluster_name
    Owner     = var.owner
    ManagedBy = "terraform"
  }, var.extra_tags)

  # Stateless network ACLs. Towards the core VPC only the listed ports may leave; from the core only return
  # traffic (ephemeral ports) may enter. The core can't open connections into the DMZ because the DMZ
  # security groups have no rules for the core CIDR. Everything else (internet, intra-VPC) is allowed.
  core_return_rules = [
    { rule_number = 100, rule_action = "allow", protocol = "tcp", from_port = 1024, to_port = 65535, cidr_block = local.core.vpc_cidr },
    { rule_number = 190, rule_action = "deny", protocol = "-1", from_port = 0, to_port = 0, cidr_block = local.core.vpc_cidr },
    { rule_number = 200, rule_action = "allow", protocol = "-1", from_port = 0, to_port = 0, cidr_block = "0.0.0.0/0" },
  ]
  any_rule  = { rule_number = 200, rule_action = "allow", protocol = "-1", from_port = 0, to_port = 0, cidr_block = "0.0.0.0/0" }
  deny_core = { rule_number = 190, rule_action = "deny", protocol = "-1", from_port = 0, to_port = 0, cidr_block = local.core.vpc_cidr }
}

################################################################################
# DMZ VPC
################################################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  # Private subnets (Gateway, read-only SR): to the core only Kafka, the core SR (schemas and DEKs for the
  # Gateway), Loki (log push, Grafana queries) and MDS (token and RBAC checks of the read-only SR).
  private_dedicated_network_acl = true
  private_inbound_acl_rules     = local.core_return_rules
  private_outbound_acl_rules = [
    { rule_number = 100, rule_action = "allow", protocol = "tcp", from_port = var.core_kafka_port, to_port = var.core_kafka_port, cidr_block = local.core.vpc_cidr },
    { rule_number = 110, rule_action = "allow", protocol = "tcp", from_port = var.core_sr_port, to_port = var.core_sr_port, cidr_block = local.core.vpc_cidr },
    { rule_number = 120, rule_action = "allow", protocol = "tcp", from_port = var.core_loki_port, to_port = var.core_loki_port, cidr_block = local.core.vpc_cidr },
    { rule_number = 130, rule_action = "allow", protocol = "tcp", from_port = var.core_mds_port, to_port = var.core_mds_port, cidr_block = local.core.vpc_cidr },
    local.deny_core,
    local.any_rule,
  ]

  # Public subnets (Gateway NLB, SR ALB, NAT) have no route to the core and the ACL denies it as well.
  public_dedicated_network_acl = true
  public_inbound_acl_rules     = [local.deny_core, local.any_rule]
  public_outbound_acl_rules    = [local.deny_core, local.any_rule]
}

################################################################################
# DMZ EKS (CPC Gateway only)
################################################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  endpoint_public_access                   = true
  enable_cluster_creator_admin_permissions = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  addons = {
    vpc-cni = {
      before_compute = true
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
  }

  eks_managed_node_groups = {
    default = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.node_instance_types

      min_size     = var.node_min_size
      desired_size = var.node_desired_size
      max_size     = var.node_max_size

      disk_size = var.node_disk_size
    }
  }
}
