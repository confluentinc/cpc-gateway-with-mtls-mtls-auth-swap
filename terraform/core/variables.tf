variable "aws_profile" {
  description = "AWS CLI profile used by Terraform and kubectl. Empty uses the default credential chain."
  type        = string
  default     = ""
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "kubernetes_version" {
  description = "EKS Kubernetes version."
  type        = string
  default     = "1.37"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "node_instance_types" {
  description = "Instance types for the managed node group."
  type        = list(string)
  default     = ["m6i.2xlarge"]
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
  default = 6
}

variable "node_disk_size" {
  description = "Root volume size (GiB) for each worker node."
  type        = number
  default     = 100
}

variable "private_zone_name" {
  description = "Route 53 private hosted zone for internal endpoints (brokers, MDS, SR)."
  type        = string
}

variable "chart_versions" {
  description = "Pinned Helm chart versions for cluster add-ons."
  type = object({
    aws_load_balancer_controller = string
    external_dns                 = string
    cert_manager                 = string
  })
  default = {
    aws_load_balancer_controller = "3.6.2"
    external_dns                 = "1.23.0"
    cert_manager                 = "v1.21.3"
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
