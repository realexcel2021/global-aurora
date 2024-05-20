resource "aws_secretsmanager_secret" "this" {
  name = "aurora-db-password-${random_pet.this.id}"

  recovery_window_in_days = 0 # comment out for PROD

  replica {
    region = local.secondary_region
  }
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id

  secret_string = <<EOF
    {
        "password": "${random_password.master.result}"
    }
  EOF
}

resource "random_password" "master" {
  length  = 20
  special = false
}

resource "random_pet" "this" {
  length  = 2
}