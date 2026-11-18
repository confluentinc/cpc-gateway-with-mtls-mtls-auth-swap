# Frontend security group for the public Gateway NLB (cpcgw-dmz-bootstrap-lb). CFK always publishes the Gateway's
# admin (9190) and http-server (9180, serves /config) ports on that Service next to the Kafka route port, so the
# NLB is attached to this group via the service.beta.kubernetes.io/aws-load-balancer-security-groups annotation and
# only the route port is reachable from the internet. The load balancer controller adds the matching node-side rules
# (aws-load-balancer-manage-backend-security-group-rules).

locals {
  gateway_route_port = 9092
  # Target-group health checks use the traffic port of every listener, so the NLB must reach all three on the pods.
  gateway_target_ports = [local.gateway_route_port, 9180, 9190]
}

resource "aws_security_group" "gateway_nlb" {
  name        = "${var.cluster_name}-gateway-nlb"
  description = "Public Gateway NLB: Kafka route port from the allowlist only, Gateway pods as targets"
  vpc_id      = module.vpc.vpc_id

  tags = {
    Name = "${var.cluster_name}-gateway-nlb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "gateway_nlb_kafka" {
  for_each = toset(var.public_allowed_cidrs)

  security_group_id = aws_security_group.gateway_nlb.id
  description       = "Kafka (TLS) from allowlisted clients"
  ip_protocol       = "tcp"
  from_port         = local.gateway_route_port
  to_port           = local.gateway_route_port
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "gateway_nlb_to_pods" {
  for_each = {
    for pair in setproduct(module.vpc.private_subnets_cidr_blocks, local.gateway_target_ports) :
    "${pair[0]}-${pair[1]}" => { cidr = pair[0], port = pair[1] }
  }

  security_group_id = aws_security_group.gateway_nlb.id
  description       = "To Gateway pods (traffic and health checks)"
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
}
