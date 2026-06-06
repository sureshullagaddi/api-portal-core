#!/usr/bin/env bash
# =============================================================================
# bootstrap-state.sh — One-time setup for all 3 api-portal repos
#
# Run this ONCE from your local machine before pushing to any repo.
# Safe to re-run — all steps are idempotent.
#
# Creates:
#   1. S3 bucket  — shared Terraform state for all 3 repos
#   2. DynamoDB   — shared state lock table for all 3 repos
#   3. OIDC provider — GitHub Actions identity provider (one per AWS account)
#   4. IAM roles  — one per repo, trusted by that repo only:
#        api-portal-core-deploy-role
#        api-portal-backend-deploy-role
#        api-portal-frontend-deploy-role
#
# Usage:
#   export AWS_REGION=eu-north-1
#   export GITHUB_ORG=your-github-org
#   export BUCKET_NAME=api-portal-terraform-state   # optional, has default
#   bash scripts/bootstrap-state.sh
#
# After running, add to each repo's GitHub Secrets:
#   AWS_ROLE_ARN = <printed at end of script>
# =============================================================================

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
AWS_REGION="${AWS_REGION:-eu-north-1}"
GITHUB_ORG="${GITHUB_ORG:?ERROR: Set GITHUB_ORG env var (your GitHub org/username)}"
BUCKET_NAME="${BUCKET_NAME:-api-portal-terraform-state}"
DYNAMO_TABLE="${DYNAMO_TABLE:-api-portal-terraform-locks}"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  API Portal — Bootstrap Terraform State + OIDC Auth"
echo "════════════════════════════════════════════════════════════════"
echo "  Account : $ACCOUNT_ID"
echo "  Region  : $AWS_REGION"
echo "  Org     : $GITHUB_ORG"
echo "  Bucket  : $BUCKET_NAME"
echo "  DynamoDB: $DYNAMO_TABLE"
echo "════════════════════════════════════════════════════════════════"
echo ""

# ── 1. S3 bucket — shared Terraform state ────────────────────────────────────
echo "▶ [1/4] S3 state bucket: $BUCKET_NAME"
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  echo "    ✓ Already exists — skipping creation"
else
  if [ "$AWS_REGION" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  echo "    ✓ Bucket created"

  aws s3api put-bucket-versioning \
    --bucket "$BUCKET_NAME" \
    --versioning-configuration Status=Enabled
  echo "    ✓ Versioning enabled"

  aws s3api put-bucket-encryption \
    --bucket "$BUCKET_NAME" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"},
        "BucketKeyEnabled": true
      }]
    }'
  echo "    ✓ Encryption enabled (AES256)"

  aws s3api put-public-access-block \
    --bucket "$BUCKET_NAME" \
    --public-access-block-configuration \
      BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  echo "    ✓ Public access blocked"
fi

# ── 2. DynamoDB — shared state lock table ─────────────────────────────────────
echo ""
echo "▶ [2/4] DynamoDB lock table: $DYNAMO_TABLE"
if aws dynamodb describe-table --table-name "$DYNAMO_TABLE" --region "$AWS_REGION" 2>/dev/null | grep -q ACTIVE; then
  echo "    ✓ Already exists — skipping creation"
else
  aws dynamodb create-table \
    --table-name "$DYNAMO_TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$AWS_REGION"
  echo "    ✓ DynamoDB table created"
fi

# ── 3. GitHub Actions OIDC identity provider (one per AWS account) ────────────
echo ""
echo "▶ [3/4] GitHub Actions OIDC provider"
if aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_PROVIDER_ARN" 2>/dev/null | grep -q Url; then
  echo "    ✓ Already exists — skipping creation"
else
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
  echo "    ✓ OIDC provider created"
fi

# ── 4. IAM roles — one per repo ───────────────────────────────────────────────
echo ""
echo "▶ [4/4] IAM deploy roles (one per repo)"

# Repos that need a deploy role (plain array — works on macOS Bash 3.x)
REPOS=(
  "api-portal-core"
  "api-portal-backend"
  "api-portal-frontend"
)

ROLE_ARNS=()

for REPO_NAME in "${REPOS[@]}"; do
  ROLE_NAME="${REPO_NAME}-deploy-role"

  TRUST_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": [
            "repo:${GITHUB_ORG}/${REPO_NAME}:ref:refs/heads/main",
            "repo:${GITHUB_ORG}/${REPO_NAME}:ref:refs/heads/*",
            "repo:${GITHUB_ORG}/${REPO_NAME}:pull_request"
          ]
        }
      }
    }
  ]
}
EOF
)

  if aws iam get-role --role-name "$ROLE_NAME" 2>/dev/null | grep -q RoleId; then
    echo "    ✓ Role $ROLE_NAME already exists — updating trust policy"
    aws iam update-assume-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-document "$TRUST_POLICY"
  else
    aws iam create-role \
      --role-name "$ROLE_NAME" \
      --assume-role-policy-document "$TRUST_POLICY" \
      --description "OIDC deploy role for GitHub repo ${GITHUB_ORG}/${REPO_NAME}" \
      --tags Key=Project,Value=api-portal Key=ManagedBy,Value=bootstrap-script
    echo "    ✓ Role $ROLE_NAME created"

    # Attach AdministratorAccess — scope down in production!
    aws iam attach-role-policy \
      --role-name "$ROLE_NAME" \
      --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
    echo "      ⚠ Attached AdministratorAccess — scope down for production"
  fi

  ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
  ROLE_ARNS+=("$REPO_NAME → $ROLE_ARN")
done

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  ✅ Bootstrap complete!"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "  Shared state bucket : $BUCKET_NAME"
echo "  Shared lock table   : $DYNAMO_TABLE"
echo ""
echo "  State key structure:"
echo "    api-portal/core/{env}/terraform.tfstate      ← api-portal-core"
echo "    api-portal/backend/{env}/terraform.tfstate   ← api-portal-backend"
echo "    api-portal/frontend/{env}/terraform.tfstate  ← api-portal-frontend"
echo ""
echo "  Add AWS_ROLE_ARN secret to each GitHub repo:"
echo ""
for entry in "${ROLE_ARNS[@]}"; do
  echo "    $entry"
done
echo ""
echo "  Also add to each repo (if using alert emails):"
echo "    ALERT_EMAIL       = your-alerts@example.com"
echo "    AUTHORIZER_API_KEY = <custom-api-key>   (core repo only)"
echo ""
echo "  Deploy order:"
echo "    1. Push to api-portal-core    (creates Cognito + Lambdas → SSM)"
echo "    2. Push to api-portal-backend (reads SSM → creates DynamoDB + API GW → SSM)"
echo "    3. Push to api-portal-frontend (reads SSM → builds React → S3)"
echo "════════════════════════════════════════════════════════════════"

