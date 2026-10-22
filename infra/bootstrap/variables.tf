variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "project_name" {
  type    = string
  default = "order-manager"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,39}$", var.project_name))
    error_message = "Use 3-40 lowercase letters, digits, or hyphens, starting with a letter."
  }
}

variable "github_repository" {
  description = "Exact OWNER/REPO trusted by the OIDC roles."
  type        = string
  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Set github_repository to OWNER/REPO, without a URL or wildcard."
  }
}

variable "state_bucket_name" {
  description = "Choose a new globally unique bucket name."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "Use a globally unique 3-63 character lowercase bucket name with digits/hyphens, no dots."
  }
}

variable "artifact_bucket_name" {
  description = "Separate private bucket for releases and sensitive saved plans."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$", var.artifact_bucket_name)) && var.artifact_bucket_name != var.state_bucket_name
    error_message = "Use a distinct globally unique 3-63 character lowercase bucket name with digits/hyphens, no dots."
  }
}

variable "github_owner_id" {
  description = "Immutable GitHub owner ID for new-format subjects. Set both IDs, or neither for verified legacy subjects."
  type        = string
  default     = null
  validation {
    condition     = (var.github_owner_id == null) == (var.github_repository_id == null) && (var.github_owner_id == null ? true : can(regex("^[0-9]+$", var.github_owner_id)))
    error_message = "Set both numeric GitHub IDs together, or leave both null for a legacy subject."
  }
}

variable "github_repository_id" {
  description = "Immutable GitHub repository ID from the repository API."
  type        = string
  default     = null
  validation {
    condition     = var.github_repository_id == null ? true : can(regex("^[0-9]+$", var.github_repository_id))
    error_message = "GitHub repository ID must be numeric."
  }
}

variable "existing_github_oidc_provider_arn" {
  description = "Explicitly reuse the account-wide GitHub OIDC provider; null creates one."
  type        = string
  default     = null
  validation {
    condition     = var.existing_github_oidc_provider_arn == null ? true : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:oidc-provider/token\\.actions\\.githubusercontent\\.com$", var.existing_github_oidc_provider_arn))
    error_message = "Provide the IAM ARN for the GitHub OIDC provider in your account."
  }
}
