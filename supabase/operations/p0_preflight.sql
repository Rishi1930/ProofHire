-- Read-only preflight before applying the ProofHire P0 migrations:
--   1. 202610260002_workspace_profile_and_account_deletion.sql
--   2. 202610290006_application_notes.sql
--   3. 202611030001_deterministic_screening_configuration.sql
--
-- Run this in the Supabase SQL Editor against the live project and read the
-- output. Nothing here writes data. Stop and investigate if any row in the
-- "blocking" section reports an unexpected value.

-- 1. Core objects the migrations depend on must already exist.
with required(schema_name, object_name, object_kind) as (values
  ('public', 'workspaces', 'table'),
  ('public', 'workspace_members', 'table'),
  ('public', 'jobs', 'table'),
  ('public', 'candidates', 'table'),
  ('public', 'applications', 'table'),
  ('public', 'application_screening_jobs', 'table'),
  ('public', 'application_screening_assessments', 'table'),
  ('public', 'application_resume_versions', 'table')
)
select
  'required_object' as check_name,
  schema_name || '.' || object_name as object_name,
  to_regclass(format('%I.%I', schema_name, object_name)) is not null as present
from required
order by present, object_name;

-- 2. Target objects for the three migrations. The tables are expected to be
--    absent and the job columns are expected to be absent. A "true" here means
--    that migration is already partly applied and must be reviewed, not re-run
--    blindly.
select
  'target_absent' as check_name,
  to_regclass('public.account_deletion_requests') is not null as account_deletion_requests_exists,
  to_regclass('public.application_notes') is not null as application_notes_exists,
  to_regclass('public.job_screening_requirements') is not null as job_screening_requirements_exists,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'jobs'
      and column_name = 'minimum_screening_percentage'
  ) as minimum_screening_percentage_exists,
  exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'jobs'
      and column_name = 'screening_weights'
  ) as screening_weights_exists,
  to_regprocedure('public.replace_job_screening_requirements(uuid, jsonb)') is not null
    as replace_job_screening_requirements_exists;

-- 3. Columns and helpers the migrations read. Any false value is a blocker.
with required_columns(table_name, column_name) as (values
  ('workspaces', 'name'),
  ('workspaces', 'created_by'),
  ('jobs', 'workspace_id'),
  ('jobs', 'required_skills'),
  ('jobs', 'preferred_skills'),
  ('jobs', 'minimum_experience'),
  ('applications', 'workspace_id'),
  ('applications', 'job_id'),
  ('applications', 'candidate_id'),
  ('applications', 'status'),
  ('applications', 'resume_path'),
  ('applications', 'created_by'),
  ('candidates', 'workspace_id'),
  ('candidates', 'resume_path')
)
select
  'required_column' as check_name,
  table_name || '.' || column_name as column_name
from required_columns
where not exists (
  select 1 from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = required_columns.table_name
    and c.column_name = required_columns.column_name
)
order by column_name;

select
  'required_function' as check_name,
  routine_name,
  to_regprocedure('public.' || routine_name || '()') is not null
    or to_regprocedure('public.' || routine_name || '(uuid)') is not null
    or to_regprocedure('public.' || routine_name || '(uuid,text[])') is not null
    as present
from (values ('is_workspace_member'), ('has_workspace_role'), ('set_updated_at')) as f(routine_name);

-- 4. Data that migration 202611030001 reads when it backfills screening input
--    fingerprints. Non-zero counts are fine; they just mean the backfill has
--    work to do.
select 'jobs_total' as metric, count(*) as value from public.jobs
union all
select 'applications_total', count(*) from public.applications
union all
select 'screening_jobs_total', count(*) from public.application_screening_jobs
union all
select 'screening_assessments_total', count(*) from public.application_screening_assessments
union all
select 'resume_versions_total', count(*) from public.application_resume_versions;

-- 5. Application statuses must already use the six supported values, otherwise
--    the screening requirement migration cannot reason about them.
select status, count(*) as applications
from public.applications
group by status
order by applications desc;

-- 6. Private resume storage. If the bucket is missing, run
--    202610240004_resume_storage.sql before relying on resumes or screening.
select
  bucket.id,
  bucket.public,
  bucket.file_size_limit,
  bucket.allowed_mime_types
from storage.buckets bucket
where bucket.id = 'candidate-resumes';

-- 7. Aptitude objects are expected to remain after P0. They are unused by the
--    application and are removed later, not as part of this step.
select
  to_regclass('public.aptitude_attempts') is not null as aptitude_attempts_exists,
  to_regclass('public.aptitude_invitations') is not null as aptitude_invitations_exists;
