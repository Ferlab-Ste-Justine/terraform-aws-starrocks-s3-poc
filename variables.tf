variable "environment" {
}

variable "region" {
  default = "us-east-1"
}

variable "project" {
  default = "star-rocks"
}

variable "starrocks_bucket" {
}

# Amazon Linux 2023 HVM x86_64
variable "ami_id" {

}

variable "vpc_id" {
}

variable "subnet_id" {
}

variable "domain_name" {
}

variable "create_dns_record" {
  default = true
}

variable "private_dns_zone" {
  default = true
}

variable "internal_nlb" {
  default = true
}

variable "root_volume_size_gb" {
  default = "30"
}

variable "frontend_volume_size_gb" {
  default = "150"
}

variable "cn_volume_size_gb" {
  default = "950"
}

variable "compute_node_instance_count" {
  default = "3"
}

variable "compute_node_instance_type" {
  default = "r6id.4xlarge"
}

variable "compute_node_heap_size" {
  default = "124000"
}

variable "frontend_instance_count" {
  default = "3"
}

variable "frontend_instance_type" {
  default = "m6i.2xlarge"
}

variable "frontend_heap_size" {
  default = "28000"
}

variable "monitoring_instance_type" {
  default = "m6i.large"
}

variable "star_rocks_version" {
  default = "3.4.4"
}

variable "star_rocks_upgrade_version" {
  default = ""
}

variable "starrocks_data_path" {
  default = "/opt/starrocks/"
}

variable "ssh_key_name" {
  default = "devops"
}

variable "additional_policy_arns" {
  default = []
}

variable "additional_fe_user_data" {
  default = ""
}

variable "additional_cn_user_data" {
  default = ""
}

variable "additional_ingress_rules" {
  description = "Security group rules to add for ingress"
  type = list(object({
    port        = number
    cidr_blocks = list(string)
  }))
  default = []
}

variable "additional_egress_rules" {
  description = "Security group rules to add for egress"
  type = list(object({
    port        = number
    cidr_blocks = list(string)
  }))
  default = []
}