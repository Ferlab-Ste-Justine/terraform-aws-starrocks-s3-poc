data "aws_s3_bucket" "star_rocks_bucket" {
  bucket = var.starrocks_bucket
}

resource "aws_s3_object" "overview_dashboard" {
  bucket                 = data.aws_s3_bucket.star_rocks_bucket.id
  key                    = "dashboards/overview.json"
  source                 = "${path.module}/grafana_dashboards/overview.json"
  server_side_encryption = "aws:kms"
  acl                    = "private"
  source_hash            = filemd5("${path.module}/grafana_dashboards/overview.json")

  override_provider {
    default_tags {
      tags = {}
    }
  }
}