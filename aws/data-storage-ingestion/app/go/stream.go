package main

import (
	"context"
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/kinesis"
	kintypes "github.com/aws/aws-sdk-go-v2/service/kinesis/types"
)

// Stream is the Kinesis data stream the producer writes to and the raw consumer reads from.
type Stream struct {
	client *kinesis.Client
	name   string
}

func NewStream(cfg aws.Config, name string) *Stream {
	return &Stream{client: kinesis.NewFromConfig(cfg), name: name}
}

// Put writes one event to the stream.
//
// The partition key is the user ID rather than a constant. With a constant key every record hashes to
// the same shard, which works on a one-shard stream and silently fails to scale the moment a second
// shard is added — a trap worth not building in from the start.
func (s *Stream) Put(ctx context.Context, e Event) error {
	data, err := MarshalRecord(e)
	if err != nil {
		return err
	}

	_, err = s.client.PutRecord(ctx, &kinesis.PutRecordInput{
		StreamName:   aws.String(s.name),
		Data:         data,
		PartitionKey: aws.String(fmt.Sprintf("user-%d", e.UserID)),
	})
	if err != nil {
		return fmt.Errorf("put record to %s: %w", s.name, err)
	}
	return nil
}

// WaitActive blocks until the stream is ACTIVE.
//
// A stream that has just been created reports CREATING and rejects writes, which otherwise shows up as
// a confusing failure on the first `produce` immediately after `task up`.
func (s *Stream) WaitActive(ctx context.Context, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for {
		desc, err := s.client.DescribeStreamSummary(ctx, &kinesis.DescribeStreamSummaryInput{
			StreamName: aws.String(s.name),
		})
		if err != nil {
			return fmt.Errorf("describe stream %s: %w", s.name, err)
		}
		if desc.StreamDescriptionSummary.StreamStatus == kintypes.StreamStatusActive {
			return nil
		}
		if time.Now().After(deadline) {
			return fmt.Errorf("stream %s still %s after %s",
				s.name, desc.StreamDescriptionSummary.StreamStatus, timeout)
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
}

// StreamRecord is one record read straight off a shard, with the shard it came from.
type StreamRecord struct {
	ShardID        string
	SequenceNumber string
	ArrivalTime    time.Time
	Event          Event
}

// ReadAll reads every record currently in the stream, from the oldest available position.
//
// This is the low-level read the AWS CLI does with `get-shard-iterator` + `get-records`, which is worth
// doing once by hand: it shows that a shard is a cursor you hold and advance, not a queue you pop.
// Firehose is doing exactly this behind the scenes, continuously.
func (s *Stream) ReadAll(ctx context.Context) ([]StreamRecord, error) {
	shards, err := s.client.ListShards(ctx, &kinesis.ListShardsInput{
		StreamName: aws.String(s.name),
	})
	if err != nil {
		return nil, fmt.Errorf("list shards of %s: %w", s.name, err)
	}

	var records []StreamRecord
	for _, shard := range shards.Shards {
		shardID := aws.ToString(shard.ShardId)

		// TRIM_HORIZON: start at the oldest record still inside the retention window, so a record put
		// before this consumer existed is still visible. That replayability is what separates a stream
		// from a queue.
		iter, err := s.client.GetShardIterator(ctx, &kinesis.GetShardIteratorInput{
			StreamName:        aws.String(s.name),
			ShardId:           shard.ShardId,
			ShardIteratorType: kintypes.ShardIteratorTypeTrimHorizon,
		})
		if err != nil {
			return nil, fmt.Errorf("get shard iterator for %s: %w", shardID, err)
		}

		shardRecords, err := s.drainShard(ctx, shardID, iter.ShardIterator)
		if err != nil {
			return nil, err
		}
		records = append(records, shardRecords...)
	}

	return records, nil
}

// drainShard follows one shard's iterator until it stops returning new records.
func (s *Stream) drainShard(ctx context.Context, shardID string, iterator *string) ([]StreamRecord, error) {
	// GetRecords can legitimately return an empty page while more data is still ahead, so a single
	// empty response is not proof the shard is drained. Stop after a few consecutive empties.
	const maxEmptyPolls = 3

	var (
		records    []StreamRecord
		emptyPolls int
	)

	for iterator != nil && emptyPolls < maxEmptyPolls {
		out, err := s.client.GetRecords(ctx, &kinesis.GetRecordsInput{
			ShardIterator: iterator,
		})
		if err != nil {
			return nil, fmt.Errorf("get records from %s: %w", shardID, err)
		}

		if len(out.Records) == 0 {
			emptyPolls++
		} else {
			emptyPolls = 0
			for _, r := range out.Records {
				events, err := ParseJSONLines(r.Data)
				if err != nil {
					return nil, fmt.Errorf("decode record %s: %w", aws.ToString(r.SequenceNumber), err)
				}
				for _, e := range events {
					records = append(records, StreamRecord{
						ShardID:        shardID,
						SequenceNumber: aws.ToString(r.SequenceNumber),
						ArrivalTime:    aws.ToTime(r.ApproximateArrivalTimestamp),
						Event:          e,
					})
				}
			}
		}

		iterator = out.NextShardIterator

		// Stay under the 5 GetRecords/s per-shard limit.
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(250 * time.Millisecond):
		}
	}

	return records, nil
}
