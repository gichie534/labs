# Firehose: the managed bridge from the Kinesis stream to S3. This unit is where the streaming path's
# latency actually comes from.
#
# buffering_interval_seconds = 60 is the LOWEST value Firehose accepts, and buffering_size_mb = 1 the
# lowest size. On a stream this quiet the size threshold is never reached, so the 60s interval is the
# floor on how fresh streamed data can be — the number the whole lab is built to measure. Raising it
# raises the measured lag; that is the intended experiment.
#
# Delivered objects go under `stream/` and undelivered ones under `errors/` so the Redshift COPY that
# loads the streaming path cannot accidentally read either the batch upload or a failed record.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/kinesis-firehose?ref=aws-kinesis-firehose-v0.1.0"
}

dependency "stream" {
  config_path = "../stream"

  mock_outputs = {
    arn = "arn:aws:kinesis:us-east-1:000000000000:stream/mock"
  }
}

dependency "data_lake" {
  config_path = "../data-lake"

  mock_outputs = {
    arn = "arn:aws:s3:::mock-bucket"
  }
}

inputs = {
  name                      = "user-events-to-s3"
  source_kinesis_stream_arn = dependency.stream.outputs.arn
  destination_bucket_arn    = dependency.data_lake.outputs.arn

  prefix              = "stream/"
  error_output_prefix = "errors/"

  # The latency floor for the streaming path. 60s is Firehose's minimum.
  buffering_interval_seconds = 60
  buffering_size_mb          = 1

  # Uncompressed so the delivered objects stay directly readable — `task verify` opens them to read
  # the event timestamps inside, and a human can inspect them with `aws s3 cp ... -`.
  compression_format = "UNCOMPRESSED"

  tags = {
    Environment = "lab"
  }
}
