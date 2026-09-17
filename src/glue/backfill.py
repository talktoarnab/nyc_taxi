"""
NYC Yellow Taxi historical backfill — AWS Glue PySpark (G.1X).

Optional HTTP ingest copies TLC monthly Parquet from CloudFront into the
datalake raw/historical/ prefix, then Spark reads with mergeSchema, normalizes
a decade of evolving columns, and writes Hive-partitioned Parquet
(year=YYYY/month=MM/) for Athena partition projection.
"""
from __future__ import annotations

import sys
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql import types as T

args = getResolvedOptions(
    sys.argv,
    [
        "JOB_NAME",
        "DATALAKE_BUCKET",
        "SOURCE_PATH",
        "START_YEAR",
        "END_YEAR",
        "ENABLE_HTTP_INGEST",
        "TLC_HTTP_BASE",
    ],
)

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

spark.conf.set("spark.sql.sources.partitionOverwriteMode", "dynamic")
spark.conf.set("spark.sql.parquet.mergeSchema", "true")
spark.conf.set("spark.sql.files.ignoreCorruptFiles", "true")
spark.conf.set("fs.s3a.requester.pays.enabled", "true")

DATALAKE_BUCKET = args["DATALAKE_BUCKET"]
SOURCE_PATH = args["SOURCE_PATH"].rstrip("/") + "/"
START_YEAR = int(args["START_YEAR"])
END_YEAR = int(args["END_YEAR"])
ENABLE_HTTP_INGEST = args["ENABLE_HTTP_INGEST"].lower() == "true"
TLC_HTTP_BASE = args["TLC_HTTP_BASE"].rstrip("/")

RAW_PREFIX = "raw/historical/"
PROCESSED_URI = f"s3://{DATALAKE_BUCKET}/processed/yellow_taxi/"
RAW_URI = f"s3://{DATALAKE_BUCKET}/{RAW_PREFIX}"

CANONICAL_FIELDS = [
    ("vendorid", T.LongType()),
    ("tpep_pickup_datetime", T.TimestampType()),
    ("tpep_dropoff_datetime", T.TimestampType()),
    ("passenger_count", T.DoubleType()),
    ("trip_distance", T.DoubleType()),
    ("ratecodeid", T.DoubleType()),
    ("store_and_fwd_flag", T.StringType()),
    ("pulocationid", T.LongType()),
    ("dolocationid", T.LongType()),
    ("payment_type", T.LongType()),
    ("fare_amount", T.DoubleType()),
    ("extra", T.DoubleType()),
    ("mta_tax", T.DoubleType()),
    ("tip_amount", T.DoubleType()),
    ("tolls_amount", T.DoubleType()),
    ("improvement_surcharge", T.DoubleType()),
    ("total_amount", T.DoubleType()),
    ("congestion_surcharge", T.DoubleType()),
    ("airport_fee", T.DoubleType()),
]


def month_keys(start_year: int, end_year: int):
    for year in range(start_year, end_year + 1):
        for month in range(1, 13):
            yield year, month


def tlc_filename(year: int, month: int) -> str:
    return f"yellow_tripdata_{year:04d}-{month:02d}.parquet"


def ingest_http_to_raw() -> int:
    """Stream TLC CloudFront objects into s3://bucket/raw/historical/."""
    s3 = boto3.client("s3")
    copied = 0
    skipped = 0
    failed = []

    def copy_one(year: int, month: int) -> str:
        name = tlc_filename(year, month)
        url = f"{TLC_HTTP_BASE}/{name}"
        key = f"{RAW_PREFIX}{name}"
        req = urllib.request.Request(url, method="GET")
        try:
            with urllib.request.urlopen(req, timeout=300) as resp:
                s3.upload_fileobj(resp, DATALAKE_BUCKET, key)
            return "ok"
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                return "missing"
            raise

    pairs = list(month_keys(START_YEAR, END_YEAR))
    print(f"HTTP ingest of {len(pairs)} monthly files → s3://{DATALAKE_BUCKET}/{RAW_PREFIX}")

    with ThreadPoolExecutor(max_workers=8) as pool:
        futures = {pool.submit(copy_one, y, m): (y, m) for y, m in pairs}
        for fut in as_completed(futures):
            year, month = futures[fut]
            name = tlc_filename(year, month)
            try:
                status = fut.result()
            except Exception as exc:  # noqa: BLE001 — log and continue the decade
                failed.append((name, str(exc)))
                print(f"FAILED {name}: {exc}")
                continue
            if status == "ok":
                copied += 1
                print(f"COPIED {name}")
            else:
                skipped += 1
                print(f"SKIP   {name} (not published)")

    print(f"Ingest complete: copied={copied} missing={skipped} failed={len(failed)}")
    if copied == 0:
        raise RuntimeError("HTTP ingest copied 0 files; check year range and TLC URL")
    return copied


def canonicalize(df: DataFrame) -> DataFrame:
    """Lower-case, coalesce duplicate names, cast to the Athena schema."""
    grouped = {}
    for col in df.columns:
        grouped.setdefault(col.lower(), []).append(col)

    exprs = []
    for name, dtype in CANONICAL_FIELDS:
        matches = grouped.get(name, [])
        if not matches:
            exprs.append(F.lit(None).cast(dtype).alias(name))
            continue
        col_expr = F.col(matches[0])
        for extra in matches[1:]:
            col_expr = F.coalesce(col_expr, F.col(extra))
        exprs.append(col_expr.cast(dtype).alias(name))
    return df.select(*exprs)


def s3_file_exists(path: str) -> bool:
    """Check if an S3 file exists."""
    s3 = boto3.client("s3")
    if not path.startswith("s3://"):
        return False
    parts = path[5:].split("/", 1)
    bucket = parts[0]
    key = parts[1] if len(parts) > 1 else ""
    try:
        s3.head_object(Bucket=bucket, Key=key)
        return True
    except Exception:
        return False


def delete_processed_data():
    """Delete all objects under the processed prefix in S3 to ensure a clean backfill."""
    s3 = boto3.client("s3")
    prefix = "processed/yellow_taxi/"
    print(f"Deleting existing processed data under s3://{DATALAKE_BUCKET}/{prefix}...")
    
    paginator = s3.get_paginator("list_objects_v2")
    pages = paginator.paginate(Bucket=DATALAKE_BUCKET, Prefix=prefix)
    
    delete_batch = []
    for page in pages:
        for obj in page.get("Contents", []):
            delete_batch.append({"Key": obj["Key"]})
            if len(delete_batch) == 1000:
                s3.delete_objects(Bucket=DATALAKE_BUCKET, Delete={"Objects": delete_batch})
                delete_batch = []
                
    if delete_batch:
        s3.delete_objects(Bucket=DATALAKE_BUCKET, Delete={"Objects": delete_batch})
    print("Processed data deletion complete.")


if ENABLE_HTTP_INGEST:
    ingest_http_to_raw()

delete_processed_data()

pairs = list(month_keys(START_YEAR, END_YEAR))
print(f"Processing {len(pairs)} months from {START_YEAR} to {END_YEAR}...")

for year, month in pairs:
    name = tlc_filename(year, month)
    if ENABLE_HTTP_INGEST:
        path = f"s3://{DATALAKE_BUCKET}/{RAW_PREFIX}{name}"
    else:
        path = f"{SOURCE_PATH}{name}"

    if not s3_file_exists(path):
        print(f"File does not exist, skipping: {path}")
        continue

    print(f"Processing {name} from {path}...")
    try:
        df = spark.read.parquet(path)
        df_canon = canonicalize(df).filter(F.col("tpep_pickup_datetime").isNotNull())
        
        df_partitioned = (
            df_canon.withColumn("year", F.lpad(F.year("tpep_pickup_datetime").cast("string"), 4, "0"))
            .withColumn("month", F.lpad(F.month("tpep_pickup_datetime").cast("string"), 2, "0"))
            .filter(
                (F.col("year").cast("int") == year) & (F.col("month").cast("int") == month)
            )
        )
        
        (
            df_partitioned.write.mode("append")
            .option("compression", "snappy")
            .partitionBy("year", "month")
            .parquet(PROCESSED_URI)
        )
        print(f"SUCCESS: Processed and wrote {name}")
    except Exception as exc:
        print(f"ERROR processing {name}: {exc}")

job.commit()
print("Backfill job committed")
