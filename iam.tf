locals {
  registration_secret_arns = compact([
    var.root_password_secret_name != "" ? "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.root_password_secret_name}*" : "",
    var.ca_cert_secret_name != "" ? "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.ca_cert_secret_name}*" : "",
    var.ssl_secret_name != "" ? "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.ssl_secret_name}*" : "",
    var.ranger_sync_password_secret_name != "" ? "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${var.ranger_sync_password_secret_name}*" : "",
  ])
}

resource "aws_iam_role" "star_rocks_role" {
  name = "${var.project}-${var.environment}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "cluster_policy" {
  name        = "${var.project}-${var.environment}-policy"
  description = "Allows Star Rocks EC2 instances to access S3 and SSM"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketTagging",
          "s3:PutBucketTagging",
          "s3:GetObjectTagging",
          "s3:PutObjectTagging",
          "s3:DeleteObjectTagging",
          "s3:GetObjectVersion",
          "s3:DeleteObjectVersion",
          "s3:ListBucketVersions"
        ]
        Resource = [
          "arn:aws:s3:::${var.starrocks_bucket}",
          "arn:aws:s3:::${var.starrocks_bucket}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = [
          "${aws_ssm_parameter.leader_ip.arn}"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "s3_attach" {
  role       = aws_iam_role.star_rocks_role.name
  policy_arn = aws_iam_policy.cluster_policy.arn
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.star_rocks_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "registration_secrets" {
  count = length(local.registration_secret_arns) > 0 ? 1 : 0

  name        = "${var.project}-${var.environment}-registration-secrets-policy"
  description = "Allows Star Rocks EC2 instances to read the root password and CA cert for secure node registration"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = local.registration_secret_arns
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "registration_secrets_attach" {
  count = length(local.registration_secret_arns) > 0 ? 1 : 0

  role       = aws_iam_role.star_rocks_role.name
  policy_arn = aws_iam_policy.registration_secrets[0].arn
}

resource "aws_iam_role_policy_attachment" "additional_policy_attachments" {
  count = length(var.additional_policy_arns)

  role       = aws_iam_role.star_rocks_role.name
  policy_arn = var.additional_policy_arns[count.index]
}

resource "aws_iam_instance_profile" "star_rocks_instance_profile" {
  name = "${var.project}-${var.environment}-ip"
  role = aws_iam_role.star_rocks_role.name
}

resource "aws_iam_role" "monitoring_role" {
  name = "${var.project}-${var.environment}-monitoring-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_policy" "monitoring_policy" {
  name        = "${var.project}-${var.environment}-monitoring-policy"
  description = "Allows Star Rocks monitoring"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cloudwatch:ListMetrics",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:GetMetricData",
          "ec2:DescribeTags",
          "ec2:DescribeInstances",
          "ec2:DescribeRegions"
        ]
        Resource = [
          "*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectTagging",
          "s3:GetObjectVersion",
          "s3:GetBucketTagging"
        ]
        Resource = [
          "arn:aws:s3:::${var.starrocks_bucket}",
          "arn:aws:s3:::${var.starrocks_bucket}/dashboards/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          "arn:aws:secretsmanager:${var.region}:${data.aws_caller_identity.current.account_id}:secret:${aws_secretsmanager_secret.grafana_admin_pw.name}*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring_attach" {
  role       = aws_iam_role.monitoring_role.name
  policy_arn = aws_iam_policy.monitoring_policy.arn
}

resource "aws_iam_role_policy_attachment" "monitoring_ssm_attach" {
  role       = aws_iam_role.monitoring_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "monitoring_instance_profile" {
  name = "${var.project}-${var.environment}-monitoring-ip"
  role = aws_iam_role.monitoring_role.name
}

resource "aws_iam_role" "dlm_role" {
  name = "dlm-snapshot-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "dlm.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dlm_attach" {
  role       = aws_iam_role.dlm_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}
