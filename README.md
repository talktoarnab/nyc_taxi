# NYC Yellow Taxi serverless lakehouse

Terraform for a **private AWS account**: S3 data lake, Glue PySpark 10-year backfill, Lambda + DuckDB monthly increments, and Athena with partition projection.

This follows the hybrid compute model in the architectural guide:

| Flow | Compute | When |
| --- | --- | --- |
| Historical backfill | Glue **G.1X** (Flex) Spark | On demand — not started by `terraform apply` |
| Monthly increment | Lambda (ARM, 4 GB) + **DuckDB** | EventBridge on the 15th, or S3 `Put` into `raw/monthly/` |

## Lake layout

Bucket name: `nyc-taxi-datalake-<account-id>`

```text
raw/historical/     Glue HTTP ingest (decade of TLC Parquet)
raw/monthly/        One file per month; S3 event → DuckDB Lambda
processed/yellow_taxi/year=YYYY/month=MM/
scripts/glue/backfill.py
athena-results/     Workgroup output (7-day expiry)
```

Source files are the public TLC Yellow Taxi monthly Parquet objects:

`https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_YYYY-MM.parquet`

## Prerequisites

- Terraform >= 1.5
- AWS credentials that can create S3, IAM roles, Glue, Lambda, Athena, EventBridge, and CloudWatch Logs
- Python 3 + pip (to package the DuckDB Lambda for Amazon Linux 2023 ARM)

This stack defaults to **us-east-1** (TLC + the guide). Pass another region in `terraform.tfvars` if you want the lake elsewhere.

## IAM on the deploying user

`terraform apply` needs more than S3 + Lambda. If the CLI user is `lamba-cli-access`-style (Lambda/S3/IAM only), attach these AWS managed policies first, then set `enable_analytics = true` and re-apply:

```bash
aws iam attach-user-policy --user-name lamba-cli-access --policy-arn arn:aws:iam::aws:policy/AWSGlueConsoleFullAccess
aws iam attach-user-policy --user-name lamba-cli-access --policy-arn arn:aws:iam::aws:policy/AmazonAthenaFullAccess
aws iam attach-user-policy --user-name lamba-cli-access --policy-arn arn:aws:iam::aws:policy/AmazonEventBridgeFullAccess
aws iam attach-user-policy --user-name lamba-cli-access --policy-arn arn:aws:iam::aws:policy/CloudWatchLogsFullAccess
```

Without Glue/Athena, keep `enable_analytics = false`. The lake, IAM roles, and DuckDB Lambdas still deploy. The Glue job and `yellow_taxi_trips` table are skipped until you flip the flag.

This account's Lambda memory quota is **3008 MB** (set in `terraform.tfvars`). EventBridge `events:PutRule` is also missing on `lamba-cli-access`, so `enable_monthly_schedule` is false until `AmazonEventBridgeFullAccess` is attached. Monthly loads still work by invoking `nyc-taxi-ingest` directly.

## Deploy

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # edit if needed
cd ..
make plan
make apply
```

`make apply` packages DuckDB for `linux/arm64` then applies. Glue is **created but not started**.

## Load data

### Smoke test (one month, DuckDB)

```bash
aws lambda invoke \
  --function-name nyc-taxi-ingest \
  --cli-binary-format raw-in-base64-out \
  --payload '{"year":2024,"month":1}' \
  --region us-east-1 \
  /tmp/nyc-taxi-ingest.json
```

That writes `raw/monthly/yellow_tripdata_2024-01.parquet` and the bucket notification runs `nyc-taxi-transform`.

### Historical backfill (Glue)

Default years are **2014–2026**. First run can take well over an hour and will incur Glue DPU charges. For a cheap trial, change `backfill_start_year` / `backfill_end_year` to a single year, apply, then:

```bash
aws glue start-job-run --job-name nyc-taxi-historical-backfill --region us-east-1
```

The job copies TLC files into `raw/historical/` (when `enable_http_ingest = true`), merges schemas, casts a stable column set, and writes `processed/yellow_taxi/year=YYYY/month=MM/`.

## Query

Athena database `nyc_taxi`, table `yellow_taxi_trips`, workgroup `nyc-taxi`. Partition projection is enabled — no `MSCK REPAIR TABLE`. Always filter `year` / `month` so the engine does not expand the full grid.

See `sql/sample_queries.sql`.

## Cost notes

- S3 + Athena results lifecycle: cheap at rest; Athena has a 10 GB scan cap per query
- Glue Flex G.1X × 10 workers is the expensive step; run it once, then rely on Lambda
- Monthly Lambda + DuckDB is billed per millisecond and is the intended path for files of a few hundred MB

## Destroy

```bash
make destroy
```

Leave `force_destroy_bucket = false` (default) so Terraform will not delete a bucket that still has objects. Empty the prefixes first, or set the flag if you intend to wipe the lake.
