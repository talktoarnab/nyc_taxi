resource "aws_glue_job" "backfill" {
  count             = var.enable_analytics ? 1 : 0
  name              = "${local.name_prefix}-historical-backfill"
  role_arn          = aws_iam_role.glue.arn
  description       = "Spark backfill of NYC Yellow Taxi into Hive-partitioned Parquet (G.1X / Flex)."
  glue_version      = var.glue_version
  worker_type       = var.glue_worker_type
  number_of_workers = var.glue_number_of_workers
  timeout           = var.glue_timeout_minutes
  max_retries       = 0
  execution_class   = var.glue_execution_class

  command {
    name            = "glueetl"
    python_version  = "3"
    script_location = "s3://${aws_s3_bucket.datalake.id}/${local.glue_script_key}"
  }

  default_arguments = {
    "--job-language"                     = "python"
    "--job-bookmark-option"              = "job-bookmark-disable"
    "--enable-metrics"                   = "true"
    "--enable-spark-ui"                  = "true"
    "--spark-event-logs-path"            = "s3://${aws_s3_bucket.datalake.id}/spark-logs/"
    "--enable-continuous-cloudwatch-log" = "true"
    "--enable-glue-datacatalog"          = "true"
    "--TempDir"                          = "s3://${aws_s3_bucket.datalake.id}/glue-temp/"
    "--DATALAKE_BUCKET"                  = aws_s3_bucket.datalake.id
    "--SOURCE_PATH"                      = var.glue_source_path
    "--START_YEAR"                       = tostring(var.backfill_start_year)
    "--END_YEAR"                         = tostring(var.backfill_end_year)
    "--ENABLE_HTTP_INGEST"               = var.enable_http_ingest ? "true" : "false"
    "--TLC_HTTP_BASE"                    = var.tlc_http_base
  }

  execution_property {
    max_concurrent_runs = 1
  }

  depends_on = [aws_s3_object.glue_script, aws_iam_role_policy.glue]
}
