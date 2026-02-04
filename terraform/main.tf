terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

resource "cloudflare_pages_project" "astro_blog" {
  account_id        = var.cloudflare_account_id
  name              = var.project_name
  production_branch = var.production_branch
  build_config = {
    build_caching   = true
    build_command   = "bun install && bun run build"
    destination_dir = "dist"
    root_dir        = "app"
  }

  source = {
    type = "github"
    config = {
      owner                          = var.owner_name
      pr_comments_enabled            = true
      production_branch              = var.production_branch
      production_deployments_enabled = true
      preview_deployment_setting     = "all"
      repo_name                      = var.repo_name
    }
  }

  deployment_configs = {
    production = {
      env_vars = {
        BUN_VERSION = {
          type  = "plain_text"
          value = "latest"
        }
        NODE_VERSION = {
          type  = "plain_text"
          value = "25"
        }
      }
    }
    preview = {
      env_vars = {
        BUN_VERSION = {
          type  = "plain_text"
          value = "latest"
        }
      }
    }
  }
}

resource "cloudflare_pages_domain" "cloudflare_custom_domain" {
  account_id   = var.cloudflare_account_id
  project_name = cloudflare_pages_project.astro_blog.name
  name         = var.custom_domain
}

# DNS record for custom domain pointing to Pages
resource "cloudflare_dns_record" "pages_cname" {
  zone_id = var.cloudflare_zone_id
  name    = "@"
  type    = "CNAME"
  content = "${cloudflare_pages_project.astro_blog.name}.pages.dev"
  proxied = true
  ttl     = 1 # Auto TTL when proxied
}

# Enable TLS 1.3
// NOTE: This resource cannot be destroyed from Terraform. 
// This will be present in the API until manually deleted.
resource "cloudflare_zone_setting" "tls_1_3" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "tls_1_3"
  value      = "on"
}

# Enable automatic HTTPS rewrites
resource "cloudflare_zone_setting" "automatic_https_rewrites" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "automatic_https_rewrites"
  value      = "on"
}

# Set SSL mode to strict
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = "strict"
}
