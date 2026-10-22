data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account_id       = data.aws_caller_identity.current.account_id
  application_path = "${var.project_name}/application"
  dev_prefix       = "${var.project_name}-dev"
  receipt_bucket   = "${local.dev_prefix}-${local.account_id}-${var.aws_region}-receipts"

  # These metadata APIs either do not support resource ARNs or are needed to
  # refresh resource identities before Terraform can produce a plan.
  application_read_actions = [
    "ec2:Describe*",
    "iam:GetInstanceProfile",
    "iam:GetRole",
    "iam:GetRolePolicy",
    "iam:ListAttachedRolePolicies",
    "iam:ListInstanceProfilesForRole",
    "iam:ListRolePolicies",
    "lambda:GetFunction",
    "lambda:GetPolicy",
    "lambda:ListVersionsByFunction",
    "lambda:ListTags",
    "logs:DescribeLogGroups",
    "logs:ListTagsForResource",
    "rds:DescribeDBInstances",
    "rds:DescribeDBParameterGroups",
    "rds:DescribeDBParameters",
    "rds:DescribeDBSubnetGroups",
    "rds:ListTagsForResource",
    "secretsmanager:DescribeSecret",
    "states:DescribeStateMachine",
    "states:ListTagsForResource",
    "sts:GetCallerIdentity"
  ]
}

data "aws_iam_policy_document" "github_plan" {
  statement {
    sid       = "ReadApplicationMetadata"
    actions   = local.application_read_actions
    resources = ["*"]
  }

  statement {
    sid = "ReadReceiptBucketConfiguration"
    actions = [
      "s3:GetBucket*",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:ListBucket"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${local.receipt_bucket}"]
  }
}

data "aws_iam_policy_document" "github_apply" {
  statement {
    sid       = "ReadApplicationMetadata"
    actions   = local.application_read_actions
    resources = ["*"]
  }

  # EC2 networking APIs use generated IDs and several do not support resource
  # permissions. The action list and region condition form the boundary here.
  statement {
    sid = "ManageRegionalComputeNetwork"
    actions = [
      "ec2:AssociateRouteTable",
      "ec2:AttachInternetGateway",
      "ec2:AuthorizeSecurityGroupEgress",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:CreateInternetGateway",
      "ec2:CreateRoute",
      "ec2:CreateRouteTable",
      "ec2:CreateSecurityGroup",
      "ec2:CreateSubnet",
      "ec2:CreateTags",
      "ec2:CreateVpc",
      "ec2:DeleteInternetGateway",
      "ec2:DeleteRoute",
      "ec2:DeleteRouteTable",
      "ec2:DeleteSecurityGroup",
      "ec2:DeleteSubnet",
      "ec2:DeleteTags",
      "ec2:DeleteVpc",
      "ec2:DetachInternetGateway",
      "ec2:DisassociateRouteTable",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifySubnetAttribute",
      "ec2:ModifyVpcAttribute",
      "ec2:ReplaceRoute",
      "ec2:ReplaceRouteTableAssociation",
      "ec2:RevokeSecurityGroupEgress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:RunInstances",
      "ec2:TerminateInstances"
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.aws_region]
    }
  }

  statement {
    sid = "ManageApplicationRoles"
    actions = [
      "iam:AddRoleToInstanceProfile",
      "iam:AttachRolePolicy",
      "iam:CreateInstanceProfile",
      "iam:CreateRole",
      "iam:DeleteInstanceProfile",
      "iam:DeleteRole",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PassRole",
      "iam:PutRolePolicy",
      "iam:RemoveRoleFromInstanceProfile",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:role/${local.application_path}/*",
      "arn:${data.aws_partition.current.partition}:iam::${local.account_id}:instance-profile/${local.application_path}/*"
    ]
  }

  statement {
    sid = "ManageApplicationDatabase"
    actions = [
      "rds:AddTagsToResource",
      "rds:CreateDBInstance",
      "rds:CreateDBParameterGroup",
      "rds:CreateDBSubnetGroup",
      "rds:DeleteDBInstance",
      "rds:DeleteDBParameterGroup",
      "rds:DeleteDBSubnetGroup",
      "rds:ModifyDBInstance",
      "rds:ModifyDBParameterGroup",
      "rds:ModifyDBSubnetGroup",
      "rds:RemoveTagsFromResource"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:rds:${var.aws_region}:${local.account_id}:db:${local.dev_prefix}",
      "arn:${data.aws_partition.current.partition}:rds:${var.aws_region}:${local.account_id}:pg:${local.dev_prefix}",
      "arn:${data.aws_partition.current.partition}:rds:${var.aws_region}:${local.account_id}:subgrp:${local.dev_prefix}"
    ]
  }

  statement {
    sid = "ManageApplicationFunctions"
    actions = [
      "lambda:AddPermission",
      "lambda:CreateFunction",
      "lambda:DeleteFunction",
      "lambda:RemovePermission",
      "lambda:TagResource",
      "lambda:UntagResource",
      "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${local.account_id}:function:${local.dev_prefix}-*"]
  }

  statement {
    sid = "ManageApplicationWorkflow"
    actions = [
      "states:CreateStateMachine",
      "states:DeleteStateMachine",
      "states:TagResource",
      "states:UntagResource",
      "states:UpdateStateMachine"
    ]
    resources = ["arn:${data.aws_partition.current.partition}:states:${var.aws_region}:${local.account_id}:stateMachine:${local.dev_prefix}-orders"]
  }

  statement {
    sid = "ManageApplicationLogs"
    actions = [
      "logs:CreateLogGroup",
      "logs:DeleteLogGroup",
      "logs:DeleteRetentionPolicy",
      "logs:PutRetentionPolicy",
      "logs:TagResource",
      "logs:UntagResource"
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/lambda/${local.dev_prefix}-*",
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/rds/instance/${local.dev_prefix}/*",
      "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${local.account_id}:log-group:/aws/vendedlogs/states/${local.dev_prefix}-orders*"
    ]
  }

  # Step Functions log delivery APIs require wildcard resources.
  statement {
    sid = "ManageWorkflowLogDelivery"
    actions = [
      "logs:CreateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:GetLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:UpdateLogDelivery"
    ]
    resources = ["*"]
  }

  statement {
    sid     = "ManageReceiptBucket"
    actions = ["s3:*"]
    resources = [
      "arn:${data.aws_partition.current.partition}:s3:::${local.receipt_bucket}",
      "arn:${data.aws_partition.current.partition}:s3:::${local.receipt_bucket}/*"
    ]
  }

  statement {
    sid       = "UseRunShellScriptDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "RunDeploymentOnLabHost"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${data.aws_partition.current.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*"]
    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project_name]
    }
  }

  statement {
    sid       = "ReadDeploymentCommand"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }
}
