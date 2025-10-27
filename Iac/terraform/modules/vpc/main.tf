locals {
  vpc_name = "ticketboat-standard-vpc"
}

##########################
# VPC CONFIGURATION
##########################

# data "aws_vpc" "selected" {
#   filter {
#     name   = "tag:Name"
#     values = [local.vpc_name]
#   }
# }

# Default VPC
data "aws_vpc" "selected" {
  default = true
}

data "aws_subnets" "subnets" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  # Note: Default VPC subnets are public by default, no tag filter needed
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
}

data "aws_route_tables" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }

  filter {
    name   = "association.subnet-id"
    values = data.aws_subnets.private.ids
  }
}

output "vpc_id" {
  description = "The ID of the VPC"
  value       = data.aws_vpc.selected.id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs"
  value       = data.aws_subnets.public.ids
}
