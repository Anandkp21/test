###############################################################################
# Providers & data sources
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.0"
    }
  }
}

provider "aws" {}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

###############################################################################
# Local values
###############################################################################

locals {
  secrets_region = (
    var.secrets_manager_region != "" ?
    var.secrets_manager_region :
    data.aws_region.current.region
  )
  server_id = var.create_server ? aws_transfer_server.this[0].id : "unknown"
}

###############################################################################
# Lambda ZIP package
###############################################################################

data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/index.py"
  output_path = "${path.module}/lambda/index.zip"
}

###############################################################################
# IAM Role — Lambda execution
###############################################################################

resource "aws_iam_role" "lambda_execution" {
  name = "LambdaExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_secrets" {
  name = "LambdaSecretsPolicy"
  role = aws_iam_role.lambda_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = "arn:${data.aws_partition.current.partition}:secretsmanager:${local.secrets_region}:${data.aws_caller_identity.current.account_id}:secret:aws/transfer/*"
    }]
  })
}

###############################################################################
# Lambda Function
###############################################################################

resource "aws_lambda_function" "get_user_config" {
  function_name    = "GetUserConfigLambda"
  description      = "A function to lookup and return user data from AWS Secrets Manager."
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  handler          = "index.lambda_handler"
  runtime          = "python3.11"
  role             = aws_iam_role.lambda_execution.arn

  environment {
    variables = {
      SecretsManagerRegion = local.secrets_region
    }
  }
}

###############################################################################
# IAM Role — CloudWatch logging for Transfer Family
###############################################################################

resource "aws_iam_role" "cloudwatch_logging" {
  count       = var.create_server ? 1 : 0
  name        = "CloudWatchLoggingRole"
  description = "IAM role used by Transfer to log API requests to CloudWatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "transfer.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "transfer_logs" {
  count = var.create_server ? 1 : 0
  name  = "TransferLogsPolicy"
  role  = aws_iam_role.cloudwatch_logging[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:DescribeLogStreams",
        "logs:PutLogEvents"
      ]
      Resource = "*"
    }]
  })
}

###############################################################################
# IAM Role — SFTP User S3 Access (SFTPUserRole)
###############################################################################

resource "aws_iam_role" "sftp_user" {
  name        = "SFTPUserRole"
  description = "IAM role used by Transfer Family to access S3 for SFTP users"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "transfer.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sftp_user_s3" {
  name = "SFTPUserS3Policy"
  role = aws_iam_role.sftp_user.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListUserFolder"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.sftp_s3_bucket}"
        Condition = {
          StringLike = {
            "s3:prefix" = [
              "kameshskuser/*",
              "kameshskuser"
            ]
          }
        }
      },
      {
        Sid    = "UserFolderAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObjectVersion"
        ]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.sftp_s3_bucket}/kameshskuser/*"
      }
    ]
  })
}

###############################################################################
# AWS Transfer Family Server
###############################################################################

resource "aws_transfer_server" "this" {
  count = var.create_server ? 1 : 0

  endpoint_type          = "PUBLIC"
  identity_provider_type = "AWS_LAMBDA"
  function               = aws_lambda_function.get_user_config.arn
  logging_role           = aws_iam_role.cloudwatch_logging[0].arn

  tags = {
    Name = "SFTP-Transfer-Server"
  }
}

###############################################################################
# Lambda Permission
###############################################################################

resource "aws_lambda_permission" "transfer_invoke" {
  statement_id  = "GetUserConfigLambdaPermission"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_user_config.arn
  principal     = "transfer.amazonaws.com"

  source_arn = (
    var.create_server ?
    aws_transfer_server.this[0].arn :
    "arn:${data.aws_partition.current.partition}:transfer:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:server/*"
  )
}

###############################################################################
# Secrets Manager — One secret per SFTP user (supports multiple users)
###############################################################################

resource "aws_secretsmanager_secret" "sftp_users" {
  for_each = var.sftp_users

  depends_on = [aws_transfer_server.this]

  name                    = "aws/transfer/${local.server_id}/${each.key}"
  description             = "SFTP credentials for user ${each.key}"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "sftp_users" {
  for_each = var.sftp_users

  secret_id = aws_secretsmanager_secret.sftp_users[each.key].id

  secret_string = jsonencode({
    Password      = each.value.password
    Role          = aws_iam_role.sftp_user.arn
    HomeDirectory = "/${var.sftp_s3_bucket}/${each.key}"
  })
}

###############################################################################
# S3 — Auto-create user folders (one folder per SFTP user)
# Eliminates the need to manually create folders in S3 console
###############################################################################

resource "aws_s3_object" "sftp_user_folders" {
  for_each = var.sftp_users

  bucket  = var.sftp_s3_bucket
  key     = "${each.key}/"  # trailing slash = folder in S3
  content = ""
}


