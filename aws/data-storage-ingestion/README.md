# aws/data-storage-ingestion

A hands-on lab and reference implementation showcasing **core AWS data storage and ingestion patterns**. The lab provisions and demonstrates three common data ingestion pipelines landing data into an Amazon S3 data lake and an Amazon Redshift Serverless data warehouse:

1. **Direct Batch Ingestion**: File-based CSV generation and upload directly to Amazon S3, followed by batch loading into Amazon Redshift.
2. **Real-Time Streaming**: Event publishing to Amazon Kinesis Data Streams and real-time shard consumption via raw shard iterators.
3. **Managed Stream-to-Storage Delivery**: Bridging a Kinesis Data Stream to Amazon S3 using Amazon Data Firehose (micro-batch buffering), followed by JSON loading into Amazon Redshift.

---

## Architecture Overview

```
                                  ┌── PutObject (CSV) ──▶ S3 (batch/) ──────────▶ Redshift: user_events_batch
                                  │
[Go CLI: Event Producer/Driver] ──┤
                                  │                       ┌── Firehose (Buffer) ─▶ S3 (stream/) ──▶ Redshift: user_events_stream
                                  └── PutRecord (JSON) ─▶ Kinesis Data Stream
                                                                 │
                                                                 └── Raw Shard Iterator ──▶ Direct CLI Console View
```

### The Ingestion Pipelines

- **Pipeline 1: Direct Batch Ingestion (`task upload`)**
  - Generates synthetic events and formats them as CSV with column headers.
  - Uploads the dataset directly to `s3://<DATA_BUCKET>/batch/` using a single `PutObject` call.
  - Represents the classic batch pattern: source systems periodically dump structured files directly to object storage for downstream bulk consumption.

- **Pipeline 2: Real-Time Stream Ingestion (`task produce` & `task consume`)**
  - Publishes individual JSON-encoded events to an Amazon Kinesis Data Stream (`user-events`) via `PutRecord`.
  - Demonstrates direct stream consumption (`task consume`) using a raw Kinesis shard iterator starting from `TRIM_HORIZON`.
  - Illustrates the low-latency pub/sub streaming pattern where decoupled microservices or stream analytics processors (e.g., Flink, Lambda) process events immediately off the stream.

- **Pipeline 3: Managed Delivery to Data Lake (`delivery` unit)**
  - Amazon Data Firehose (`user-events-to-s3`) continuously pulls records from the Kinesis Data Stream, buffers them according to configured buffer thresholds (60 seconds / 1 MB), and writes uncompressed JSON Lines objects to `s3://<DATA_BUCKET>/stream/`.
  - Delivery failures are automatically isolated and routed to `s3://<DATA_BUCKET>/errors/`.
  - Represents the managed ingestion pattern for continuously archiving streaming events to an object storage data lake without custom consumer code.

- **Warehouse Loading (`task load` & `task query`)**
  - Loads data from both S3 prefixes into distinct Amazon Redshift Serverless tables (`user_events_batch` and `user_events_stream`).
  - Demonstrates Redshift `COPY` syntax differences: positional CSV parsing (`IGNOREHEADER 1`) versus schema-matching JSON parsing (`FORMAT AS JSON 'auto'`).
  - Executes queries through the IAM-authenticated **Amazon Redshift Data API**, requiring no persistent client connections or open inbound database ports.

- **Analytics Views & UI Visualization (`task setup-views`)**
  - Deploys database views (`v_unified_events`, `v_pipeline_event_summary`, and `v_user_engagement_profile`) to Redshift schema `public`.
  - Enables instant visual charting in **AWS Redshift Query Editor v2** (Grouped Bar, Donut/Pie, and Timeline charts) without manual DDL setup.

- **Pipeline Verification (`task verify`)**
  - Asserts that both the batch upload and Firehose delivery paths successfully deposited objects into S3.
  - Validates that Redshift loaded rows into both tables without truncation or silent errors.
  - Confirms that zero failed records were written to the `errors/` prefix.

---

## Theoretical Comparison: Batch vs. Real-Time Streaming vs. Managed Delivery

While this lab implements these pipelines side by side for demonstration and testing purposes, production architectures choose between them based on data freshness requirements, operational complexity, and cost characteristics:

| Architectural Dimension | Direct Batch Ingestion | Real-Time Streaming (Kinesis) | Managed Streaming Delivery (Firehose) |
| :--- | :--- | :--- | :--- |
| **Primary Use Case** | Periodic bulk uploads, ETL jobs, historical backfills | Sub-second reaction, fraud detection, live alerting | Continuous data lake archiving, log aggregation |
| **Target Storage / Consumer** | Amazon S3, EMR, Data Warehouses | Custom consumers, AWS Lambda, Apache Flink | Amazon S3, Amazon Redshift, OpenSearch, Splunk |
| **Ingestion Latency** | High (minutes to hours; depends on batch interval) | Low (milliseconds to seconds) | Near real-time (buffered: 60s–900s or 1MB–128MB) |
| **Wire & File Format** | Controlled by producer (CSV, Parquet, ORC) | Arbitrary payloads (JSON, Avro, Protobuf) | Concatenated records (JSON Lines, optional Parquet) |
| **Buffering Strategy** | Source-side accumulation before push | Record-by-record ingestion into stream | Time/size windowed micro-batches |
| **Replayability** | Re-run batch file upload or S3 object retention | Shard retention buffer (24h to 365 days) | None on Firehose itself; depends on upstream stream |
| **Failure Handling** | Retries at file level; idempotent overwrite | Consumer manages shard checkpoints and DLQ | Automatic retry with fallback to S3 `errors/` prefix |
| **Scaling Mechanism** | S3 scales automatically to arbitrary throughput | Managed by shard count (1MB/s or 1,000 records/s/shard) | Scales automatically with incoming record throughput |
| **Cost Drivers** | S3 API requests (`PUT`/`GET`) and storage volume | Provisioned shard-hours or On-Demand stream fees | Ingestion volume (per GB converted/delivered) |

### Trade-Off Summary

1. **Direct Batch Ingestion**:
   - *Advantages*: Simplest architecture, lowest overhead for large volumes, native support for columnar formats (Parquet) at write time, immediately queryable upon upload.
   - *Disadvantages*: High latency (data is only as fresh as the upload cadence), bursty network and compute load during batch processing windows.

2. **Real-Time Streaming (Kinesis Data Streams)**:
   - *Advantages*: Sub-second event visibility, multiple independent consumers can read the same stream concurrently, retention window allows replaying events from a specific point in time.
   - *Disadvantages*: Requires dedicated consumer infrastructure or managed compute (Lambda, Flink), requires shard capacity planning (if using provisioned mode), payload size limit of 1 MB per record.

3. **Managed Stream Delivery (Firehose)**:
   - *Advantages*: Zero consumer code or server management required to write stream data to S3 or Redshift; built-in buffering, optional data transformation (via Lambda), and automatic error routing.
   - *Disadvantages*: Incurs a latency floor due to minimum buffering constraints (minimum 60 seconds), stream records are concatenated on delivery requiring clear delimiter conventions (e.g., newline termination for JSON).

---

## Infrastructure Architecture & Units

Infrastructure is managed using Terragrunt units pulling pinned modules from `gichie534/infrastructure-catalog`:

```
infra/
├── lookups/          # Local glue: Queries AWS availability zones (Redshift requires >= 3 AZs)
├── vpc/              # Dedicated 3-AZ VPC (public and private subnets; NAT disabled)
├── data-lake/        # S3 bucket hosting batch/, stream/, and errors/ prefixes
├── stream/           # Amazon Kinesis Data Stream (1 shard, metrics enabled)
├── delivery/         # Amazon Data Firehose (60s / 1MB buffer, S3 destination)
├── warehouse-sg/     # Egress-only Security Group for Redshift Serverless
└── warehouse/        # Amazon Redshift Serverless workgroup and namespace
```

| Unit | Module Source | Version / Ref | Description |
| :--- | :--- | :--- | :--- |
| `lookups` | Local (`.`) | — | Queries availability zones; ensures 3 AZs for Redshift |
| `vpc` | `modules/aws/vpc` | `aws-vpc-v0.1.0` | 3 AZs, private `/20` subnets, **no NAT Gateway** |
| `data-lake` | `modules/aws/s3-bucket` | `aws-s3-bucket-v0.3.0` | Destination bucket with `force_destroy = true` |
| `stream` | `modules/aws/kinesis-stream` | `aws-kinesis-stream-v0.1.0` | 1 shard, provisioned throughput and lag metrics |
| `delivery` | `modules/aws/kinesis-firehose` | `aws-kinesis-firehose-v0.1.0` | Buffers Kinesis events to S3 under `stream/` |
| `warehouse-sg` | `modules/aws/security-group` | `aws-security-group-v0.1.0` | Egress-only security group for warehouse workgroup |
| `warehouse` | `modules/aws/redshift-serverless` | `aws-redshift-serverless-v0.1.1` | 8 RPU capacity ceiling, IAM default COPY role |

### Key Design & Cost Safeguards

- **No NAT Gateway**: Outbound NAT is omitted from the VPC. The Redshift workgroup is queried via the **Redshift Data API** (IAM-authenticated over AWS regional endpoints), and `COPY` traffic to S3 stays on the AWS internal backbone. This completely avoids the hourly cost of NAT gateways.
- **Redshift Serverless 8 RPU Ceiling**: Capacity is explicitly bounded with `base_capacity = 8` and `max_capacity = 8` RPUs to prevent unexpected auto-scaling during query execution.
- **Zero Credentials in State**: Database master credentials are automatically generated and stored in AWS Secrets Manager (`manage_admin_password = true`), while application access uses IAM authentication via the Redshift Data API.
- **Default Namespace COPY Role**: The warehouse IAM role has read permissions on the data bucket and is configured as the Redshift namespace default role, enabling `COPY ... IAM_ROLE default` in SQL templates.

---

## Prerequisites

Before running the lab, ensure you have the following installed:

- **Terraform** (`>= 1.10.0`, pinned in `.terraform-version`)
- **Terragrunt** (`>= 1.0.0`, pinned in `.terragrunt-version`)
- **Task** (`task` runner)
- **Go** (`>= 1.24`)
- **AWS CLI** configured with credentials for your AWS account.

---

## Setup & Provisioning

### 1. Initialize Environment Configuration

Create your `.env` configuration from the provided template:

```bash
task init-env
```

Edit `.env` to configure your AWS region and bucket names:

```bash
# Region where all resources will be created
AWS_REGION=us-east-1

# S3 bucket for Terraform remote state (uses S3-native locking)
TF_STATE_BUCKET=your-unique-tf-state-bucket

# S3 bucket to receive batch and stream datasets
DATA_BUCKET=your-unique-data-lake-bucket
```

### 2. Bootstrap Remote State

Create and initialize the S3 backend bucket for Terraform state (run once):

```bash
task state-bootstrap
```

### 3. Run Pre-flight Checks (Cost-Free)

Validate code, templates, and infrastructure configuration locally without provisioning cloud resources:

```bash
task fmt        # Format Terragrunt HCL and Go files
task validate   # Validate all Terragrunt units
task plan       # Generate Terraform plan for all units
task test       # Run Go unit tests for serialization and SQL templates
```

### 4. Deploy Infrastructure

Provision the VPC, S3 data lake, Kinesis stream, Firehose delivery stream, and Redshift Serverless warehouse:

```bash
task up
```

> [!NOTE]
> `task up` provisions real AWS resources. Redshift Serverless incurs costs per RPU-second during query execution. Always run `task down` when you have finished your lab session.

---

## Running the Pipelines

You can execute the entire pipeline suite automatically with one command, or step through each component individually.

### Automated End-to-End Execution

Run all pipeline steps in sequence: upload batch data, publish streaming events, wait for the Firehose buffer flush, load into Redshift, and verify delivery:

```bash
task ingest
```

---

### Step-by-Step Walkthrough

#### Step 1: Execute Direct Batch Ingestion
Generates synthetic user events and performs a direct S3 `PutObject` of a CSV file:

```bash
task upload
```
*Output:*
```text
Uploaded 15 events (498 bytes) to s3://<DATA_BUCKET>/batch/sample_data.csv in 135ms
The object is durable and readable now — there is no buffer to wait on.
```

#### Step 2: Produce Events to Kinesis Stream
Publishes events onto the Kinesis Data Stream:

```bash
task produce
```
*Output:*
```text
Sending 15 events to the user-events stream...
  [ 1/15] user_id=1 event=login    event_time=2026-09-25T19:30:00Z
  [ 2/15] user_id=3 event=purchase event_time=2026-09-25T19:30:00Z
  ...
Sent. These records are on the stream but NOT yet in S3.
Firehose buffers for 1m0s before it writes an object — wait at least that long, then run `task load`.
```

#### Step 3: Consume Events Directly from the Stream
Inspects records in real time directly from Kinesis shards using a shard iterator (`TRIM_HORIZON`), bypassing S3 and Firehose:

```bash
task consume
```
*Output:*
```text
Reading the user-events stream from TRIM_HORIZON (the oldest record still retained)...

shard             arrived               user_id   event      event_time
----------------  --------------------  -------   --------   --------------------
shardId-00000000  2026-09-25T19:30:01Z  1         login      2026-09-25T19:30:00Z
shardId-00000000  2026-09-25T19:30:01Z  3         purchase   2026-09-25T19:30:00Z

Read 15 record(s) directly off the shard(s). Firehose does exactly this, continuously.
```

#### Step 4: Load Datasets into Redshift Warehouse
After the Firehose buffer flushes to S3 (allow 60–90 seconds after `task produce`), trigger the `COPY` operations to populate both Redshift tables:

```bash
task load
```
*This invokes the Redshift Data API to create/truncate `user_events_batch` and `user_events_stream` and load each table from its respective S3 prefix.*

#### Step 5: Query and Sample Loaded Data
Perform a schema and data sanity check by sampling rows from both Redshift tables:

```bash
task query
```

#### Step 6: Create Analytics Views for Redshift Query Editor v2
Deploy the comparative views to Redshift schema `public`:

```bash
task setup-views
```
*Output:*
```text
Setting up analytics views in Redshift for Query Editor v2...
  creating v_unified_events (Combines batch and stream records into a single unified dataset)...
  creating v_pipeline_event_summary (Aggregates event counts by event type and pipeline (for Bar Charts))...
  creating v_user_engagement_profile (Aggregates logins, purchases, and logouts per user (for Donut/Bar Charts))...

All views created successfully in Redshift schema 'public'!
```

#### Step 7: Verify Delivery Pipelines
Assert that both data paths successfully landed all records in S3 and Redshift, and verify that no delivery errors occurred:

```bash
task verify
```
*Output:*
```text
== what each path delivered ==
path     objects in s3   rows in redshift   table
-------  -------------   ----------------   ------------------
batch    1               15                 user_events_batch
stream   1               15                 user_events_stream

== how stale each path was on arrival ==
(newest event inside the first object, versus when S3 accepted that object)
path     newest event          landed in s3          delivery lag
-------  --------------------  --------------------  ------------
batch    2026-09-25T19:29:58Z  2026-09-25T19:29:58Z  0s
stream   2026-09-25T19:30:03Z  2026-09-25T19:31:05Z  1m2s

The streaming path was 1m2s staler than the batch path on arrival.
Firehose is configured to buffer for 1m0s, which is where that time goes.

== assertions ==
  PASS: both paths delivered (15 batch rows, 15 stream rows), no delivery failures.
  PASS: the batch path was fresher on arrival, by 1m2s.
```

---

## Visualizing in AWS Redshift Query Editor v2

To view and chart the data visually directly inside the AWS Management Console:

### 1. Connect to Redshift Query Editor v2
1. In the AWS Management Console, open **Amazon Redshift** $\rightarrow$ **Query editor v2**.
2. Under **Serverless workgroups**, locate and click **`events-warehouse`**.
3. In the connection dialog:
   - **Authentication**: Select **Federated user** (IAM authentication — no database password required).
   - **Database**: Enter `labdb`.
4. Click **Create connection**.

### 2. Inspect the Schema & Views
In the left navigation tree, expand:
`events-warehouse` $\rightarrow$ `labdb` $\rightarrow$ `public` $\rightarrow$ `Views`

You will see the three views created by `task setup-views`:
- `v_unified_events`
- `v_pipeline_event_summary`
- `v_user_engagement_profile`

Click the three dots next to any view and select **Preview data** to inspect the rows instantly.

### 3. Render Visual Charts
Open a new SQL editor tab and use the queries from [`queries.sql`](file:///Users/richard/Desktop/study-and-practice/labs/aws/data-storage-ingestion/queries.sql):

#### Chart A: Pipeline Comparison (Grouped Bar Chart)
```sql
SELECT 
    event,
    source_pipeline,
    event_count
FROM v_pipeline_event_summary
ORDER BY event, source_pipeline;
```
1. Click **Run**.
2. Above the results grid, toggle from **Table** to **Chart**.
3. Configure the chart panel:
   - **Chart type**: `Bar`
   - **X axis**: `event`
   - **Y axis**: `event_count`
   - **Group by**: `source_pipeline`

#### Chart B: Event Type Breakdown (Donut / Pie Chart)
```sql
SELECT 
    event,
    COUNT(*) AS total_count
FROM v_unified_events
GROUP BY event
ORDER BY total_count DESC;
```
1. Click **Run**.
2. Toggle to **Chart** and configure:
   - **Chart type**: `Donut` (or `Pie`)
   - **Category**: `event`
   - **Value**: `total_count`

#### Chart C: User Activity Breakdown (Stacked Bar Chart)
```sql
SELECT 
    CAST(user_id AS VARCHAR) AS user_id,
    logins,
    purchases,
    logouts
FROM v_user_engagement_profile
ORDER BY user_id;
```
1. Click **Run**.
2. Toggle to **Chart** and configure:
   - **Chart type**: `Stacked Bar`
   - **X axis**: `user_id`
   - **Values**: Select `logins`, `purchases`, `logouts`

---

## Teardown

Destroy all deployed infrastructure when finished:

```bash
task down
```

> [!TIP]
> The `data-lake` bucket has `force_destroy = true` enabled in Terragrunt, allowing `task down` to cleanly remove the bucket even though it contains objects created during the lab.

---

## Repository Structure

```
.
├── Taskfile.yml              # Task orchestration for build, infra, and pipeline tasks
├── queries.sql               # Curated queries and chart settings for Redshift Query Editor v2
├── root.hcl                  # Terragrunt root configuration (provider and remote state)
├── .env.example              # Template for lab environment variables
├── infra/                    # Terragrunt infrastructure units
│   ├── lookups/              # Regional AZ discovery (local data source)
│   ├── vpc/                  # Dedicated 3-AZ VPC (no NAT gateway)
│   ├── data-lake/            # Shared S3 bucket (batch/, stream/, errors/)
│   ├── stream/               # Amazon Kinesis Data Stream
│   ├── delivery/             # Amazon Data Firehose Delivery Stream
│   ├── warehouse-sg/         # Egress-only security group for Redshift
│   └── warehouse/            # Amazon Redshift Serverless workgroup and namespace
└── app/go/                   # Go CLI driver (`ingest`)
    ├── main.go               # Command line router and entry point
    ├── commands.go           # Subcommands: upload, produce, consume, load, query, verify, views
    ├── config.go             # Configuration loader (.env parser)
    ├── event.go              # Event domain models and serializers (CSV / JSON Lines)
    ├── lake.go               # Amazon S3 operations
    ├── stream.go             # Amazon Kinesis and Firehose API client
    ├── warehouse.go          # Redshift Data API query runner
    ├── verify.go             # Delivery verification and assertions
    └── sql/                  # Redshift SQL templates
        ├── copy_batch.sql.tmpl
        ├── copy_stream.sql.tmpl
        ├── create_table.sql.tmpl
        ├── count.sql.tmpl
        ├── sample.sql.tmpl
        ├── truncate.sql.tmpl
        ├── view_unified_events.sql.tmpl
        ├── view_pipeline_event_summary.sql.tmpl
        └── view_user_engagement_profile.sql.tmpl
```
