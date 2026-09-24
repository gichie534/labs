// Command migrator carries the three pieces of this lab's logic that no off-the-shelf tool provides:
// seeding the source, migrating logs, and verifying the result.
//
// ONE BINARY, THREE SUBCOMMANDS — because a Kubernetes ConfigMap cannot hold subdirectories (its keys
// may not contain "/"), so three separate main packages could not be delivered this way. Sharing one
// package turns out to be the better shape anyway: the HTTP and multiset helpers are written once
// instead of three times.
//
// # HOW IT RUNS, AND WHY THERE IS NO IMAGE BUILD
//
// These sources are mounted into a stock `golang` image from a ConfigMap and executed with `go run`.
// That keeps the property that matters for a two-cloud lab: no container registry, no push step, and no
// pull credentials in either cluster. What you read in deploy/migrator/ is exactly what runs.
//
// The cost is a few seconds of compilation at the start of each Job, and a larger base image than a
// prebuilt binary would need. The alternative — building an image and pushing it to ECR *and* Artifact
// Registry — is more production-shaped but adds two registries, their IAM, and a build step to a lab
// about data migration. `task build` compiles locally so a syntax or type error surfaces before any
// cloud resource is touched.
//
// Only the metric migration has no code here: `vmctl vm-native` does that job, and this binary exists
// only where no tool does.
package main

import (
	"fmt"
	"os"
	"strconv"
)

const usage = `migrator — supporting logic for the EKS -> GKE VictoriaMetrics/VictoriaLogs migration

Usage:
  migrator fields         inspect a VictoriaLogs instance read-only: field names, values, filter dry run
  migrator seed           write a deterministic, backdated dataset into the SOURCE
  migrator migrate-logs   copy logs from the SOURCE to the TARGET (metrics are vmctl's job)
  migrator verify         diff the migrated dataset exactly and publish the verdict as metrics

Each subcommand is configured entirely by environment variables; see the corresponding source file.

Run "fields" before "migrate-logs" against anything you care about: a filter naming a field that does not
exist matches nothing, and the migration then reports success having moved no data.
`

func main() {
	if len(os.Args) < 2 {
		fmt.Fprint(os.Stderr, usage)
		os.Exit(2)
	}

	var code int
	var err error

	switch os.Args[1] {
	case "seed":
		code, err = runSeed()
	case "migrate-logs":
		code, err = runMigrateLogs()
	case "fields":
		code, err = runFields()
	case "verify":
		code, err = runVerify()
	case "-h", "--help", "help":
		fmt.Print(usage)
		return
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n\n%s", os.Args[1], usage)
		os.Exit(2)
	}

	if err != nil {
		fmt.Fprintf(os.Stderr, "\nERROR: %v\n", err)
		if code == 0 {
			code = 1
		}
	}
	os.Exit(code)
}

// logf writes progress to stdout. Job logs are the primary interface for all three subcommands, so
// output is deliberately plain and line-oriented.
func logf(format string, args ...any) {
	fmt.Printf(format+"\n", args...)
}

// mustEnv returns a required environment variable or fails with a message naming it. A missing variable
// is a wiring mistake in the Job manifest, and saying which one is missing is the whole value here.
func mustEnv(key string) (string, error) {
	v := os.Getenv(key)
	if v == "" {
		return "", fmt.Errorf("%s must be set", key)
	}
	return v, nil
}

func envInt(key string, fallback int) (int, error) {
	raw := os.Getenv(key)
	if raw == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("%s must be an integer, got %q", key, raw)
	}
	return n, nil
}

func envIs(key, want string) bool {
	return os.Getenv(key) == want
}
