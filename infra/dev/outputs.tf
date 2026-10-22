output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_ids" {
  value = { for key, subnet in aws_subnet.public : key => subnet.id }
}

output "database_subnet_ids" {
  value = { for key, subnet in aws_subnet.database : key => subnet.id }
}

output "instance_id" {
  value = aws_instance.app.id
}

output "app_url" {
  description = "HTTP lab URL after the Milestone 5 SSM application deployment."
  value       = "http://${aws_instance.app.public_ip}:8000"
}

output "db_host" {
  value = aws_db_instance.main.address
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "db_secret_arn" {
  description = "Secret identifier only. The password is never read into Terraform state."
  value       = aws_db_instance.main.master_user_secret[0].secret_arn
}

output "ssm_start_session" {
  value = "aws ssm start-session --region ${var.aws_region} --target ${aws_instance.app.id}"
}

output "state_machine_arn" {
  value = aws_sfn_state_machine.orders.arn
}

output "receipt_bucket" {
  value = aws_s3_bucket.receipts.id
}

output "workflow_console_url" {
  value = "https://${var.aws_region}.console.aws.amazon.com/states/home?region=${var.aws_region}#/statemachines/view/${aws_sfn_state_machine.orders.arn}"
}

output "worker_function_names" {
  value = { for name, worker in aws_lambda_function.worker : name => worker.function_name }
}
