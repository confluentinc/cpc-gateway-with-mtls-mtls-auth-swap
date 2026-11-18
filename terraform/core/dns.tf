resource "aws_route53_zone" "internal" {
  name    = var.private_zone_name
  comment = "Private endpoints for ${var.cluster_name} (Kafka, MDS, SR)"

  vpc {
    vpc_id = module.vpc.vpc_id
  }

  # The DMZ VPC is associated separately (aws_route53_zone_association in terraform/dmz).
  lifecycle {
    ignore_changes = [vpc]
  }
}
