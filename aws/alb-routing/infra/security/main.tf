# Lab-local security group for the app instances — NOT reusable infra.
#
# Inbound: HTTP (80) from the VPC CIDR only. The ALB lives in the same (default) VPC, so this admits
# the ALB's health checks and forwarded requests while keeping the instances closed to the internet
# directly — clients must go through the ALB. Scoping to the CIDR (rather than the ALB's SG) keeps
# this unit independent of the ALB, so there's no dependency cycle.
# Egress: all (package installs at boot).

variable "name" {
  description = "Name for the security group."
  type        = string
}

variable "vpc_id" {
  description = "VPC the security group is created in."
  type        = string
}

variable "vpc_cidr_block" {
  description = "VPC CIDR allowed to reach the instances on port 80 (admits the in-VPC ALB)."
  type        = string
}

resource "aws_security_group" "app" {
  name        = var.name
  description = "HTTP from within the VPC (the ALB) to the app instances"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTP from within the VPC (ALB)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  egress {
    description = "All egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = var.name
    Environment = "lab"
  }
}

output "app_security_group_id" {
  description = "ID of the app instances' security group."
  value       = aws_security_group.app.id
}
