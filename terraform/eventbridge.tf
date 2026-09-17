resource "aws_cloudwatch_event_rule" "monthly_ingest" {
  provider            = aws.notags
  count               = var.enable_monthly_schedule ? 1 : 0
  name                = "${local.name_prefix}-monthly-ingest"
  description         = "Ingest the previous calendar month of TLC Yellow Taxi data on the 15th."
  schedule_expression = "cron(0 12 15 * ? *)"
}

resource "aws_cloudwatch_event_target" "monthly_ingest" {
  provider  = aws.notags
  count     = var.enable_monthly_schedule ? 1 : 0
  rule      = aws_cloudwatch_event_rule.monthly_ingest[0].name
  target_id = "ingest-lambda"
  arn       = aws_lambda_function.ingest.arn
}

resource "aws_lambda_permission" "allow_eventbridge_ingest" {
  count         = var.enable_monthly_schedule ? 1 : 0
  statement_id  = "AllowEventBridgeInvokeIngest"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.ingest.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.monthly_ingest[0].arn
}
