# star-rocks-module
A basic setup of a StarRocks cluster using an S3 backend on AWS EC2. You can scale up compute nodes as needed and they will join the front end servers. New front end servers need to [join the cluster manually](https://docs.starrocks.io/docs/administration/management/Scale_up_down/#scale-fe-in-and-out). New instances are automatically added to Grafana and Prometheus, although deleted instances are not removed from Prometheus for a while.

This currently only deploys an internal NLB to a single subnet, uses private DNS, and only allows traffic from within the VPC to encourage security by default. It **does not create an authenticated mySQL user**, instead only using creating the user `root` with all privileges and no password. 

You can connect to your Star Rocks instance by using the SSM proxy command:

```
aws ssm start-session --debug --target "$INSTANCE_ID" \
  --document-name AWS-StartPortForwardingSession \
  --parameters "{\"portNumber\":[\"$PORT\"],\"localPortNumber\":[\"$PORT\"]}"
```

where the default for `PORT` is `9030`. After that, you can access Star Rocks using a mysql client:
```
mysql -h 127.0.0.1 -P 9030 -u root
```

## Binary download source and CPU architecture (x86_64 / Graviton)

Nodes download the StarRocks tarball from `var.download_base_url` (default the public
`https://releases.starrocks.io/starrocks`). Point it at a private mirror when external
downloads are blocked. The full URL the nodes fetch is:

```
<download_base_url>/StarRocks-<star_rocks_version>-<arch>.tar.gz
```

`<arch>` is **inferred at boot** from the instance's CPU (`uname -m`), not passed as a
variable — the architecture is already fixed by `ami_id` and the instance types, so this
keeps a single source of truth and removes any chance of a mismatch:

- `x86_64` -> `centos-amd64` (matches the public StarRocks filename)
- `aarch64` -> `arm64`

To run on **Graviton (arm64)**, set `ami_id` to an arm64 AMI and pick arm64 instance types
(e.g. `m7gd.4xlarge` for the compute nodes, `m7g.large` for the FE). StarRocks publishes **no
arm64 tarball**, so the mirror must host a `StarRocks-<version>-arm64.tar.gz` built from the
official `starrocks/artifacts-*` Docker image (see the consumer repo's publish scripts). The
JVM directory (`.x86_64` / `.aarch64`) is likewise resolved at boot from the installed JDK,
so no arch-specific path is hardcoded.

> Monitoring (Prometheus) is still x86_64-only and unaffected; it runs on its own
> `monitoring_instance_type`.

## Upgrade Process
We do a modified canary process for upgrades.
1. Ensure the SSM parameter for the leader IP is up to date.
2. Change the value for `starrocks_upgrade_version` in `variables.tfvars` for your environment.  Create a PR, get reviews, and merge.
3. This will add 2 new nodes to the cluster, both upgraded. They will join the cluster and syncronize their data.
4. Make sure the new FE nodes join the old cleanly. You can query `SHOW FRONTENDS;` on the old FE.
6. Verify new CNs joined the old FE correctly. 
7. Verify new FEs have data in their databases.
8. Make a new PR with `starrocks_version` matching the upgraded version, get reviews, and merge.
9. This will delete the old leader, forcing a leader election. Watch for the new leader and update the SSM parameter accordingly.
10. Depending on where in the new instance initialization you updated the SSM parameter, you may need to restart the systemd service on the new instance.
11. Go through the database and delete any terminated CNs and FE nodes.
12. You may now scale down the FEs to 1 if desired. If you delete FEs, be sure to remove them from the MySQL database first (`ALTER SYSTEM DROP FOLLOWER '{IP}:9010'`) before terminating the instances.


<!-- BEGIN_TF_DOCS -->
## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | n/a |
| <a name="provider_random"></a> [random](#provider\_random) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_dlm_lifecycle_policy.ebs_snapshots](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dlm_lifecycle_policy) | resource |
| [aws_iam_instance_profile.monitoring_instance_profile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_instance_profile.star_rocks_instance_profile](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_policy.monitoring_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.s3_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.dlm_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.monitoring_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.star_rocks_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy_attachment.dlm_attach](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.monitoring_attach](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.monitoring_ssm_attach](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.s3_attach](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ssm_attach](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_instance.star_rocks_compute_nodes](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_instance.star_rocks_frontend](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_instance.star_rocks_grafana](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_instance.star_rocks_prometheus](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/instance) | resource |
| [aws_lb.star_rocks_nlb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb) | resource |
| [aws_lb_listener.frontend_listener](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_target_group.frontend_tg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_lb_target_group_attachment.frontend_attachment](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group_attachment) | resource |
| [aws_route53_record.private_star_rocks_dns](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_s3_object.overview_dashboard](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_object) | resource |
| [aws_secretsmanager_secret.grafana_admin_pw](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.grafana_admin_pw_version](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [aws_security_group.grafana_sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.prometheus_sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.star_rocks_sg](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [random_password.initial_password](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password) | resource |
| [aws_ami.al2023](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_kms_key.ebs_kms_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/kms_key) | data source |
| [aws_route53_zone.private_dns_zone](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_s3_bucket.star_rocks_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/s3_bucket) | data source |
| [aws_vpc.target_vpc](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cn_volume_size_gb"></a> [cn\_volume\_size\_gb](#input\_cn\_volume\_size\_gb) | n/a | `string` | `"950"` | no |
| <a name="input_compute_node_heap_size"></a> [compute\_node\_heap\_size](#input\_compute\_node\_heap\_size) | n/a | `string` | `"124000"` | no |
| <a name="input_compute_node_instance_count"></a> [compute\_node\_instance\_count](#input\_compute\_node\_instance\_count) | n/a | `string` | `"3"` | no |
| <a name="input_compute_node_instance_type"></a> [compute\_node\_instance\_type](#input\_compute\_node\_instance\_type) | n/a | `string` | `"r6id.4xlarge"` | no |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | n/a | `any` | n/a | yes |
| <a name="input_environment"></a> [environment](#input\_environment) | n/a | `any` | n/a | yes |
| <a name="input_frontend_heap_size"></a> [frontend\_heap\_size](#input\_frontend\_heap\_size) | n/a | `string` | `"28000"` | no |
| <a name="input_frontend_instance_count"></a> [frontend\_instance\_count](#input\_frontend\_instance\_count) | n/a | `string` | `"1"` | no |
| <a name="input_frontend_instance_type"></a> [frontend\_instance\_type](#input\_frontend\_instance\_type) | n/a | `string` | `"m6i.2xlarge"` | no |
| <a name="input_frontend_volume_size_gb"></a> [frontend\_volume\_size\_gb](#input\_frontend\_volume\_size\_gb) | n/a | `string` | `"150"` | no |
| <a name="input_monitoring_instance_type"></a> [monitoring\_instance\_type](#input\_monitoring\_instance\_type) | n/a | `string` | `"m6i.large"` | no |
| <a name="input_project"></a> [project](#input\_project) | n/a | `string` | `"star-rocks"` | no |
| <a name="input_region"></a> [region](#input\_region) | n/a | `string` | `"us-east-1"` | no |
| <a name="input_root_volume_size_gb"></a> [root\_volume\_size\_gb](#input\_root\_volume\_size\_gb) | n/a | `string` | `"30"` | no |
| <a name="input_ssh_key_name"></a> [ssh\_key\_name](#input\_ssh\_key\_name) | n/a | `string` | `"devops"` | no |
| <a name="input_star_rocks_version"></a> [star\_rocks\_version](#input\_star\_rocks\_version) | n/a | `string` | `"3.3.11"` | no |
| <a name="input_starrocks_bucket"></a> [starrocks\_bucket](#input\_starrocks\_bucket) | n/a | `any` | n/a | yes |
| <a name="input_starrocks_data_path"></a> [starrocks\_data\_path](#input\_starrocks\_data\_path) | n/a | `string` | `"/opt/starrocks/"` | no |
| <a name="input_subnet_id"></a> [subnet\_id](#input\_subnet\_id) | n/a | `any` | n/a | yes |
| <a name="input_vpc_id"></a> [vpc\_id](#input\_vpc\_id) | n/a | `any` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_fe_dns_name"></a> [fe\_dns\_name](#output\_fe\_dns\_name) | n/a |
| <a name="output_grafana_address"></a> [grafana\_address](#output\_grafana\_address) | n/a |
<!-- END_TF_DOCS -->