# Supabase database setup

Run migrations in timestamp order from the Supabase SQL Editor or Supabase CLI.
The aptitude-related migrations listed below are historical and remain in this
chain only to preserve existing migration history. The final
`202611090002_remove_aptitude_assessments.sql` migration drops their schema and
permanently deletes aptitude data. The final database no longer includes
aptitude tests or their results.

1. `202610240001_initial_schema.sql`
2. `202610240002_security_policies.sql`
3. `202610240003_public_application.sql`
4. `202610240004_resume_storage.sql`
5. `202610260001_job_requirements.sql`
6. `202610260002_workspace_profile_and_account_deletion.sql`
7. `202610260003_candidate_management_schema.sql`
8. `202610260004_public_application_status_and_duplicates.sql`
9. `202610260005_candidate_workspace_email_normalized_unique.sql`
10. `202610260006_recruiter_decisions_and_interviews.sql`
11. `202610290001_screening_pipeline.sql`
12. `202610290002_account_deletion_and_screening_indexes.sql`
13. `202610290003_aptitude_assessment_schema.sql`
14. `202610290004_application_resume_versions.sql`
15. `202610290005_status_default_and_deletion_indexes.sql`
16. `202610290006_application_notes.sql`
17. `202610290007_aptitude_assessment_workflow.sql`
18. `202611020001_application_stage_history_and_interviews.sql`
19. `202611020002_aptitude_assessment_foundation_completion.sql`
20. `202611020003_coding_assessment_and_email_delivery.sql`
21. `202611020005_proofhire_live_schema_completion.sql`
22. `202611030001_deterministic_screening_configuration.sql`
23. `202611030002_score_aptitude_timeouts.sql`
24. `202611030003_automated_aptitude_delivery.sql`
25. `202611090001_resume_profile_and_deterministic_screening.sql`
26. `202611090002_remove_aptitude_assessments.sql`

Migration `202610260002_workspace_profile_and_account_deletion.sql` adds
company profile fields and a 15-day account deletion queue. A returning
recruiter can cancel a pending request by signing in again. Once the grace
period passes, the purge worker removes that recruiter's account. Shared
workspace records are retained and attributed to another active member; when
the recruiter was the only workspace member, the workspace data and its
candidate resume files are deleted.

The candidate-management migration adds LinkedIn URLs, allows candidates to
omit email, and aligns application statuses to `new`, `screening`,
`shortlisted`, `rejected`, `interview`, and `hired`. Existing `applied` and
`selected` statuses are migrated to `new` and `hired`.

The public-application migration updates the six-argument submission function
to use the `new` application status, match legacy candidate emails without
case or surrounding whitespace differences, and avoid changing candidate
details for duplicate submissions. The public form uploads the resume before
calling the function, so a duplicate or failed submission can leave an
unreferenced object in the private bucket; this migration does not grant
anonymous delete access or otherwise clean up those uploads.

The normalized-email migration adds a partial unique expression index on
`(workspace_id, lower(btrim(email)))` for non-null candidate emails. It does
not modify candidate or application rows. Index creation fails transactionally
if normalized duplicates exist when the migration runs.

The recruiter-decision and interview migration creates an append-only
workspace-scoped decision history and interview scheduling/feedback records.
The decision RPC updates the existing application stage and writes the
corresponding recruiter decision atomically. Interview records are separate
from application stages. Interview table grants limit updates to interview
status, outcome, and feedback; immutable workspace, application, and creator
fields are not updateable by clients. This migration does not send email,
create invitations, or grant anonymous access. It must be applied before the
corresponding decision-history and interview-management UI can persist data.

The screening migration adds the persistent AI-screening queue, assessment
history, recruiter RPCs, and service-role worker operations. The next migration
allows account deletion to retain decision and interview history by clearing a
deleted user's actor reference, and adds an index for expired screening leases.
The resume-version migration backfills application resume paths into an
application-scoped history table, captures future resume-path changes, and
associates newly queued screening work with the exact resume version while
retaining `applications.resume_path` for existing callers.

The status-default migration changes `applications.status` from the original
`applied` default to the currently allowed `new` value and indexes pending and
stale-processing account-deletion requests.

The application-notes migration provides an append-only recruiter note stream
with workspace/application foreign-key checks. A recruiter-notes UI is not
implemented yet.

The application-stage and interview migration records the known current stage
for existing applications without fabricating earlier transitions, then
captures future status changes. It adds interview schedule-change history,
interviewer assignments, structured feedback, and scheduling metadata without
replacing existing interview records. Historical aptitude migrations added
assessment setup and automated follow-up; the final removal migration drops
those aptitude objects and their data while retaining interviews and
deterministic resume screening.

The coding migration adds immutable challenge versions, private test cases and
submission source, job configuration, invitations/attempts, and a lease-based
evaluation queue. It deliberately does not execute submitted code or implement
a runner. The email migration tracks invitations and scheduling notices in an
idempotent delivery queue; it deliberately does not connect to an email
provider or claim that a message was sent. The final application summary view
reports screening, coding, and interview results and does not calculate a
composite hiring score.

See [`../database-architecture.md`](../database-architecture.md) for the
repository audit, relationships, access matrix, migration caveats, and safe
fresh-test-database procedure. The migrations have not been replayed against a
local database or verified against the live Supabase project.

## Fresh local test database

The repository has no Supabase project link metadata. Use a dedicated local
Supabase instance with Docker Desktop; do not link or point these commands at
production. Check `supabase status` and confirm the database endpoint is
loopback before applying or inspecting migrations.

```powershell
npx supabase --version
npx supabase start
npx supabase status
npx supabase db reset
npx supabase migration list --local
```

`db reset` rebuilds the local database and deletes its local data. Run it only
for a disposable local test instance with no data to preserve. It does not
validate a linked hosted project. For a dedicated hosted test project, first
verify its project reference in the Supabase dashboard, then use the CLI's
`db push --dry-run` before any push and inspect the resulting plan. Do not use
`--linked` with `db reset`, and do not apply these migrations to production.

After migrations apply locally, inspect the schema, constraints, grants, RLS,
functions, and storage policies using the read-only verification queries in
the architecture document. Verify public application submission with a test
job and disposable candidate data. The local database test does not verify
external email, OCR, or hosted Storage behavior. Resume screening uses a
deterministic engine and does not require an external AI provider.

## Deploy and schedule account deletion

The purge worker uses the Supabase service-role key only in the Edge Function
runtime. Never put that key in frontend code.

1. Deploy the function:

   ```powershell
   supabase functions deploy purge-account-deletions
   ```

2. Generate a long random secret and configure the deployed function:

   ```powershell
   supabase secrets set "ACCOUNT_DELETION_CRON_SECRET=<long-random-secret>"
   ```

3. Enable the `pg_cron`, `pg_net`, and Vault extensions in the Supabase
   dashboard. In the SQL Editor, store the project URL and the same cron secret
   in Vault, then schedule the worker hourly. Replace both placeholders with
   your values; do not commit real secrets:

   ```sql
   select vault.create_secret(
     'https://<project-ref>.supabase.co',
     'proofhire_project_url'
   );

   select vault.create_secret(
     '<same-long-random-secret-configured-for-the-function>',
     'proofhire_account_deletion_cron_secret'
   );

   select cron.schedule(
     'proofhire-purge-account-deletions',
     '0 * * * *',
     $$
       select net.http_post(
         url := (
           select decrypted_secret
           from vault.decrypted_secrets
           where name = 'proofhire_project_url'
         ) || '/functions/v1/purge-account-deletions',
         headers := jsonb_build_object(
           'Content-Type', 'application/json',
           'x-cron-secret', (
             select decrypted_secret
             from vault.decrypted_secrets
             where name = 'proofhire_account_deletion_cron_secret'
           )
         ),
         body := '{}'::jsonb
       );
     $$
   );
   ```

The scheduled function claims due requests and retries interrupted deletions.
Review the Edge Function logs and the cron job's run history when operating
account deletion in production.
