package main

import (
	"context"
	"flag"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
)

// cmdUpload is the BATCH path in full: build a file, write it to S3 once, done.
//
// Note how little there is to it, and that the object is readable the instant PutObject returns. That
// immediacy is the batch path's advantage, and the reason it is still the right answer for a dataset
// you already have in hand.
func cmdUpload(ctx context.Context, cfg Config, awsCfg aws.Config, args []string) error {
	fs := flag.NewFlagSet("upload", flag.ExitOnError)
	count := fs.Int("count", 15, "number of events to generate")
	key := fs.String("key", "", "object key (default <batch prefix>sample_data.csv)")
	if err := fs.Parse(args); err != nil {
		return err
	}

	objectKey := *key
	if objectKey == "" {
		objectKey = cfg.BatchPrefix + "sample_data.csv"
	}

	events := GenerateEvents(*count)
	body, err := MarshalCSV(events)
	if err != nil {
		return err
	}

	lake := NewLake(awsCfg, cfg.DataBucket)
	elapsed, err := lake.Put(ctx, objectKey, body, "text/csv")
	if err != nil {
		return err
	}

	fmt.Printf("Uploaded %d events (%d bytes) to s3://%s/%s in %s\n",
		len(events), len(body), cfg.DataBucket, objectKey, elapsed.Round(time.Millisecond))
	fmt.Println("The object is durable and readable now — there is no buffer to wait on.")
	return nil
}

// cmdProduce is the STREAM path's producer: put events on the Kinesis stream one at a time.
//
// The records are on the stream immediately, but they are NOT in S3 yet. Firehose is buffering them and
// will not write an object until its interval elapses — which is the entire difference this lab exists
// to measure.
func cmdProduce(ctx context.Context, cfg Config, awsCfg aws.Config, args []string) error {
	fs := flag.NewFlagSet("produce", flag.ExitOnError)
	count := fs.Int("count", 15, "number of events to send")
	interval := fs.Duration("interval", 200*time.Millisecond, "delay between records")
	if err := fs.Parse(args); err != nil {
		return err
	}

	stream := NewStream(awsCfg, cfg.StreamName)
	if err := stream.WaitActive(ctx, 2*time.Minute); err != nil {
		return err
	}

	fmt.Printf("Sending %d events to the %s stream...\n", *count, cfg.StreamName)

	for i, e := range GenerateEvents(*count) {
		if err := stream.Put(ctx, e); err != nil {
			return err
		}
		fmt.Printf("  [%2d/%d] user_id=%d event=%-8s event_time=%s\n",
			i+1, *count, e.UserID, e.Event, e.EventTime.Format(time.RFC3339))

		if i < *count-1 {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(*interval):
			}
		}
	}

	bufferInterval, err := bufferingInterval(ctx, awsCfg, cfg.DeliveryName)
	if err != nil {
		// Not fatal: the records are on the stream regardless, and this is only used for the hint below.
		fmt.Printf("\nSent. (could not read the Firehose buffer interval: %v)\n", err)
		return nil
	}

	fmt.Printf("\nSent. These records are on the stream but NOT yet in S3.\n")
	fmt.Printf("Firehose buffers for %s before it writes an object — wait at least that long, then run `task load`.\n",
		bufferInterval)
	return nil
}

// cmdConsume reads records straight off the shards, with no Firehose in the picture.
//
// This is the low-level read that `aws kinesis get-shard-iterator` + `get-records` performs. Doing it
// once makes the shard model concrete: you hold a cursor and advance it, and because the iterator
// starts at TRIM_HORIZON you see records that were written before this consumer existed. That replay is
// what a queue cannot do, and it is what lets a second consumer be added later.
func cmdConsume(ctx context.Context, cfg Config, awsCfg aws.Config, args []string) error {
	fs := flag.NewFlagSet("consume", flag.ExitOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}

	stream := NewStream(awsCfg, cfg.StreamName)
	if err := stream.WaitActive(ctx, 2*time.Minute); err != nil {
		return err
	}

	fmt.Printf("Reading the %s stream from TRIM_HORIZON (the oldest record still retained)...\n\n",
		cfg.StreamName)

	records, err := stream.ReadAll(ctx)
	if err != nil {
		return err
	}
	if len(records) == 0 {
		return fmt.Errorf("no records on the stream — run `task produce` first (or the retention window has passed)")
	}

	rows := make([][]string, 0, len(records))
	for _, r := range records {
		rows = append(rows, []string{
			r.ShardID,
			r.ArrivalTime.Format(time.RFC3339),
			fmt.Sprintf("%d", r.Event.UserID),
			r.Event.Event,
			r.Event.EventTime.Format(time.RFC3339),
		})
	}
	printTable([]string{"shard", "arrived", "user_id", "event", "event_time"}, rows)

	fmt.Printf("\nRead %d record(s) directly off the shard(s). Firehose does exactly this, continuously.\n",
		len(records))
	return nil
}

// cmdLoad creates both tables and COPYs each path's objects into its own table.
//
// Two tables rather than one with a source column: keeping them separate means a COPY failure on one
// path cannot be mistaken for missing data on the other, and the row counts stay independently
// meaningful.
func cmdLoad(ctx context.Context, cfg Config, awsCfg aws.Config, args []string) error {
	fs := flag.NewFlagSet("load", flag.ExitOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}

	warehouse := NewWarehouse(awsCfg, cfg.Workgroup, cfg.Database)

	loads := []struct {
		label    string
		table    string
		prefix   string
		template string
	}{
		{"batch", cfg.BatchTable, cfg.BatchPrefix, "copy_batch.sql.tmpl"},
		{"stream", cfg.StreamTable, cfg.StreamPrefix, "copy_stream.sql.tmpl"},
	}

	for _, load := range loads {
		fmt.Printf("== %s path -> %s ==\n", load.label, load.table)

		fmt.Printf("  creating and truncating %s...\n", load.table)
		if err := warehouse.EnsureSchema(ctx, load.table); err != nil {
			return err
		}

		fmt.Printf("  COPY from s3://%s/%s ...\n", cfg.DataBucket, load.prefix)
		err := warehouse.Copy(ctx, load.template, sqlParams{
			Table:  load.table,
			Bucket: cfg.DataBucket,
			Prefix: load.prefix,
			Region: cfg.Region,
		})
		if err != nil {
			return err
		}

		stats, err := warehouse.Stats(ctx, load.table)
		if err != nil {
			return err
		}
		fmt.Printf("  loaded %d row(s)\n\n", stats.RowCount)
	}

	fmt.Println("Both paths loaded. Run `task verify` to compare them.")
	return nil
}

// cmdQuery is the schema-and-data sanity check on both tables.
func cmdQuery(ctx context.Context, cfg Config, awsCfg aws.Config, args []string) error {
	fs := flag.NewFlagSet("query", flag.ExitOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}

	warehouse := NewWarehouse(awsCfg, cfg.Workgroup, cfg.Database)

	for _, table := range []string{cfg.BatchTable, cfg.StreamTable} {
		fmt.Printf("== %s ==\n", table)
		result, err := warehouse.Sample(ctx, table)
		if err != nil {
			return err
		}
		if len(result.Rows) == 0 {
			fmt.Print("(no rows)\n\n")
			continue
		}
		printTable(result.Columns, result.Rows)
		fmt.Println()
	}

	return nil
}

// cmdViews creates analytics views in Redshift for inspection and visual charting in Query Editor v2.
func cmdViews(ctx context.Context, cfg Config, awsCfg aws.Config, args []string) error {
	fs := flag.NewFlagSet("views", flag.ExitOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}

	warehouse := NewWarehouse(awsCfg, cfg.Workgroup, cfg.Database)

	views := []struct {
		name     string
		desc     string
		template string
	}{
		{
			name:     "v_unified_events",
			desc:     "Combines batch and stream records into a single unified dataset",
			template: "view_unified_events.sql.tmpl",
		},
		{
			name:     "v_pipeline_event_summary",
			desc:     "Aggregates event counts by event type and pipeline (for Bar Charts)",
			template: "view_pipeline_event_summary.sql.tmpl",
		},
		{
			name:     "v_user_engagement_profile",
			desc:     "Aggregates logins, purchases, and logouts per user (for Donut/Bar Charts)",
			template: "view_user_engagement_profile.sql.tmpl",
		},
	}

	fmt.Println("Setting up analytics views in Redshift for Query Editor v2...")

	params := sqlParams{
		BatchTable:  cfg.BatchTable,
		StreamTable: cfg.StreamTable,
	}

	for _, v := range views {
		fmt.Printf("  creating %s (%s)...\n", v.name, v.desc)
		if err := warehouse.CreateView(ctx, v.template, params); err != nil {
			return fmt.Errorf("create %s: %w", v.name, err)
		}
	}

	if err := warehouse.GrantAccess(ctx); err != nil {
		return fmt.Errorf("grant view access: %w", err)
	}

	fmt.Println("\nAll views created successfully in Redshift schema 'public'!")
	fmt.Println("\nTo inspect and visualize them in AWS Redshift Query Editor v2:")
	fmt.Println("  1. In AWS Console, navigate to Amazon Redshift -> Query editor v2.")
	fmt.Println("  2. Connect to workgroup 'events-warehouse', database 'labdb'.")
	fmt.Println("  3. Expand: labdb -> public -> Views to see the new views.")
	fmt.Println("  4. Run a query such as:")
	fmt.Println("       SELECT * FROM v_pipeline_event_summary;")
	fmt.Println("  5. Toggle from 'Table' to 'Chart' (choose Bar chart, X: event, Y: event_count, Group: source_pipeline).")

	return nil
}
