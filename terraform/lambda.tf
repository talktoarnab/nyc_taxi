data "archive_file" "ingest" {
  type        = "zip"
  output_path = "${path.module}/../build/lambda_ingest.zip"

  source {
    content  = file("${path.module}/../src/lambda/ingest/handler.py")
    filename = "handler.py"
  }
}

resource "null_resource" "transform_package" {
  triggers = {
    handler = filemd5("${path.module}/../src/lambda/transform/handler.py")
    reqs    = filemd5("${path.module}/../src/lambda/transform/requirements.txt")
    script  = filemd5("${path.module}/../scripts/package_lambda.sh")
  }

  provisioner "local-exec" {
    command     = "${path.module}/../scripts/package_lambda.sh"
    interpreter = ["bash", "-c"]
  }
}

data "archive_file" "transform" {
  type        = "zip"
  source_dir  = "${path.module}/../build/lambda_transform"
  output_path = "${path.module}/../build/lambda_transform.zip"
  excludes    = []
  depends_on  = [null_resource.transform_package]
}

resource "aws_lambda_function" "ingest" {
  function_name    = "${local.name_prefix}-ingest"
  filename         = data.archive_file.ingest.output_path
  source_code_hash = data.archive_file.ingest.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  role             = aws_iam_role.ingest.arn
  timeout          = 300
  memory_size      = 512
  description      = "Copy one monthly TLC Yellow Taxi Parquet file into raw/monthly/"

  environment {
    variables = merge(local.common_env, {
      RAW_PREFIX = local.raw_monthly
    })
  }

  depends_on = [aws_iam_role_policy.ingest]
}

resource "aws_lambda_function" "transform" {
  function_name    = "${local.name_prefix}-transform"
  filename         = data.archive_file.transform.output_path
  source_code_hash = data.archive_file.transform.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  architectures    = ["arm64"]
  role             = aws_iam_role.transform.arn
  timeout          = 300
  memory_size      = var.transform_memory_mb
  description      = "DuckDB incremental transform of a monthly Parquet file into processed/"

  ephemeral_storage {
    size = 1024
  }

  environment {
    variables = merge(local.common_env, {
      PROCESSED_PREFIX = local.processed
    })
  }

  depends_on = [aws_iam_role_policy.transform]
}

resource "aws_lambda_permission" "allow_s3_transform" {
  statement_id  = "AllowS3InvokeTransform"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.transform.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.datalake.arn
}

resource "aws_s3_bucket_notification" "monthly_raw" {
  bucket = aws_s3_bucket.datalake.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.transform.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = local.raw_monthly
    filter_suffix       = ".parquet"
  }

  depends_on = [aws_lambda_permission.allow_s3_transform]
}
