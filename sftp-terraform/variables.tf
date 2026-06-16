variable "create_server" {
  description = "Whether to create a new Transfer Family server."
  type        = bool
  default     = true
}

variable "secrets_manager_region" {
  description = "The region the secrets are stored in. Leave empty to use the deployment region."
  type        = string
  default     = ""
}

variable "sftp_s3_bucket" {
  description = "The name of the EXISTING S3 bucket that SFTP users will access. No new bucket is created."
  type        = string
}

variable "sftp_users" {
  description = "Map of SFTP users. Each user gets their own Secrets Manager secret."
  type = map(object({
    password = string
  }))
}
