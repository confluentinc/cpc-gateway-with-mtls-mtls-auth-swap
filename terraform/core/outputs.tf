output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "region" {
  value = var.region
}

output "storage_class" {
  value = kubernetes_storage_class_v1.gp3.metadata[0].name
}

# Consumed by terraform/dmz (peering, routes, network ACLs, DNS association).

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  value = module.vpc.private_subnets
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnets_cidr_blocks
}

output "private_route_table_ids" {
  value = module.vpc.private_route_table_ids
}

output "node_security_group_id" {
  value = module.eks.node_security_group_id
}

output "private_zone_id" {
  value = aws_route53_zone.internal.zone_id
}

output "private_zone_name" {
  value = aws_route53_zone.internal.name
}
