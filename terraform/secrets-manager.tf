resource "time_static" "argocd_admin_password_mtime" {
  triggers = {
    password_hash = var.argocd_admin_password_hash
  }
}

resource "aws_secretsmanager_secret" "argocd_admin" {
  name                    = "argocd-admin"
  description             = "Argo CD admin password"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    ExternalSecret = "true"
  })
}

resource "aws_secretsmanager_secret_version" "argocd_admin" {
  secret_id = aws_secretsmanager_secret.argocd_admin.id

  secret_string = jsonencode(
    merge(
      {
        adminPasswordHash  = var.argocd_admin_password_hash
        adminPasswordMtime = time_static.argocd_admin_password_mtime.rfc3339
      },
      var.argocd_admin_password_plaintext != null ? {
        adminPassword = var.argocd_admin_password_plaintext
      } : {}
    )
  )
}

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "grafana-admin"
  description             = "Grafana admin credentials"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    ExternalSecret = "true"
  })
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id

  secret_string = jsonencode({
    adminUser     = var.grafana_admin_user
    adminPassword = var.grafana_admin_password
  })
}


resource "aws_secretsmanager_secret" "alertmanager_webhook" {
  name                    = "alertmanager-webhook"
  description             = "Alertmanager Slack webhook URL"
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    ExternalSecret = "true"
  })
}

resource "aws_secretsmanager_secret_version" "alertmanager_webhook" {
  secret_id = aws_secretsmanager_secret.alertmanager_webhook.id

  secret_string = jsonencode({
    slackWebhookUrl = var.alertmanager_slack_webhook_url
  })
}