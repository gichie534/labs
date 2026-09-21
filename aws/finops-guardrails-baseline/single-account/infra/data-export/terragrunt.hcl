# The line-item record — the only thing here that can answer "which resource?".
#
# Budgets and anomaly detection alert on aggregates: they tell you THAT spend moved. Neither can tell you
# which resource, tag or service moved it, and that is always the next question. CUR 2.0 at hourly
# granularity with resource IDs is the dataset that answers it, queryable with Athena straight out of the
# bucket.
#
# It is in the baseline for one reason: it is not retroactive. A budget turned on today works today; an
# export turned on today gives you data from today forward and nothing before. Of everything in this lab
# this is the only piece whose absence cannot be fixed later.
#
# Ongoing cost: the export service is free, you pay standard S3 rates for what it delivers (a few MB a
# month on a quiet account, which the export-bucket lifecycle rule then expires). Nothing appears for
# roughly 24 hours after apply — an empty bucket an hour later is expected, not broken.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/cost-data-export?ref=aws-cost-data-export-v0.2.0"
}

dependency "export_bucket" {
  config_path = "../export-bucket"

  mock_outputs = {
    bucket = "mock-finops-export-bucket"
  }
}

inputs = {
  export_name = "finops-baseline-cur2-hourly"

  s3_bucket = dependency.export_bucket.outputs.bucket
  s3_prefix = "cur2"

  # Matches the lab's single region. The Data Exports control plane is us-east-1 regardless; this is the
  # bucket's region.
  s3_region = "us-east-1"

  # Defaults from the module: CUR 2.0, hourly, resource IDs included, Parquet, overwrite in place.
  # Granularity you did not capture cannot be recovered later; an export that is too large is one
  # lifecycle rule away from being fine.

  tags = {
    Environment = "lab"
  }
}
