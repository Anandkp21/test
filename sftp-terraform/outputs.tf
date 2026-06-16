output "ServerId" {
  description = "The ID of the Transfer Family server"
  value       = var.create_server ? aws_transfer_server.this[0].id : null
}

output "SFTPEndpoint" {
  description = "SFTP endpoint to connect to"
  value       = var.create_server ? "${aws_transfer_server.this[0].id}.server.transfer.${data.aws_region.current.region}.amazonaws.com" : null
}

output "SFTPUserRoleArn" {
  description = "ARN of the IAM role used by SFTP users to access S3"
  value       = aws_iam_role.sftp_user.arn
}

output "SecretNames" {
  description = "List of Secrets Manager secret names created for SFTP users"
  value       = [for s in aws_secretsmanager_secret.sftp_users : s.name]
}

output "StackArn" {
  description = "Equivalent of the CloudFormation StackId"
  value       = "terraform://${data.aws_caller_identity.current.account_id}/${terraform.workspace}"
}
