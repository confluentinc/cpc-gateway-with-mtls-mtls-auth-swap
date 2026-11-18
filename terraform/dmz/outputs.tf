output "cluster_name" {
  value = module.eks.cluster_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnets_cidr_blocks
}

output "public_subnet_cidrs" {
  value = module.vpc.public_subnets_cidr_blocks
}

output "peering_connection_id" {
  value = aws_vpc_peering_connection.core.id
}

output "public_zone_id" {
  value = aws_route53_zone.public.zone_id
}

output "public_zone_name_servers" {
  value = aws_route53_zone.public.name_servers
}

output "sr_public_url" {
  value = "https://${local.sr_public_hostname}"
}

output "payments_kek_arn" {
  description = "KMS key for the demo-payments encryption rule (encrypt.kms.key.id)."
  value       = aws_kms_key.payments_kek.arn
}

output "gateway_irsa_role_arn" {
  description = "IRSA role of the Gateway service account gateway/cpcgw-dmz (base credentials)."
  value       = aws_iam_role.gateway_irsa.arn
}

output "gateway_kms_role_arn" {
  description = "Role the Gateway rule executors assume for KMS (role.arn in aws-kms-role-params)."
  value       = aws_iam_role.gateway_kms.arn
}

output "gateway_nlb_security_group_id" {
  description = "Set as service.beta.kubernetes.io/aws-load-balancer-security-groups on the Gateway externalAccess."
  value       = aws_security_group.gateway_nlb.id
}

output "sr_target_group_arn" {
  description = "ALB target group of the DMZ read-only Schema Registry pods (TargetGroupBinding)."
  value       = aws_lb_target_group.sr.arn
}
