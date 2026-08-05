# Production cutover runbook

This lab's `task migrate` is a **downtime** migration (dump → restore). The steps below adapt it to
a real production cutover and give a rollback path. Treat it as a checklist, not a script.

## Pre-flight (days before)

- [ ] Run the whole lab end-to-end against a **copy** of production data to rehearse and time it.
- [ ] Confirm every extension the app uses is on Cloud SQL's supported list (see section 8 of
      `db/verify/migration_verification.sql` run against the source).
- [ ] Confirm no object depends on a real `SUPERUSER`, event triggers, or `rds_*`-owned objects that
      Cloud SQL cannot host. Reassign any such ownership on the source first.
- [ ] Size the target instance (`tier`) for production; enable the private IP path and remove the
      public IP (see ADR 0002); provision the jump host / VPN.
- [ ] Capture a baseline parity snapshot (`db/verify/migration_verification.sql`) of the source.

## Cutover window

1. [ ] **Quiesce writes** to the source (stop app writers / put the app in maintenance mode).
2. [ ] Take a final logical dump: `db/migrate/10_dump.sh`.
3. [ ] Create roles on the target: `db/migrate/20_load_roles.sh`.
4. [ ] Restore: `db/migrate/30_restore.sh`.
5. [ ] Reassign ownership: `db/migrate/40_reassign_owners.sh`.
6. [ ] **Advance sequences** and refresh materialized views: `db/migrate/50_finalize.sh`. (Critical
       after any incremental/CDC sync — a stale sequence hands out a colliding id on the first
       insert. Section 7 of the verification SQL flags this.)
7. [ ] Set real per-role passwords on the target (edit `gen_passwords.sql` usage to supply each
       role's own secret, or `ALTER ROLE` individually).
8. [ ] **Verify**: `task verify` (strict parity) plus a manual read of
       `db/verify/migration_verification.sql` diff for extensions/privileges.
9. [ ] Smoke-test the application against the target (read + write paths).
10. [ ] Repoint the application's connection string to Cloud SQL; resume writes.

## Rollback

- Until step 10, the source is untouched and authoritative — abort by resuming writes on the source
  and discarding the target.
- After step 10, roll back by repointing the app to the source **only if** no writes have landed on
  the target you cannot afford to lose. Beyond that point, roll *forward* (fix on the target).

## Lower-downtime variants

For a database too large for a dump-window cutover, keep every step above but replace steps 1–4 with
a continuous-replication approach (GCP DMS, or pglogical using the `rds.logical_replication`
parameter the `aws/rds-postgres` module exposes). Steps 5–10 — ownership, sequences, passwords,
verification, cutover — are unchanged and remain necessary.
