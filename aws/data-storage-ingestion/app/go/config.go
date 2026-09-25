package main

import (
	"fmt"
	"os"
)

// Config is everything the CLI needs to talk to the lab's infrastructure.
//
// Only the region and the data bucket really vary between runs, so those are the only two the lab's
// .env has to set. The rest default to the names the Terragrunt units create, which keeps `.env`
// short and stops it drifting out of sync with infra/.
type Config struct {
	Region     string
	DataBucket string

	StreamName   string // Kinesis data stream (infra/stream)
	DeliveryName string // Firehose delivery stream (infra/delivery)

	Workgroup string // Redshift Serverless workgroup (infra/warehouse)
	Database  string // database inside the namespace

	BatchPrefix  string // where the batch path writes
	StreamPrefix string // where Firehose delivers

	BatchTable  string
	StreamTable string
}

// LoadConfig reads configuration from the environment. Task loads the lab's .env before invoking the
// binary, so these are already populated by the time we run.
func LoadConfig() (Config, error) {
	cfg := Config{
		Region:     env("AWS_REGION", "us-east-1"),
		DataBucket: os.Getenv("DATA_BUCKET"),

		StreamName:   env("STREAM_NAME", "user-events"),
		DeliveryName: env("DELIVERY_STREAM_NAME", "user-events-to-s3"),

		Workgroup: env("REDSHIFT_WORKGROUP", "events-warehouse"),
		Database:  env("REDSHIFT_DATABASE", "labdb"),

		BatchPrefix:  "batch/",
		StreamPrefix: "stream/",

		BatchTable:  "user_events_batch",
		StreamTable: "user_events_stream",
	}

	if cfg.DataBucket == "" {
		return Config{}, fmt.Errorf("DATA_BUCKET is not set — run `task init-env` and fill in .env")
	}

	return cfg, nil
}

func env(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
