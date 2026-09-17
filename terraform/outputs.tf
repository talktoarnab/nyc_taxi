output "github_actions_role_arn" {
  description = "OIDC role assumed by GitHub Actions. Hardcoded in .github/workflows/terraform.yml."
  value       = aws_iam_role.github_actions.arn
}

output "account_id" {
  value = local.account_id
}

output "region" {
  value = var.aws_region
}

output "datalake_bucket" {
  value       = aws_s3_bucket.datalake.id
  description = "S3 datalake: raw/, processed/, scripts/"
}

output "glue_job_name" {
  value = try(aws_glue_job.backfill[0].name, null)
}

output "ingest_lambda_name" {
  value = aws_lambda_function.ingest.function_name
}

output "transform_lambda_name" {
  value = aws_lambda_function.transform.function_name
}

output "athena_database" {
  value = try(aws_glue_catalog_database.nyc_taxi[0].name, null)
}

output "athena_table" {
  value = try(aws_glue_catalog_table.yellow_taxi_trips[0].name, null)
}

output "athena_workgroup" {
  value = try(aws_athena_workgroup.nyc_taxi[0].name, null)
}

output "start_backfill_command" {
  description = "Start the Glue historical backfill (does not run on terraform apply)."
  value       = var.enable_analytics ? "aws glue start-job-run --job-name ${aws_glue_job.backfill[0].name} --region ${var.aws_region}" : "enable_analytics is false"
}

output "ingest_one_month_command" {
  description = "Manually ingest a specific month into raw/monthly/ (triggers DuckDB)."
  value       = "aws lambda invoke --function-name ${aws_lambda_function.ingest.function_name} --cli-binary-format raw-in-base64-out --payload '{\"year\":2024,\"month\":1}' --region ${var.aws_region} /tmp/nyc-taxi-ingest.json && cat /tmp/nyc-taxi-ingest.json"
}

output "athena_query_command" {
  value = var.enable_analytics ? "aws athena start-query-execution --work-group ${aws_athena_workgroup.nyc_taxi[0].name} --query-string 'SELECT year, month, count(*) AS trips FROM nyc_taxi.yellow_taxi_trips WHERE year = 2024 AND month = 1 GROUP BY 1, 2' --region ${var.aws_region}" : "enable_analytics is false"
}
