variable "aws_profile" {
  description = "AWS CLI profile used by Terraform and kubectl. Empty uses the default credential chain."
  type        = string
  default     = ""
}

variable "region" {
  description = "AWS region to deploy into (same as the core stack)."
  type        = string
  default     = "us-east-1"
}

variable "core_state_path" {
  description = "Path to the core stack's local Terraform state."
  type        = string
  default     = "../core/terraform.tfstate"
}

variable "cluster_name" {
  description = "Name of the DMZ EKS cluster (CPC Gateway only)."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.37"
}

variable "vpc_cidr" {
  description = "CIDR block for the DMZ VPC. Must not overlap the core VPC."
  type        = string
}

variable "node_instance_types" {
  description = "Instance types for the DMZ node group."
  type        = list(string)
  default     = ["m6i.large"]
}

variable "node_min_size" {
  type    = number
  default = 3
}

variable "node_desired_size" {
  type    = number
  default = 3
}

variable "node_max_size" {
  type    = number
  default = 4
}

variable "node_disk_size" {
  description = "Root volume size (GiB) for each worker node."
  type        = number
  default     = 50
}

variable "parent_zone_name" {
  description = "Existing public Route 53 zone that delegates the demo zone."
  type        = string
}

variable "public_zone_name" {
  description = "Public zone created (and delegated) for the demo's internet-facing names."
  type        = string
}

variable "public_allowed_cidrs" {
  description = "Source CIDRs allowed to the public Gateway NLB and SR ALB."
  type        = list(string)
}

variable "core_kafka_port" {
  description = "Port of the core internal Kafka NLBs (bootstrap and per broker)."
  type        = number
  default     = 9092
}

variable "core_sr_port" {
  description = "Port of the core internal SR NLB (Gateway: schemas and DEKs)."
  type        = number
  default     = 443
}

variable "core_loki_port" {
  description = "Port of the core internal Loki NLB (log push from the DMZ Alloy, queries from the DMZ Grafana)."
  type        = number
  default     = 3100
}

variable "core_mds_port" {
  description = "Port of the core internal MDS NLB (DMZ Schema Registry: token and RBAC checks)."
  type        = number
  default     = 8090
}

variable "dmz_sr_port" {
  description = "Port of the DMZ read-only Schema Registry pods (ALB targets)."
  type        = number
  default     = 8081
}

variable "chart_versions" {
  description = "Pinned Helm chart versions for cluster add-ons."
  type = object({
    aws_load_balancer_controller = string
    external_dns                 = string
  })
  default = {
    aws_load_balancer_controller = "3.6.2"
    external_dns                 = "1.23.0"
  }
}

variable "owner" {
  description = "Owner tag applied to all resources."
  type        = string
}

variable "extra_tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
