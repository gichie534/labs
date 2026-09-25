# The Kinesis data stream the producer writes user events into.
#
# One shard is far more than this lab needs (a shard absorbs 1,000 records/s; the producer sends a
# handful). Shard-level metrics are enabled because they are what you would actually watch in
# production: producer throttling and consumer lag.
#
# enforce_consumer_deletion is on so `task down` removes the stream even if a consumer is still
# registered.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/kinesis-stream?ref=aws-kinesis-stream-v0.1.0"
}

inputs = {
  name        = "user-events"
  shard_count = 1

  shard_level_metrics = [
    "WriteProvisionedThroughputExceeded",
    "IteratorAgeMilliseconds",
  ]

  enforce_consumer_deletion = true

  tags = {
    Environment = "lab"
  }
}
