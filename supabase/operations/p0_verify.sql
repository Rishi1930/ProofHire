-- Read-only verification after applying the ProofHire P0 migrations:
--   1. 202610260002_workspace_profile_and_account_deletion.sql
--   2. 202610290006_application_notes.sql
--   3. 202611030001_deterministic_screening_configuration.sql
--
-- Every "present" column below must be true before the frontend is redeployed.

-- 1. Tables, columns and routines the frontend and worker now depend on.
select
  to_regclass('public.account_deletion_requests') is not null as account_deletion_requests,
  to_regclass('public.application_notes') is not null as application_notes,
  to_regclass('public.job_screening_requirements') is not null as job_screening_requirements,
  to_regprocedure('public.replace_job_screening_requirements(uuid, jsonb)') is not null
    as replace_job_screening_requirements,
  to_regprocedure('public.request_account_deletion()') is not null
    as request_account_deletion,
  to_regprocedure('public.enqueue_application_screening(uuid)') is not null
    as enqueue_application_screening;

select column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public' and table_name = 'jobs'
  and column_name in ('minimum_screening_percentage', 'screening_weights')
order by column_name;

-- 2. Constraints and defaults added by the migrations.
select conname, pg_get_constraintdef(oid) as definition
from pg_constraint
where conrelid in (
  'public.jobs'::regclass,
  'public.job_screening_requirements'::regclass
)
  and conname in (
    'jobs_minimum_screening_percentage_check',
    'jobs_screening_weights_check',
    'job_screening_requirements_priority_check',
    'job_screening_requirements_workspace_job_fk'
  )
order by conname;

-- 3. RLS must be enabled on every new table, and clients must only get the
--    grants the migrations intend.
select c.relname as table_name, c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname in (
    'account_deletion_requests',
    'application_notes',
    'job_screening_requirements'
  )
order by c.relname;

select table_name, grantee, string_agg(privilege_type, ', ' order by privilege_type) as privileges
from information_schema.role_table_grants
where table_schema = 'public'
  and table_name in (
    'account_deletion_requests',
    'application_notes',
    'job_screening_requirements'
  )
  and grantee in ('anon', 'authenticated', 'service_role')
group by table_name, grantee
order by table_name, grantee;

-- 4. Policies created for the new tables.
select tablename, policyname, cmd, roles
from pg_policies
where schemaname = 'public'
  and tablename in (
    'account_deletion_requests',
    'application_notes',
    'job_screening_requirements'
  )
order by tablename, policyname;

-- 5. Screening triggers and functions that must exist for automatic queueing.
select trigger_name, event_object_table, action_timing, event_manipulation
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name in (
    'applications_queue_screening',
    'jobs_requeue_screening_on_criteria_change'
  )
order by trigger_name;

-- 6. Resume storage must stay private.
select id, public, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'candidate-resumes';

-- 7. A quick health read of the workspace data the screener will consume.
select
  (select count(*) from public.jobs) as jobs,
  (select count(*) from public.jobs where required_skills <> '{}') as jobs_with_required_skills,
  (select count(*) from public.jobs where minimum_screening_percentage is null) as jobs_without_threshold,
  (select count(*) from public.job_screening_requirements) as screening_requirements;


-- 8. Technical interview engine (migration 202611120001).
select
  to_regclass('public.interview_sessions') is not null as interview_sessions,
  to_regclass('public.interview_questions') is not null as interview_questions,
  to_regclass('public.interview_answers') is not null as interview_answers,
  to_regclass('public.interview_code_drafts') is not null as interview_code_drafts,
  to_regclass('public.interview_code_submissions') is not null as interview_code_submissions,
  to_regclass('public.interview_proctor_events') is not null as interview_proctor_events,
  to_regprocedure('public.create_interview_session(uuid, uuid[], uuid[], integer, integer, numeric)') is not null
    as create_interview_session,
  to_regprocedure('public.interview_candidate_state(text)') is not null
    as interview_candidate_state,
  to_regprocedure('public.claim_interview_code_submissions(text, integer)') is not null
    as claim_interview_code_submissions,
  to_regprocedure('public.complete_interview_code_submission(uuid, uuid, text, numeric, integer, integer, jsonb, text)') is not null
    as complete_interview_code_submission;

select c.relname as table_name, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'interview_%'
order by c.relname;

-- Candidate RPCs must be callable by anon (token mediated) but the worker RPCs
-- must not be.
select routine_name, grantee
from information_schema.routine_privileges
where routine_schema = 'public'
  and routine_name in (
    'interview_candidate_state',
    'interview_submit_code',
    'claim_interview_code_submissions',
    'complete_interview_code_submission'
  )
  and grantee in ('anon', 'authenticated', 'service_role')
order by routine_name, grantee;

select indexname from pg_indexes
where schemaname = 'public' and indexname = 'idx_interview_sessions_one_active';
