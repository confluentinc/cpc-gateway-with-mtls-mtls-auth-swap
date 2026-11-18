################################################################################
# VPC peering DMZ <-> core, private subnets only in both directions:
#   DMZ private route table   -> core private subnets
#   core private route tables -> DMZ private subnets (return traffic; the DMZ security groups admit nothing from the core)
# The DMZ public subnets (internet-facing load balancers, NAT) have no route to the core.
################################################################################

resource "aws_vpc_peering_connection" "core" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = local.core.vpc_id
  auto_accept = true

  tags = {
    Name = "${var.cluster_name}-to-core"
  }
}

locals {
  # single_nat_gateway = true gives the DMZ VPC one private route table.
  dmz_to_core = toset(local.core.private_subnet_cidrs)

  core_to_dmz = {
    for pair in setproduct(local.core.private_route_table_ids, local.private_subnets) :
    "${pair[0]}-${pair[1]}" => { table_id = pair[0], cidr = pair[1] }
  }
}

resource "aws_route" "dmz_to_core" {
  for_each = local.dmz_to_core

  route_table_id            = module.vpc.private_route_table_ids[0]
  destination_cidr_block    = each.value
  vpc_peering_connection_id = aws_vpc_peering_connection.core.id
}

resource "aws_route" "core_to_dmz" {
  for_each = local.core_to_dmz

  route_table_id            = each.value.table_id
  destination_cidr_block    = each.value.cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.core.id
}
