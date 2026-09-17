data "aws_iam_policy_document" "glue_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "glue" {
  statement {
    sid = "DatalakeS3"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:AbortMultipartUpload",
      "s3:ListBucketMultipartUploads",
    ]
    resources = [
      aws_s3_bucket.datalake.arn,
      "${aws_s3_bucket.datalake.arn}/*",
    ]
  }

  statement {
    sid = "PublicTlcRead"
    actions = [
      "s3:GetObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [
      "arn:aws:s3:::nyc-tlc",
      "arn:aws:s3:::nyc-tlc/*",
    ]
  }

  statement {
    sid = "Logs"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:*"]
  }

  statement {
    sid = "GlueCatalog"
    actions = [
      "glue:GetDatabase",
      "glue:GetTable",
      "glue:GetPartitions",
      "glue:CreateTable",
      "glue:UpdateTable",
      "glue:BatchCreatePartition",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "ingest" {
  statement {
    sid = "PutMonthlyRaw"
    actions = [
      "s3:PutObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.datalake.arn}/${local.raw_monthly}*"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:*"]
  }
}

data "aws_iam_policy_document" "transform" {
  statement {
    sid = "ReadMonthlyRaw"
    actions = [
      "s3:GetObject",
    ]
    resources = ["${aws_s3_bucket.datalake.arn}/${local.raw_monthly}*"]
  }

  statement {
    sid = "WriteProcessed"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]
    resources = ["${aws_s3_bucket.datalake.arn}/${local.processed}*"]
  }

  statement {
    sid       = "ListBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.datalake.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        trim(local.raw_monthly, "/"),
        "${local.raw_monthly}*",
        trim(local.processed, "/"),
        "${local.processed}*",
      ]
    }
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["arn:aws:logs:${var.aws_region}:${local.account_id}:*"]
  }
}

resource "aws_iam_role" "glue" {
  name               = "${local.name_prefix}-glue-backfill"
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json
}

resource "aws_iam_role_policy" "glue" {
  name   = "${local.name_prefix}-glue-backfill"
  role   = aws_iam_role.glue.id
  policy = data.aws_iam_policy_document.glue.json
}

resource "aws_iam_role" "ingest" {
  name               = "${local.name_prefix}-lambda-ingest"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "ingest" {
  name   = "${local.name_prefix}-lambda-ingest"
  role   = aws_iam_role.ingest.id
  policy = data.aws_iam_policy_document.ingest.json
}

resource "aws_iam_role" "transform" {
  name               = "${local.name_prefix}-lambda-transform"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

resource "aws_iam_role_policy" "transform" {
  name   = "${local.name_prefix}-lambda-transform"
  role   = aws_iam_role.transform.id
  policy = data.aws_iam_policy_document.transform.json
}
