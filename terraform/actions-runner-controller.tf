# GitHub App credentials for Actions Runner Controller.
#
# The ARC controller itself never talks to GitHub - the per-runner-scale-set
# listener does. Each consuming project (for example the separate
# mlops-platform repository) deploys its own AutoScalingRunnerSet into the
# arc-runners namespace and points it at the Kubernetes Secret that
# gitops/ci/actions-runner-controller/arc-github-app-secret.yaml materialises
# from this Secrets Manager entry.
#
# A GitHub App is used instead of a PAT: it is scoped to the organisation or
# repositories the app is installed on, its installation token is short-lived
# and refreshed by the listener, and it is not tied to a human account.
#
# All three values default to empty so an EKS-only deployment still applies
# cleanly. The secret is created either way; the ExternalSecret syncs whatever
# is in it, and nothing consumes it until a project declares a runner scale set.

resource "aws_secretsmanager_secret" "arc_github_app" {
  name                    = "arc-github-app"
  description             = "GitHub App credentials used by Actions Runner Controller runner scale sets"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    ExternalSecret = "true"
  })
}

resource "aws_secretsmanager_secret_version" "arc_github_app" {
  secret_id = aws_secretsmanager_secret.arc_github_app.id

  # All three keys must always be present, even when empty.
  #
  # External Secrets fails an ExternalSecret when a referenced property is
  # *absent*, but accepts an empty value - so writing empty strings is what lets
  # an EKS-only deployment sync this Secret and stay Healthy with no GitHub App
  # configured. Do not make these conditional the way
  # argocd_admin_password_plaintext is in secrets-manager.tf: dropping a key
  # would break arc-github-app-secret with "key githubAppId does not exist in
  # secret arc-github-app", for a feature the deployment is not even using.
  secret_string = jsonencode({
    githubAppId             = var.github_app_id
    githubAppInstallationId = var.github_app_installation_id
    githubAppPrivateKey     = var.github_app_private_key
  })
}
