#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/lambda/transform"
BUILD="$ROOT/build/lambda_transform"

rm -rf "$BUILD"
mkdir -p "$BUILD"
cp "$SRC/handler.py" "$BUILD/handler.py"

python3 -m pip install \
  --disable-pip-version-check \
  --upgrade \
  -r "$SRC/requirements.txt" \
  -t "$BUILD" \
  --platform manylinux2014_aarch64 \
  --python-version 3.12 \
  --only-binary=:all:

# Runtime already provides boto3; keep the zip under the 50 MB upload limit.
rm -rf "$BUILD"/boto3* "$BUILD"/botocore* "$BUILD"/s3transfer* "$BUILD"/jmespath* \
  "$BUILD"/dateutil "$BUILD"/python_dateutil* "$BUILD"/urllib3* "$BUILD"/six* \
  "$BUILD"/bin "$BUILD"/*.dist-info
find "$BUILD" -type d -name '__pycache__' -exec rm -rf {} +
find "$BUILD" -type d -name 'tests' -exec rm -rf {} +

echo "Packaged DuckDB Lambda at $BUILD"
du -sh "$BUILD"
