# 0001 — Path-based routing to three private S3 buckets behind one CloudFront distribution

Status: accepted
Date: 2026-07-04

## Context

The lab serves a static website and two kinds of downloadable content (`.jpg`, `.pdf`) from three
separate S3 buckets, behind a single public entry point. Opening the CloudFront DNS lands on the
site; its links to `/photo.jpg` and `/report.pdf` resolve to the other two buckets. The reusable
modules repo has a hardened `s3-bucket` module (all public access blocked, ACLs disabled) but no
CloudFront module, so one was written.

## Decisions

### CloudFront + Origin Access Control, buckets stay private

The `s3-bucket` module refuses to compromise its baseline — all public access is blocked and ACLs
are disabled — which rules out classic public S3 *website hosting* endpoints. Instead CloudFront
fronts the three buckets as REST origins using **Origin Access Control (OAC)**: CloudFront signs each
origin request with SigV4, and each bucket policy allows `s3:GetObject` only to the
`cloudfront.amazonaws.com` service principal, scoped to this distribution via
`AWS:SourceArn = distribution_arn`. The buckets are never publicly reachable; the only public surface
is the CloudFront domain. This keeps the security posture of the modules repo intact.

### A new reusable module: `aws/cloudfront-s3`

CloudFront fronting private S3 origins with path routing is a general building block, not
lab-specific glue, so it was built as a reusable module in the catalog (released as
`aws-cloudfront-s3-v0.1.0`) rather than inlined. The module owns only the distribution and a shared
OAC; it takes a map of S3 origins and an ordered list of `path_pattern -> origin_key` behaviors. It
deliberately does **not** own the buckets or their policies — that composition (and the OAC trust
wiring) is the consumer's concern, which keeps the module account/region-agnostic.

### Dependency direction chosen to break the OAC cycle

There is a natural cycle: the distribution needs each bucket's regional domain name, and each
bucket's policy needs the distribution ARN. It is broken by having the `cdn` unit derive origin
domain names from the (env-known) bucket names — `<prefix>-<role>.s3.<region>.amazonaws.com` — so
`cdn` has **no** dependency on the bucket units. The three bucket units then depend on `cdn` for
`distribution_arn`. Apply order: `cdn` → `bucket-site`/`bucket-jpg`/`bucket-pdf` → `seed`. This is
the same "derive the name instead of taking a dependency" trick the sibling `s3-policy-eval-matrix`
lab uses for bucket ARNs.

### Routing by path suffix, default to the site

CloudFront evaluates ordered cache behaviors before the default: `*.jpg` → jpg bucket, `*.pdf` → pdf
bucket, everything else (including `/` → `index.html`) → the site bucket. Because links in the
generated `index.html` are root-relative (`/photo.jpg`), they match the path patterns automatically —
the site's links and the routing are the same contract.

### `index.html` generated from the actual uploaded files

Rather than hand-maintain the site's links, a local `seed` unit uploads every file under
`app/assets/jpg` and `app/assets/pdf` and generates `index.html` with a link per uploaded file. Add
or remove an asset and re-run `up`; the page stays in sync. Uploading objects and building the page
is lab-specific glue, so `seed` is a local unit, ordered after the buckets exist.

## Consequences

- Real, costed resources exist for the lab's lifetime: one CloudFront distribution and three S3
  buckets (plus objects). Tear down with `task cdn:down` (`force_destroy = true` lets the non-empty
  buckets be destroyed).
- A fresh distribution takes several minutes to deploy to the edge before `verify` will pass.
- The lab pins two module tags: `aws-cloudfront-s3-v0.1.0` and `aws-s3-bucket-v0.1.0`.
- `BUCKET_PREFIX` (and the state bucket) must be globally unique across all of S3.
- The distribution uses the default `*.cloudfront.net` certificate — no custom domain/ACM, which is
  out of scope for this lab.
