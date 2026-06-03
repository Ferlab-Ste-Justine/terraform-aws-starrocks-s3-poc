resource "aws_lb" "star_rocks_nlb" {
  name                       = "${var.project}-nlb-${var.environment}"
  internal                   = var.internal_nlb
  load_balancer_type         = "network"
  subnets                    = [var.subnet_id]
  enable_deletion_protection = false
}

# 9030 is the query port
resource "aws_lb_target_group" "frontend_query_tg" {
  name     = "${var.project}-fe-query-tg-${var.environment}"
  port     = 9030
  protocol = "TCP"
  vpc_id   = var.vpc_id
}

resource "aws_lb_target_group_attachment" "frontend_query_attachment" {
  count            = local.canary_frontend_node_count
  target_group_arn = aws_lb_target_group.frontend_query_tg.arn
  target_id        = aws_instance.star_rocks_frontend[count.index].id
}

resource "aws_lb_listener" "frontend_query_listener" {
  load_balancer_arn = aws_lb.star_rocks_nlb.arn
  port              = 9030
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_query_tg.arn
  }
}

# In case your VPN only allows port 80/443 outbound
resource "aws_lb_listener" "frontend_https_listener" {
  load_balancer_arn = aws_lb.star_rocks_nlb.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend_query_tg.arn
  }
}


