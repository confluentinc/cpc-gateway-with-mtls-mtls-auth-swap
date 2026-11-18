################################################################################
# KMS key for Gateway field-level encryption (CSFLE rules with enableAt: GATEWAY)
#
# The Gateway pods run as service account gateway/cpcgw-dmz. Through IRSA they get the base role
# (cpcgw-dmz-irsa), whose only permission is to assume the KMS role. The Gateway's encryption rule
# executors assume the KMS role (role.arn in the aws-kms-role-params secret) to wrap and unwrap DEKs.
################################################################################

locals {
  gateway_service_account = "system:serviceaccount:gateway:cpcgw-dmz"
}

resource "aws_kms_key" "payments_kek" {
  description             = "WF demo: KEK for Gateway field encryption of demo-payments"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  tags                    = local.tags
}

resource "aws_kms_alias" "payments_kek" {
  name          = "alias/wf-demo-payments-kek"
  target_key_id = aws_kms_key.payments_kek.key_id
}

data "aws_iam_policy_document" "gateway_irsa_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [module.eks.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:sub"
      values   = [local.gateway_service_account]
    }
    condition {
      test     = "StringEquals"
      variable = "${module.eks.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gateway_irsa" {
  name               = "${var.cluster_name}-cpcgw-irsa"
  assume_role_policy = data.aws_iam_policy_document.gateway_irsa_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "gateway_irsa_assume_kms" {
  name = "assume-kms-role"
  role = aws_iam_role.gateway_irsa.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Resource = aws_iam_role.gateway_kms.arn }]
  })
}

data "aws_iam_policy_document" "gateway_kms_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.gateway_irsa.arn]
    }
  }
}

resource "aws_iam_role" "gateway_kms" {
  name               = "${var.cluster_name}-cpcgw-kms"
  assume_role_policy = data.aws_iam_policy_document.gateway_kms_trust.json
  tags               = local.tags
}

resource "aws_iam_role_policy" "gateway_kms" {
  name = "payments-kek"
  role = aws_iam_role.gateway_kms.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
      Resource = aws_kms_key.payments_kek.arn
    }]
  })
}
