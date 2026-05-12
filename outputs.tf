output "fe_dns_name" {
  value = "${var.project}-${var.environment}.${var.domain_name}"
}

output "grafana_address" {
  value = one(aws_instance.star_rocks_grafana[*].private_ip)
}

output "star_rocks_role_arn" {
  value = aws_iam_role.star_rocks_role.arn
}