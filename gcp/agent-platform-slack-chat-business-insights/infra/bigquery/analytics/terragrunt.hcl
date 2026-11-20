# The analytics warehouse the agent queries through the BigQuery remote MCP server: web events, order items and
# products copied from bigquery-public-data.thelook_ecommerce by `task seed`. The agent gets dataViewer on this
# dataset only (iam/agent unit).
include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "${include.root.locals.catalog_git}/bigquery-dataset?ref=gcp-bigquery-dataset-v0.1.0"
}

dependencies {
  paths = ["../../project/apis"]
}

inputs = {
  project_id    = include.root.locals.project_id
  dataset_id    = include.root.locals.names.analytics_dataset
  location      = include.root.locals.bq_location
  friendly_name = "Business insights - analytics"
  description   = "TheLook e-commerce events, order items and products (snapshot). Read by the business-insights agent."

  delete_contents_on_destroy = true
  labels                     = include.root.locals.labels
}
