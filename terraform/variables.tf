variable "cloudflare_api_token" {
  description = "Cloudflare API Token with appropriate permissions"
  type        = string
}

variable "cloudflare_zone_id" {
  description = "The Zone ID for the Cloudflare zone"
  type        = string
}

variable "cloudflare_account_id" {
  description = "The Account ID for the Cloudflare account"
  type        = string
}

variable "custom_domain" {
  description = "The custom domain to be used"
  type        = string
}

variable "production_branch" {
  description = "The production branch for the Cloudflare Pages project"
  type        = string
  default     = "main"
}

variable "owner_name" {
  description = "The GitHub username or organization name"
  type        = string
}

variable "repo_name" {
  description = "The GitHub repository name"
  type        = string
}

variable "project_name" {
  description = "The name of the Cloudflare Pages project"
  type        = string
}
