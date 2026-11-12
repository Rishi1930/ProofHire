# P0 runbook — bring the live Supabase schema up to the application code

Project: `gooffgqrwvvcjsfgfaev` (ProofHire).
Verified missing on 12 November 2026. Until these steps are done, the deployed
frontend fails on **Jobs & Hiring** and **create/edit job**, account deletion
fails in Settings, and the screening configuration UI has no storage behind it.

This runbook applies four migrations: three aptitude-free fixes plus the new
technical interview engine. It deliberately does not touch the aptitude schema
or the bundled completion migration.

## What is being applied

| Order | File | Adds |
| --- | --- | --- |
| 1 | `supabase/migrations/202610260002_workspace_profile_and_account_deletion.sql` | company profile columns on `workspaces`, `account_deletion_requests`, request/cancel/claim RPCs |
| 2 | `supabase/migrations/202610290006_application_notes.sql` | `application_notes` table, index, RLS policies |
| 3 | `supabase/migrations/202611030001_deterministic_screening_configuration.sql` | `jobs.minimum_screening_percentage`, `jobs.screening_weights`, `job_screening_requirements`, `replace_job_screening_requirements`, screening queue functions |
| 4 | `supabase/migrations/202611120001_technical_interview_engine.sql` | interview question bank, sessions, answers, code drafts/submissions, proctoring events, recruiter RPCs and the service-role evaluation queue |

Each file is wrapped in `begin; … commit;`, so a failure rolls the whole file
back. Apply them one at a time and wait for success before starting the next.

## Do not run

- `202611030002_score_aptitude_timeouts.sql` and
  `202611030003_automated_aptitude_delivery.sql` — aptitude modules. The product
  no longer has aptitude, and the code for these features was removed.
- `202611020005_proofhire_live_schema_completion.sql` — the bundled migration
  already reflected in the live database.
- `202610260005_candidate_workspace_email_normalized_unique.sql` — the unique
  index fails if normalized duplicate candidate emails already exist. Review
  duplicates first if you ever want it.

## Step 1 — take a backup

1. Supabase Dashboard → the ProofHire project → **Database → Backups**.
2. Confirm a recent backup exists, or take a manual one. If the plan has
   point-in-time recovery, note the current timestamp; that is your rollback
   point.
3. Optional belt-and-braces export from a machine with `pg_dump`:

   ```bash
   pg_dump "postgresql://postgres:<password>@db.gooffgqrwvvcjsfgfaev.supabase.co:5432/postgres" \
     --schema=public --no-owner --no-privileges -f proofhire_pre_p0.sql
   ```

   Never commit that dump or put the password in a file in this repository.

## Step 2 — run the preflight

1. Dashboard → **SQL Editor** → **New query**.
2. Open [`p0_preflight.sql`](./p0_preflight.sql), paste the whole file, run it.
3. Expected output:
   - every `required_object` row is `present = true`,
   - `account_deletion_requests_exists`, `application_notes_exists`,
     `job_screening_requirements_exists`, `minimum_screening_percentage_exists`,
     `screening_weights_exists`, `replace_job_screening_requirements_exists`
     are all **false**,
   - the `required_column` and `required_function` result sets are empty,
   - the `candidate-resumes` storage row is returned with `public = false`.

Stop if any of those differ and send the output back before applying anything.

## Step 3 — apply the three migrations, in order

For each file, in this exact order:

1. SQL Editor → **New query**.
2. Copy the entire file contents and paste them.
3. **Run**. Wait for `Success. No rows returned`.
4. Only then move to the next file.

1. `202610260002_workspace_profile_and_account_deletion.sql`
2. `202610290006_application_notes.sql`
3. `202611030001_deterministic_screening_configuration.sql`
4. `202611120001_technical_interview_engine.sql`

Migration 3 is the large one; it recreates the screening queue functions and
backfills input fingerprints for existing jobs and applications. Migration 4
creates the technical interview engine. Both take a few seconds on a small
dataset. If migration 4 fails, nothing in that file is applied: send me the
error and the output of `p0_verify.sql`.

## Step 4 — verify

1. New query → paste [`p0_verify.sql`](./p0_verify.sql) → run.
2. Every boolean in the first result must be `true`.
3. `jobs` must now expose `minimum_screening_percentage` (`numeric`) and
   `screening_weights` (`jsonb`).
4. `jobs_minimum_screening_percentage_check` and `jobs_screening_weights_check`
   must appear in the constraint list.
5. All three new tables must show `rls_enabled = true`, with policies present
   and no `anon` grants on deal-sensitive tables.
6. The `candidate-resumes` bucket must be present, private, and 5 MiB-limited.
   If it is missing entirely, re-run
   `202610240004_resume_storage.sql` — it creates/updates the bucket with
   `on conflict (id) do update` and recreates its policies.

## Step 5 — storage check

If `storage.buckets` had no `candidate-resumes` row, run
`202610240004_resume_storage.sql` and then re-run step 4. Resume upload,
signed-URL viewing and resume screening all depend on that private bucket.

## Step 6 — redeploy the application

The frontend reads these at build time:

- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_PUBLISHABLE_KEY` (or the legacy `VITE_SUPABASE_ANON_KEY`)

Check the Vercel project has both set for Production and Preview, then
redeploy. Set the Go server/worker variables in the host's secret store, never
in a `VITE_` variable: `SUPABASE_URL`, `SUPABASE_ANON_KEY`,
`SUPABASE_SECRET_KEY`, and for email sending `EMAIL_PROVIDER`, `EMAIL_API_KEY`,
`EMAIL_FROM_ADDRESS`, `EMAIL_FROM_NAME`, `APP_BASE_URL`,
`RESEND_WEBHOOK_SECRET`.

## Step 7 — smoke test in the deployed app

1. Sign in as a recruiter and open **Jobs & Hiring** — the list must load with
   no `column jobs.minimum_screening_percentage does not exist` error.
2. Create a job with required skills, a minimum experience and an additional
   screening requirement line, then edit it and confirm the requirements reload.
3. Open **Resume Screening** and confirm the queue overview loads.
4. Open **Settings** and start (then cancel) an account deletion request.
5. Sign out and submit a public application against a published job with a
   resume, then confirm the application appears for the recruiter.
6. Open **Interviews → Open the technical interview engine**, add a question for a
   job, and create a session for a candidate. The candidate link is shown once.
7. Open that link in a private window: the full-screen gate must appear, the
   timer must start from the server, answers must survive a refresh, and a code
   submission must queue and then show a score once the runner worker is up.
   Without the runner worker it stays `queued` — that is expected.

## Rollback

- If a migration fails, nothing in that file is applied — fix the reported
  error and re-run that file only.
- If the schema is wrong after applying, restore the backup from step 1 or use
  PITR to the pre-change timestamp. Do not hand-edit applied migration files.

## Step 8 — run the interview runner host

The interview coding session needs a host with Docker (a small VPS, not Vercel):

```bash
docker pull python:3.12-alpine
CODE_RUNNER_ENABLED=true RUNNER_PREWARM_LANGUAGES=python \
  SUPABASE_URL=... SUPABASE_SECRET_KEY=... \
  go run ./backend/cmd/worker
```

Verify the sandbox itself on that host:

```bash
go test ./backend/runner -run TestPythonExecution -v
```

For email, set `EMAIL_PROVIDER=smtp` plus `SMTP_HOST`, `SMTP_PORT`,
`SMTP_SECURITY`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `EMAIL_FROM_ADDRESS`,
`EMAIL_FROM_NAME` and `APP_BASE_URL` in the worker's secret environment. The
worker logs `email delivery is disabled` when those values are rejected.

## Step 9 — create a challenge to test with (optional)

Challenge authoring has no screen yet. To exercise the coding session end to end,
run [`seed_demo_coding_challenge.sql`](./seed_demo_coding_challenge.sql) once in
the SQL Editor. It creates one published challenge with three test cases (one
visible sample, two hidden) in your first workspace and prints the version id the
recruiter UI will list. It is a test fixture, not candidate-facing content.

## Follow-ups this runbook does not cover

- Dropping the unused aptitude tables (planned, after interview data exists).
- Automatic interview invitation emails: sessions currently issue a copy-once
  link. Wiring the queue needs the `email_delivery_jobs` enqueue RPC that lives
  in the unapplied aptitude-delivery migration; it will be added in its own
  additive migration.
