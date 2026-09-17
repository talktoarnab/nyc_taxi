locals {
  deployer_managed_policies = toset([
    "arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess",
    "arn:aws:iam::aws:policy/AmazonAthenaFullAccess",
    "arn:aws:iam::aws:policy/AmazonEventBridgeFullAccess",
    "arn:aws:iam::aws:policy/CloudWatchLogsFullAccess",
  ])

  github_actions_managed_policies = setunion(local.deployer_managed_policies, toset([
    "arn:aws:iam::aws:policy/AWSLambda_FullAccess",
    "arn:aws:iam::aws:policy/AmazonS3FullAccess",
    "arn:aws:iam::aws:policy/IAMFullAccess",
  ]))
}

# Attach Glue/Athena/EventBridge/Logs to the existing CLI user so a local
# terraform apply can create those services. Uses IAMFullAccess already on the user.
resource "aws_iam_user_policy_attachment" "deployer" {
  for_each = var.attach_deployer_user_policies ? local.deployer_managed_policies : toset([])

  user       = var.deployer_iam_user
  policy_arn = each.value
}

resource "time_sleep" "iam_propagation" {
  count           = var.attach_deployer_user_policies ? 1 : 0
  create_duration = "30s"
  depends_on      = [aws_iam_user_policy_attachment.deployer]
}

# Account already has the GitHub OIDC provider; do not create a second one.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_iam_policy_document" "github_actions_assume" {
  statement {
    sid     = "GitHubActionsOidc"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_owner}/${var.github_repo}:pull_request",
        "repo:${var.github_owner}/${var.github_repo}:environment:aws",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "${local.name_prefix}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json
  description        = "GitHub Actions OIDC role for Terraform apply of the NYC taxi lakehouse."
}

resource "aws_iam_role_policy_attachment" "github_actions" {
  for_each = local.github_actions_managed_policies

  role       = aws_iam_role.github_actions.name
  policy_arn = each.value
}
