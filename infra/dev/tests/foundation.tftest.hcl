mock_provider "aws" {
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/order-manager/application/mock" }
  }
  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-2:123456789012:function:mock-worker" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-2:123456789012:log-group:mock-log" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_ami" {
    defaults = { id = "ami-0123456789abcdef0" }
  }
  mock_resource "aws_db_instance" {
    defaults = {
      master_user_secret = [{
        secret_arn    = "arn:aws:secretsmanager:us-east-2:123456789012:secret:rds!db-test"
        kms_key_id    = "arn:aws:kms:us-east-2:123456789012:key/test"
        secret_status = "active"
      }]
    }
  }
}

variables {
  lambda_package_directory = null
  release_sha              = "0000000000000000000000000000000000000000"
  lambda_hashes = {
    validate = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    fulfill  = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    receipt  = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
  }
  learner_cidr       = "203.0.113.10/32"
  artifact_bucket    = "order-manager-test-artifacts"
  ami_id             = "ami-0123456789abcdef0"
  aws_region         = "us-east-2"
  availability_zones = ["us-east-2a", "us-east-2b"]
}

run "network_and_database_isolation" {
  command = apply
  assert {
    condition     = length(aws_subnet.database) == 2 && aws_subnet.database["a"].availability_zone != aws_subnet.database["b"].availability_zone
    error_message = "RDS placement must span two distinct AZs."
  }
  assert {
    condition     = alltrue([for subnet in aws_subnet.database : !subnet.map_public_ip_on_launch]) && alltrue([for table in aws_route_table.database : length(table.route) == 0])
    error_message = "Database subnets must have no public IP assignment or internet default routes."
  }
  assert {
    condition     = !aws_db_instance.main.publicly_accessible && !aws_db_instance.main.multi_az && aws_db_instance.main.storage_encrypted
    error_message = "The lab database must be private, encrypted, and Single-AZ."
  }
  assert {
    condition     = aws_db_instance.main.manage_master_user_password && aws_db_instance.main.password == null
    error_message = "RDS must generate the password; never put it in Terraform."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.postgres.referenced_security_group_id == aws_security_group.app.id && aws_vpc_security_group_ingress_rule.postgres.from_port == 5432 && aws_vpc_security_group_ingress_rule.postgres.cidr_ipv4 == null
    error_message = "DB ingress must reference the app security group, not an IP range."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.app_http.cidr_ipv4 == "203.0.113.10/32" && aws_vpc_security_group_ingress_rule.app_http.from_port == 8000
    error_message = "App access must stay restricted to the learner."
  }
}

run "host_and_credentials" {
  command = apply
  assert {
    condition     = aws_instance.app.metadata_options[0].http_tokens == "required" && aws_instance.app.root_block_device[0].encrypted
    error_message = "EC2 requires IMDSv2 and encrypted root storage."
  }
  assert {
    condition     = aws_instance.app.user_data_replace_on_change && endswith(aws_iam_role_policy_attachment.ssm.policy_arn, ":iam::aws:policy/AmazonSSMManagedInstanceCore")
    error_message = "Use SSM management and rerun changed host setup through replacement."
  }
  assert {
    condition     = jsondecode(aws_iam_role_policy.app.policy).Statement[0].Resource[0] == aws_db_instance.main.master_user_secret[0].secret_arn && length(jsondecode(aws_iam_role_policy.app.policy).Statement[0].Resource) == 1
    error_message = "The host can read only its RDS-managed secret."
  }
  assert {
    condition     = aws_cloudwatch_log_group.postgres.retention_in_days == 7
    error_message = "Database log retention must be bounded."
  }
}

run "reject_open_ingress" {
  command = plan
  variables {
    learner_cidr = "0.0.0.0/0"
  }
  expect_failures = [var.learner_cidr]
}

run "reject_single_az_subnet_group" {
  command = plan
  variables {
    availability_zones = ["us-east-2a", "us-east-2a"]
  }
  expect_failures = [var.availability_zones]
}

run "require_snapshot_name" {
  command = plan
  variables {
    db_skip_final_snapshot       = false
    db_final_snapshot_identifier = null
  }
  expect_failures = [aws_db_instance.main]
}

run "retain_named_snapshot" {
  command = plan
  variables {
    db_skip_final_snapshot       = false
    db_final_snapshot_identifier = "order-manager-dev-final-review"
  }
  assert {
    condition     = !aws_db_instance.main.skip_final_snapshot && aws_db_instance.main.final_snapshot_identifier == "order-manager-dev-final-review"
    error_message = "A requested final snapshot must be preserved."
  }
}

run "serverless_flow_and_permissions" {
  command = apply
  assert {
    condition     = aws_sfn_state_machine.orders.type == "STANDARD" && jsondecode(aws_sfn_state_machine.orders.definition).StartAt == "Validate" && jsondecode(aws_sfn_state_machine.orders.definition).States.Fulfill.Next == "Receipt"
    error_message = "Orders require a Standard validate/fulfill/receipt workflow."
  }
  assert {
    condition     = jsondecode(aws_sfn_state_machine.orders.definition).States.Fulfill.Catch[0].Next == "ProcessingFailed" && jsondecode(aws_sfn_state_machine.orders.definition).States.ProcessingFailed.Type == "Fail"
    error_message = "Controlled failures must terminate as failed executions."
  }
  assert {
    condition     = alltrue([for worker in aws_lambda_function.worker : worker.runtime == "python3.13" && worker.timeout == 20]) && length(aws_lambda_function.worker) == 3
    error_message = "Deploy exactly three Python workers with bounded timeouts."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.receipts.block_public_policy && aws_s3_bucket_public_access_block.receipts.restrict_public_buckets && !aws_s3_bucket.receipts.force_destroy
    error_message = "Receipts stay private and require deliberate data cleanup."
  }
  assert {
    condition     = aws_iam_role_policy.receipt_write.role == aws_iam_role.worker["receipt"].id && jsondecode(aws_iam_role_policy.receipt_write.policy).Statement[0].Action[0] == "s3:PutObject" && endswith(jsondecode(aws_iam_role_policy.receipt_write.policy).Statement[0].Resource[0], "/receipts/*")
    error_message = "Only the receipt writer gets write access to the receipt prefix."
  }
  assert {
    condition     = length(jsondecode(aws_iam_role_policy.workflow.policy).Statement[0].Resource) == 3 && jsondecode(aws_iam_role_policy.workflow.policy).Statement[0].Action[0] == "lambda:InvokeFunction"
    error_message = "Workflow invocation must be limited to the three workers."
  }
  assert {
    condition     = aws_cloudwatch_log_group.workflow.retention_in_days == 7 && alltrue([for group in aws_cloudwatch_log_group.worker : group.retention_in_days == 7])
    error_message = "Workflow and worker logs must expire after seven days."
  }
  assert {
    condition     = endswith(jsondecode(aws_iam_role_policy.app_workflow.policy).Statement[1].Resource[0], ":execution:order-manager-dev-orders:*") && jsondecode(aws_iam_role_policy.app_workflow.policy).Statement[2].Action[0] == "s3:GetObject"
    error_message = "EC2 may inspect only its order executions and read receipts."
  }
}
