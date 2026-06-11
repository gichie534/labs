---
inclusion: always
---

# Product Overview — Cloud Engineering Labs

This repository is a personal cloud-engineering **study and practice lab**. Each lab is a
self-contained, reproducible, version-pinned "vertical slice" that provisions real
infrastructure and (where relevant) deploys a sample application to it.

## Goals (the "why" behind every decision)

- **Reproducible** — any lab can be destroyed and recreated identically from a clean checkout.
- **Trackable** — every lab records what it does, why, and what was learned.
- **Versioned** — infrastructure pins exact versions (Terraform, providers, shared modules) so a
  lab rebuilds the same way months later.
- **Modular & composable** — reusable building blocks live in a separate modules repo; labs
  compose them and can be combined.

## Two-repository model

- **Modules repo** (`gichie534/infrastructure-catalog`) — reusable, versioned Terraform modules,
  released via semantic git tags (e.g. `v1.2.0`). This is the **only** place reusable infra lives.
- **Labs repo** (this repo) — self-contained practice examples. Labs **consume** modules by a
  pinned git ref; they never copy module source.

## What a "lab" is

A lab is the unit of work. Opening one lab folder should reveal **everything** it involves: the
infrastructure, the application, the deployment, the decisions, and a runbook to stand it all up
with one command.

## Guiding engineering principles

High cohesion, low coupling. A lab owns everything specific to it; anything reused by a second lab
is promoted to the modules repo (rule of three). Keep clean separation between reusable modules
(no environment knowledge) and live composition (wiring + inputs).
