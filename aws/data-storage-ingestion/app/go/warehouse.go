package main

import (
	"bytes"
	"context"
	"embed"
	"fmt"
	"strconv"
	"strings"
	"text/template"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/redshiftdata"
	rdtypes "github.com/aws/aws-sdk-go-v2/service/redshiftdata/types"
)

// The SQL lives in .sql.tmpl files rather than inline Go strings so it stays reviewable as SQL, with
// its own comments explaining the COPY options. Embedding keeps the binary self-contained.
//
//go:embed sql/*.sql.tmpl
var sqlFS embed.FS

// sqlParams is the substitution set every statement template draws from.
type sqlParams struct {
	Table       string
	BatchTable  string
	StreamTable string
	Bucket      string
	Prefix      string
	Region      string
}

func renderSQL(name string, p sqlParams) (string, error) {
	tmpl, err := template.ParseFS(sqlFS, "sql/"+name)
	if err != nil {
		return "", fmt.Errorf("parse %s: %w", name, err)
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, p); err != nil {
		return "", fmt.Errorf("render %s: %w", name, err)
	}
	return buf.String(), nil
}

// Warehouse talks to Redshift Serverless over the Data API.
//
// The Data API is why this lab needs no bastion, no security-group ingress, no psql, and no database
// password: statements are submitted to a regional AWS endpoint authenticated with the caller's IAM
// identity, and Redshift executes them against the workgroup from the inside.
type Warehouse struct {
	client    *redshiftdata.Client
	workgroup string
	database  string
}

func NewWarehouse(cfg aws.Config, workgroup, database string) *Warehouse {
	return &Warehouse{
		client:    redshiftdata.NewFromConfig(cfg),
		workgroup: workgroup,
		database:  database,
	}
}

// submit sends one statement and returns its ID. The Data API is asynchronous — this returns as soon
// as the statement is accepted, not when it completes.
func (w *Warehouse) submit(ctx context.Context, sql string) (string, error) {
	out, err := w.client.ExecuteStatement(ctx, &redshiftdata.ExecuteStatementInput{
		WorkgroupName: aws.String(w.workgroup),
		Database:      aws.String(w.database),
		Sql:           aws.String(sql),
	})
	if err != nil {
		return "", fmt.Errorf("submit statement: %w", err)
	}
	return aws.ToString(out.Id), nil
}

// await polls until the statement reaches a terminal state.
//
// A COPY can run for a while, and a workgroup that has been idle has to resume before it executes
// anything, so the timeout here is generous.
func (w *Warehouse) await(ctx context.Context, id string) error {
	const (
		pollInterval = 1 * time.Second
		timeout      = 10 * time.Minute
	)

	deadline := time.Now().Add(timeout)
	for {
		desc, err := w.client.DescribeStatement(ctx, &redshiftdata.DescribeStatementInput{
			Id: aws.String(id),
		})
		if err != nil {
			return fmt.Errorf("describe statement %s: %w", id, err)
		}

		switch desc.Status {
		case rdtypes.StatusStringFinished:
			return nil
		case rdtypes.StatusStringFailed, rdtypes.StatusStringAborted:
			// Redshift's error text is the single most useful thing when a COPY rejects rows, so surface
			// it verbatim rather than wrapping it in something friendlier.
			return fmt.Errorf("statement %s %s: %s", id, desc.Status, aws.ToString(desc.Error))
		}

		if time.Now().After(deadline) {
			return fmt.Errorf("statement %s still %s after %s", id, desc.Status, timeout)
		}

		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(pollInterval):
		}
	}
}

// Exec runs a statement to completion and discards any result.
func (w *Warehouse) Exec(ctx context.Context, sql string) error {
	id, err := w.submit(ctx, sql)
	if err != nil {
		return err
	}
	return w.await(ctx, id)
}

// Table is a materialised query result: column names plus rows of already-stringified values.
type Table struct {
	Columns []string
	Rows    [][]string
}

// Query runs a statement to completion and fetches its result set.
func (w *Warehouse) Query(ctx context.Context, sql string) (Table, error) {
	id, err := w.submit(ctx, sql)
	if err != nil {
		return Table{}, err
	}
	if err := w.await(ctx, id); err != nil {
		return Table{}, err
	}

	var (
		result    Table
		nextToken *string
	)
	for {
		out, err := w.client.GetStatementResult(ctx, &redshiftdata.GetStatementResultInput{
			Id:        aws.String(id),
			NextToken: nextToken,
		})
		if err != nil {
			return Table{}, fmt.Errorf("get result for %s: %w", id, err)
		}

		if result.Columns == nil {
			for _, c := range out.ColumnMetadata {
				result.Columns = append(result.Columns, aws.ToString(c.Name))
			}
		}
		for _, record := range out.Records {
			row := make([]string, 0, len(record))
			for _, field := range record {
				row = append(row, fieldString(field))
			}
			result.Rows = append(result.Rows, row)
		}

		if out.NextToken == nil {
			return result, nil
		}
		nextToken = out.NextToken
	}
}

// fieldString flattens the Data API's tagged-union field type into a printable string.
func fieldString(f rdtypes.Field) string {
	switch v := f.(type) {
	case *rdtypes.FieldMemberStringValue:
		return v.Value
	case *rdtypes.FieldMemberLongValue:
		return strconv.FormatInt(v.Value, 10)
	case *rdtypes.FieldMemberDoubleValue:
		return strconv.FormatFloat(v.Value, 'f', -1, 64)
	case *rdtypes.FieldMemberBooleanValue:
		return strconv.FormatBool(v.Value)
	case *rdtypes.FieldMemberBlobValue:
		return string(v.Value)
	case *rdtypes.FieldMemberIsNull:
		return "NULL"
	default:
		return ""
	}
}

// EnsureSchema creates the table if it does not exist, then empties it so a reload is idempotent.
func (w *Warehouse) EnsureSchema(ctx context.Context, table string) error {
	create, err := renderSQL("create_table.sql.tmpl", sqlParams{Table: table})
	if err != nil {
		return err
	}
	if err := w.Exec(ctx, create); err != nil {
		return fmt.Errorf("create table %s: %w", table, err)
	}

	truncate, err := renderSQL("truncate.sql.tmpl", sqlParams{Table: table})
	if err != nil {
		return err
	}
	if err := w.Exec(ctx, truncate); err != nil {
		return fmt.Errorf("truncate table %s: %w", table, err)
	}
	if err := w.GrantAccess(ctx); err != nil {
		return fmt.Errorf("grant access on %s: %w", table, err)
	}
	return nil
}

// Copy loads one path's objects from S3 into its table using the given COPY template.
func (w *Warehouse) Copy(ctx context.Context, templateName string, p sqlParams) error {
	stmt, err := renderSQL(templateName, p)
	if err != nil {
		return err
	}
	if err := w.Exec(ctx, stmt); err != nil {
		return fmt.Errorf("copy into %s: %w", p.Table, err)
	}
	return nil
}

// TableStats is the row count and event-time range present in a loaded table.
type TableStats struct {
	RowCount      int64
	EarliestEvent string
	LatestEvent   string
}

// Stats reports what actually made it into a table.
func (w *Warehouse) Stats(ctx context.Context, table string) (TableStats, error) {
	stmt, err := renderSQL("count.sql.tmpl", sqlParams{Table: table})
	if err != nil {
		return TableStats{}, err
	}

	result, err := w.Query(ctx, stmt)
	if err != nil {
		return TableStats{}, err
	}
	if len(result.Rows) == 0 || len(result.Rows[0]) < 3 {
		return TableStats{}, fmt.Errorf("unexpected result shape counting %s", table)
	}

	count, err := strconv.ParseInt(strings.TrimSpace(result.Rows[0][0]), 10, 64)
	if err != nil {
		return TableStats{}, fmt.Errorf("parse row count for %s: %w", table, err)
	}

	return TableStats{
		RowCount:      count,
		EarliestEvent: result.Rows[0][1],
		LatestEvent:   result.Rows[0][2],
	}, nil
}

// Sample returns the first rows of a table — the schema-and-data sanity check.
func (w *Warehouse) Sample(ctx context.Context, table string) (Table, error) {
	stmt, err := renderSQL("sample.sql.tmpl", sqlParams{Table: table})
	if err != nil {
		return Table{}, err
	}
	return w.Query(ctx, stmt)
}

// CreateView creates or replaces a database view using the given template.
func (w *Warehouse) CreateView(ctx context.Context, templateName string, p sqlParams) error {
	stmt, err := renderSQL(templateName, p)
	if err != nil {
		return err
	}
	return w.Exec(ctx, stmt)
}

// GrantAccess grants USAGE and SELECT privileges on public schema objects to PUBLIC so that
// any console identity or Query Editor v2 federated user can inspect and query them.
func (w *Warehouse) GrantAccess(ctx context.Context) error {
	const sql = "GRANT USAGE ON SCHEMA public TO PUBLIC; GRANT SELECT ON ALL TABLES IN SCHEMA public TO PUBLIC; ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO PUBLIC;"
	return w.Exec(ctx, sql)
}
