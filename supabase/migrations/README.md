# Supabase database setup

Run migrations in timestamp order from the Supabase SQL Editor or Supabase CLI.

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

The latest migration adds company profile fields and a 15-day account
deletion queue. A returning recruiter can cancel a pending request by signing
in again. Once the grace period passes, the purge worker removes that
recruiter's account. Shared workspace records are retained and attributed to
another active member; when the recruiter was the only workspace member, the
workspace data and its candidate resume files are deleted.

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
