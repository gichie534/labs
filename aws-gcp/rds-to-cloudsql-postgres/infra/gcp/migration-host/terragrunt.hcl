# The migration host: a small Compute Engine instance INSIDE the GCP VPC that runs the migration
# (pg_dump / pg_restore / psql). This is the production-faithful shape — a jump host rather than an
# operator laptop:
#   - it reaches the TARGET Cloud SQL over its PRIVATE IP (same VPC + PSA peering), so Cloud SQL
#     needs no public endpoint;
#   - it has NO external IP (org policy commonly forbids them); it egresses to the SOURCE RDS public
#     endpoint via the VPC's Cloud NAT, whose reserved static IP the rds unit allowlists, TLS enforced;
#   - the operator drives it over IAP SSH (no public SSH exposure); the gcp/network unit opens tcp/22
#     from the IAP range to this host's network tag.
#
# A startup script installs the PostgreSQL 16 client (>= the server version, required by pg_dump).
#
# TODO(release): switch source to the pinned catalog tag before this lab is "done":
#   source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/gcp/compute-engine?ref=gcp-compute-engine-vX.Y.Z"

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "../../../../../../infrastructure-catalog/modules/gcp/compute-engine"
}

locals {
  project_id = get_env("GCP_PROJECT", "REPLACE_WITH_PROJECT_ID")
  region     = get_env("GCP_REGION", "us-central1")
}

dependency "gcp_network" {
  config_path = "../network"

  mock_outputs = {
    subnets_self_links = { db = "projects/mock/regions/us-central1/subnetworks/rds2cloudsql-db" }
  }
  # apply/destroy included so run --all can parse inputs when the dependency's outputs aren't ready
  # yet or are already gone (teardown re-run); mocks are transient and never affect real resources.
  mock_outputs_allowed_terraform_commands = ["validate", "plan", "apply", "destroy"]
}

inputs = {
  name         = "rds2cloudsql-migrator"
  project_id   = local.project_id
  zone         = "${local.region}-b"
  machine_type = "e2-small"

  subnetwork       = dependency.gcp_network.outputs.subnets_self_links["db"]
  enable_public_ip = false # no external IP (org policy); egress via Cloud NAT, SSH via IAP
  tags             = ["migration-host"]

  # Install the PostgreSQL 16 client (pg_dump must be >= the source server version). Egress is via
  # Cloud NAT, which can lag a few seconds after boot, so wait for connectivity and retry apt.
  startup_script = <<-EOT
    #!/usr/bin/env bash
    set -uo pipefail
    export DEBIAN_FRONTEND=noninteractive

    # Wait until outbound internet (via Cloud NAT) is reachable.
    for i in $(seq 1 60); do
      if curl -fsS -o /dev/null --max-time 5 https://apt.postgresql.org/; then break; fi
      echo "waiting for network egress ($i/60)"; sleep 5
    done

    apt_retry() { for i in $(seq 1 20); do apt-get "$@" && return 0; echo "apt retry $i"; sleep 10; done; return 1; }

    apt_retry update
    apt_retry install -y curl ca-certificates gnupg lsb-release
    install -d /usr/share/postgresql-common/pgdg
    curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
      https://www.postgresql.org/media/keys/ACCC4CF8.asc
    echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list
    apt_retry update
    apt_retry install -y postgresql-client-16
  EOT

  labels = {
    lab = "rds-to-cloudsql-postgres"
  }
}
