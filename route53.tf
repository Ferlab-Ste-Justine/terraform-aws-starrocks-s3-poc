data "aws_route53_zone" "private_dns_zone" {
  count        = var.create_dns_record ? 1 : 0
  name         = "${var.domain_name}."
  private_zone = var.private_dns_zone
}

resource "aws_route53_record" "private_star_rocks_dns" {
  count   = var.create_dns_record ? 1 : 0
  zone_id = data.aws_route53_zone.private_dns_zone[0].zone_id
  name    = "${var.project}-${var.environment}"
  type    = "A"

  alias {
    name                   = aws_lb.star_rocks_nlb.dns_name
    zone_id                = aws_lb.star_rocks_nlb.zone_id
    evaluate_target_health = true
  }
}
