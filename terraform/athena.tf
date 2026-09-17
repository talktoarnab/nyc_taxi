resource "aws_glue_catalog_database" "nyc_taxi" {
  count       = var.enable_analytics ? 1 : 0
  name        = "nyc_taxi"
  description = "NYC Yellow Taxi lakehouse catalog (Athena partition projection)."
}

resource "aws_athena_workgroup" "nyc_taxi" {
  count         = var.enable_analytics ? 1 : 0
  name          = local.name_prefix
  description   = "Workgroup for NYC Yellow Taxi lakehouse queries."
  force_destroy = true

  configuration {
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true
    bytes_scanned_cutoff_per_query     = var.athena_bytes_scanned_cutoff == 0 ? null : var.athena_bytes_scanned_cutoff

    result_configuration {
      output_location = "s3://${aws_s3_bucket.datalake.id}/${local.athena_results}"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }
}

resource "aws_glue_catalog_table" "yellow_taxi_trips" {
  count         = var.enable_analytics ? 1 : 0
  name          = "yellow_taxi_trips"
  database_name = aws_glue_catalog_database.nyc_taxi[0].name
  table_type    = "EXTERNAL_TABLE"
  description   = "Hive-partitioned Yellow Taxi trips with Athena partition projection."

  parameters = {
    EXTERNAL                    = "TRUE"
    classification              = "parquet"
    "projection.enabled"        = "true"
    "projection.year.type"      = "integer"
    "projection.year.range"     = local.projection_year_range
    "projection.month.type"     = "integer"
    "projection.month.range"    = "1,12"
    "projection.month.digits"   = "2"
    "storage.location.template" = "s3://${aws_s3_bucket.datalake.id}/${local.processed}year=$${year}/month=$${month}/"
  }

  partition_keys {
    name = "year"
    type = "string"
  }

  partition_keys {
    name = "month"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.datalake.id}/${local.processed}"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      name                  = "parquet"
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters = {
        "serialization.format" = "1"
      }
    }

    columns {
      name = "vendorid"
      type = "bigint"
    }
    columns {
      name = "tpep_pickup_datetime"
      type = "timestamp"
    }
    columns {
      name = "tpep_dropoff_datetime"
      type = "timestamp"
    }
    columns {
      name = "passenger_count"
      type = "double"
    }
    columns {
      name = "trip_distance"
      type = "double"
    }
    columns {
      name = "ratecodeid"
      type = "double"
    }
    columns {
      name = "store_and_fwd_flag"
      type = "string"
    }
    columns {
      name = "pulocationid"
      type = "bigint"
    }
    columns {
      name = "dolocationid"
      type = "bigint"
    }
    columns {
      name = "payment_type"
      type = "bigint"
    }
    columns {
      name = "fare_amount"
      type = "double"
    }
    columns {
      name = "extra"
      type = "double"
    }
    columns {
      name = "mta_tax"
      type = "double"
    }
    columns {
      name = "tip_amount"
      type = "double"
    }
    columns {
      name = "tolls_amount"
      type = "double"
    }
    columns {
      name = "improvement_surcharge"
      type = "double"
    }
    columns {
      name = "total_amount"
      type = "double"
    }
    columns {
      name = "congestion_surcharge"
      type = "double"
    }
    columns {
      name = "airport_fee"
      type = "double"
    }
  }
}
