################################################################################
# Private zone: let the DMZ resolve the core's internal names (brokers, SR, MDS, Loki).
# The core zone ignores changes to its VPC list, so this association is owned here.
################################################################################

resource "aws_route53_zone_association" "internal" {
  zone_id = local.core.private_zone_id
  vpc_id  = module.vpc.vpc_id
}

################################################################################
# Public zone, delegated from the existing parent zone. Holds sr.<zone> (Terraform), the ACM validation record and
# the Gateway names (ExternalDNS in the DMZ cluster).
################################################################################

data "aws_route53_zone" "parent" {
  name         = var.parent_zone_name
  private_zone = false
}

resource "aws_route53_zone" "public" {
  name          = var.public_zone_name
  comment       = "WF demo public names (${var.cluster_name})"
  force_destroy = true
}

resource "aws_route53_record" "delegation" {
  zone_id = data.aws_route53_zone.parent.zone_id
  name    = var.public_zone_name
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.public.name_servers
}
