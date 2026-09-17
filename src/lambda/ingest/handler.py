"""
Monthly TLC ingest: copy one Yellow Taxi Parquet file from CloudFront into
s3://<datalake>/raw/monthly/. An S3 ObjectCreated event then starts the
DuckDB transform Lambda.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from datetime import date
from typing import Any

import boto3

s3 = boto3.client("s3")

DATALAKE_BUCKET = os.environ["DATALAKE_BUCKET"]
TLC_HTTP_BASE = os.environ.get(
    "TLC_HTTP_BASE", "https://d37ci6vzurychx.cloudfront.net/trip-data"
).rstrip("/")
RAW_PREFIX = os.environ.get("RAW_PREFIX", "raw/monthly/").strip("/") + "/"


def previous_month(today: date | None = None) -> tuple[int, int]:
    today = today or date.today()
    if today.month == 1:
        return today.year - 1, 12
    return today.year, today.month - 1


def resolve_year_month(event: dict[str, Any]) -> tuple[int, int]:
    if event.get("year") and event.get("month"):
        return int(event["year"]), int(event["month"])
    detail = event.get("detail") or {}
    if detail.get("year") and detail.get("month"):
        return int(detail["year"]), int(detail["month"])
    return previous_month()


def copy_month(year: int, month: int) -> dict[str, Any]:
    filename = f"yellow_tripdata_{year:04d}-{month:02d}.parquet"
    url = f"{TLC_HTTP_BASE}/{filename}"
    key = f"{RAW_PREFIX}{filename}"
    req = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=300) as resp:
            s3.upload_fileobj(resp, DATALAKE_BUCKET, key)
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return {
                "status": "not_published",
                "year": year,
                "month": month,
                "url": url,
            }
        raise
    return {
        "status": "ingested",
        "year": year,
        "month": month,
        "bucket": DATALAKE_BUCKET,
        "key": key,
        "uri": f"s3://{DATALAKE_BUCKET}/{key}",
    }


def lambda_handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    print(json.dumps({"event_keys": list(event.keys())}))
    year, month = resolve_year_month(event)
    result = copy_month(year, month)
    print(json.dumps(result))
    return result
