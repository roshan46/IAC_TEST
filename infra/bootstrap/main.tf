locals {
  tags    = { Project = var.project_name, Component = "bootstrap", ManagedBy = "Terraform" }
  buckets = { state = var.state_bucket_name, artifacts = var.artifact_bucket_name }
  repository_claim = var.github_owner_id == null ? var.github_repository : format(
    "%s@%s/%s@%s", split("/", var.github_repository)[0], var.github_owner_id,
    split("/", var.github_repository)[1], var.github_repository_id
  )
  github_subject = "repo:${local.repository_claim}:ref:refs/heads/main"
  oidc_arn       = var.existing_github_oidc_provider_arn == null ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.existing[0].arn
  dev_state_key  = "dev/order-manager/terraform.tfstate"
  application_role_policies = {
    plan  = data.aws_iam_policy_document.github_plan.json
    apply = data.aws_iam_policy_document.github_apply.json
  }
}

# Bootstrap storage survives application teardown; never force-delete its contents.
resource "aws_s3_bucket" "bootstrap" {
  for_each      = local.buckets
  bucket        = each.value
  force_destroy = false
  tags          = merge(local.tags, { Purpose = each.key })
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_public_access_block" "bootstrap" {
  for_each                = local.buckets
  bucket                  = aws_s3_bucket.bootstrap[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "bootstrap" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.bootstrap[each.key].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "bootstrap" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.bootstrap[each.key].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.bootstrap["state"].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_policy" "https_only" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.bootstrap[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport", Effect = "Deny", Principal = "*", Action = "s3:*"
      Resource  = [aws_s3_bucket.bootstrap[each.key].arn, "${aws_s3_bucket.bootstrap[each.key].arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.bootstrap["artifacts"].id
  rule {
    id     = "expire-reviewed-plans"
    status = "Enabled"
    filter {
      prefix = "plans/"
    }
    expiration {
      days = 2
    }
  }
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = var.existing_github_oidc_provider_arn == null ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = local.tags
  # AWS uses its trusted CA library for GitHub; no rotating leaf thumbprint.
}

data "aws_iam_openid_connect_provider" "existing" {
  count = var.existing_github_oidc_provider_arn == null ? 0 : 1
  arn   = var.existing_github_oidc_provider_arn
}

resource "aws_iam_role" "github" {
  for_each             = toset(["plan", "apply"])
  name                 = "${var.project_name}-github-${each.key}"
  path                 = "/${var.project_name}/bootstrap/"
  description          = "GitHub main-branch ${each.key} role for the Order Manager lab"
  max_session_duration = 3600
  tags                 = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRoleWithWebIdentity"
      Principal = { Federated = local.oidc_arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = local.github_subject
        }
      }
    }]
  })
  lifecycle {
    precondition {
      condition = var.existing_github_oidc_provider_arn == null ? true : (
        trimsuffix(trimprefix(data.aws_iam_openid_connect_provider.existing[0].url, "https://"), "/") == "token.actions.githubusercontent.com" &&
        contains(data.aws_iam_openid_connect_provider.existing[0].client_id_list, "sts.amazonaws.com")
      )
      error_message = "The existing provider must be GitHub's OIDC provider and include sts.amazonaws.com."
    }
  }
}

resource "aws_iam_role_policy" "state_access" {
  for_each = aws_iam_role.github
  name     = "dev-state-and-lock"
  role     = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ListDevState", Effect = "Allow", Action = ["s3:ListBucket"]
        Resource  = [aws_s3_bucket.bootstrap["state"].arn]
        Condition = { StringEquals = { "s3:prefix" = [local.dev_state_key, "${local.dev_state_key}.tflock"] } }
      },
      {
        Sid      = "ReadWriteDevState", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${aws_s3_bucket.bootstrap["state"].arn}/${local.dev_state_key}"]
      },
      {
        Sid      = "ManageDevLock", Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = ["${aws_s3_bucket.bootstrap["state"].arn}/${local.dev_state_key}.tflock"]
      },
      {
        Sid      = "NeverAccessBootstrapState", Effect = "Deny", Action = ["s3:*"]
        Resource = ["${aws_s3_bucket.bootstrap["state"].arn}/bootstrap/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy" "artifacts" {
  for_each = aws_iam_role.github
  name     = "reviewed-artifacts"
  role     = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReleaseAndPlanObjects", Effect = "Allow"
      Action = each.key == "plan" ? ["s3:GetObject", "s3:PutObject"] : ["s3:GetObject"]
      Resource = [
        "${aws_s3_bucket.bootstrap["artifacts"].arn}/releases/*",
        "${aws_s3_bucket.bootstrap["artifacts"].arn}/plans/*"
      ]
    }]
  })
}

# Milestone 5 policies are deliberately split: plan can inspect the stack, while
# apply can change only the services and named resources used by this lab.
resource "aws_iam_role_policy" "application" {
  for_each = local.application_role_policies
  name     = "application-${each.key}"
  role     = aws_iam_role.github[each.key].id
  policy   = each.value
}
