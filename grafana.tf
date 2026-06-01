resource "aws_instance" "star_rocks_grafana" {
  count         = var.include_prometheus_monitoring ? 1 : 0
  ami           = var.ami_id
  instance_type = var.monitoring_instance_type
  user_data = templatefile("${path.module}/templates/grafana_startup.sh.tpl", {
    prometheus_ip = aws_instance.star_rocks_prometheus[0].private_ip
    bucket        = "${var.starrocks_bucket}"
    pw_secret     = "${var.project}-${var.environment}-grafana-admin-pw"
  })
  iam_instance_profile   = aws_iam_instance_profile.monitoring_instance_profile.name
  vpc_security_group_ids = [aws_security_group.grafana_sg.id]
  subnet_id              = var.subnet_id
  key_name               = var.ssh_key_name
  ebs_optimized          = true
  monitoring             = true
  volume_tags = {
    Name             = "${var.project}-grafana-${var.environment}-volume"
    Application      = var.project
    Description      = "Instance for ${var.project}"
    Starrocks_Backup = "false"
  }
  root_block_device {
    volume_type = "standard"
    volume_size = var.root_volume_size_gb
    encrypted   = "true"
  }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = {
    Name             = "${var.project}-grafana-${var.environment}"
    Application      = var.project
    Description      = "Instance for ${var.project}"
    Starrocks_Backup = "false"
  }
}


resource "aws_instance" "star_rocks_prometheus" {
  count         = var.include_prometheus_monitoring ? 1 : 0
  ami           = var.ami_id
  instance_type = var.monitoring_instance_type
  user_data = templatefile("${path.module}/templates/prometheus_startup.sh.tpl", {
    cn_tag = "${var.project}-cn"
    fe_tag = "${var.project}-fe"
  })
  iam_instance_profile   = aws_iam_instance_profile.monitoring_instance_profile.name
  vpc_security_group_ids = [aws_security_group.prometheus_sg.id]
  subnet_id              = var.subnet_id
  key_name               = var.ssh_key_name
  ebs_optimized          = true
  monitoring             = true
  volume_tags = {
    Name             = "${var.project}-${var.environment}-volume"
    Application      = var.project
    Description      = "Instance for ${var.project}"
    Starrocks_Backup = "false"
  }
  root_block_device {
    volume_type = "standard"
    volume_size = var.root_volume_size_gb
    encrypted   = "true"
  }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = {
    Name             = "${var.project}-prometheus-${var.environment}"
    Application      = var.project
    Description      = "Instance for ${var.project}"
    Starrocks_Backup = "false"
  }
}