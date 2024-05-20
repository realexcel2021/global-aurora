provider "aws" {
  region = local.primary_region
}

provider "aws" {
  alias  = "secondary"
  region = local.secondary_region
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "primary" {}
data "aws_availability_zones" "secondary" {
  provider = aws.secondary
}

locals {
  name = "db-global-aurora"

  primary_region   = "us-east-1"
  primary_vpc_cidr = "10.0.0.0/16"
  primary_azs      = slice(data.aws_availability_zones.primary.names, 0, 3)

  secondary_region   = "us-west-1"
  secondary_vpc_cidr = "10.1.0.0/16"
  secondary_azs      = slice(data.aws_availability_zones.secondary.names, 0, 2)

  tags = {
    Project    = local.name
  }
}

################################################################################
# RDS Aurora Module
################################################################################

resource "aws_rds_global_cluster" "this" {
  global_cluster_identifier = local.name
  engine                    = "aurora-postgresql"
  engine_version            = "14.5"
  database_name             = "aurora_db"
  storage_encrypted         = true
}

module "aurora_primary" {
  source = "terraform-aws-modules/rds-aurora/aws"

  name                      = local.name
  database_name             = aws_rds_global_cluster.this.database_name
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version
  master_username           = "root"
  global_cluster_identifier = aws_rds_global_cluster.this.id
  instance_class            = "db.r5.large" # db.r6g.large
  instances                 = { for i in range(2) : i => {} }
  kms_key_id                = aws_kms_key.primary.arn

  vpc_id               = module.primary_vpc.vpc_id
  db_subnet_group_name = module.primary_vpc.database_subnet_group_name
  security_group_rules = {
    vpc_ingress = {
      cidr_blocks = [module.primary_vpc.vpc_cidr_block]
    }
  }

  # Global clusters do not support managed master user password
  manage_master_user_password = false
  master_password             = random_password.master.result

  skip_final_snapshot = true

  tags = local.tags
}

module "aurora_secondary" {
  source = "terraform-aws-modules/rds-aurora/aws"

  providers = { aws = aws.secondary }

  is_primary_cluster = false

  name                      = local.name
  engine                    = aws_rds_global_cluster.this.engine
  engine_version            = aws_rds_global_cluster.this.engine_version
  global_cluster_identifier = aws_rds_global_cluster.this.id
  source_region             = local.primary_region
  instance_class            = "db.r5.large"
  instances                 = { for i in range(2) : i => {} }
  kms_key_id                = aws_kms_key.secondary.arn
  #enable_global_write_forwarding = true

  vpc_id               = module.secondary_vpc.vpc_id
  db_subnet_group_name = module.secondary_vpc.database_subnet_group_name
  security_group_rules = {
    vpc_ingress = {
      cidr_blocks = [module.secondary_vpc.vpc_cidr_block]
    }
  }

  # Global clusters do not support managed master user password
  master_password = random_password.master.result

  skip_final_snapshot = true

  depends_on = [
    module.aurora_primary
  ]

  tags = local.tags
}

################################################################################
# Supporting Resources
################################################################################

data "aws_iam_policy_document" "rds" {
  statement {
    sid       = "Enable IAM User Permissions"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type = "AWS"
      identifiers = [
        "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
        data.aws_caller_identity.current.arn,
      ]
    }
  }

  statement {
    sid = "Allow use of the key"
    actions = [
      "kms:Encrypt",
      "kms:Decrypt",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:DescribeKey"
    ]
    resources = ["*"]

    principals {
      type = "Service"
      identifiers = [
        "monitoring.rds.amazonaws.com",
        "rds.amazonaws.com",
      ]
    }
  }
}

resource "aws_kms_key" "primary" {
  policy = data.aws_iam_policy_document.rds.json
  tags   = local.tags
}

resource "aws_kms_key" "secondary" {
  provider = aws.secondary

  policy = data.aws_iam_policy_document.rds.json
  tags   = local.tags
}