variable "project_id" {
  description = "Project in which to reserve the global address."
  type        = string
  nullable    = false
}

variable "name" {
  description = "Name of the reserved global address. The Gateway references this name via spec.addresses[].value (type NamedAddress)."
  type        = string
  nullable    = false
}

# Global external static IP for the global external Application Load Balancer that the
# gke-l7-global-external-managed Gateway provisions.
resource "google_compute_global_address" "gateway" {
  name         = var.name
  project      = var.project_id
  address_type = "EXTERNAL"
}

output "name" {
  description = "Name of the reserved address — the value for the Gateway's NamedAddress."
  value       = google_compute_global_address.gateway.name
}

output "address" {
  description = "The reserved global IPv4 address, published as the child zone's apex A record."
  value       = google_compute_global_address.gateway.address
}
