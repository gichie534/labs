package main

import (
	"bytes"
	"context"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	s3types "github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// Lake is the S3 bucket both ingestion paths land in.
type Lake struct {
	client *s3.Client
	bucket string
}

func NewLake(cfg aws.Config, bucket string) *Lake {
	return &Lake{client: s3.NewFromConfig(cfg), bucket: bucket}
}

// Put writes an object and returns how long the write took.
//
// The elapsed time is the point of the batch path: a direct PutObject is durable and readable the
// moment it returns, with no buffer to wait on.
func (l *Lake) Put(ctx context.Context, key string, body []byte, contentType string) (time.Duration, error) {
	start := time.Now()
	_, err := l.client.PutObject(ctx, &s3.PutObjectInput{
		Bucket:      aws.String(l.bucket),
		Key:         aws.String(key),
		Body:        bytes.NewReader(body),
		ContentType: aws.String(contentType),
	})
	if err != nil {
		return 0, fmt.Errorf("put s3://%s/%s: %w", l.bucket, key, err)
	}
	return time.Since(start), nil
}

// List returns every object under a prefix, oldest first.
func (l *Lake) List(ctx context.Context, prefix string) ([]s3types.Object, error) {
	var objects []s3types.Object

	paginator := s3.NewListObjectsV2Paginator(l.client, &s3.ListObjectsV2Input{
		Bucket: aws.String(l.bucket),
		Prefix: aws.String(prefix),
	})
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("list s3://%s/%s: %w", l.bucket, prefix, err)
		}
		objects = append(objects, page.Contents...)
	}

	sort.Slice(objects, func(i, j int) bool {
		return aws.ToTime(objects[i].LastModified).Before(aws.ToTime(objects[j].LastModified))
	})
	return objects, nil
}

// Get reads an object's bytes.
func (l *Lake) Get(ctx context.Context, key string) ([]byte, error) {
	out, err := l.client.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(l.bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return nil, fmt.Errorf("get s3://%s/%s: %w", l.bucket, key, err)
	}
	defer out.Body.Close()

	body, err := io.ReadAll(out.Body)
	if err != nil {
		return nil, fmt.Errorf("read s3://%s/%s: %w", l.bucket, key, err)
	}
	return body, nil
}

// ParseCSV reads back the batch path's own format, header row included.
func ParseCSV(data []byte) ([]Event, error) {
	reader := csv.NewReader(bytes.NewReader(data))
	rows, err := reader.ReadAll()
	if err != nil {
		return nil, fmt.Errorf("read csv: %w", err)
	}
	if len(rows) < 2 {
		return nil, fmt.Errorf("csv has no data rows")
	}

	events := make([]Event, 0, len(rows)-1)
	for i, row := range rows[1:] { // skip header
		if len(row) < 3 {
			return nil, fmt.Errorf("csv row %d has %d fields, want 3", i+2, len(row))
		}
		userID, err := strconv.Atoi(row[0])
		if err != nil {
			return nil, fmt.Errorf("csv row %d user_id: %w", i+2, err)
		}
		eventTime, err := time.Parse(time.RFC3339, row[2])
		if err != nil {
			return nil, fmt.Errorf("csv row %d event_time: %w", i+2, err)
		}
		events = append(events, Event{UserID: userID, Event: row[1], EventTime: eventTime})
	}
	return events, nil
}

// ParseJSONLines reads back what Firehose delivered.
//
// Firehose concatenates the raw bytes of the records it buffered, so this only works because the
// producer terminated each record with a newline. Without that the whole object is one unsplittable
// run of JSON — the failure mode this parser would otherwise hit.
func ParseJSONLines(data []byte) ([]Event, error) {
	var events []Event

	for i, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var e Event
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			return nil, fmt.Errorf("json line %d: %w", i+1, err)
		}
		events = append(events, e)
	}

	if len(events) == 0 {
		return nil, fmt.Errorf("object contained no JSON records")
	}
	return events, nil
}
