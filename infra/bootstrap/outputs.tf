output "state_bucket_name" {
  description = "Remote state bucket; bootstrap and dev use different keys."
  value       = aws_s3_bucket.bootstrap["state"].id
}
output "artifact_bucket_name" {
  value = aws_s3_bucket.bootstrap["artifacts"].id
}
output "github_plan_role_arn" {
  value = aws_iam_role.github["plan"].arn
}
output "github_apply_role_arn" {
  value = aws_iam_role.github["apply"].arn
}
output "github_oidc_provider_arn" {
  value = local.oidc_arn
}
output "github_oidc_subject" {
  description = "Exact sub claim trusted by both roles."
  value       = local.github_subject
}
output "bootstrap_backend_config" {
  description = "Copy into backend.s3.tfbackend AFTER creating the bucket."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.bootstrap["state"].id}"
    key          = "bootstrap/terraform.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
