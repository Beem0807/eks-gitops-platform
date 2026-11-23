# GitHub App credentials for the MLOps ingestion worker.
#
# A SEPARATE App from arc-github-app, deliberately. That one authenticates CI
# runner scale sets; this one can write to the mlops-platform repository's
# default branch, because the ingestion worker's whole job is to commit an
# updated dataset pointer. Sharing one App would hand every CI runner commit
# rights it has no use for.
#
# What the consumer does with it: the worker signs a JWT with the private key
# and exchanges it for an installation token at the moment it pushes. The token
# is never stored. An installation token lives 60 minutes and that is not
# configurable, so a token cached in a Secret can be dead by the time a Job
# picks it up - see
# applications/fraud-detection/src/ingestion/github_auth.py in the MLOps
# repository.
#
# Like arc-github-app, all three values default to empty so an EKS-only
# deployment still applies cleanly, and all three keys are always written even
# when empty - External Secrets fails on an *absent* property but accepts an
# empty value.
#
# recovery_window_in_days = 0 matches the rest of the platform: without it a
# destroyed secret is only *scheduled* for deletion for 30 days, and the next
# bootstrap fails because the name is still taken.

resource "aws_secretsmanager_secret" "mlops_ingestion_github_app" {
  name                    = "mlops-ingestion-github-app"
  description             = "GitHub App credentials used by the MLOps dataset ingestion worker to push pointer commits"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, local.crossplane_denied_tags, {
    ExternalSecret = "true"
    Workload       = "mlops"
  })
}

resource "aws_secretsmanager_secret_version" "mlops_ingestion_github_app" {
  secret_id = aws_secretsmanager_secret.mlops_ingestion_github_app.id

  secret_string = jsonencode({
    githubAppId             = var.mlops_github_app_id
    githubAppInstallationId = var.mlops_github_app_installation_id
    githubAppPrivateKey     = var.mlops_github_app_private_key
  })
}

output "mlops_ingestion_github_app_secret_name" {
  description = "Secrets Manager entry the MLOps ingestion ExternalSecret reads"
  value       = aws_secretsmanager_secret.mlops_ingestion_github_app.name
}

output "mlops_github_app_configured" {
  description = "Whether the MLOps ingestion GitHub App credentials were supplied"

  # nonsensitive() on the BOOLEAN, not on the key.
  #
  # Terraform propagates sensitivity through any expression, so a plain
  # comparison against the private key makes this output sensitive and
  # `terraform output -raw` returns nothing useful - which is what bootstrap.sh
  # needs to read. Unwrapping the comparison result exports one bit ("is it
  # set"), never the key itself. Marking the whole output sensitive instead
  # would hide that bit from the script for no gain.
  value = var.mlops_github_app_id != "" && nonsensitive(var.mlops_github_app_private_key != "")
}
