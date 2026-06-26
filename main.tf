data "aws_kms_key" "ebs_kms_key" {
  key_id = "alias/aws/ebs"
}

data "aws_caller_identity" "current" {}

data "aws_vpc" "target_vpc" {
  id = var.vpc_id
}

locals {
  # When upgrading StarRocks, new FE and CN nodes should use the new version 
  # to test compatibility. Otherwise use the same version as the leader
  canary_version = var.star_rocks_upgrade_version != "" ? var.star_rocks_upgrade_version : var.star_rocks_version
  # Extra canary FE and CN nodes are added to teh instance count automatically.
  # Two FE nodes are needed to avoid leader election issues (cluster needs a minimum of 3 FEs)
  canary_frontend_node_count = var.star_rocks_upgrade_version != "" ? var.frontend_instance_count + 2 : var.frontend_instance_count
  canary_compute_node_count  = var.star_rocks_upgrade_version != "" ? var.compute_node_instance_count + 1 : var.compute_node_instance_count
  binaries_s3_bucket         = startswith(var.download_base_url, "s3://") ? split("/", trimprefix(var.download_base_url, "s3://"))[0] : ""
}

# Manually controlled leader IP node for upgrades
resource "aws_ssm_parameter" "leader_ip" {
  name  = "${var.project}-${var.environment}-leader-ip"
  type  = "String"
  value = "replace_me"

  lifecycle {
    ignore_changes = [
      value
    ]
  }
}

resource "aws_instance" "star_rocks_frontend" {
  count         = local.canary_frontend_node_count
  ami           = var.ami_id
  instance_type = var.frontend_instance_type
  user_data = templatefile("${path.module}/templates/frontend_startup.sh.tpl", {
    starrocks_version         = count.index == 0 ? var.star_rocks_version : local.canary_version
    starrocks_data_path       = var.starrocks_data_path
    region                    = var.region
    bucket                    = "${var.starrocks_bucket}"
    vpc_cidr                  = data.aws_vpc.target_vpc.cidr_block
    java_heap_size_mb         = var.frontend_heap_size
    download_base_url         = var.download_base_url
    ssm_parameter_name        = aws_ssm_parameter.leader_ip.name
    additional_fe_user_data   = var.additional_fe_user_data
    root_password_secret_name = var.root_password_secret_name
    ca_cert_secret_name       = var.ca_cert_secret_name
    ssl_secret_name           = var.ssl_secret_name

    ranger_host                      = var.ranger_host
    ranger_sync_username             = var.ranger_sync_username
    ranger_sync_password_secret_name = var.ranger_sync_password_secret_name
  })
  iam_instance_profile   = aws_iam_instance_profile.star_rocks_instance_profile.name
  vpc_security_group_ids = [aws_security_group.star_rocks_sg.id]
  subnet_id              = var.subnet_id
  key_name               = var.ssh_key_name
  ebs_optimized          = true
  monitoring             = true
  volume_tags = {
    Name             = "${var.project}-fe-${var.environment}-volume"
    Application      = var.project
    Description      = "Instance for ${var.project}"
    Version          = count.index == 0 ? var.star_rocks_version : local.canary_version
    Starrocks_Backup = "true"
  }
  root_block_device {
    volume_type = "standard"
    volume_size = var.frontend_volume_size_gb
    encrypted   = "true"
  }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = {
    Name             = "${var.project}-fe-${var.environment}-${count.index + 1}" # +1 because humans like 1-indexing
    Application      = "${var.project}-fe"
    Description      = "Instance for ${var.project}"
    Version          = count.index == 0 ? var.star_rocks_version : local.canary_version
    Starrocks_Backup = "true"
  }
}

# During an upgrade, the number of compute nodes is increased by one, and the
# new compute node will use the new version to verify compatibility
resource "aws_instance" "star_rocks_compute_nodes" {
  count         = local.canary_compute_node_count
  ami           = var.ami_id
  instance_type = var.compute_node_instance_type
  user_data = templatefile("${path.module}/templates/compute_node_startup.sh.tpl", {
    starrocks_version         = count.index == (local.canary_compute_node_count - 1) ? var.star_rocks_version : local.canary_version
    starrocks_data_path       = var.starrocks_data_path
    fe_host                   = "${var.project}-${var.environment}.${var.domain_name}"
    fe_query_port             = 9030
    region                    = var.region
    vpc_cidr                  = data.aws_vpc.target_vpc.cidr_block
    java_heap_size_mb         = var.compute_node_heap_size
    download_base_url         = var.download_base_url
    additional_cn_user_data   = var.additional_cn_user_data
    root_password_secret_name = var.root_password_secret_name
    ca_cert_secret_name       = var.ca_cert_secret_name
  })
  iam_instance_profile   = aws_iam_instance_profile.star_rocks_instance_profile.name
  vpc_security_group_ids = [aws_security_group.star_rocks_sg.id]
  subnet_id              = var.subnet_id
  key_name               = var.ssh_key_name
  ebs_optimized          = true
  monitoring             = true
  volume_tags = {
    Name             = "${var.project}-cn-${var.environment}-volume"
    Application      = var.project
    Description      = "Instance for ${var.project}"
    Version          = count.index == (local.canary_compute_node_count - 1) ? var.star_rocks_version : local.canary_version
    Starrocks_Backup = "true"
  }
  root_block_device {
    volume_type = "standard"
    volume_size = var.cn_volume_size_gb
    encrypted   = "true"
  }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags = {
    Name             = "${var.project}-cn-${var.environment}"
    Application      = "${var.project}-cn"
    Description      = "Instance for ${var.project}"
    Version          = count.index == (local.canary_compute_node_count - 1) ? var.star_rocks_version : local.canary_version
    Starrocks_Backup = "true"
  }
}
