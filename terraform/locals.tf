data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  bucket_name    = "nyc-taxi-datalake-${data.aws_caller_identity.current.account_id}"
  name_prefix    = "nyc-taxi"
  raw_historical = "raw/historical/"
  raw_monthly    = "raw/monthly/"
  processed      = "processed/yellow_taxi/"
  scripts        = "scripts/"
  athena_results = "athena-results/"

  glue_script_key = "scripts/glue/backfill.py"

  projection_year_range = "${var.backfill_start_year},${var.backfill_end_year}"

  # Do not set AWS_REGION — it is reserved by Lambda.
  common_env = {
    DATALAKE_BUCKET = local.bucket_name
    TLC_HTTP_BASE   = var.tlc_http_base
  }
}
