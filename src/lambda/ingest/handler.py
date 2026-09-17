"""
Monthly TLC ingest: copy one or more Yellow Taxi Parquet files from CloudFront into
s3://<datalake>/raw/monthly/. An S3 ObjectCreated event then starts the
DuckDB transform Lambda.
"""
from __future__ import annotations

import json
import os
import re
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


def next_month(year: int, month: int) -> tuple[int, int]:
    if month == 12:
        return year + 1, 1
    return year, month + 1


def get_latest_processed_month() -> tuple[int, int] | None:
    """List S3 to find the latest year and month in processed/yellow_taxi/."""
    prefix = "processed/yellow_taxi/"
    print(f"Checking latest processed partition under s3://{DATALAKE_BUCKET}/{prefix}...")
    
    # List with delimiter to find year=YYYY/ prefixes
    result = s3.list_objects_v2(Bucket=DATALAKE_BUCKET, Prefix=prefix, Delimiter="/")
    years = []
    for common_prefix in result.get("CommonPrefixes", []):
        folder = common_prefix["Prefix"].rstrip("/")
        match = re.search(r"year=(\d{4})", folder)
        if match:
            years.append(int(match.group(1)))
    
    if not years:
        return None
        
    latest_year = max(years)
    
    # List months for that latest year
    month_prefix = f"{prefix}year={latest_year}/"
    result_months = s3.list_objects_v2(Bucket=DATALAKE_BUCKET, Prefix=month_prefix, Delimiter="/")
    months = []
    for common_prefix in result_months.get("CommonPrefixes", []):
        folder = common_prefix["Prefix"].rstrip("/")
        match = re.search(r"month=(\d{2})", folder)
        if match:
            months.append(int(match.group(1)))
            
    if not months:
        return latest_year, 1
        
    latest_month = max(months)
    return latest_year, latest_month


def check_url_exists(url: str) -> bool:
    """Perform a HEAD request to check if a file exists on the source URL."""
    req = urllib.request.Request(url, method="HEAD")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            return resp.status == 200
    except urllib.error.HTTPError as exc:
        if exc.code == 404:
            return False
        print(f"HTTP error checking {url}: {exc.code} {exc.reason}")
        return False
    except Exception as exc:
        print(f"Error checking {url}: {exc}")
        return False


def find_delta_months() -> list[tuple[int, int]]:
    """Determine which months are missing in the datalake compared to the source."""
    latest = get_latest_processed_month()
    if latest is None:
        # No processed data found; default to starting from previous month as a safe default
        start_year, start_month = previous_month()
        print(f"No processed data found. Defaulting to previous month: {start_year:04d}-{start_month:02d}")
    else:
        # Start checking from the month after the latest processed
        start_year, start_month = next_month(*latest)
        print(f"Latest processed month is {latest[0]:04d}-{latest[1]:02d}. Starting delta check from {start_year:04d}-{start_month:02d}...")

    delta_months = []
    curr_year, curr_month = start_year, start_month
    
    # Safety guard: don't check beyond the current calendar month
    today = date.today()
    
    while (curr_year < today.year) or (curr_year == today.year and curr_month <= today.month):
        filename = f"yellow_tripdata_{curr_year:04d}-{curr_month:02d}.parquet"
        url = f"{TLC_HTTP_BASE}/{filename}"
        
        if check_url_exists(url):
            print(f"Found new source file: {filename}")
            delta_months.append((curr_year, curr_month))
        else:
            print(f"Source file not available yet: {filename}. Stopping delta search.")
            break
            
        curr_year, curr_month = next_month(curr_year, curr_month)
        
    return delta_months


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
    
    # Support manual override if year and month are explicitly requested
    if event.get("year") and event.get("month"):
        year, month = int(event["year"]), int(event["month"])
        print(f"Manual override requested for month: {year:04d}-{month:02d}")
        result = copy_month(year, month)
        print(json.dumps(result))
        return {"status": "success", "results": [result]}
        
    # Otherwise, perform self-healing delta ingestion
    delta_months = find_delta_months()
    if not delta_months:
        print("Datalake is fully up to date. No delta months found to ingest.")
        return {"status": "up_to_date", "results": []}
        
    print(f"Ingesting {len(delta_months)} delta months: {delta_months}")
    results = []
    for year, month in delta_months:
        print(f"Ingesting delta month: {year:04d}-{month:02d}...")
        res = copy_month(year, month)
        results.append(res)
        
    print(json.dumps(results))
    return {"status": "success", "results": results}
