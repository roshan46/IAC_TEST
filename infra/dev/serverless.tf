data "aws_caller_identity" "current" {}

locals {
  worker_names = toset(["validate", "fulfill", "receipt"])
  workflow_arn = "arn:${data.aws_partition.current.partition}:states:${var.aws_region}:${data.aws_caller_identity.current.account_id}:stateMachine:${local.name_prefix}-orders"
  package_path = var.lambda_package_directory == null ? null : abspath("${path.module}/${var.lambda_package_directory}")
}

resource "aws_s3_bucket" "receipts" {
  bucket        = "${local.name_prefix}-${data.aws_caller_identity.current.account_id}-${var.aws_region}-receipts"
  force_destroy = false
}

resource "aws_s3_bucket_public_access_block" "receipts" {
  bucket                  = aws_s3_bucket.receipts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "receipts" {
  bucket = aws_s3_bucket.receipts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "receipts" {
  bucket = aws_s3_bucket.receipts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "receipts" {
  bucket = aws_s3_bucket.receipts.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RequireTLS", Effect = "Deny", Principal = "*", Action = "s3:*"
      Resource  = [aws_s3_bucket.receipts.arn, "${aws_s3_bucket.receipts.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_cloudwatch_log_group" "worker" {
  for_each          = local.worker_names
  name              = "/aws/lambda/${local.name_prefix}-${each.key}"
  retention_in_days = 7
}

resource "aws_iam_role" "worker" {
  for_each = local.worker_names
  name     = "${local.name_prefix}-${each.key}"
  path     = "/${var.project_name}/application/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "worker_logs" {
  for_each = local.worker_names
  name     = "own-log-streams"
  role     = aws_iam_role.worker[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["${aws_cloudwatch_log_group.worker[each.key].arn}:*"]
    }]
  })
}

resource "aws_iam_role_policy" "receipt_write" {
  name = "write-receipts"
  role = aws_iam_role.worker["receipt"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow", Action = ["s3:PutObject"]
      Resource = ["${aws_s3_bucket.receipts.arn}/receipts/*"]
    }]
  })
}

resource "aws_lambda_function" "worker" {
  for_each      = local.worker_names
  function_name = "${local.name_prefix}-${each.key}"
  description   = "Order Manager ${each.key} worker"
  role          = aws_iam_role.worker[each.key].arn
  runtime       = "python3.13"
  handler       = "workers.${each.key}.handler"
  architectures = ["x86_64"]
  timeout       = 20
  memory_size   = 128

  # Local milestone: upload ZIPs during apply. CI: use already-published S3 objects.
  filename         = local.package_path == null ? null : "${local.package_path}/${each.key}.zip"
  s3_bucket        = local.package_path == null ? var.artifact_bucket : null
  s3_key           = local.package_path == null && var.release_sha != null ? "releases/${var.release_sha}/${each.key}.zip" : null
  source_code_hash = local.package_path == null ? lookup(var.lambda_hashes, each.key, null) : filebase64sha256("${local.package_path}/${each.key}.zip")

  dynamic "environment" {
    for_each = each.key == "receipt" ? [1] : []
    content {
      variables = { RECEIPT_BUCKET = aws_s3_bucket.receipts.id }
    }
  }

  depends_on = [
    aws_iam_role_policy.worker_logs,
    aws_iam_role_policy.receipt_write,
    aws_s3_bucket_public_access_block.receipts,
    aws_s3_bucket_policy.receipts,
    aws_s3_bucket_server_side_encryption_configuration.receipts
  ]

  lifecycle {
    precondition {
      condition     = local.package_path != null || (var.release_sha != null && contains(keys(var.lambda_hashes), each.key))
      error_message = "Build local ZIPs and set lambda_package_directory, or supply a release_sha and all three lambda_hashes for S3."
    }
  }
}

resource "aws_cloudwatch_log_group" "workflow" {
  name              = "/aws/vendedlogs/states/${local.name_prefix}-orders"
  retention_in_days = 7
}

resource "aws_iam_role" "workflow" {
  name = "${local.name_prefix}-workflow"
  path = "/${var.project_name}/application/"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow", Action = "sts:AssumeRole"
      Principal = { Service = "states.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnEquals    = { "aws:SourceArn" = local.workflow_arn }
      }
    }]
  })
}

resource "aws_iam_role_policy" "workflow" {
  name = "invoke-workers-and-deliver-logs"
  role = aws_iam_role.workflow.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeWorkers", Effect = "Allow", Action = ["lambda:InvokeFunction"]
        Resource = [for worker in aws_lambda_function.worker : worker.arn]
      },
      {
        # These log-delivery APIs require wildcard Resource per AWS documentation.
        Sid = "LogDelivery", Effect = "Allow"
        Action = [
          "logs:CreateLogDelivery", "logs:GetLogDelivery", "logs:UpdateLogDelivery",
          "logs:DeleteLogDelivery", "logs:ListLogDeliveries", "logs:PutResourcePolicy",
          "logs:DescribeResourcePolicies", "logs:DescribeLogGroups"
        ]
        Resource = ["*"]
      },
      {
        Sid      = "WorkflowLogStreams", Effect = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.workflow.arn}:*"]
      }
    ]
  })
}

resource "aws_sfn_state_machine" "orders" {
  name     = "${local.name_prefix}-orders"
  type     = "STANDARD"
  role_arn = aws_iam_role.workflow.arn
  definition = templatefile("${path.module}/workflow.asl.json.tftpl", {
    validate_arn = aws_lambda_function.worker["validate"].arn
    fulfill_arn  = aws_lambda_function.worker["fulfill"].arn
    receipt_arn  = aws_lambda_function.worker["receipt"].arn
  })
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.workflow.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }
  depends_on = [aws_iam_role_policy.workflow]
}

resource "aws_iam_role_policy" "app_workflow" {
  name = "start-orders-and-read-receipts"
  role = aws_iam_role.app.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow", Action = ["states:StartExecution"]
        Resource = [aws_sfn_state_machine.orders.arn]
      },
      {
        Effect   = "Allow", Action = ["states:DescribeExecution"]
        Resource = ["${replace(local.workflow_arn, ":stateMachine:", ":execution:")}:*"]
      },
      {
        Effect   = "Allow", Action = ["s3:GetObject"]
        Resource = ["${aws_s3_bucket.receipts.arn}/receipts/*"]
      }
    ]
  })
}
