-- Read-only preflight for the standalone live-schema completion migration.
-- Run against the confirmed ProofHire production project before the migration.

-- Core tables, target-object collisions, and required helpers.
with required_objects(schema_name, object_name, object_kind) as (
  values
    ('public', 'workspaces', 'table'),
    ('public', 'workspace_members', 'table'),
    ('public', 'jobs', 'table'),
    ('public', 'candidates', 'table'),
    ('public', 'applications', 'table'),
    ('public', 'application_decision_events', 'new table'),
    ('public', 'application_resume_versions', 'new table'),
    ('public', 'application_screening_jobs', 'new table'),
    ('public', 'application_screening_assessments', 'new table'),
    ('public', 'aptitude_tests', 'new table'),
    ('public', 'aptitude_attempts', 'new table'),
    ('public', 'coding_challenges', 'new table'),
    ('public', 'coding_attempts', 'new table'),
    ('public', 'interview_records', 'new table'),
    ('public', 'application_stage_history', 'new table'),
    ('public', 'email_delivery_jobs', 'new table'),
    ('public', 'application_recruitment_stage_summary', 'new view')
)
select
  object_kind,
  schema_name || '.' || object_name as object_name,
  to_regclass(format('%I.%I', schema_name, object_name)) is not null as exists
from required_objects
order by object_kind, object_name;

-- These counts must be zero before adding workspace-scoped foreign keys.
select 'application_workspace_mismatch' as check_name, count(*) as issue_count
from public.applications application
left join public.jobs job
  on job.id = application.job_id
left join public.candidates candidate
  on candidate.id = application.candidate_id
where job.id is null
   or candidate.id is null
   or job.workspace_id is distinct from application.workspace_id
   or candidate.workspace_id is distinct from application.workspace_id
union all
select 'unsupported_application_status', count(*)
from public.applications
where status not in ('new', 'screening', 'shortlisted', 'rejected', 'interview', 'hired');

-- These live columns are consumed by the bundled screening and resume-history
-- routines. Missing columns require a reviewed compatibility change first.
with required_columns(table_name, column_name) as (
  values
    ('jobs', 'required_skills'),
    ('jobs', 'preferred_skills'),
    ('jobs', 'minimum_experience'),
    ('jobs', 'employment_type'),
    ('jobs', 'workplace_type'),
    ('applications', 'workspace_id'),
    ('applications', 'job_id'),
    ('applications', 'candidate_id'),
    ('applications', 'source'),
    ('applications', 'resume_path'),
    ('applications', 'created_by'),
    ('candidates', 'workspace_id'),
    ('candidates', 'resume_path')
)
select required_columns.table_name, required_columns.column_name
from required_columns
where not exists (
  select 1
  from information_schema.columns column_info
  where column_info.table_schema = 'public'
    and column_info.table_name = required_columns.table_name
    and column_info.column_name = required_columns.column_name
)
order by required_columns.table_name, required_columns.column_name;

-- The migration only removes these known, workspace-member-wide write policies
-- after verifying that recruiter/admin alternatives remain in place.
select schemaname, tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and policyname in (
    'Members can create workspace applications',
    'Members can update workspace applications',
    'Members can delete workspace applications',
    'Members can create workspace candidates',
    'Members can update workspace candidates',
    'Members can delete workspace candidates',
    'Recruiters can create applications',
    'Recruiters can update applications',
    'Workspace admins can delete applications',
    'Recruiters can create candidates',
    'Recruiters can update candidates',
    'Workspace admins can delete candidates'
  )
order by tablename, policyname;

-- Expected to be absent in the audited live state. Any pre-existing private
-- schema or target object needs manual reconciliation before deployment.
select
  to_regnamespace('proofhire_private') is not null as private_schema_exists,
  to_regclass('public.application_recruitment_stage_summary') is not null
    as summary_view_exists,
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.applications'::regclass
      and conname in (
        'proofhire_applications_job_workspace_fk',
        'proofhire_applications_candidate_workspace_fk'
      )
  ) as target_application_workspace_constraint_exists,
  to_regclass('storage.buckets') is not null as storage_buckets_accessible,
  exists (
    select 1
    from storage.buckets
    where id = 'candidate-resumes'
      and public = false
  ) as private_resume_bucket_exists;
