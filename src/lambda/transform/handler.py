"""
Incremental Yellow Taxi transform: DuckDB reads one monthly Parquet from
raw/monthly/ and writes Hive partitions under processed/yellow_taxi/.
"""
from __future__ import annotations

import json
import os
import re
import urllib.parse
from typing import Any

import boto3
import duckdb

s3 = boto3.client("s3")

DATALAKE_BUCKET = os.environ["DATALAKE_BUCKET"]
AWS_REGION = os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "us-east-1")
PROCESSED_PREFIX = os.environ.get("PROCESSED_PREFIX", "processed/yellow_taxi/").strip("/")
FILENAME_RE = re.compile(r"yellow_tripdata_(\d{4})-(\d{2})\.parquet$", re.I)

CANONICAL = [
    ("vendorid", "BIGINT"),
    ("tpep_pickup_datetime", "TIMESTAMP"),
    ("tpep_dropoff_datetime", "TIMESTAMP"),
    ("passenger_count", "DOUBLE"),
    ("trip_distance", "DOUBLE"),
    ("ratecodeid", "DOUBLE"),
    ("store_and_fwd_flag", "VARCHAR"),
    ("pulocationid", "BIGINT"),
    ("dolocationid", "BIGINT"),
    ("payment_type", "BIGINT"),
    ("fare_amount", "DOUBLE"),
    ("extra", "DOUBLE"),
    ("mta_tax", "DOUBLE"),
    ("tip_amount", "DOUBLE"),
    ("tolls_amount", "DOUBLE"),
    ("improvement_surcharge", "DOUBLE"),
    ("total_amount", "DOUBLE"),
    ("congestion_surcharge", "DOUBLE"),
    ("airport_fee", "DOUBLE"),
]


def _sql_quote(value: str) -> str:
    return value.replace("'", "''")


def _connect() -> duckdb.DuckDBPyConnection:
    os.makedirs("/tmp/duckdb", exist_ok=True)
    con = duckdb.connect(database=":memory:")
    con.execute("SET home_directory='/tmp/duckdb';")
    con.execute("SET extension_directory='/tmp/duckdb/extensions';")
    con.execute("INSTALL httpfs;")
    con.execute("LOAD httpfs;")
    key = _sql_quote(os.environ["AWS_ACCESS_KEY_ID"])
    secret = _sql_quote(os.environ["AWS_SECRET_ACCESS_KEY"])
    token = _sql_quote(os.environ.get("AWS_SESSION_TOKEN", ""))
    region = _sql_quote(AWS_REGION)
    token_clause = f"SESSION_TOKEN '{token}'," if token else ""
    con.execute(
        f"""
        CREATE OR REPLACE SECRET lambda_s3 (
            TYPE S3,
            KEY_ID '{key}',
            SECRET '{secret}',
            {token_clause}
            REGION '{region}'
        );
        """
    )
    return con


def _source_from_event(event: dict[str, Any]) -> tuple[str, str]:
    if event.get("Records"):
        record = event["Records"][0]
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
        return bucket, key
    if event.get("bucket") and event.get("key"):
        return event["bucket"], event["key"]
    raise ValueError("Event is missing S3 Records or bucket/key")


def _year_month_from_key(key: str) -> tuple[str, str] | None:
    match = FILENAME_RE.search(key.rsplit("/", 1)[-1])
    if not match:
        return None
    return match.group(1), match.group(2)


def _delete_partition(year: str, month: str) -> int:
    prefix = f"{PROCESSED_PREFIX}/year={year}/month={month}/"
    deleted = 0
    token = None
    while True:
        kwargs: dict[str, Any] = {"Bucket": DATALAKE_BUCKET, "Prefix": prefix}
        if token:
            kwargs["ContinuationToken"] = token
        resp = s3.list_objects_v2(**kwargs)
        objects = [{"Key": obj["Key"]} for obj in resp.get("Contents", [])]
        if objects:
            s3.delete_objects(Bucket=DATALAKE_BUCKET, Delete={"Objects": objects})
            deleted += len(objects)
        if not resp.get("IsTruncated"):
            break
        token = resp.get("NextContinuationToken")
    return deleted


def _select_sql(con: duckdb.DuckDBPyConnection, source_uri: str) -> str:
    con.execute(f"CREATE OR REPLACE VIEW src AS SELECT * FROM read_parquet('{source_uri}')")
    described = con.execute("DESCRIBE src").fetchall()
    available = {row[0].lower(): row[0] for row in described}

    parts = []
    for name, duck_type in CANONICAL:
        src_col = available.get(name)
        if src_col:
            parts.append(f'CAST("{src_col}" AS {duck_type}) AS {name}')
        else:
            parts.append(f"CAST(NULL AS {duck_type}) AS {name}")
    inner = "SELECT " + ", ".join(parts) + " FROM src WHERE tpep_pickup_datetime IS NOT NULL"
    return f"""
        SELECT
            inner_src.*,
            printf('%04d', year(tpep_pickup_datetime)) AS year,
            lpad(CAST(month(tpep_pickup_datetime) AS VARCHAR), 2, '0') AS month
        FROM ({inner}) AS inner_src
    """


def transform(bucket: str, key: str) -> dict[str, Any]:
    source_uri = f"s3://{bucket}/{key}"
    target_uri = f"s3://{DATALAKE_BUCKET}/{PROCESSED_PREFIX}"
    parsed = _year_month_from_key(key)
    deleted = 0
    if parsed:
        deleted = _delete_partition(*parsed)

    con = _connect()
    try:
        select_sql = _select_sql(con, source_uri)
        copy_sql = f"""
            COPY ({select_sql})
            TO '{target_uri}'
            (FORMAT PARQUET, COMPRESSION SNAPPY, PARTITION_BY (year, month), OVERWRITE_OR_IGNORE);
        """
        con.execute(copy_sql)
        count = con.execute(f"SELECT count(*) FROM ({select_sql})").fetchone()[0]
    finally:
        con.close()

    return {
        "status": "success",
        "source": source_uri,
        "target": target_uri,
        "rows": int(count),
        "deleted_partition_objects": deleted,
        "year_month": None if parsed is None else f"{parsed[0]}-{parsed[1]}",
    }


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    print(json.dumps({"event_keys": list(event.keys())}))
    bucket, key = _source_from_event(event)
    if not key.lower().endswith(".parquet"):
        return {"status": "skipped", "reason": "not parquet", "key": key}
    result = transform(bucket, key)
    print(json.dumps(result))
    return result
