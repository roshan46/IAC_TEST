mock_provider "aws" {
  # The provider mock replaces computed policy-document data sources too.
  # Supply syntactically valid JSON so the inline-policy resources can plan.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"sts:GetCallerIdentity\"],\"Resource\":[\"*\"]}]}"
    }
  }
  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      arn            = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
      url            = "token.actions.githubusercontent.com"
      client_id_list = ["sts.amazonaws.com"]
    }
  }
}

variables {
  github_repository                 = "learner/order-manager"
  github_owner_id                   = null
  github_repository_id              = null
  state_bucket_name                 = "order-manager-test-state-123456"
  artifact_bucket_name              = "order-manager-test-artifacts-123456"
  existing_github_oidc_provider_arn = null
}

run "storage_and_legacy_trust" {
  command = apply
  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State recovery requires versioning."
  }
  assert {
    condition     = alltrue([for block in aws_s3_bucket_public_access_block.bootstrap : block.block_public_acls && block.block_public_policy && block.ignore_public_acls && block.restrict_public_buckets])
    error_message = "Both buckets must block all public access."
  }
  assert {
    condition     = jsondecode(aws_iam_role.github["plan"].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == "repo:learner/order-manager:ref:refs/heads/main"
    error_message = "Trust must match exactly the requested repository's main branch."
  }
  assert {
    condition     = !contains(jsondecode(aws_iam_role_policy.artifacts["apply"].policy).Statement[0].Action, "s3:PutObject") && contains(jsondecode(aws_iam_role_policy.artifacts["plan"].policy).Statement[0].Action, "s3:PutObject")
    error_message = "Only the plan role should publish saved plans and releases."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.state_access["apply"].policy).Statement[3].Effect == "Deny" && endswith(jsondecode(aws_iam_role_policy.state_access["apply"].policy).Statement[3].Resource[0], "/bootstrap/*")
    error_message = "Deployment roles must not access bootstrap state."
  }
  assert {
    condition     = !contains(jsondecode(aws_iam_role_policy.state_access["apply"].policy).Statement[1].Action, "s3:DeleteObject") && contains(jsondecode(aws_iam_role_policy.state_access["apply"].policy).Statement[2].Action, "s3:DeleteObject")
    error_message = "Deletion is needed for the lock, not the state object."
  }
  assert {
    condition     = length(aws_iam_role_policy.application) == 2
    error_message = "Milestone 5 requires separate plan and apply application policies."
  }
}

run "immutable_repository_subject" {
  command = apply
  variables {
    github_owner_id      = "1234"
    github_repository_id = "5678"
  }
  assert {
    condition     = output.github_oidc_subject == "repo:learner@1234/order-manager@5678:ref:refs/heads/main"
    error_message = "New-format subjects must include immutable owner and repository IDs."
  }
}

run "reuse_existing_provider" {
  command = plan
  variables {
    existing_github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }
  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && length(data.aws_iam_openid_connect_provider.existing) == 1
    error_message = "An existing shared provider must be read instead of created."
  }
}

run "reject_shared_bucket" {
  command = plan
  variables {
    artifact_bucket_name = "order-manager-test-state-123456"
  }
  expect_failures = [var.artifact_bucket_name]
}

run "reject_partial_ids" {
  command = plan
  variables {
    github_owner_id = "1234"
  }
  expect_failures = [var.github_owner_id]
}
