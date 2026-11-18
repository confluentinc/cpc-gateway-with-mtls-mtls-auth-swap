################################################################################
# Public Schema Registry: internet -> ALB (DMZ public subnets, ACM certificate) -> HTTPS re-encrypt -> the DMZ
# read-only Schema Registry pods (schema linking followers, cfk/dmz/02-schema-registry). The pods register
# themselves in the target group through a TargetGroupBinding. Clients still log in with LDAP basic auth.
################################################################################

resource "aws_acm_certificate" "sr" {
  domain_name       = local.sr_public_hostname
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "sr_validation" {
  for_each = {
    for o in aws_acm_certificate.sr.domain_validation_options : o.domain_name => o
  }

  zone_id         = aws_route53_zone.public.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  ttl             = 60
  records         = [each.value.resource_record_value]
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "sr" {
  certificate_arn         = aws_acm_certificate.sr.arn
  validation_record_fqdns = [for r in aws_route53_record.sr_validation : r.fqdn]

  depends_on = [aws_route53_record.delegation]
}

resource "aws_security_group" "sr_alb" {
  name        = "${var.cluster_name}-sr-alb"
  description = "Public SR ALB: HTTPS from the allowlist, to the DMZ read-only SR pods only"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.cluster_name}-sr-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "sr_alb_https" {
  for_each = toset(var.public_allowed_cidrs)

  security_group_id = aws_security_group.sr_alb.id
  description       = "HTTPS from allowlisted clients"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "sr_alb_to_pods" {
  for_each = toset(local.private_subnets)

  security_group_id = aws_security_group.sr_alb.id
  description       = "To the DMZ read-only SR pods"
  ip_protocol       = "tcp"
  from_port         = var.dmz_sr_port
  to_port           = var.dmz_sr_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "nodes_from_sr_alb" {
  security_group_id            = module.eks.node_security_group_id
  description                  = "Public SR ALB to the read-only SR pods"
  ip_protocol                  = "tcp"
  from_port                    = var.dmz_sr_port
  to_port                      = var.dmz_sr_port
  referenced_security_group_id = aws_security_group.sr_alb.id
}

resource "aws_lb" "sr" {
  name                       = "${var.cluster_name}-sr"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = module.vpc.public_subnets
  security_groups            = [aws_security_group.sr_alb.id]
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "sr" {
  name        = "${var.cluster_name}-sr"
  target_type = "ip"
  protocol    = "HTTPS"
  port        = var.dmz_sr_port
  vpc_id      = module.vpc.vpc_id

  # SR requires basic auth everywhere, so an unauthenticated health check answers 401.
  health_check {
    protocol = "HTTPS"
    path     = "/"
    matcher  = "200,401"
  }
}

resource "aws_lb_listener" "sr_https" {
  load_balancer_arn = aws_lb.sr.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.sr.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sr.arn
  }
}

resource "aws_route53_record" "sr" {
  zone_id = aws_route53_zone.public.zone_id
  name    = local.sr_public_hostname
  type    = "A"

  alias {
    name                   = aws_lb.sr.dns_name
    zone_id                = aws_lb.sr.zone_id
    evaluate_target_health = true
  }
}
