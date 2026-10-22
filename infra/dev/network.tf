locals {
  subnets = {
    a = { az = var.availability_zones[0], public_cidr = "10.20.1.0/24", database_cidr = "10.20.11.0/24" }
    b = { az = var.availability_zones[1], public_cidr = "10.20.2.0/24", database_cidr = "10.20.12.0/24" }
  }
}

resource "aws_vpc" "main" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  for_each                = local.subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.public_cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name_prefix}-public-${each.key}" }
}

resource "aws_subnet" "database" {
  for_each                = local.subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.database_cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name_prefix}-database-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name_prefix}-public" }
}

resource "aws_route" "internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each       = local.subnets
  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public.id
}

# Each DB subnet has an explicit local-only route table: no IGW or NAT default route.
resource "aws_route_table" "database" {
  for_each = local.subnets
  vpc_id   = aws_vpc.main.id
  tags     = { Name = "${local.name_prefix}-database-${each.key}" }
}

resource "aws_route_table_association" "database" {
  for_each       = local.subnets
  subnet_id      = aws_subnet.database[each.key].id
  route_table_id = aws_route_table.database[each.key].id
}

resource "aws_security_group" "app" {
  name        = "${local.name_prefix}-app"
  description = "App access from learner IP; administration through outbound SSM"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name_prefix}-app" }
}

resource "aws_security_group" "database" {
  name        = "${local.name_prefix}-database"
  description = "PostgreSQL from the application security group only"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name_prefix}-database" }
}

resource "aws_vpc_security_group_ingress_rule" "app_http" {
  security_group_id = aws_security_group.app.id
  description       = "Temporary lab HTTP from the learner public IPv4"
  cidr_ipv4         = var.learner_cidr
  ip_protocol       = "tcp"
  from_port         = 8000
  to_port           = 8000
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.app.id
  description                  = "PostgreSQL from EC2"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "app_web" {
  for_each          = toset(["80", "443"])
  security_group_id = aws_security_group.app.id
  description       = "Outbound package downloads, AWS APIs, and SSM"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
}

resource "aws_vpc_security_group_egress_rule" "app_postgres" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.database.id
  description                  = "PostgreSQL connection to private RDS"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
