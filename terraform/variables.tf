variable "github_oidc_sub_patterns" {
  description = "IAM StringLike patterns for GitHub OIDC sub claims. Use repo:OWNER/REPO:* so workflow_dispatch, tags, and custom subject claims still match."
  type        = list(string)
  default = [
    "repo:talktoarnab/nyc_taxi:*",
    "repo:talktoarnab/NYC_Taxi:*",
    "repo:talktoarnab/nyc-taxi:*",
    "repo:talktoarnab/NYC-Taxi:*",
    "repo:talktoarnab@*/nyc_taxi@*:*",
    "repo:talktoarnab@*/NYC_Taxi@*:*",
    "repo:talktoarnab@*/nyc-taxi@*:*",
    "repo:talktoarnab@*/NYC-Taxi@*:*",
  ]
}

variable "attach_deployer_user_policies" {
  description = "Attach Glue/Athena/EventBridge/Logs managed policies to deployer_iam_user via Terraform."
  type        = bool
  default     = true
}

variable "deployer_iam_user" {
  description = "IAM user that runs terraform locally (lamba-cli-access in this account)."
  type        = string
  default     = "lamba-cli-access"
}

variable "github_owner" {
  description = "GitHub org or user that hosts this repo (OIDC trust)."
  type        = string
  default     = "talktoarnab"
}

variable "github_repo" {
  description = "GitHub repository name (OIDC trust)."
  type        = string
  default     = "nyc_taxi"
}

variable "aws_region" {
  description = "AWS region for the datalake. The architectural guide uses us-east-1 (TLC public dataset lives there)."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Optional named AWS CLI profile. Leave empty to use the default credential chain."
  type        = string
  default     = ""
}

variable "enable_analytics" {
  description = "Create the Glue backfill job, Glue Data Catalog database/table, and Athena workgroup. Requires glue:* and athena:* on the deploying IAM identity."
  type        = bool
  default     = true
}

variable "enable_monthly_schedule" {
  description = "Create the EventBridge rule that ingests last month's TLC file on the 15th."
  type        = bool
  default     = true
}

variable "enable_http_ingest" {
  description = "Glue backfill copies TLC files from CloudFront into raw/historical/ before Spark runs. Disable to read SOURCE_PATH directly (e.g. s3://nyc-tlc/trip data/)."
  type        = bool
  default     = true
}

variable "glue_source_path" {
  description = "Parquet path the Glue job reads when enable_http_ingest is false."
  type        = string
  default     = "s3://nyc-tlc/trip data/"
}

variable "tlc_http_base" {
  description = "HTTPS base URL for monthly yellow_tripdata_YYYY-MM.parquet files."
  type        = string
  default     = "https://d37ci6vzurychx.cloudfront.net/trip-data"
}

variable "backfill_start_year" {
  description = "Inclusive start year for the Glue historical backfill and Athena projection."
  type        = number
  default     = 2014
}

variable "backfill_end_year" {
  description = "Inclusive end year for the Glue historical backfill and Athena projection."
  type        = number
  default     = 2026
}

variable "glue_version" {
  type    = string
  default = "4.0"
}

variable "glue_worker_type" {
  description = "Glue worker type. Architectural guide specifies G.1X."
  type        = string
  default     = "G.1X"
}

variable "glue_number_of_workers" {
  type    = number
  default = 10
}

variable "glue_timeout_minutes" {
  type    = number
  default = 180
}

variable "glue_execution_class" {
  description = "STANDARD or FLEX (cheaper, best-effort capacity — preferred for backfills)."
  type        = string
  default     = "FLEX"
}

variable "transform_memory_mb" {
  description = "Lambda memory for DuckDB. More memory also adds vCPU."
  type        = number
  default     = 3008
}

variable "athena_bytes_scanned_cutoff" {
  description = "Per-query Athena scan cap in bytes (FinOps guardrail). 0 disables the cap."
  type        = number
  default     = 10737418240
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "force_destroy_bucket" {
  description = "Allow terraform destroy to empty the datalake bucket. Leave false in production."
  type        = bool
  default     = false
}

variable "tags" {
  type = map(string)
  default = {
    Project     = "nyc-taxi-datalake"
    ManagedBy   = "terraform"
    Environment = "private"
  }
}
