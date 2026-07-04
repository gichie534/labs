# aws/s3-cloudfront-routing

A single CloudFront distribution that fronts **three private S3 buckets** and routes requests by
path: the default path serves a static website, `*.jpg` is served from a jpg bucket, and `*.pdf`
from a pdf bucket. You open the CloudFront DNS, land on the site, and its links to the images and
documents resolve to the other two buckets — all reached privately through **Origin Access Control
(OAC)**, so none of the buckets is publicly accessible.

## Architecture

```
                         ┌──────────────────────────┐
        browser ───────► │  CloudFront distribution  │  (public *.cloudfront.net, HTTPS)
                         └────────────┬─────────────┘
                          path routing│ (OAC-signed origin requests)
             ┌────────────────────────┼────────────────────────┐
             │ default (/)            │ *.jpg                   │ *.pdf
             ▼                        ▼                         ▼
      ┌──────────────┐        ┌──────────────┐          ┌──────────────┐
      │  site bucket │        │  jpg bucket  │          │  pdf bucket  │   (all PRIVATE)
      │ index.html   │        │  *.jpg       │          │  *.pdf       │
      └──────────────┘        └──────────────┘          └──────────────┘
```

Each bucket comes from the hardened `aws/s3-bucket` module (all public access blocked, SSE on, ACLs
disabled) and trusts only the CloudFront service principal for this distribution
(`AWS:SourceArn = distribution_arn`). The `index.html` is generated from whatever assets you drop in,
with a link per file — and because the links are root-relative (`/photo.jpg`), they match the path
routing automatically.

## Layout

```
infra/
  cdn/          # CloudFront distribution (aws/cloudfront-s3 module) — created first
  bucket-site/  # static-website bucket (aws/s3-bucket) + OAC policy
  bucket-jpg/   # jpg bucket           (aws/s3-bucket) + OAC policy
  bucket-pdf/   # pdf bucket           (aws/s3-bucket) + OAC policy
  seed/         # local unit: uploads assets + generates/uploads index.html
app/assets/
  jpg/          # drop your .jpg files here
  pdf/          # drop your .pdf files here
```

## Module versions pinned

- `aws/cloudfront-s3` @ `aws-cloudfront-s3-v0.1.0`
- `aws/s3-bucket` @ `aws-s3-bucket-v0.1.0`

## Run it

Prereqs: AWS credentials, and [tenv](https://github.com/tofuutils/tenv) to honour the pinned
`.terraform-version` / `.terragrunt-version`.

```bash
# 1. Configure environment
task cdn:init-env          # creates .env from .env.example
$EDITOR .env               # set AWS_REGION, TF_STATE_BUCKET, BUCKET_PREFIX (all globally unique)

# 2. Add your content
cp your-image.jpg  app/assets/jpg/
cp your-doc.pdf    app/assets/pdf/

# 3. (first time only) create the remote-state bucket
task cdn:state-bootstrap

# 4. Cost-free checks
task cdn:fmt
task cdn:validate
task cdn:plan

# 5. Provision (creates cloud resources)
task cdn:up

# 6. Open it — wait a few minutes for the distribution to finish deploying
task cdn:url               # prints the https://... CloudFront URL
task cdn:verify            # fetches / , a .jpg and a .pdf and asserts routing

# 7. Tear down
task cdn:down
```

## Notes

- A freshly created CloudFront distribution takes several minutes to deploy to the edge; `verify`
  (and the browser) will 403/404 until it finishes and the objects are readable.
- The distribution uses the default `*.cloudfront.net` certificate — no custom domain in this lab.
- `BUCKET_PREFIX` produces `<prefix>-site`, `<prefix>-jpg`, `<prefix>-pdf`; all S3 bucket names are
  global, so pick something unique.
