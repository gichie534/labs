package main

import (
	"context"
	"flag"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/firehose"
)

// PathReport is what one ingestion path actually did, measured rather than assumed.
type PathReport struct {
	Name string

	// The first object this path landed in S3, and when S3 accepted it.
	ObjectKey    string
	ObjectCount  int
	LandedAt     time.Time
	LatestEvent  time.Time
	DeliveryLag  time.Duration
	RowsInTable  int64
	TableName    string
	RecordsInObj int
}

// measurePath reads back the objects a path produced and computes the gap between the newest event
// inside the first object and the moment S3 accepted that object.
//
// This is the honest definition of ingestion latency for a path that lands in S3: how long after an
// event happened was it durable and readable. Nothing here is estimated — the event time comes from
// inside the payload and the landing time from S3's own metadata.
func measurePath(ctx context.Context, lake *Lake, name, prefix, table string, parse func([]byte) ([]Event, error)) (PathReport, error) {
	report := PathReport{Name: name, TableName: table}

	objects, err := lake.List(ctx, prefix)
	if err != nil {
		return report, err
	}
	if len(objects) == 0 {
		return report, fmt.Errorf("%s path: no objects under %s", name, prefix)
	}
	report.ObjectCount = len(objects)

	first := objects[0]
	report.ObjectKey = aws.ToString(first.Key)
	report.LandedAt = aws.ToTime(first.LastModified)

	body, err := lake.Get(ctx, report.ObjectKey)
	if err != nil {
		return report, err
	}

	events, err := parse(body)
	if err != nil {
		return report, fmt.Errorf("%s path: parse %s: %w", name, report.ObjectKey, err)
	}
	report.RecordsInObj = len(events)

	latest, ok := MaxEventTime(events)
	if !ok {
		return report, fmt.Errorf("%s path: %s contained no events", name, report.ObjectKey)
	}
	report.LatestEvent = latest
	report.DeliveryLag = report.LandedAt.Sub(latest)

	return report, nil
}

// bufferingInterval reads the delivery stream's configured buffer interval straight from AWS rather
// than trusting a number copied out of the Terragrunt unit.
func bufferingInterval(ctx context.Context, cfg aws.Config, deliveryStream string) (time.Duration, error) {
	client := firehose.NewFromConfig(cfg)

	out, err := client.DescribeDeliveryStream(ctx, &firehose.DescribeDeliveryStreamInput{
		DeliveryStreamName: aws.String(deliveryStream),
	})
	if err != nil {
		return 0, fmt.Errorf("describe delivery stream %s: %w", deliveryStream, err)
	}

	for _, dest := range out.DeliveryStreamDescription.Destinations {
		if dest.ExtendedS3DestinationDescription != nil &&
			dest.ExtendedS3DestinationDescription.BufferingHints != nil {
			seconds := aws.ToInt32(dest.ExtendedS3DestinationDescription.BufferingHints.IntervalInSeconds)
			return time.Duration(seconds) * time.Second, nil
		}
	}
	return 0, fmt.Errorf("delivery stream %s has no extended S3 buffering hints", deliveryStream)
}

// cmdVerify is the lab's assertion step and its conclusion in one.
//
// It proves both paths actually delivered — rows in S3 and rows in Redshift, no silent Firehose
// failures — and then reports the measured staleness of each, which is the comparison the lab exists to
// make. It fails loudly rather than printing something ambiguous, so it is usable as a test.
func cmdVerify(ctx context.Context, cfg Config, awsCfg aws.Config, args []string) error {
	fs := flag.NewFlagSet("verify", flag.ExitOnError)
	if err := fs.Parse(args); err != nil {
		return err
	}

	lake := NewLake(awsCfg, cfg.DataBucket)
	warehouse := NewWarehouse(awsCfg, cfg.Workgroup, cfg.Database)

	// --- gather ------------------------------------------------------------------------------------
	batch, err := measurePath(ctx, lake, "batch", cfg.BatchPrefix, cfg.BatchTable, ParseCSV)
	if err != nil {
		return fmt.Errorf("%w\nhint: run `task upload` first", err)
	}

	stream, err := measurePath(ctx, lake, "stream", cfg.StreamPrefix, cfg.StreamTable, ParseJSONLines)
	if err != nil {
		return fmt.Errorf("%w\nhint: run `task produce`, then wait for the Firehose buffer to flush", err)
	}

	for _, report := range []*PathReport{&batch, &stream} {
		stats, err := warehouse.Stats(ctx, report.TableName)
		if err != nil {
			return fmt.Errorf("%w\nhint: run `task load` first", err)
		}
		report.RowsInTable = stats.RowCount
	}

	// Firehose writes what it could not deliver under errors/. Anything there means the stream path
	// partially failed, which would otherwise look identical to it simply being slow.
	failed, err := lake.List(ctx, "errors/")
	if err != nil {
		return err
	}

	bufferInterval, err := bufferingInterval(ctx, awsCfg, cfg.DeliveryName)
	if err != nil {
		return err
	}

	// --- report ------------------------------------------------------------------------------------
	fmt.Println("== what each path delivered ==")
	printTable(
		[]string{"path", "objects in s3", "rows in redshift", "table"},
		[][]string{
			{batch.Name, fmt.Sprintf("%d", batch.ObjectCount), fmt.Sprintf("%d", batch.RowsInTable), batch.TableName},
			{stream.Name, fmt.Sprintf("%d", stream.ObjectCount), fmt.Sprintf("%d", stream.RowsInTable), stream.TableName},
		},
	)

	fmt.Println("\n== how stale each path was on arrival ==")
	fmt.Println("(newest event inside the first object, versus when S3 accepted that object)")
	printTable(
		[]string{"path", "newest event", "landed in s3", "delivery lag"},
		[][]string{
			{
				batch.Name,
				batch.LatestEvent.Format(time.RFC3339),
				batch.LandedAt.UTC().Format(time.RFC3339),
				batch.DeliveryLag.Round(time.Second).String(),
			},
			{
				stream.Name,
				stream.LatestEvent.Format(time.RFC3339),
				stream.LandedAt.UTC().Format(time.RFC3339),
				stream.DeliveryLag.Round(time.Second).String(),
			},
		},
	)

	difference := stream.DeliveryLag - batch.DeliveryLag
	fmt.Printf("\nThe streaming path was %s staler than the batch path on arrival.\n",
		difference.Round(time.Second))
	fmt.Printf("Firehose is configured to buffer for %s, which is where that time goes.\n", bufferInterval)

	// --- assert ------------------------------------------------------------------------------------
	var failures []string

	if batch.RowsInTable == 0 {
		failures = append(failures, fmt.Sprintf("%s is empty — the batch COPY loaded nothing", batch.TableName))
	}
	if stream.RowsInTable == 0 {
		failures = append(failures, fmt.Sprintf("%s is empty — the stream COPY loaded nothing", stream.TableName))
	}
	if len(failed) > 0 {
		failures = append(failures, fmt.Sprintf("%d object(s) under errors/ — Firehose failed to deliver some records", len(failed)))
	}
	if stream.DeliveryLag <= batch.DeliveryLag {
		// If this ever fires, the measurement is wrong rather than the infrastructure: a buffered path
		// cannot be fresher than a direct write.
		failures = append(failures, fmt.Sprintf(
			"streaming lag (%s) is not greater than batch lag (%s) — expected the buffer to make it slower",
			stream.DeliveryLag.Round(time.Second), batch.DeliveryLag.Round(time.Second)))
	}

	fmt.Println("\n== assertions ==")
	if len(failures) > 0 {
		for _, f := range failures {
			fmt.Printf("  FAIL: %s\n", f)
		}
		return fmt.Errorf("%d assertion(s) failed", len(failures))
	}

	fmt.Printf("  PASS: both paths delivered (%d batch rows, %d stream rows), no delivery failures.\n",
		batch.RowsInTable, stream.RowsInTable)
	fmt.Printf("  PASS: the batch path was fresher on arrival, by %s.\n", difference.Round(time.Second))
	return nil
}
