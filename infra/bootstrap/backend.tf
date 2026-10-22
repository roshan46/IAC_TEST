# Activate only AFTER applying bootstrap with local state.
# Copy this file to backend.tf, then run init -migrate-state.
terraform {
  backend "s3" {}
}
