# SFTP Transfer Family — Terraform Deployment Guide

Terraform equivalent of the AWS CloudFormation template `SFTP_1.yml`.  
All resource names, IAM policy actions, and logic are preserved exactly as in the CFT.

---

## What This Deploys

| CFT Resource | Terraform Resource |
|---|---|
| `TransferServer` | `aws_transfer_server.this[0]` |
| `CloudWatchLoggingRole` | `aws_iam_role.cloudwatch_logging[0]` |
| `TransferLogsPolicy` | `aws_iam_role_policy.transfer_logs[0]` |
| `LambdaExecutionRole` | `aws_iam_role.lambda_execution` |
| `LambdaSecretsPolicy` | `aws_iam_role_policy.lambda_secrets` |
| `GetUserConfigLambda` | `aws_lambda_function.get_user_config` |
| `GetUserConfigLambdaPermission` | `aws_lambda_permission.transfer_invoke` |

---

## Folder Structure

```
sftp-terraform/
├── main.tf                   # All AWS resources
├── variables.tf              # Input variables (mirrors CFT Parameters)
├── outputs.tf                # Outputs (mirrors CFT Outputs)
├── terraform.tfvars.example  # Copy → terraform.tfvars and fill in
└── lambda/
    └── index.py              # Python 3.11 handler (exact copy from CFT)
```

---

## Step-by-Step Deployment

### Step 1 — Prerequisites

Make sure these are installed on your machine:

```bash
# Check Terraform (need >= 1.5)
terraform -version

# Check AWS CLI
aws --version

# Check Python (needed to test Lambda locally, optional)
python3 --version
```

Install Terraform: https://developer.hashicorp.com/terraform/install  
Install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html

---

### Step 2 — Configure AWS Credentials

```bash
# Option A: Named profile (recommended)
aws configure --profile myprofile
export AWS_PROFILE=myprofile
export AWS_REGION=us-east-1   # change to your target region

# Option B: Environment variables
export AWS_ACCESS_KEY_ID=AKIAxxx
export AWS_SECRET_ACCESS_KEY=xxxxxx
export AWS_REGION=us-east-1
```

Verify credentials work:

```bash
aws sts get-caller-identity
```

---

### Step 3 — Clone / Copy the Project

```bash
# If you downloaded the zip, extract it:
unzip sftp-terraform.zip
cd sftp-terraform
```

---

### Step 4 — Create Your tfvars File

```bash
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`:

```hcl
# true  = creates the Transfer server (same as CreateServer=true in CFT)
# false = only Lambda + IAM (attach to an existing server yourself)
create_server = true

# Leave empty to use the deployment region.
# Only set if your Secrets Manager is in a DIFFERENT region.
secrets_manager_region = ""
```

---

### Step 5 — Initialize Terraform

This downloads the AWS provider and archive provider plugins.

```bash
terraform init
```

Expected output:

```
Terraform has been successfully initialized!
```

---

### Step 6 — Preview Changes (Dry Run)

```bash
terraform plan
```

Review what Terraform will create. You should see 7 resources being added  
(or 5 if `create_server = false`).

---

### Step 7 — Apply (Deploy)

```bash
terraform apply
```

Type `yes` when prompted. Deployment takes ~1–2 minutes.

---

### Step 8 — Note the Outputs

After apply completes:

```
Outputs:

ServerId = "s-xxxxxxxxxxxx"   ← your Transfer server ID
StackArn = "terraform://123456789012/default"
```

The `ServerId` is what you use when creating secrets in Secrets Manager.

---

### Step 9 — Create a User Secret in Secrets Manager

For each SFTP user, create a secret following this naming pattern:

```
aws/transfer/{ServerId}/{username}
```

Example for user `alice` on server `s-abc123`:

```bash
aws secretsmanager create-secret \
  --name "aws/transfer/s-abc123/alice" \
  --secret-string '{
    "Password": "MySecurePassword123!",
    "Role": "arn:aws:iam::123456789012:role/S3AccessRole",
    "HomeDirectory": "/my-bucket/alice"
  }'
```

**Secret key reference (all optional except Role):**

| Key | Required | Description |
|---|---|---|
| `Password` | For password auth | Plain text password |
| `PublicKey` | For SSH key auth | SSH public key(s), comma-separated for multiple |
| `Role` | Yes | IAM role ARN the user assumes |
| `HomeDirectory` | No | S3 path like `/bucket/prefix` |
| `HomeDirectoryDetails` | No | JSON for virtual folder mapping (logical mode) |
| `Policy` | No | Session policy to scope permissions |

---

### Step 10 — Test the Connection

```bash
# Password auth
sftp -P 22 alice@s-abc123.server.transfer.us-east-1.amazonaws.com

# SSH key auth
sftp -i ~/.ssh/id_rsa alice@s-abc123.server.transfer.us-east-1.amazonaws.com
```

---

## Conditional Behaviour (mirrors CFT Conditions)

| Scenario | Setting | Result |
|---|---|---|
| Full deployment | `create_server = true` | Server + Lambda + all IAM roles |
| Lambda only | `create_server = false` | Lambda + Lambda IAM role only (no CloudWatch role, no server) |
| Cross-region secrets | `secrets_manager_region = "eu-west-1"` | Lambda reads secrets from `eu-west-1` |

---

## Destroying / Teardown

```bash
terraform destroy
```

Type `yes`. Note: secrets in Secrets Manager are NOT deleted — remove them manually if needed.

---

## Troubleshooting

**Lambda not authenticating:**
```bash
# Check Lambda logs
aws logs tail /aws/lambda/GetUserConfigLambda --follow
```

**Permission denied on Transfer:**
- Verify the secret path exactly matches `aws/transfer/{serverId}/{username}`
- Check the IAM role in the secret has S3 permissions for the home directory

**Terraform state issues:**
```bash
# Force re-read of remote state
terraform refresh
```
