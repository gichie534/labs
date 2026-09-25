// Command ingest drives both ingestion paths in the aws/streaming-vs-batch-ingestion lab.
//
// One binary with subcommands rather than a script per step: all six steps share the same
// configuration, the same AWS clients, and the same event definition, and splitting them into separate
// programs would mean duplicating all three.
//
//	ingest upload    batch path  — write a CSV straight to S3 with one PutObject
//	ingest produce   stream path — put events on the Kinesis stream
//	ingest consume   read records back off the shards directly (no Firehose involved)
//	ingest load      COPY both paths from S3 into their Redshift tables
//	ingest query     SELECT the first rows of each table
//	ingest verify    assert both paths landed, and measure how stale each one was
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func run(args []string) error {
	if len(args) == 0 {
		usage()
		return errors.New("no subcommand given")
	}

	command := args[0]
	if command == "help" || command == "-h" || command == "--help" {
		usage()
		return nil
	}

	// Ctrl-C should stop a long `produce` or a Data API poll cleanly rather than leaving the terminal
	// mid-statement.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, err := LoadConfig()
	if err != nil {
		return err
	}

	awsCfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(cfg.Region))
	if err != nil {
		return fmt.Errorf("load aws config: %w", err)
	}

	switch command {
	case "upload":
		return cmdUpload(ctx, cfg, awsCfg, args[1:])
	case "produce":
		return cmdProduce(ctx, cfg, awsCfg, args[1:])
	case "consume":
		return cmdConsume(ctx, cfg, awsCfg, args[1:])
	case "load":
		return cmdLoad(ctx, cfg, awsCfg, args[1:])
	case "query":
		return cmdQuery(ctx, cfg, awsCfg, args[1:])
	case "verify":
		return cmdVerify(ctx, cfg, awsCfg, args[1:])
	case "views":
		return cmdViews(ctx, cfg, awsCfg, args[1:])
	default:
		usage()
		return fmt.Errorf("unknown subcommand %q", command)
	}
}

func usage() {
	fmt.Fprint(os.Stderr, `ingest — drive the batch and streaming ingestion paths

Usage:
  ingest <command> [flags]

Commands:
  upload    Generate a CSV and PutObject it to the batch/ prefix (the batch path)
  produce   Put events on the Kinesis stream (the streaming path)
  consume   Read records back off the shards with a raw shard iterator
  load      COPY both prefixes from S3 into their Redshift tables
  query     SELECT the first rows of each table
  verify    Assert both paths landed and report how stale each was
  views     Create analytics views in Redshift for Query Editor v2 inspection

Configuration comes from the environment (Task loads the lab's .env):
  AWS_REGION             region everything lives in           (default us-east-1)
  DATA_BUCKET            bucket both paths land in            (required)
  STREAM_NAME            Kinesis data stream                  (default user-events)
  DELIVERY_STREAM_NAME   Firehose delivery stream             (default user-events-to-s3)
  REDSHIFT_WORKGROUP     Redshift Serverless workgroup        (default events-warehouse)
  REDSHIFT_DATABASE      database in the namespace            (default labdb)
`)
}

// printTable writes aligned columns to stdout.
func printTable(columns []string, rows [][]string) {
	w := tabwriter.NewWriter(os.Stdout, 0, 0, 3, ' ', 0)
	defer w.Flush()

	fmt.Fprintln(w, strings.Join(columns, "\t"))

	separators := make([]string, len(columns))
	for i, c := range columns {
		separators[i] = strings.Repeat("-", len(c))
	}
	fmt.Fprintln(w, strings.Join(separators, "\t"))

	for _, row := range rows {
		fmt.Fprintln(w, strings.Join(row, "\t"))
	}
}
