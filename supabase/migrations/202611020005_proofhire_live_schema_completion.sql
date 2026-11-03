-- Forward-only completion migration for the audited live ProofHire baseline.
-- This bundles the reviewed feature migrations in dependency order because
-- the remote migration ledger is absent. It does not replay the core schema.
-- Apply only after the companion preflight succeeds and a verified backup exists.

begin;

do $preflight$
declare
  object_name text;
  routine_name text;
  policy_row record;
  policy_expression text;
begin
  foreach object_name in array array[
    'workspaces',
    'workspace_members',
    'jobs',
    'candidates',
    'applications'
  ]
  loop
    if to_regclass(format('public.%I', object_name)) is null then
      raise exception 'Required live core table public.% is missing.', object_name;
    end if;
  end loop;

  if to_regprocedure('public.is_workspace_member(uuid)') is null
     or to_regprocedure('public.has_workspace_role(uuid,text[])') is null
     or to_regprocedure('public.set_updated_at()') is null then
    raise exception 'Required live workspace/security helper functions are missing.';
  end if;

  if exists (
    select 1
    from (values
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
    ) as required(table_name, column_name)
    where not exists (
      select 1
      from information_schema.columns column_info
      where column_info.table_schema = 'public'
        and column_info.table_name = required.table_name
        and column_info.column_name = required.column_name
    )
  ) then
    raise exception
      'A required live job/application/candidate column is missing; reconcile the schema manually.';
  end if;

  if not exists (
    select 1
    from pg_constraint constraint_row
    where constraint_row.conrelid = 'public.workspace_members'::regclass
      and constraint_row.contype = 'c'
      and pg_get_constraintdef(constraint_row.oid) like '%admin%'
      and pg_get_constraintdef(constraint_row.oid) like '%recruiter%'
  ) then
    raise exception
      'The live workspace role constraint does not permit the expected admin/recruiter roles.';
  end if;

  if to_regnamespace('proofhire_private') is not null then
    raise exception
      'Schema proofhire_private already exists; reconcile it manually before deployment.';
  end if;
  if to_regclass('public.application_recruitment_stage_summary') is not null then
    raise exception
      'The recruitment summary view already exists; reconcile it manually before deployment.';
  end if;
  if exists (
    select 1
    from pg_constraint constraint_row
    where constraint_row.conrelid = 'public.applications'::regclass
      and constraint_row.conname in (
        'proofhire_applications_job_workspace_fk',
        'proofhire_applications_candidate_workspace_fk'
      )
  ) then
    raise exception
      'A target application workspace constraint already exists; reconcile it manually.';
  end if;

  foreach routine_name in array array[
    'capture_application_resume_version',
    'capture_application_stage_history',
    'capture_email_delivery_status',
    'capture_interview_schedule_history',
    'claim_application_screening_job',
    'claim_coding_evaluation_jobs',
    'claim_email_delivery_jobs',
    'complete_application_screening_job',
    'complete_coding_evaluation_job',
    'complete_email_delivery_job',
    'create_aptitude_invitation',
    'enqueue_application_screening',
    'enqueue_manual_aptitude_invitation_email',
    'enqueue_manual_coding_invitation_email',
    'enqueue_manual_interview_invitation_email',
    'enqueue_manual_interview_update_email',
    'fail_application_screening_job',
    'fail_coding_evaluation_job',
    'fail_email_delivery_job',
    'get_application_screening_overview',
    'get_aptitude_attempt_question_scores',
    'get_aptitude_candidate_session',
    'get_coding_test_cases',
    'link_screening_job_resume_version',
    'mark_email_delivery_delivered',
    'pause_application_screening_jobs',
    'prevent_published_aptitude_content_changes',
    'prevent_published_aptitude_version_changes',
    'prevent_published_coding_test_case_changes',
    'prevent_published_coding_version_changes',
    'publish_aptitude_test_version',
    'publish_coding_challenge_version',
    'queue_coding_evaluation',
    'queue_screening_for_application',
    'queue_screening_for_job',
    'record_application_decision',
    'record_aptitude_candidate_event',
    'request_application_screening',
    'resume_application_screening_jobs',
    'resume_coding_evaluation_jobs',
    'save_aptitude_answer_key',
    'save_aptitude_candidate_answer',
    'save_coding_submission',
    'save_coding_test_case',
    'set_interview_cancelled_at',
    'start_aptitude_candidate_attempt',
    'submit_aptitude_candidate_attempt',
    'validate_aptitude_attempt',
    'validate_aptitude_invitation',
    'validate_coding_attempt',
    'validate_coding_invitation'
  ]
  loop
    if exists (
      select 1
      from pg_proc routine
      join pg_namespace routine_schema on routine_schema.oid = routine.pronamespace
      where routine_schema.nspname = 'public'
        and routine.proname = routine_name
    ) then
      raise exception
        'Target routine public.% already exists; reconcile it instead of replacing it.',
        routine_name;
    end if;
  end loop;

  foreach object_name in array array[
    'application_decision_events',
    'application_resume_versions',
    'job_screening_criteria',
    'application_screening_jobs',
    'application_screening_assessments',
    'aptitude_tests',
    'aptitude_test_versions',
    'aptitude_questions',
    'aptitude_question_options',
    'aptitude_invitations',
    'aptitude_attempts',
    'aptitude_answers',
    'aptitude_monitoring_events',
    'job_aptitude_assessments',
    'aptitude_attempt_questions',
    'coding_challenges',
    'coding_challenge_versions',
    'job_coding_assessments',
    'coding_invitations',
    'coding_attempts',
    'coding_submissions',
    'coding_question_results',
    'coding_evaluation_jobs',
    'interview_records',
    'interview_schedule_events',
    'interview_assignments',
    'interview_feedback',
    'interview_feedback_criteria',
    'application_stage_history',
    'email_delivery_jobs',
    'email_delivery_attempts'
  ]
  loop
    if to_regclass(format('public.%I', object_name)) is not null then
      raise exception
        'Target object public.% already exists; reconcile it instead of replaying this migration.',
        object_name;
    end if;
  end loop;

  if exists (
    select 1
    from public.applications application
    left join public.jobs job on job.id = application.job_id
    left join public.candidates candidate on candidate.id = application.candidate_id
    where job.id is null
       or candidate.id is null
       or job.workspace_id is distinct from application.workspace_id
       or candidate.workspace_id is distinct from application.workspace_id
  ) then
    raise exception
      'Applications contain missing or cross-workspace job/candidate references; resolve them manually.';
  end if;

  if exists (
    select 1
    from public.applications
    where status not in ('new', 'screening', 'shortlisted', 'rejected', 'interview', 'hired')
  ) then
    raise exception
      'Applications contain statuses unsupported by stage history; reconcile without changing status data.';
  end if;

  for policy_row in
    select *
    from pg_policies
    where schemaname = 'public'
      and policyname in (
        'Members can create workspace applications',
        'Members can update workspace applications',
        'Members can delete workspace applications',
        'Members can create workspace candidates',
        'Members can update workspace candidates',
        'Members can delete workspace candidates'
      )
  loop
    if policy_row.roles::text <> '{authenticated}' then
      raise exception 'Unexpected roles on policy %.', policy_row.policyname;
    end if;

    policy_expression := regexp_replace(
      lower(coalesce(policy_row.qual, policy_row.with_check, '')),
      '[[:space:]]',
      '',
      'g'
    );

    if policy_row.cmd = 'DELETE' then
      if policy_expression <> 'is_workspace_member(workspace_id)' then
        raise exception 'Unexpected definition for policy %.', policy_row.policyname;
      end if;
    elsif policy_row.cmd = 'UPDATE' then
      if regexp_replace(lower(coalesce(policy_row.qual, '')), '[[:space:]]', '', 'g')
           <> 'is_workspace_member(workspace_id)'
         or regexp_replace(lower(coalesce(policy_row.with_check, '')), '[[:space:]]', '', 'g')
           <> 'is_workspace_member(workspace_id)' then
        raise exception 'Unexpected definition for policy %.', policy_row.policyname;
      end if;
    elsif policy_row.cmd = 'INSERT' then
      if position('is_workspace_member(workspace_id)' in policy_expression) = 0
         or position('has_workspace_role(' in policy_expression) > 0 then
        raise exception 'Unexpected definition for policy %.', policy_row.policyname;
      end if;
    else
      raise exception 'Unexpected command on policy %.', policy_row.policyname;
    end if;
  end loop;

  foreach object_name in array array[
    'Recruiters can create applications',
    'Recruiters can update applications',
    'Workspace admins can delete applications',
    'Recruiters can create candidates',
    'Recruiters can update candidates',
    'Workspace admins can delete candidates'
  ]
  loop
    if not exists (
      select 1
      from pg_policies
      where schemaname = 'public'
        and policyname = object_name
        and roles::text = '{authenticated}'
        and cmd = case
          when policyname like 'Recruiters can create %' then 'INSERT'
          when policyname like 'Recruiters can update %' then 'UPDATE'
          when policyname like 'Workspace admins can delete %' then 'DELETE'
        end
        and (
          (cmd = 'INSERT'
            and position('has_workspace_role(' in lower(coalesce(with_check, ''))) > 0
            and position('created_by' in lower(coalesce(with_check, ''))) > 0)
          or
          (cmd = 'UPDATE'
            and position('has_workspace_role(' in lower(coalesce(qual, ''))) > 0
            and position('has_workspace_role(' in lower(coalesce(with_check, ''))) > 0)
          or
          (cmd = 'DELETE'
            and position('has_workspace_role(' in lower(coalesce(qual, ''))) > 0)
        )
    ) then
      raise exception
        'Expected restrictive recruiter/admin policy % is missing; reconcile manually.',
        object_name;
    end if;
  end loop;
end;
$preflight$;

-- Remove only audited, workspace-member-wide write policies. Leave the
-- read policies untouched; recruiter/admin alternatives are checked above.
drop policy if exists "Members can create workspace applications" on public.applications;
drop policy if exists "Members can update workspace applications" on public.applications;
drop policy if exists "Members can delete workspace applications" on public.applications;
drop policy if exists "Members can create workspace candidates" on public.candidates;
drop policy if exists "Members can update workspace candidates" on public.candidates;
drop policy if exists "Members can delete workspace candidates" on public.candidates;

-- Composite keys required by workspace-scoped foreign keys in feature tables.
-- Reuse the audited live jobs index rather than creating a duplicate.
do $index_preflight$
begin
  if not exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and indexname = 'idx_jobs_id_workspace_unique'
      and indexdef ilike '%unique index%on public.jobs% (id, workspace_id)%'
  ) then
    raise exception 'Expected unique public.jobs(id, workspace_id) index is missing.';
  end if;
end;
$index_preflight$;

create unique index proofhire_candidates_workspace_id_unique
  on public.candidates(workspace_id, id);
create unique index proofhire_applications_workspace_id_unique
  on public.applications(workspace_id, id);

-- Enforce that an application, its job, and its candidate remain in one
-- workspace. Preflight rejects existing mismatches instead of rewriting rows.
alter table public.applications
  add constraint proofhire_applications_job_workspace_fk
  foreign key (job_id, workspace_id)
  references public.jobs(id, workspace_id)
  on delete cascade;

alter table public.applications
  add constraint proofhire_applications_candidate_workspace_fk
  foreign key (workspace_id, candidate_id)
  references public.candidates(workspace_id, id)
  on delete cascade;

-- Source migrations follow in reviewed dependency order.

-- BEGIN SOURCE: 202610260006_recruiter_decisions_and_interviews.sql
-- Store recruiter decisions and interview operations separately from the
-- application's current recruitment stage. Apply after migration 005.
create table public.application_decision_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  decision text not null check (
    decision in (
      'shortlist',
      'reject',
      'advance_to_interview',
      'return_to_screening',
      'mark_hired'
    )
  ),
  note text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  constraint application_decision_events_application_workspace_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade
);

create index idx_application_decision_events_workspace_created
  on public.application_decision_events(workspace_id, created_at desc);

create index idx_application_decision_events_application_created
  on public.application_decision_events(application_id, created_at desc);

alter table public.application_decision_events enable row level security;

drop policy if exists "Workspace members can read application decision events"
  on public.application_decision_events;

create policy "Workspace members can read application decision events"
on public.application_decision_events
for select to authenticated
using (public.is_workspace_member(workspace_id));

revoke all on table public.application_decision_events from anon, authenticated;
grant select on table public.application_decision_events to authenticated;

create or replace function public.record_application_decision(
  target_application_id uuid,
  target_decision text,
  target_note text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
  target_workspace_id uuid;
  next_status text;
  decision_event_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication is required.';
  end if;

  next_status := case target_decision
    when 'shortlist' then 'shortlisted'
    when 'reject' then 'rejected'
    when 'advance_to_interview' then 'interview'
    when 'return_to_screening' then 'screening'
    when 'mark_hired' then 'hired'
    else null
  end;

  if next_status is null then
    raise exception 'Unsupported recruiter decision.';
  end if;

  select application.workspace_id
  into target_workspace_id
  from public.applications as application
  where application.id = target_application_id
  for update;

  if target_workspace_id is null then
    raise exception 'Application was not found.';
  end if;

  if not public.has_workspace_role(
    target_workspace_id,
    array['admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to record a recruiter decision.';
  end if;

  update public.applications
  set status = next_status
  where id = target_application_id
    and workspace_id = target_workspace_id;

  insert into public.application_decision_events (
    workspace_id,
    application_id,
    decision,
    note,
    created_by
  )
  values (
    target_workspace_id,
    target_application_id,
    target_decision,
    nullif(trim(target_note), ''),
    current_user_id
  )
  returning id into decision_event_id;

  return decision_event_id;
end;
$$;

revoke all on function public.record_application_decision(uuid, text, text)
  from public, anon;
grant execute on function public.record_application_decision(uuid, text, text)
  to authenticated;

create table public.interview_records (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  round_number integer not null default 1 check (round_number > 0),
  scheduled_at timestamptz not null,
  interview_status text not null default 'scheduled' check (
    interview_status in ('scheduled', 'completed', 'cancelled', 'rescheduled')
  ),
  outcome text not null default 'pending' check (
    outcome in ('pending', 'positive', 'negative', 'next_round', 'hired')
  ),
  interviewer_name text,
  feedback text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint interview_records_application_round_unique
    unique (workspace_id, application_id, round_number),
  constraint interview_records_application_workspace_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade
);

create index idx_interview_records_workspace_scheduled
  on public.interview_records(workspace_id, scheduled_at);

alter table public.interview_records enable row level security;

drop policy if exists "Workspace members can read interview records"
  on public.interview_records;
drop policy if exists "Recruiters can create interview records"
  on public.interview_records;
drop policy if exists "Recruiters can update interview records"
  on public.interview_records;

create policy "Workspace members can read interview records"
on public.interview_records
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create interview records"
on public.interview_records
for insert to authenticated
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and created_by = (select auth.uid())
  and exists (
    select 1
    from public.applications as application
    where application.id = interview_records.application_id
      and application.workspace_id = interview_records.workspace_id
  )
);

create policy "Recruiters can update interview records"
on public.interview_records
for update to authenticated
using (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
)
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and exists (
    select 1
    from public.applications as application
    where application.id = interview_records.application_id
      and application.workspace_id = interview_records.workspace_id
  )
);

revoke all on table public.interview_records from anon, authenticated;
grant select, insert on table public.interview_records to authenticated;
grant update (interview_status, outcome, feedback)
  on table public.interview_records to authenticated;

drop trigger if exists interview_records_set_updated_at
  on public.interview_records;

create trigger interview_records_set_updated_at
before update on public.interview_records
for each row execute function public.set_updated_at();

-- END SOURCE: 202610260006_recruiter_decisions_and_interviews.sql


-- BEGIN SOURCE: 202610290001_screening_pipeline.sql
-- Persist application-specific screening work and immutable assessment history.
-- Apply after migrations 001 through 006; do not apply without reviewing the target.
create table public.job_screening_criteria (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  job_id uuid not null,
  input_fingerprint text not null check (input_fingerprint ~ '^[0-9a-f]{64}$'),
  criteria jsonb not null check (jsonb_typeof(criteria) = 'object'),
  model text not null check (char_length(model) between 1 and 120),
  created_at timestamptz not null default now(),
  constraint job_screening_criteria_job_workspace_fk
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,
  constraint job_screening_criteria_fingerprint_unique
    unique (workspace_id, job_id, input_fingerprint),
  unique (workspace_id, id)
);

create table public.application_screening_jobs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  input_fingerprint text not null check (input_fingerprint ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending' check (
    status in (
      'pending',
      'processing',
      'retry_wait',
      'waiting_configuration',
      'completed',
      'failed',
      'superseded'
    )
  ),
  attempts integer not null default 0 check (attempts between 0 and 5),
  max_attempts integer not null default 5 check (max_attempts between 1 and 5),
  available_at timestamptz not null default now(),
  lease_token uuid,
  locked_by text,
  locked_until timestamptz,
  last_error_code text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint application_screening_jobs_application_workspace_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint application_screening_jobs_input_unique
    unique (application_id, input_fingerprint),
  constraint application_screening_jobs_lease_check
    check (
      (status = 'processing' and lease_token is not null and locked_until is not null)
      or
      (status <> 'processing' and lease_token is null and locked_until is null)
    ),
  unique (workspace_id, id)
);

create index idx_screening_jobs_claim
  on public.application_screening_jobs(status, available_at, created_at)
  where status in ('pending', 'retry_wait', 'processing');
create index idx_screening_jobs_workspace_created
  on public.application_screening_jobs(workspace_id, created_at desc);
create index idx_screening_jobs_application_created
  on public.application_screening_jobs(application_id, created_at desc);

create table public.application_screening_assessments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  criteria_version_id uuid not null,
  screening_job_id uuid not null,
  input_fingerprint text not null check (input_fingerprint ~ '^[0-9a-f]{64}$'),
  assessment_version integer not null check (assessment_version > 0),
  match_score numeric(5, 2) check (match_score is null or match_score between 0 and 100),
  report jsonb not null check (jsonb_typeof(report) = 'object'),
  model text not null check (char_length(model) between 1 and 120),
  input_tokens integer check (input_tokens is null or input_tokens >= 0),
  output_tokens integer check (output_tokens is null or output_tokens >= 0),
  created_at timestamptz not null default now(),
  constraint application_screening_assessments_application_workspace_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint application_screening_assessments_criteria_workspace_fk
    foreign key (workspace_id, criteria_version_id)
    references public.job_screening_criteria(workspace_id, id)
    on delete restrict,
  constraint application_screening_assessments_job_workspace_fk
    foreign key (workspace_id, screening_job_id)
    references public.application_screening_jobs(workspace_id, id)
    on delete cascade,
  constraint application_screening_assessments_version_unique
    unique (application_id, assessment_version),
  constraint application_screening_assessments_input_unique
    unique (application_id, input_fingerprint)
);

create index idx_screening_assessments_application_created
  on public.application_screening_assessments(application_id, created_at desc);
create index idx_screening_assessments_job_score
  on public.application_screening_assessments(workspace_id, created_at desc, match_score desc);

alter table public.job_screening_criteria enable row level security;
alter table public.application_screening_jobs enable row level security;
alter table public.application_screening_assessments enable row level security;

drop policy if exists "Workspace members can read job screening criteria"
  on public.job_screening_criteria;
create policy "Workspace members can read job screening criteria"
on public.job_screening_criteria
for select to authenticated
using (public.is_workspace_member(workspace_id));

drop policy if exists "Workspace members can read screening job status"
  on public.application_screening_jobs;
create policy "Workspace members can read screening job status"
on public.application_screening_jobs
for select to authenticated
using (public.is_workspace_member(workspace_id));

drop policy if exists "Workspace members can read screening assessments"
  on public.application_screening_assessments;
create policy "Workspace members can read screening assessments"
on public.application_screening_assessments
for select to authenticated
using (public.is_workspace_member(workspace_id));

revoke all on public.job_screening_criteria from anon, authenticated;
revoke all on public.application_screening_jobs from anon, authenticated;
revoke all on public.application_screening_assessments from anon, authenticated;
grant select on public.job_screening_criteria to authenticated;
grant select (
  id,
  workspace_id,
  application_id,
  status,
  attempts,
  available_at,
  last_error_code,
  failure_reason,
  created_at,
  updated_at,
  completed_at
) on public.application_screening_jobs to authenticated;
grant select on public.application_screening_assessments to authenticated;
grant all on public.job_screening_criteria to service_role;
grant all on public.application_screening_jobs to service_role;
grant all on public.application_screening_assessments to service_role;

create or replace function public.enqueue_application_screening(
  target_application_id uuid,
  allow_failed_retry boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row record;
  job_row public.jobs%rowtype;
  fingerprint text;
  screening_job_id uuid;
begin
  select
    application.id,
    application.workspace_id,
    application.job_id,
    application.resume_path
  into application_row
  from public.applications as application
  where application.id = target_application_id;

  if not found or application_row.resume_path is null then
    return null;
  end if;

  select job.*
  into job_row
  from public.jobs as job
  where job.id = application_row.job_id
    and job.workspace_id = application_row.workspace_id;

  if not found then
    return null;
  end if;

  fingerprint := encode(
    extensions.digest(
      convert_to(
        jsonb_build_array(
          application_row.resume_path,
          job_row.title,
          job_row.department,
          job_row.description,
          job_row.required_skills,
          job_row.preferred_skills,
          job_row.minimum_experience
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  );

  insert into public.application_screening_jobs (
    workspace_id,
    application_id,
    input_fingerprint
  )
  values (
    application_row.workspace_id,
    application_row.id,
    fingerprint
  )
  on conflict (application_id, input_fingerprint) do nothing
  returning id into screening_job_id;

  if screening_job_id is null and allow_failed_retry then
    update public.application_screening_jobs as screening_job
    set status = 'pending',
        attempts = 0,
        available_at = now(),
        lease_token = null,
        locked_by = null,
        locked_until = null,
        last_error_code = null,
        failure_reason = null,
        completed_at = null,
        updated_at = now()
    where screening_job.application_id = application_row.id
      and screening_job.input_fingerprint = fingerprint
      and screening_job.status in ('failed', 'waiting_configuration')
    returning id into screening_job_id;
  end if;

  if screening_job_id is null then
    select screening_job.id
    into screening_job_id
    from public.application_screening_jobs as screening_job
    where screening_job.application_id = application_row.id
      and screening_job.input_fingerprint = fingerprint;
  end if;

  return screening_job_id;
end;
$$;

create or replace function public.request_application_screening(
  target_application_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_workspace_id uuid;
  result_id uuid;
begin
  select application.workspace_id
  into target_workspace_id
  from public.applications as application
  where application.id = target_application_id;

  if target_workspace_id is null then
    raise exception 'Application was not found.';
  end if;
  if not public.has_workspace_role(
    target_workspace_id,
    array['admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to request screening.';
  end if;

  result_id := public.enqueue_application_screening(target_application_id, true);
  if result_id is null then
    raise exception 'This application has no resume to screen.';
  end if;
  return result_id;
end;
$$;

create or replace function public.get_application_screening_overview(
  target_workspace_id uuid,
  target_application_ids uuid[]
)
returns table (
  application_id uuid,
  screening_status text,
  attempts integer,
  failure_reason text,
  last_error_code text,
  assessment_id uuid,
  assessment_version integer,
  match_score numeric,
  report jsonb,
  criteria jsonb,
  assessed_at timestamptz
)
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not public.is_workspace_member(target_workspace_id) then
    raise exception 'Workspace access is not permitted.';
  end if;
  if target_application_ids is null or cardinality(target_application_ids) > 100 then
    raise exception 'At most 100 application IDs may be requested.';
  end if;

  return query
  select
    application.id,
    coalesce(screening_job.status, 'not_queued'),
    coalesce(screening_job.attempts, 0),
    screening_job.failure_reason,
    screening_job.last_error_code,
    assessment.id,
    assessment.assessment_version,
    assessment.match_score,
    assessment.report,
    assessment.criteria,
    assessment.created_at
  from public.applications as application
  left join lateral (
    select
      current_job.status,
      current_job.attempts,
      current_job.failure_reason,
      current_job.last_error_code,
      current_job.created_at
    from public.application_screening_jobs as current_job
    where current_job.application_id = application.id
      and current_job.workspace_id = application.workspace_id
    order by current_job.created_at desc
    limit 1
  ) as screening_job on true
  left join lateral (
    select
      current_assessment.id,
      current_assessment.assessment_version,
      current_assessment.match_score,
      current_assessment.report,
      current_assessment.created_at,
      criteria_version.criteria
    from public.application_screening_assessments as current_assessment
    join public.job_screening_criteria as criteria_version
      on criteria_version.id = current_assessment.criteria_version_id
     and criteria_version.workspace_id = current_assessment.workspace_id
    where current_assessment.application_id = application.id
      and current_assessment.workspace_id = application.workspace_id
    order by current_assessment.assessment_version desc
    limit 1
  ) as assessment on true
  where application.workspace_id = target_workspace_id
    and application.id = any(target_application_ids)
  order by application.created_at desc, application.id desc;
end;
$$;

create or replace function public.queue_screening_for_application()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.enqueue_application_screening(new.id, false);
  return new;
end;
$$;

create or replace function public.queue_screening_for_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_id uuid;
begin
  for application_id in
    select application.id
    from public.applications as application
    where application.job_id = new.id
      and application.workspace_id = new.workspace_id
      and application.resume_path is not null
  loop
    perform public.enqueue_application_screening(application_id, false);
  end loop;
  return new;
end;
$$;

drop trigger if exists applications_queue_screening
  on public.applications;
create trigger applications_queue_screening
after insert or update of resume_path on public.applications
for each row execute function public.queue_screening_for_application();

drop trigger if exists jobs_queue_screening
  on public.jobs;
create trigger jobs_queue_screening
after update of title, department, description, required_skills,
  preferred_skills, minimum_experience on public.jobs
for each row execute function public.queue_screening_for_job();

create or replace function public.claim_application_screening_job(
  worker_id text,
  lease_seconds integer default 120
)
returns setof public.application_screening_jobs
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if worker_id is null or char_length(trim(worker_id)) not between 1 and 120 then
    raise exception 'Worker identifier is invalid.';
  end if;
  lease_seconds := greatest(30, least(coalesce(lease_seconds, 600), 600));

  update public.application_screening_jobs as screening_job
  set status = 'failed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'lease_expired',
      failure_reason = 'Processing lease expired after the retry limit.',
      updated_at = now()
  where screening_job.status = 'processing'
    and screening_job.locked_until < now()
    and screening_job.attempts >= screening_job.max_attempts;

  update public.application_screening_jobs as screening_job
  set status = 'superseded',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'inputs_changed',
      failure_reason = 'Job or resume changed; a newer screening job is queued.',
      updated_at = now()
  from public.applications as application
  join public.jobs as job
    on job.id = application.job_id
   and job.workspace_id = application.workspace_id
  where screening_job.application_id = application.id
    and screening_job.workspace_id = application.workspace_id
    and (
      screening_job.status in ('pending', 'retry_wait')
      or (
        screening_job.status = 'processing'
        and screening_job.locked_until < now()
      )
    )
    and screening_job.input_fingerprint <> encode(
      extensions.digest(
        convert_to(
          jsonb_build_array(
            application.resume_path,
            job.title,
            job.department,
            job.description,
            job.required_skills,
            job.preferred_skills,
            job.minimum_experience
          )::text,
          'UTF8'
        ),
        'sha256'
      ),
      'hex'
    );

  return query
  with next_job as (
    select screening_job.id
    from public.application_screening_jobs as screening_job
    where screening_job.attempts < screening_job.max_attempts
      and (
        (screening_job.status in ('pending', 'retry_wait')
          and screening_job.available_at <= now()
          and screening_job.input_fingerprint = (
            select encode(
              extensions.digest(
                convert_to(
                  jsonb_build_array(
                    application.resume_path,
                    job.title,
                    job.department,
                    job.description,
                    job.required_skills,
                    job.preferred_skills,
                    job.minimum_experience
                  )::text,
                  'UTF8'
                ),
                'sha256'
              ),
              'hex'
            )
            from public.applications as application
            join public.jobs as job
              on job.id = application.job_id
             and job.workspace_id = application.workspace_id
            where application.id = screening_job.application_id
              and application.workspace_id = screening_job.workspace_id
          ))
        or
        (screening_job.status = 'processing'
          and screening_job.locked_until < now())
      )
    order by screening_job.available_at, screening_job.created_at
    for update skip locked
    limit 1
  )
  update public.application_screening_jobs as screening_job
  set status = 'processing',
      attempts = screening_job.attempts + 1,
      lease_token = gen_random_uuid(),
      locked_by = worker_id,
      locked_until = now() + make_interval(secs => lease_seconds),
      updated_at = now()
  from next_job
  where screening_job.id = next_job.id
  returning screening_job.*;
end;
$$;

create or replace function public.complete_application_screening_job(
  target_job_id uuid,
  target_lease_token uuid,
  target_criteria_fingerprint text,
  target_criteria jsonb,
  target_report jsonb,
  target_match_score numeric,
  target_model text,
  target_input_tokens integer default null,
  target_output_tokens integer default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  job_row public.application_screening_jobs%rowtype;
  application_row public.applications%rowtype;
  criteria_id uuid;
  next_version integer;
  assessment_id uuid;
  current_fingerprint text;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if target_match_score is not null and (target_match_score < 0 or target_match_score > 100) then
    raise exception 'Assessment score is invalid.';
  end if;
  if jsonb_typeof(target_criteria) is distinct from 'object'
     or jsonb_typeof(target_report) is distinct from 'object'
     or target_model is null
     or char_length(target_model) not between 1 and 120
     or target_criteria_fingerprint is null
     or target_criteria_fingerprint !~ '^[0-9a-f]{64}$' then
    raise exception 'Assessment payload is invalid.';
  end if;

  select screening_job.*
  into job_row
  from public.application_screening_jobs as screening_job
  where screening_job.id = target_job_id
  for update;
  if not found or job_row.status <> 'processing'
     or job_row.lease_token <> target_lease_token
     or job_row.locked_until < now() then
    raise exception 'Screening job lease is no longer valid.';
  end if;

  select application.*
  into application_row
  from public.applications as application
  where application.id = job_row.application_id
    and application.workspace_id = job_row.workspace_id
  for update;
  if not found then
    raise exception 'Screening application no longer exists.';
  end if;

  perform 1
  from public.jobs as job
  where job.id = application_row.job_id
    and job.workspace_id = application_row.workspace_id
  for share;

  select encode(
    extensions.digest(
      convert_to(
        jsonb_build_array(
          application_row.resume_path,
          job.title,
          job.department,
          job.description,
          job.required_skills,
          job.preferred_skills,
          job.minimum_experience
        )::text,
        'UTF8'
      ),
      'sha256'
    ),
    'hex'
  )
  into current_fingerprint
  from public.jobs as job
  where job.id = application_row.job_id
    and job.workspace_id = application_row.workspace_id;

  if current_fingerprint is distinct from job_row.input_fingerprint then
    update public.application_screening_jobs
    set status = 'superseded',
        lease_token = null,
        locked_by = null,
        locked_until = null,
        last_error_code = 'inputs_changed',
        failure_reason = 'Job or resume changed during screening; a current version is queued.',
        updated_at = now()
    where id = job_row.id;
    return null;
  end if;

  insert into public.job_screening_criteria (
    workspace_id,
    job_id,
    input_fingerprint,
    criteria,
    model
  )
  values (
    job_row.workspace_id,
    application_row.job_id,
    target_criteria_fingerprint,
    target_criteria,
    target_model
  )
  on conflict (workspace_id, job_id, input_fingerprint)
  do nothing
  returning id into criteria_id;
  if criteria_id is null then
    select criteria_row.id
    into criteria_id
    from public.job_screening_criteria as criteria_row
    where criteria_row.workspace_id = job_row.workspace_id
      and criteria_row.job_id = application_row.job_id
      and criteria_row.input_fingerprint = target_criteria_fingerprint;
  end if;

  select coalesce(max(assessment.assessment_version), 0) + 1
  into next_version
  from public.application_screening_assessments as assessment
  where assessment.application_id = application_row.id;

  insert into public.application_screening_assessments (
    workspace_id,
    application_id,
    criteria_version_id,
    screening_job_id,
    input_fingerprint,
    assessment_version,
    match_score,
    report,
    model,
    input_tokens,
    output_tokens
  )
  values (
    job_row.workspace_id,
    application_row.id,
    criteria_id,
    job_row.id,
    job_row.input_fingerprint,
    next_version,
    target_match_score,
    target_report,
    target_model,
    target_input_tokens,
    target_output_tokens
  )
  on conflict (application_id, input_fingerprint)
  do update set
    criteria_version_id = excluded.criteria_version_id,
    screening_job_id = excluded.screening_job_id,
    match_score = excluded.match_score,
    report = excluded.report,
    model = excluded.model,
    input_tokens = excluded.input_tokens,
    output_tokens = excluded.output_tokens
  returning id into assessment_id;

  update public.application_screening_jobs
  set status = 'completed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = null,
      failure_reason = null,
      completed_at = now(),
      updated_at = now()
  where id = job_row.id;

  return assessment_id;
end;
$$;

create or replace function public.fail_application_screening_job(
  target_job_id uuid,
  target_lease_token uuid,
  target_error_code text,
  target_failure_reason text,
  retryable boolean
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  job_row public.application_screening_jobs%rowtype;
  next_status text;
  retry_seconds integer;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role is required.';
  end if;
  select screening_job.*
  into job_row
  from public.application_screening_jobs as screening_job
  where screening_job.id = target_job_id
  for update;
  if not found or job_row.status <> 'processing'
     or job_row.lease_token <> target_lease_token then
    raise exception 'Screening job lease is no longer valid.';
  end if;

  next_status := case
    when retryable and job_row.attempts < job_row.max_attempts then 'retry_wait'
    else 'failed'
  end;
  retry_seconds := least(
    3600::numeric,
    15::numeric * power(2::numeric, greatest(job_row.attempts - 1, 0))
  )::integer;

  update public.application_screening_jobs
  set status = next_status,
      available_at = case
        when next_status = 'retry_wait'
          then now() + make_interval(secs => retry_seconds)
        else available_at
      end,
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = left(coalesce(target_error_code, 'processing_failed'), 80),
      failure_reason = left(coalesce(target_failure_reason, 'Screening could not be completed.'), 500),
      updated_at = now()
  where id = job_row.id;

  return next_status;
end;
$$;

create or replace function public.pause_application_screening_jobs()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role is required.';
  end if;
  update public.application_screening_jobs
  set status = 'waiting_configuration',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'gemini_not_configured',
      failure_reason = 'Configure GEMINI_API_KEY and restart the screening worker.',
      updated_at = now()
  where status in ('pending', 'retry_wait');
  get diagnostics changed_rows = row_count;
  return changed_rows;
end;
$$;

create or replace function public.resume_application_screening_jobs()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role is required.';
  end if;
  update public.application_screening_jobs
  set status = 'pending',
      available_at = now(),
      last_error_code = null,
      failure_reason = null,
      updated_at = now()
  where status = 'waiting_configuration';
  get diagnostics changed_rows = row_count;
  return changed_rows;
end;
$$;

revoke all on function public.enqueue_application_screening(uuid, boolean)
  from public, anon, authenticated;
revoke all on function public.request_application_screening(uuid)
  from public, anon;
revoke all on function public.get_application_screening_overview(uuid, uuid[])
  from public, anon;
revoke all on function public.claim_application_screening_job(text, integer)
  from public, anon, authenticated;
revoke all on function public.complete_application_screening_job(
  uuid, uuid, text, jsonb, jsonb, numeric, text, integer, integer
) from public, anon, authenticated;
revoke all on function public.fail_application_screening_job(
  uuid, uuid, text, text, boolean
) from public, anon, authenticated;
revoke all on function public.pause_application_screening_jobs()
  from public, anon, authenticated;
revoke all on function public.resume_application_screening_jobs()
  from public, anon, authenticated;
revoke all on function public.queue_screening_for_application()
  from public, anon, authenticated;
revoke all on function public.queue_screening_for_job()
  from public, anon, authenticated;

grant execute on function public.request_application_screening(uuid)
  to authenticated;
grant execute on function public.get_application_screening_overview(uuid, uuid[])
  to authenticated;
grant execute on function public.claim_application_screening_job(text, integer)
  to service_role;
grant execute on function public.complete_application_screening_job(
  uuid, uuid, text, jsonb, jsonb, numeric, text, integer, integer
) to service_role;
grant execute on function public.fail_application_screening_job(
  uuid, uuid, text, text, boolean
) to service_role;
grant execute on function public.pause_application_screening_jobs()
  to service_role;
grant execute on function public.resume_application_screening_jobs()
  to service_role;

-- END SOURCE: 202610290001_screening_pipeline.sql


-- BEGIN SOURCE: 202610290003_aptitude_assessment_schema.sql
-- Versioned aptitude assessments. Candidate-facing access is intentionally
-- service-mediated; answer keys and candidate answers are never exposed via
-- authenticated or anonymous table access.
create schema proofhire_private;
revoke all on schema proofhire_private from public, anon, authenticated;
grant usage on schema proofhire_private to service_role;

create table public.aptitude_tests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 180),
  description text check (description is null or char_length(description) <= 5000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_tests_workspace_id_unique unique (workspace_id, id)
);

create table public.aptitude_test_versions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  test_id uuid not null,
  version_number integer not null check (version_number > 0),
  version_title text not null
    check (char_length(trim(version_title)) between 1 and 180),
  version_description text
    check (version_description is null or char_length(version_description) <= 5000),
  version_status text not null default 'draft'
    check (version_status in ('draft', 'published')),
  time_limit_seconds integer not null
    check (time_limit_seconds between 60 and 21600),
  max_attempts integer not null default 1
    check (max_attempts between 1 and 5),
  passing_score numeric(5, 2)
    check (passing_score is null or passing_score between 0 and 100),
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_test_versions_test_fk
    foreign key (workspace_id, test_id)
    references public.aptitude_tests(workspace_id, id)
    on delete cascade,
  constraint aptitude_test_versions_test_number_unique
    unique (test_id, version_number),
  constraint aptitude_test_versions_workspace_id_unique
    unique (workspace_id, id),
  constraint aptitude_test_versions_publication_timestamp_check
    check (
      (version_status = 'draft' and published_at is null)
      or (version_status = 'published' and published_at is not null)
    )
);

create table public.aptitude_questions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  test_version_id uuid not null,
  display_order integer not null check (display_order > 0),
  question_type text not null
    check (question_type in ('single_choice', 'multiple_choice', 'short_text')),
  prompt text not null check (char_length(trim(prompt)) between 1 and 10000),
  points numeric(6, 2) not null default 1 check (points > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_questions_version_fk
    foreign key (workspace_id, test_version_id)
    references public.aptitude_test_versions(workspace_id, id)
    on delete cascade,
  constraint aptitude_questions_version_order_unique
    unique (test_version_id, display_order),
  constraint aptitude_questions_workspace_id_unique
    unique (workspace_id, id),
  constraint aptitude_questions_workspace_version_id_unique
    unique (workspace_id, test_version_id, id)
);

create table public.aptitude_question_options (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  question_id uuid not null,
  display_order integer not null check (display_order > 0),
  option_text text not null
    check (char_length(trim(option_text)) between 1 and 2000),
  created_at timestamptz not null default now(),
  constraint aptitude_question_options_question_fk
    foreign key (workspace_id, question_id)
    references public.aptitude_questions(workspace_id, id)
    on delete cascade,
  constraint aptitude_question_options_question_order_unique
    unique (question_id, display_order),
  constraint aptitude_question_options_workspace_id_unique
    unique (workspace_id, id)
);

create table proofhire_private.aptitude_answer_keys (
  workspace_id uuid not null,
  question_id uuid not null,
  answer_key jsonb not null
    check (jsonb_typeof(answer_key) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (workspace_id, question_id),
  constraint aptitude_answer_keys_question_fk
    foreign key (workspace_id, question_id)
    references public.aptitude_questions(workspace_id, id)
    on delete cascade
);

create table public.aptitude_invitations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  test_version_id uuid not null,
  candidate_email text not null
    check (
      char_length(candidate_email) between 3 and 320
      and candidate_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),
  token_hash text not null
    check (token_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check (status in ('pending', 'sent', 'started', 'completed', 'expired', 'revoked', 'failed')),
  email_status text not null default 'queued'
    check (email_status in ('queued', 'sent', 'delivered', 'failed')),
  email_provider_message_id text,
  email_error_code text,
  expires_at timestamptz not null,
  max_attempts integer not null default 1
    check (max_attempts between 1 and 5),
  invited_by uuid references auth.users(id) on delete set null,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_invitations_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint aptitude_invitations_version_fk
    foreign key (workspace_id, test_version_id)
    references public.aptitude_test_versions(workspace_id, id)
    on delete restrict,
  constraint aptitude_invitations_token_hash_unique unique (token_hash),
  constraint aptitude_invitations_workspace_id_version_unique
    unique (workspace_id, id, test_version_id)
);

create table public.aptitude_attempts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  invitation_id uuid not null,
  test_version_id uuid not null,
  attempt_number integer not null check (attempt_number between 1 and 5),
  status text not null default 'in_progress'
    check (status in ('in_progress', 'submitted', 'expired', 'abandoned')),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  score numeric(5, 2) check (score is null or score between 0 and 100),
  result jsonb check (result is null or jsonb_typeof(result) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_attempts_invitation_fk
    foreign key (workspace_id, invitation_id, test_version_id)
    references public.aptitude_invitations(workspace_id, id, test_version_id)
    on delete cascade,
  constraint aptitude_attempts_invitation_number_unique
    unique (invitation_id, attempt_number),
  constraint aptitude_attempts_workspace_id_unique
    unique (workspace_id, id),
  constraint aptitude_attempts_workspace_version_id_unique
    unique (workspace_id, id, test_version_id),
  constraint aptitude_attempts_submission_timestamp_check
    check (
      (status = 'in_progress' and submitted_at is null)
      or (status <> 'in_progress' and submitted_at is not null)
    )
);

create table public.aptitude_answers (
  workspace_id uuid not null,
  attempt_id uuid not null,
  test_version_id uuid not null,
  question_id uuid not null,
  answer jsonb not null,
  saved_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  constraint aptitude_answers_attempt_version_fk
    foreign key (workspace_id, attempt_id, test_version_id)
    references public.aptitude_attempts(workspace_id, id, test_version_id)
    on delete cascade,
  constraint aptitude_answers_question_version_fk
    foreign key (workspace_id, test_version_id, question_id)
    references public.aptitude_questions(workspace_id, test_version_id, id)
    on delete cascade
);

create table public.aptitude_monitoring_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  attempt_id uuid not null,
  event_type text not null
    check (
      event_type in (
        'focus_lost',
        'visibility_hidden',
        'fullscreen_exit',
        'copy_attempt',
        'paste_attempt',
        'network_disconnected',
        'network_reconnected',
        'heartbeat_timeout',
        'candidate_reported_issue'
      )
    ),
  event_data jsonb not null default '{}'::jsonb
    check (jsonb_typeof(event_data) = 'object'),
  created_at timestamptz not null default now(),
  constraint aptitude_monitoring_events_attempt_fk
    foreign key (workspace_id, attempt_id)
    references public.aptitude_attempts(workspace_id, id)
    on delete cascade
);

create index idx_aptitude_tests_workspace_created
  on public.aptitude_tests(workspace_id, created_at desc);
create index idx_aptitude_versions_test_status
  on public.aptitude_test_versions(workspace_id, test_id, version_status);
create index idx_aptitude_questions_version_order
  on public.aptitude_questions(workspace_id, test_version_id, display_order);
create index idx_aptitude_invitations_application_created
  on public.aptitude_invitations(workspace_id, application_id, created_at desc);
create index idx_aptitude_invitations_expiry
  on public.aptitude_invitations(status, expires_at)
  where status in ('pending', 'sent', 'started');
create index idx_aptitude_attempts_invitation
  on public.aptitude_attempts(workspace_id, invitation_id, attempt_number);
create index idx_aptitude_attempts_workspace_created
  on public.aptitude_attempts(workspace_id, created_at desc);
create index idx_aptitude_monitoring_attempt_created
  on public.aptitude_monitoring_events(workspace_id, attempt_id, created_at);

alter table public.aptitude_tests enable row level security;
alter table public.aptitude_test_versions enable row level security;
alter table public.aptitude_questions enable row level security;
alter table public.aptitude_question_options enable row level security;
alter table proofhire_private.aptitude_answer_keys enable row level security;
alter table public.aptitude_invitations enable row level security;
alter table public.aptitude_attempts enable row level security;
alter table public.aptitude_answers enable row level security;
alter table public.aptitude_monitoring_events enable row level security;

create policy "Workspace members can read aptitude tests"
on public.aptitude_tests
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create aptitude tests"
on public.aptitude_tests
for insert to authenticated
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and created_by = (select auth.uid())
);

create policy "Recruiters can update aptitude tests"
on public.aptitude_tests
for update to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']))
with check (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Workspace admins can delete aptitude tests"
on public.aptitude_tests
for delete to authenticated
using (public.has_workspace_role(workspace_id, array['admin']));

create policy "Workspace members can read aptitude test versions"
on public.aptitude_test_versions
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create aptitude test drafts"
on public.aptitude_test_versions
for insert to authenticated
with check (
  version_status = 'draft'
  and created_by = (select auth.uid())
  and public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
);

create policy "Recruiters can update aptitude test drafts"
on public.aptitude_test_versions
for update to authenticated
using (
  version_status = 'draft'
  and public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
)
with check (
  version_status = 'draft'
  and public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
);

create policy "Workspace admins can delete aptitude test drafts"
on public.aptitude_test_versions
for delete to authenticated
using (
  version_status = 'draft'
  and public.has_workspace_role(workspace_id, array['admin'])
);

create policy "Workspace members can read aptitude questions"
on public.aptitude_questions
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can manage aptitude questions in drafts"
on public.aptitude_questions
for all to authenticated
using (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = aptitude_questions.workspace_id
      and version.id = aptitude_questions.test_version_id
      and version.version_status = 'draft'
  )
)
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = aptitude_questions.workspace_id
      and version.id = aptitude_questions.test_version_id
      and version.version_status = 'draft'
  )
);

create policy "Workspace members can read aptitude question options"
on public.aptitude_question_options
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can manage aptitude options in drafts"
on public.aptitude_question_options
for all to authenticated
using (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_questions question
    join public.aptitude_test_versions version
      on version.workspace_id = question.workspace_id
     and version.id = question.test_version_id
    where question.workspace_id = aptitude_question_options.workspace_id
      and question.id = aptitude_question_options.question_id
      and version.version_status = 'draft'
  )
)
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_questions question
    join public.aptitude_test_versions version
      on version.workspace_id = question.workspace_id
     and version.id = question.test_version_id
    where question.workspace_id = aptitude_question_options.workspace_id
      and question.id = aptitude_question_options.question_id
      and version.version_status = 'draft'
  )
);

create policy "Service role manages private aptitude answer keys"
on proofhire_private.aptitude_answer_keys
for all to service_role
using (true)
with check (true);

create policy "Workspace members can read aptitude invitations"
on public.aptitude_invitations
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Workspace members can read aptitude attempts"
on public.aptitude_attempts
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can read aptitude monitoring events"
on public.aptitude_monitoring_events
for select to authenticated
using (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
);

revoke all on public.aptitude_tests from anon, authenticated;
revoke all on public.aptitude_test_versions from anon, authenticated;
revoke all on public.aptitude_questions from anon, authenticated;
revoke all on public.aptitude_question_options from anon, authenticated;
revoke all on proofhire_private.aptitude_answer_keys from public, anon, authenticated;
revoke all on public.aptitude_invitations from anon, authenticated;
revoke all on public.aptitude_attempts from anon, authenticated;
revoke all on public.aptitude_answers from public, anon, authenticated;
revoke all on public.aptitude_monitoring_events from anon, authenticated;

grant select, insert, update, delete
  on public.aptitude_tests to authenticated;
grant select, insert, update, delete
  on public.aptitude_test_versions to authenticated;
grant select, insert, update, delete
  on public.aptitude_questions to authenticated;
grant select, insert, update, delete
  on public.aptitude_question_options to authenticated;
grant select (
  id,
  workspace_id,
  application_id,
  test_version_id,
  candidate_email,
  status,
  email_status,
  email_provider_message_id,
  email_error_code,
  expires_at,
  max_attempts,
  invited_by,
  sent_at,
  created_at,
  updated_at
) on public.aptitude_invitations to authenticated;
grant select on public.aptitude_attempts to authenticated;
grant select on public.aptitude_monitoring_events to authenticated;

grant all on public.aptitude_tests to service_role;
grant all on public.aptitude_test_versions to service_role;
grant all on public.aptitude_questions to service_role;
grant all on public.aptitude_question_options to service_role;
grant all on proofhire_private.aptitude_answer_keys to service_role;
grant all on public.aptitude_invitations to service_role;
grant all on public.aptitude_attempts to service_role;
grant all on public.aptitude_answers to service_role;
grant all on public.aptitude_monitoring_events to service_role;

create or replace function public.prevent_published_aptitude_version_changes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.version_status = 'published' then
    raise exception 'Published aptitude test versions are immutable.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger aptitude_test_versions_are_immutable
before update or delete on public.aptitude_test_versions
for each row execute function public.prevent_published_aptitude_version_changes();

create or replace function public.prevent_published_aptitude_content_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_data jsonb;
  target_workspace_id uuid;
  target_question_id uuid;
  target_version_id uuid;
  version_state text;
begin
  row_data := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  target_workspace_id := (row_data ->> 'workspace_id')::uuid;

  if tg_table_name = 'aptitude_questions' then
    target_version_id := (row_data ->> 'test_version_id')::uuid;
  else
    target_question_id := (row_data ->> 'question_id')::uuid;
    select question.test_version_id
    into target_version_id
    from public.aptitude_questions question
    where question.workspace_id = target_workspace_id
      and question.id = target_question_id;
  end if;

  select version.version_status
  into version_state
  from public.aptitude_test_versions version
  where version.workspace_id = target_workspace_id
    and version.id = target_version_id;

  if version_state is null and tg_op = 'DELETE' then
    return old;
  end if;
  if version_state is distinct from 'draft' then
    raise exception 'Aptitude content can only change while its version is a draft.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger aptitude_questions_are_immutable_when_published
before insert or update or delete on public.aptitude_questions
for each row execute function public.prevent_published_aptitude_content_changes();

create trigger aptitude_options_are_immutable_when_published
before insert or update or delete on public.aptitude_question_options
for each row execute function public.prevent_published_aptitude_content_changes();

create trigger aptitude_answer_keys_are_immutable_when_published
before insert or update or delete on proofhire_private.aptitude_answer_keys
for each row execute function public.prevent_published_aptitude_content_changes();

create or replace function public.publish_aptitude_test_version(
  target_version_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.aptitude_test_versions%rowtype;
  question_row record;
  option_count integer;
  distinct_option_count integer;
  matched_option_count integer;
  question_option_count integer;
  accepted_answer_count integer;
begin
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.id = target_version_id
  for update;

  if not found then
    raise exception 'Aptitude test version was not found.';
  end if;
  if not public.has_workspace_role(
    version_row.workspace_id,
    array['admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to publish this aptitude test.';
  end if;
  if version_row.version_status <> 'draft' then
    raise exception 'Only a draft aptitude test version can be published.';
  end if;
  if not exists (
    select 1
    from public.aptitude_questions question
    where question.workspace_id = version_row.workspace_id
      and question.test_version_id = version_row.id
  ) then
    raise exception 'Add at least one question before publishing.';
  end if;

  for question_row in
    select
      question.id,
      question.question_type,
      answer_key.answer_key
    from public.aptitude_questions question
    left join proofhire_private.aptitude_answer_keys answer_key
      on answer_key.workspace_id = question.workspace_id
     and answer_key.question_id = question.id
    where question.workspace_id = version_row.workspace_id
      and question.test_version_id = version_row.id
  loop
    if question_row.answer_key is null then
      raise exception 'Every aptitude question must have a private answer key.';
    end if;

    if question_row.question_type in ('single_choice', 'multiple_choice') then
      if jsonb_typeof(question_row.answer_key -> 'option_ids') is distinct from 'array' then
        raise exception 'Choice-question answer keys must contain an option_ids array.';
      end if;
      select
        count(*),
        count(distinct selected.value)
      into option_count, distinct_option_count
      from jsonb_array_elements_text(question_row.answer_key -> 'option_ids')
        as selected(value);

      if option_count = 0 or option_count <> distinct_option_count then
        raise exception 'Choice-question answer keys must contain unique option IDs.';
      end if;
      if question_row.question_type = 'single_choice' and option_count <> 1 then
        raise exception 'A single-choice question must have exactly one correct option.';
      end if;
      select count(*)
      into question_option_count
      from public.aptitude_question_options option_row
      where option_row.workspace_id = version_row.workspace_id
        and option_row.question_id = question_row.id;
      if question_option_count < 2 then
        raise exception 'Choice questions must have at least two options.';
      end if;
      select count(*)
      into matched_option_count
      from jsonb_array_elements_text(question_row.answer_key -> 'option_ids')
        as selected(value)
      join public.aptitude_question_options option_row
        on option_row.workspace_id = version_row.workspace_id
       and option_row.question_id = question_row.id
       and option_row.id::text = selected.value;
      if matched_option_count <> option_count then
        raise exception 'An answer key refers to an option outside its question.';
      end if;
    elsif question_row.question_type = 'short_text' then
      if jsonb_typeof(question_row.answer_key -> 'accepted_answers') is distinct from 'array' then
        raise exception 'Short-text answer keys must contain an accepted_answers array.';
      end if;
      select count(*)
      into accepted_answer_count
      from jsonb_array_elements_text(question_row.answer_key -> 'accepted_answers')
        as accepted(value)
      where char_length(trim(accepted.value)) > 0;
      if accepted_answer_count = 0 then
        raise exception 'A short-text question must have at least one accepted answer.';
      end if;
    end if;
  end loop;

  update public.aptitude_test_versions
  set version_status = 'published',
      published_at = now(),
      updated_at = now()
  where id = version_row.id
    and workspace_id = version_row.workspace_id;

  return version_row.id;
end;
$$;

create or replace function public.validate_aptitude_invitation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.aptitude_test_versions%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create aptitude invitations.';
  end if;
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = new.workspace_id
    and version.id = new.test_version_id;
  if not found or version_row.version_status <> 'published' then
    raise exception 'Invitations require a published aptitude test version.';
  end if;
  if new.max_attempts > version_row.max_attempts then
    raise exception 'Invitation attempt limit exceeds its published test version.';
  end if;
  if new.expires_at <= now() then
    raise exception 'Aptitude invitation expiry must be in the future.';
  end if;
  return new;
end;
$$;

create trigger aptitude_invitations_require_published_version
before insert or update of workspace_id, test_version_id, max_attempts, expires_at
on public.aptitude_invitations
for each row execute function public.validate_aptitude_invitation();

create or replace function public.validate_aptitude_attempt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  previous_attempts integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create aptitude attempts.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.workspace_id = new.workspace_id
    and invitation.id = new.invitation_id
    and invitation.test_version_id = new.test_version_id
  for update;
  if not found
     or invitation_row.status not in ('pending', 'sent', 'started')
     or invitation_row.expires_at <= now() then
    raise exception 'Aptitude invitation is unavailable or expired.';
  end if;
  select count(*)
  into previous_attempts
  from public.aptitude_attempts attempt
  where attempt.workspace_id = new.workspace_id
    and attempt.invitation_id = new.invitation_id;
  if new.attempt_number <> previous_attempts + 1
     or new.attempt_number > invitation_row.max_attempts then
    raise exception 'Aptitude attempt limit has been reached.';
  end if;
  update public.aptitude_invitations
  set status = 'started',
      updated_at = now()
  where id = invitation_row.id
    and workspace_id = invitation_row.workspace_id;
  return new;
end;
$$;

create trigger aptitude_attempts_enforce_invitation_limits
before insert on public.aptitude_attempts
for each row execute function public.validate_aptitude_attempt();

revoke all on function public.publish_aptitude_test_version(uuid)
  from public, anon;
grant execute on function public.publish_aptitude_test_version(uuid)
  to authenticated;

revoke all on function public.validate_aptitude_invitation()
  from public, anon, authenticated;
revoke all on function public.validate_aptitude_attempt()
  from public, anon, authenticated;
revoke all on function public.prevent_published_aptitude_version_changes()
  from public, anon, authenticated;
revoke all on function public.prevent_published_aptitude_content_changes()
  from public, anon, authenticated;

create trigger aptitude_tests_set_updated_at
before update on public.aptitude_tests
for each row execute function public.set_updated_at();

create trigger aptitude_test_versions_set_updated_at
before update on public.aptitude_test_versions
for each row execute function public.set_updated_at();

create trigger aptitude_questions_set_updated_at
before update on public.aptitude_questions
for each row execute function public.set_updated_at();

create trigger aptitude_invitations_set_updated_at
before update on public.aptitude_invitations
for each row execute function public.set_updated_at();

create trigger aptitude_attempts_set_updated_at
before update on public.aptitude_attempts
for each row execute function public.set_updated_at();

create trigger aptitude_answer_keys_set_updated_at
before update on proofhire_private.aptitude_answer_keys
for each row execute function public.set_updated_at();

-- END SOURCE: 202610290003_aptitude_assessment_schema.sql


-- BEGIN SOURCE: 202610290004_application_resume_versions.sql
-- Keep an application-scoped history of resume objects while retaining the
-- existing applications.resume_path field for compatibility.
create table public.application_resume_versions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  resume_path text not null check (char_length(trim(resume_path)) > 0),
  source text not null check (source in ('manual', 'public', 'import')),
  uploaded_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint application_resume_versions_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint application_resume_versions_application_path_unique
    unique (application_id, resume_path),
  constraint application_resume_versions_workspace_id_unique
    unique (workspace_id, id),
  constraint application_resume_versions_workspace_application_id_unique
    unique (workspace_id, application_id, id)
);

create index idx_application_resume_versions_application_created
  on public.application_resume_versions(workspace_id, application_id, created_at desc);

insert into public.application_resume_versions (
  workspace_id,
  application_id,
  resume_path,
  source,
  uploaded_by,
  created_at
)
select
  application.workspace_id,
  application.id,
  application.resume_path,
  application.source,
  application.created_by,
  coalesce(application.applied_at, application.created_at)
from public.applications as application
where application.resume_path is not null
  and char_length(trim(application.resume_path)) > 0
on conflict (application_id, resume_path) do nothing;

alter table public.application_resume_versions enable row level security;

create policy "Workspace members can read application resume versions"
on public.application_resume_versions
for select to authenticated
using (public.is_workspace_member(workspace_id));

revoke all on public.application_resume_versions from anon, authenticated;
grant select on public.application_resume_versions to authenticated;
grant all on public.application_resume_versions to service_role;

create or replace function public.capture_application_resume_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.resume_path is null or char_length(trim(new.resume_path)) = 0 then
    return new;
  end if;
  if tg_op = 'UPDATE' and new.resume_path is not distinct from old.resume_path then
    return new;
  end if;

  insert into public.application_resume_versions (
    workspace_id,
    application_id,
    resume_path,
    source,
    uploaded_by
  )
  values (
    new.workspace_id,
    new.id,
    new.resume_path,
    new.source,
    (select auth.uid())
  )
  on conflict (application_id, resume_path) do nothing;

  return new;
end;
$$;

revoke all on function public.capture_application_resume_version()
  from public, anon, authenticated;

create trigger applications_capture_resume_version
after insert or update of resume_path on public.applications
for each row execute function public.capture_application_resume_version();

alter table public.application_screening_jobs
  add column if not exists resume_version_id uuid;

alter table public.application_screening_jobs
  add constraint application_screening_jobs_resume_version_fk
  foreign key (workspace_id, application_id, resume_version_id)
  references public.application_resume_versions(workspace_id, application_id, id)
  on delete cascade;

create index idx_screening_jobs_resume_version
  on public.application_screening_jobs(resume_version_id)
  where resume_version_id is not null;

create or replace function public.link_screening_job_resume_version()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  select version.id
  into new.resume_version_id
  from public.applications as application
  join public.application_resume_versions as version
    on version.workspace_id = application.workspace_id
   and version.application_id = application.id
   and version.resume_path = application.resume_path
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;

  if new.resume_version_id is null then
    raise exception 'The screening job has no matching application resume version.';
  end if;
  return new;
end;
$$;

revoke all on function public.link_screening_job_resume_version()
  from public, anon, authenticated;

create trigger screening_jobs_link_resume_version
before insert on public.application_screening_jobs
for each row execute function public.link_screening_job_resume_version();

-- END SOURCE: 202610290004_application_resume_versions.sql


-- BEGIN SOURCE: 202610290007_aptitude_assessment_workflow.sql
-- Service-mediated aptitude invitations, candidate sessions, autosave, scoring,
-- and low-detail monitoring. Candidate APIs never return private answer keys.
create or replace function public.save_aptitude_answer_key(
  target_question_id uuid,
  target_answer_key jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  question_row public.aptitude_questions%rowtype;
  selected_option text;
  selected_count integer;
  unique_count integer;
begin
  select question.*
  into question_row
  from public.aptitude_questions question
  where question.id = target_question_id;
  if not found or not public.has_workspace_role(
    question_row.workspace_id,
    array['admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to edit this aptitude answer key.';
  end if;
  if not exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = question_row.workspace_id
      and version.id = question_row.test_version_id
      and version.version_status = 'draft'
  ) then
    raise exception 'Answer keys can only be changed on draft aptitude tests.';
  end if;
  if jsonb_typeof(target_answer_key) is distinct from 'object' then
    raise exception 'A valid aptitude answer key is required.';
  end if;

  if question_row.question_type in ('single_choice', 'multiple_choice') then
    if jsonb_typeof(target_answer_key -> 'option_ids') is distinct from 'array' then
      raise exception 'Choice answer keys must contain option IDs.';
    end if;
    select count(*), count(distinct selected.value)
    into selected_count, unique_count
    from jsonb_array_elements_text(target_answer_key -> 'option_ids')
      as selected(value);
    if selected_count = 0 or selected_count <> unique_count then
      raise exception 'Select at least one unique correct option.';
    end if;
    if question_row.question_type = 'single_choice' and selected_count <> 1 then
      raise exception 'Select exactly one correct option.';
    end if;
    for selected_option in
      select selected.value
      from jsonb_array_elements_text(target_answer_key -> 'option_ids')
        as selected(value)
    loop
      if not exists (
        select 1
        from public.aptitude_question_options option_row
        where option_row.workspace_id = question_row.workspace_id
          and option_row.question_id = question_row.id
          and option_row.id::text = selected_option
      ) then
        raise exception 'An answer key option does not belong to this question.';
      end if;
    end loop;
  elsif question_row.question_type = 'short_text' then
    if jsonb_typeof(target_answer_key -> 'accepted_answers') is distinct from 'array'
       or not exists (
         select 1
         from jsonb_array_elements_text(target_answer_key -> 'accepted_answers')
           as accepted(value)
         where char_length(trim(accepted.value)) > 0
       ) then
      raise exception 'Add at least one accepted short-text answer.';
    end if;
  else
    raise exception 'Unsupported aptitude question type.';
  end if;

  insert into proofhire_private.aptitude_answer_keys (
    workspace_id,
    question_id,
    answer_key
  )
  values (
    question_row.workspace_id,
    question_row.id,
    target_answer_key
  )
  on conflict (workspace_id, question_id)
  do update set answer_key = excluded.answer_key,
                updated_at = now();
end;
$$;

create or replace function public.create_aptitude_invitation(
  target_user_id uuid,
  target_workspace_id uuid,
  target_application_id uuid,
  target_test_version_id uuid,
  target_token_hash text,
  target_expires_at timestamptz,
  target_max_attempts integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate_email_value text;
  invitation_row public.aptitude_invitations%rowtype;
  test_title_value text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create aptitude invitations.';
  end if;
  if not exists (
    select 1
    from public.workspace_members workspace_member
    where workspace_member.workspace_id = target_workspace_id
      and workspace_member.user_id = target_user_id
      and workspace_member.role = any(array['admin', 'recruiter']::text[])
  ) then
    raise exception 'You do not have permission to invite this candidate.';
  end if;
  if target_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'A valid invitation token hash is required.';
  end if;
  select candidate.email
  into candidate_email_value
  from public.applications application
  join public.candidates candidate
    on candidate.workspace_id = application.workspace_id
   and candidate.id = application.candidate_id
  where application.workspace_id = target_workspace_id
    and application.id = target_application_id;
  if candidate_email_value is null then
    raise exception 'The application does not have a candidate email address.';
  end if;
  select test.title
  into test_title_value
  from public.aptitude_test_versions version
  join public.aptitude_tests test
    on test.workspace_id = version.workspace_id
   and test.id = version.test_id
  where version.workspace_id = target_workspace_id
    and version.id = target_test_version_id
    and version.version_status = 'published';
  if test_title_value is null then
    raise exception 'Select a published aptitude test.';
  end if;

  insert into public.aptitude_invitations (
    workspace_id,
    application_id,
    test_version_id,
    candidate_email,
    token_hash,
    status,
    email_status,
    email_error_code,
    expires_at,
    max_attempts,
    invited_by
  )
  select
    target_workspace_id,
    target_application_id,
    target_test_version_id,
    candidate_email_value,
    target_token_hash,
    'pending',
    'failed',
    'manual_delivery',
    target_expires_at,
    target_max_attempts,
    target_user_id
  from public.aptitude_test_versions version
  where version.workspace_id = target_workspace_id
    and version.id = target_test_version_id
    and version.version_status = 'published'
    and target_max_attempts between 1 and version.max_attempts;
  if not found then
    raise exception 'The invitation attempt limit is invalid.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash;
  return jsonb_build_object(
    'id', invitation_row.id,
    'workspace_id', invitation_row.workspace_id,
    'application_id', invitation_row.application_id,
    'test_version_id', invitation_row.test_version_id,
    'candidate_email', invitation_row.candidate_email,
    'test_title', test_title_value,
    'status', invitation_row.status,
    'expires_at', invitation_row.expires_at,
    'max_attempts', invitation_row.max_attempts,
    'email_status', invitation_row.email_status
  );
end;
$$;

create or replace function public.get_aptitude_candidate_session(
  target_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  version_row public.aptitude_test_versions%rowtype;
  test_title_value text;
  test_description_value text;
  attempt_count_value integer;
  active_attempt public.aptitude_attempts%rowtype;
  question_list jsonb;
  saved_answers_value jsonb := '{}'::jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to read aptitude sessions.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('pending', 'sent', 'started');
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = invitation_row.workspace_id
    and version.id = invitation_row.test_version_id
    and version.version_status = 'published';
  select test.title, test.description
  into test_title_value, test_description_value
  from public.aptitude_tests test
  where test.workspace_id = version_row.workspace_id
    and test.id = version_row.test_id;
  select count(*)
  into attempt_count_value
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id;
  select attempt.*
  into active_attempt
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.status = 'in_progress'
  order by attempt.attempt_number desc
  limit 1;
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', question.id,
        'display_order', question.display_order,
        'question_type', question.question_type,
        'prompt', question.prompt,
        'points', question.points,
        'options', (
          select coalesce(
            jsonb_agg(
              jsonb_build_object('id', option_row.id, 'option_text', option_row.option_text)
              order by option_row.display_order
            ),
            '[]'::jsonb
          )
          from public.aptitude_question_options option_row
          where option_row.workspace_id = question.workspace_id
            and option_row.question_id = question.id
        )
      )
      order by question.display_order
    ),
    '[]'::jsonb
  )
  into question_list
  from public.aptitude_questions question
  where question.workspace_id = invitation_row.workspace_id
    and question.test_version_id = invitation_row.test_version_id;
  if active_attempt.id is not null then
    select coalesce(
      jsonb_object_agg(answer.question_id::text, answer.answer),
      '{}'::jsonb
    )
    into saved_answers_value
    from public.aptitude_answers answer
    where answer.workspace_id = invitation_row.workspace_id
      and answer.attempt_id = active_attempt.id;
  end if;

  return jsonb_build_object(
    'invitation_id', invitation_row.id,
    'status', invitation_row.status,
    'expires_at', invitation_row.expires_at,
    'attempts_used', attempt_count_value,
    'max_attempts', invitation_row.max_attempts,
    'time_limit_seconds', version_row.time_limit_seconds,
    'passing_score', version_row.passing_score,
    'title', test_title_value,
    'description', test_description_value,
    'active_attempt_id', case when active_attempt.id is null then null else active_attempt.id end,
    'active_attempt_started_at', active_attempt.started_at,
    'saved_answers', saved_answers_value,
    'questions', question_list
  );
end;
$$;

create or replace function public.start_aptitude_candidate_attempt(
  target_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  active_attempt public.aptitude_attempts%rowtype;
  next_attempt_number integer;
  session_payload jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to start aptitude sessions.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('pending', 'sent', 'started')
  for update;
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;
  select attempt.*
  into active_attempt
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.status = 'in_progress'
  order by attempt.attempt_number desc
  limit 1
  for update;
  if found then
    if active_attempt.started_at + make_interval(
      secs => (
        select version.time_limit_seconds
        from public.aptitude_test_versions version
        where version.id = active_attempt.test_version_id
      )
    ) > now() then
      select public.get_aptitude_candidate_session(target_token_hash)
      into session_payload;
      return session_payload || jsonb_build_object(
        'attempt_id', active_attempt.id,
        'attempt_number', active_attempt.attempt_number,
        'started_at', active_attempt.started_at
      );
    end if;
    update public.aptitude_attempts
    set status = 'expired',
        submitted_at = now(),
        result = jsonb_build_object('reason', 'time_expired')
    where id = active_attempt.id;
    if active_attempt.attempt_number >= invitation_row.max_attempts then
      update public.aptitude_invitations
      set status = 'completed'
      where id = invitation_row.id;
      return jsonb_build_object(
        'status', 'completed',
        'attempts_used', active_attempt.attempt_number,
        'max_attempts', invitation_row.max_attempts
      );
    end if;
  end if;

  select count(*) + 1
  into next_attempt_number
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id;
  if next_attempt_number > invitation_row.max_attempts then
    update public.aptitude_invitations
    set status = 'completed'
    where id = invitation_row.id;
    return jsonb_build_object(
      'status', 'completed',
      'attempts_used', next_attempt_number - 1,
      'max_attempts', invitation_row.max_attempts
    );
  end if;
  insert into public.aptitude_attempts (
    workspace_id,
    invitation_id,
    test_version_id,
    attempt_number
  )
  values (
    invitation_row.workspace_id,
    invitation_row.id,
    invitation_row.test_version_id,
    next_attempt_number
  )
  returning * into active_attempt;
  select public.get_aptitude_candidate_session(target_token_hash)
  into session_payload;
  return session_payload || jsonb_build_object(
    'attempt_id', active_attempt.id,
    'attempt_number', active_attempt.attempt_number,
    'started_at', active_attempt.started_at
  );
end;
$$;

create or replace function public.save_aptitude_candidate_answer(
  target_token_hash text,
  target_attempt_id uuid,
  target_question_id uuid,
  target_answer jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  attempt_row public.aptitude_attempts%rowtype;
  question_row public.aptitude_questions%rowtype;
  selected_count integer;
  unique_count integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to save aptitude answers.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('pending', 'sent', 'started');
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;
  select attempt.*
  into attempt_row
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.id = target_attempt_id
    and attempt.status = 'in_progress'
  for update;
  if not found then
    raise exception 'The aptitude attempt is not active.';
  end if;
  select question.*
  into question_row
  from public.aptitude_questions question
  join public.aptitude_test_versions version
    on version.workspace_id = question.workspace_id
   and version.id = question.test_version_id
  where question.workspace_id = invitation_row.workspace_id
    and question.test_version_id = invitation_row.test_version_id
    and question.id = target_question_id
    and attempt_row.started_at + make_interval(secs => version.time_limit_seconds) > now();
  if not found then
    raise exception 'The aptitude question is unavailable or the attempt has expired.';
  end if;
  if question_row.question_type in ('single_choice', 'multiple_choice') then
    if jsonb_typeof(target_answer -> 'option_ids') is distinct from 'array' then
      raise exception 'Select one or more listed options.';
    end if;
    select count(*), count(distinct selected.value)
    into selected_count, unique_count
    from jsonb_array_elements_text(target_answer -> 'option_ids')
      as selected(value);
    if selected_count <> unique_count
       or (question_row.question_type = 'single_choice' and selected_count > 1)
       or exists (
         select 1
         from jsonb_array_elements_text(target_answer -> 'option_ids')
           as selected(value)
         where not exists (
           select 1
           from public.aptitude_question_options option_row
           where option_row.workspace_id = question_row.workspace_id
             and option_row.question_id = question_row.id
             and option_row.id::text = selected.value
         )
       ) then
      raise exception 'The answer contains an invalid option.';
    end if;
  elsif question_row.question_type = 'short_text' then
    if jsonb_typeof(target_answer) is distinct from 'string'
       or char_length(target_answer #>> '{}') > 5000 then
      raise exception 'Enter a short-text answer of at most 5000 characters.';
    end if;
  else
    raise exception 'Unsupported aptitude question type.';
  end if;

  insert into public.aptitude_answers (
    workspace_id,
    attempt_id,
    test_version_id,
    question_id,
    answer,
    saved_at
  )
  values (
    attempt_row.workspace_id,
    attempt_row.id,
    attempt_row.test_version_id,
    question_row.id,
    target_answer,
    now()
  )
  on conflict (attempt_id, question_id)
  do update set answer = excluded.answer, saved_at = now();
  return true;
end;
$$;

create or replace function public.submit_aptitude_candidate_attempt(
  target_token_hash text,
  target_attempt_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  attempt_row public.aptitude_attempts%rowtype;
  version_row public.aptitude_test_versions%rowtype;
  question_row record;
  answer_value jsonb;
  candidate_options text[];
  correct_options text[];
  total_points numeric := 0;
  earned_points numeric := 0;
  answer_count integer := 0;
  question_count integer := 0;
  is_correct boolean;
  score_value numeric(5, 2);
  passed_value boolean;
  result_value jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to submit aptitude attempts.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
  for update;
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;
  select attempt.*
  into attempt_row
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.id = target_attempt_id
  for update;
  if not found then
    raise exception 'The aptitude attempt was not found.';
  end if;
  if attempt_row.status in ('submitted', 'expired') then
    return jsonb_build_object(
      'attempt_id', attempt_row.id,
      'status', attempt_row.status,
      'score', attempt_row.score,
      'result', attempt_row.result
    );
  end if;
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = invitation_row.workspace_id
    and version.id = invitation_row.test_version_id;
  if attempt_row.started_at + make_interval(secs => version_row.time_limit_seconds) <= now()
     or invitation_row.expires_at <= now() then
    update public.aptitude_attempts
    set status = 'expired',
        submitted_at = now(),
        result = jsonb_build_object('reason', 'time_expired')
    where id = attempt_row.id;
    update public.aptitude_invitations
    set status = case
      when attempt_row.attempt_number >= invitation_row.max_attempts then 'completed'
      else 'started'
    end
    where id = invitation_row.id;
    return jsonb_build_object(
      'attempt_id', attempt_row.id,
      'status', 'expired',
      'score', null,
      'result', jsonb_build_object('reason', 'time_expired')
    );
  end if;

  for question_row in
    select
      question.id,
      question.question_type,
      question.points,
      answer_key.answer_key
    from public.aptitude_questions question
    join proofhire_private.aptitude_answer_keys answer_key
      on answer_key.workspace_id = question.workspace_id
     and answer_key.question_id = question.id
    where question.workspace_id = invitation_row.workspace_id
      and question.test_version_id = invitation_row.test_version_id
    order by question.display_order
  loop
    question_count := question_count + 1;
    total_points := total_points + question_row.points;
    select answer.answer
    into answer_value
    from public.aptitude_answers answer
    where answer.workspace_id = attempt_row.workspace_id
      and answer.attempt_id = attempt_row.id
      and answer.question_id = question_row.id;
    if found then
      answer_count := answer_count + 1;
      if question_row.question_type in ('single_choice', 'multiple_choice') then
        select coalesce(array_agg(selected.value order by selected.value), array[]::text[])
        into candidate_options
        from jsonb_array_elements_text(answer_value -> 'option_ids') as selected(value);
        select coalesce(array_agg(selected.value order by selected.value), array[]::text[])
        into correct_options
        from jsonb_array_elements_text(question_row.answer_key -> 'option_ids') as selected(value);
        is_correct := candidate_options = correct_options;
      else
        is_correct := exists (
          select 1
          from jsonb_array_elements_text(question_row.answer_key -> 'accepted_answers')
            as accepted(value)
          where lower(trim(accepted.value)) = lower(trim(answer_value #>> '{}'))
        );
      end if;
      if is_correct then
        earned_points := earned_points + question_row.points;
      end if;
    end if;
  end loop;
  score_value := round(earned_points / nullif(total_points, 0) * 100, 2);
  passed_value := case
    when version_row.passing_score is null then null
    else score_value >= version_row.passing_score
  end;
  result_value := jsonb_build_object(
    'earned_points', earned_points,
    'available_points', total_points,
    'answered_questions', answer_count,
    'question_count', question_count,
    'passed', passed_value
  );
  update public.aptitude_attempts
  set status = 'submitted',
      submitted_at = now(),
      score = score_value,
      result = result_value
  where id = attempt_row.id;
  update public.aptitude_invitations
  set status = case
    when attempt_row.attempt_number >= invitation_row.max_attempts then 'completed'
    else 'started'
  end
  where id = invitation_row.id;
  return jsonb_build_object(
    'attempt_id', attempt_row.id,
    'status', 'submitted',
    'score', score_value,
    'result', result_value,
    'passing_score', version_row.passing_score
  );
end;
$$;

create or replace function public.record_aptitude_candidate_event(
  target_token_hash text,
  target_attempt_id uuid,
  target_event_type text,
  target_event_data jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  event_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to record aptitude events.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  join public.aptitude_attempts attempt
    on attempt.workspace_id = invitation.workspace_id
   and attempt.invitation_id = invitation.id
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('started', 'completed')
    and attempt.id = target_attempt_id
    and attempt.status = 'in_progress';
  if not found or jsonb_typeof(target_event_data) is distinct from 'object'
     or octet_length(target_event_data::text) > 2048 then
    raise exception 'The aptitude monitoring event is invalid.';
  end if;
  insert into public.aptitude_monitoring_events (
    workspace_id,
    attempt_id,
    event_type,
    event_data
  )
  values (
    invitation_row.workspace_id,
    target_attempt_id,
    target_event_type,
    target_event_data
  )
  returning id into event_id;
  return event_id;
end;
$$;

revoke all on function public.save_aptitude_answer_key(uuid, jsonb)
  from public, anon;
grant execute on function public.save_aptitude_answer_key(uuid, jsonb)
  to authenticated;
revoke all on function public.create_aptitude_invitation(uuid, uuid, uuid, uuid, text, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.create_aptitude_invitation(uuid, uuid, uuid, uuid, text, timestamptz, integer)
  to service_role;
revoke all on function public.get_aptitude_candidate_session(text)
  from public, anon, authenticated;
grant execute on function public.get_aptitude_candidate_session(text)
  to service_role;
revoke all on function public.start_aptitude_candidate_attempt(text)
  from public, anon, authenticated;
grant execute on function public.start_aptitude_candidate_attempt(text)
  to service_role;
revoke all on function public.save_aptitude_candidate_answer(text, uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_aptitude_candidate_answer(text, uuid, uuid, jsonb)
  to service_role;
revoke all on function public.submit_aptitude_candidate_attempt(text, uuid)
  from public, anon, authenticated;
grant execute on function public.submit_aptitude_candidate_attempt(text, uuid)
  to service_role;
revoke all on function public.record_aptitude_candidate_event(text, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.record_aptitude_candidate_event(text, uuid, text, jsonb)
  to service_role;

-- END SOURCE: 202610290007_aptitude_assessment_workflow.sql


-- BEGIN SOURCE: 202611020001_application_stage_history_and_interviews.sql
-- Add append-only stage history and structured, workspace-scoped interview
-- scheduling/feedback without replacing existing application or interview data.
create table public.application_stage_history (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  from_status text,
  to_status text not null check (
    to_status in ('new', 'screening', 'shortlisted', 'rejected', 'interview', 'hired')
  ),
  event_source text not null check (
    event_source in ('application_created', 'status_changed', 'baseline')
  ),
  actor_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint application_stage_history_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade
);

create index idx_application_stage_history_application_created
  on public.application_stage_history(workspace_id, application_id, created_at desc);

alter table public.application_stage_history enable row level security;

create policy "Workspace members can read application stage history"
on public.application_stage_history
for select to authenticated
using (public.is_workspace_member(workspace_id));

revoke all on public.application_stage_history from public, anon, authenticated;
grant select on public.application_stage_history to authenticated;
grant all on public.application_stage_history to service_role;

create or replace function public.capture_application_stage_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.application_stage_history (
      workspace_id,
      application_id,
      from_status,
      to_status,
      event_source,
      actor_id
    )
    values (
      new.workspace_id,
      new.id,
      null,
      new.status,
      'application_created',
      (select auth.uid())
    );
    return new;
  end if;

  if new.status is distinct from old.status then
    insert into public.application_stage_history (
      workspace_id,
      application_id,
      from_status,
      to_status,
      event_source,
      actor_id
    )
    values (
      new.workspace_id,
      new.id,
      old.status,
      new.status,
      'status_changed',
      (select auth.uid())
    );
  end if;
  return new;
end;
$$;

revoke all on function public.capture_application_stage_history()
  from public, anon, authenticated;

drop trigger if exists applications_capture_stage_history
  on public.applications;
create trigger applications_capture_stage_history
after insert or update of status on public.applications
for each row execute function public.capture_application_stage_history();

-- Existing rows can only be represented by their current stage; prior
-- transitions are not inferred or fabricated.
insert into public.application_stage_history (
  workspace_id,
  application_id,
  from_status,
  to_status,
  event_source,
  actor_id,
  created_at
)
select
  application.workspace_id,
  application.id,
  null,
  application.status,
  'baseline',
  null,
  coalesce(application.created_at, application.applied_at, now())
from public.applications as application
where not exists (
  select 1
  from public.application_stage_history as history
  where history.application_id = application.id
    and history.event_source in ('application_created', 'baseline')
);

alter table public.interview_records
  add column if not exists scheduled_end_at timestamptz,
  add column if not exists timezone text not null default 'UTC',
  add column if not exists interview_mode text not null default 'unspecified',
  add column if not exists location_or_url text,
  add column if not exists cancelled_at timestamptz;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.interview_records'::regclass
      and conname = 'interview_records_schedule_end_check'
  ) then
    alter table public.interview_records
      add constraint interview_records_schedule_end_check
      check (scheduled_end_at is null or scheduled_end_at > scheduled_at);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.interview_records'::regclass
      and conname = 'interview_records_mode_check'
  ) then
    alter table public.interview_records
      add constraint interview_records_mode_check
      check (interview_mode in ('unspecified', 'video', 'phone', 'onsite'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.interview_records'::regclass
      and conname = 'interview_records_timezone_check'
  ) then
    alter table public.interview_records
      add constraint interview_records_timezone_check
      check (char_length(trim(timezone)) between 1 and 64);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.interview_records'::regclass
      and conname = 'interview_records_workspace_id_unique'
  ) then
    alter table public.interview_records
      add constraint interview_records_workspace_id_unique
      unique (workspace_id, id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.interview_records'::regclass
      and conname = 'interview_records_workspace_application_unique'
  ) then
    alter table public.interview_records
      add constraint interview_records_workspace_application_unique
      unique (workspace_id, id, application_id);
  end if;
end;
$migration$;

create table public.interview_schedule_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  interview_id uuid not null,
  event_type text not null check (
    event_type in ('scheduled', 'rescheduled', 'cancelled', 'completed', 'updated')
  ),
  previous_start_at timestamptz,
  next_start_at timestamptz,
  previous_status text,
  next_status text not null,
  actor_id uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint interview_schedule_events_interview_fk
    foreign key (workspace_id, interview_id)
    references public.interview_records(workspace_id, id)
    on delete cascade
);

create index idx_interview_schedule_events_interview_created
  on public.interview_schedule_events(workspace_id, interview_id, created_at desc);

create table public.interview_assignments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  interview_id uuid not null,
  user_id uuid references auth.users(id) on delete set null,
  display_name text not null
    check (char_length(trim(display_name)) between 1 and 180),
  email text
    check (email is null or char_length(email) between 3 and 320),
  assigned_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint interview_assignments_interview_fk
    foreign key (workspace_id, interview_id)
    references public.interview_records(workspace_id, id)
    on delete cascade,
  constraint interview_assignments_workspace_id_unique
    unique (workspace_id, id),
  constraint interview_assignments_workspace_interview_id_unique
    unique (workspace_id, interview_id, id)
);

create unique index idx_interview_assignments_user_unique
  on public.interview_assignments(interview_id, user_id)
  where user_id is not null;

create unique index idx_interview_assignments_email_unique
  on public.interview_assignments(interview_id, lower(btrim(email)))
  where user_id is null and email is not null;

create table public.interview_feedback (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  interview_id uuid not null,
  assignment_id uuid,
  submitted_by uuid references auth.users(id) on delete set null,
  recommendation text not null check (
    recommendation in ('strong_yes', 'yes', 'mixed', 'no', 'strong_no')
  ),
  strengths text[] not null default '{}'::text[],
  concerns text[] not null default '{}'::text[],
  notes text check (notes is null or char_length(notes) <= 10000),
  submitted_at timestamptz not null default now(),
   constraint interview_feedback_workspace_id_unique
    unique (workspace_id, id),
  constraint interview_feedback_interview_fk
    foreign key (workspace_id, interview_id)
    references public.interview_records(workspace_id, id)
    on delete cascade,
  constraint interview_feedback_assignment_fk
    foreign key (workspace_id, interview_id, assignment_id)
    references public.interview_assignments(workspace_id, interview_id, id)
    on delete set null (assignment_id)
);

create index idx_interview_feedback_interview_submitted
  on public.interview_feedback(workspace_id, interview_id, submitted_at desc);

create table public.interview_feedback_criteria (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  feedback_id uuid not null,
  criterion text not null
    check (char_length(trim(criterion)) between 1 and 180),
  rating numeric(3, 2) not null check (rating between 1 and 5),
  notes text check (notes is null or char_length(notes) <= 2000),
  created_at timestamptz not null default now(),
  constraint interview_feedback_criteria_feedback_fk
    foreign key (workspace_id, feedback_id)
    references public.interview_feedback(workspace_id, id)
    on delete cascade,
  constraint interview_feedback_criteria_unique
    unique (feedback_id, criterion)
);

create index idx_interview_feedback_criteria_feedback
  on public.interview_feedback_criteria(workspace_id, feedback_id);

create or replace function public.capture_interview_schedule_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  event_name text;
begin
  if tg_op = 'INSERT' then
    event_name := case new.interview_status
      when 'cancelled' then 'cancelled'
      when 'completed' then 'completed'
      else 'scheduled'
    end;
  elsif new.interview_status is distinct from old.interview_status
        and new.interview_status = 'rescheduled' then
    event_name := 'rescheduled';
  elsif new.interview_status is distinct from old.interview_status
        and new.interview_status = 'cancelled' then
    event_name := 'cancelled';
  elsif new.interview_status is distinct from old.interview_status
        and new.interview_status = 'completed' then
    event_name := 'completed';
  elsif new.scheduled_at is distinct from old.scheduled_at
        or new.scheduled_end_at is distinct from old.scheduled_end_at then
    event_name := 'rescheduled';
  elsif new.interview_status is distinct from old.interview_status then
    event_name := 'updated';
  else
    return new;
  end if;

  insert into public.interview_schedule_events (
    workspace_id,
    interview_id,
    event_type,
    previous_start_at,
    next_start_at,
    previous_status,
    next_status,
    actor_id
  )
  values (
    new.workspace_id,
    new.id,
    event_name,
    case when tg_op = 'UPDATE' then old.scheduled_at else null end,
    new.scheduled_at,
    case when tg_op = 'UPDATE' then old.interview_status else null end,
    new.interview_status,
    (select auth.uid())
  );
  return new;
end;
$$;

create or replace function public.set_interview_cancelled_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.interview_status = 'cancelled' then
    new.cancelled_at := coalesce(new.cancelled_at, now());
  end if;
  return new;
end;
$$;

revoke all on function public.capture_interview_schedule_history()
  from public, anon, authenticated;
revoke all on function public.set_interview_cancelled_at()
  from public, anon, authenticated;

drop trigger if exists interview_records_capture_schedule_history
  on public.interview_records;
create trigger interview_records_set_cancelled_at
before insert or update of interview_status on public.interview_records
for each row execute function public.set_interview_cancelled_at();

create trigger interview_records_capture_schedule_history
after insert or update of scheduled_at, scheduled_end_at, interview_status
on public.interview_records
for each row execute function public.capture_interview_schedule_history();

alter table public.interview_schedule_events enable row level security;
alter table public.interview_assignments enable row level security;
alter table public.interview_feedback enable row level security;
alter table public.interview_feedback_criteria enable row level security;

create policy "Recruiters can read interview schedule events"
on public.interview_schedule_events
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Recruiters can manage interview assignments"
on public.interview_assignments
for all to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']))
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and (assigned_by is null or assigned_by = (select auth.uid()))
  and (
    user_id is null
    or exists (
      select 1 from public.workspace_members member
      where member.workspace_id = interview_assignments.workspace_id
        and member.user_id = interview_assignments.user_id
    )
  )
  and exists (
    select 1 from public.interview_records interview
    where interview.workspace_id = interview_assignments.workspace_id
      and interview.id = interview_assignments.interview_id
  )
);

create policy "Recruiters can read interview feedback"
on public.interview_feedback
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Recruiters can add interview feedback"
on public.interview_feedback
for insert to authenticated
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and submitted_by = (select auth.uid())
);

create policy "Recruiters can read interview feedback criteria"
on public.interview_feedback_criteria
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Recruiters can add interview feedback criteria"
on public.interview_feedback_criteria
for insert to authenticated
with check (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

revoke all on public.interview_schedule_events from public, anon, authenticated;
revoke all on public.interview_assignments from public, anon, authenticated;
revoke all on public.interview_feedback from public, anon, authenticated;
revoke all on public.interview_feedback_criteria from public, anon, authenticated;
grant select on public.interview_schedule_events to authenticated;
grant select, insert, update, delete on public.interview_assignments to authenticated;
grant select, insert on public.interview_feedback to authenticated;
grant select, insert on public.interview_feedback_criteria to authenticated;
grant all on public.interview_schedule_events to service_role;
grant all on public.interview_assignments to service_role;
grant all on public.interview_feedback to service_role;
grant all on public.interview_feedback_criteria to service_role;

grant update (
  scheduled_at,
  scheduled_end_at,
  timezone,
  interview_mode,
  location_or_url,
  interview_status,
  outcome,
  feedback
) on public.interview_records to authenticated;

-- END SOURCE: 202611020001_application_stage_history_and_interviews.sql


-- BEGIN SOURCE: 202610290002_account_deletion_and_screening_indexes.sql
-- Preserve recruiter audit records when a user account is deleted, and index
-- the screening worker's expired-lease recovery query.
alter table public.application_decision_events
  alter column created_by drop not null,
  drop constraint if exists application_decision_events_created_by_fkey,
  add constraint application_decision_events_created_by_fkey
    foreign key (created_by)
    references auth.users(id)
    on delete set null;

alter table public.interview_records
  alter column created_by drop not null,
  drop constraint if exists interview_records_created_by_fkey,
  add constraint interview_records_created_by_fkey
    foreign key (created_by)
    references auth.users(id)
    on delete set null;

create index if not exists idx_screening_jobs_expired_lease
  on public.application_screening_jobs(locked_until, created_at)
  where status = 'processing';

-- END SOURCE: 202610290002_account_deletion_and_screening_indexes.sql


-- BEGIN SOURCE: 202611020002_aptitude_assessment_foundation_completion.sql
-- Complete the existing aptitude foundation with job configuration,
-- per-attempt question ordering, question-level scores, and recruiter metadata.
alter table public.aptitude_questions
  add column if not exists category text not null default 'general',
  add column if not exists difficulty text not null default 'medium';

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_questions'::regclass
      and conname = 'aptitude_questions_category_check'
  ) then
    alter table public.aptitude_questions
      add constraint aptitude_questions_category_check
      check (char_length(trim(category)) between 1 and 120);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_questions'::regclass
      and conname = 'aptitude_questions_difficulty_check'
  ) then
    alter table public.aptitude_questions
      add constraint aptitude_questions_difficulty_check
      check (difficulty in ('beginner', 'medium', 'advanced', 'expert'));
  end if;
end;
$migration$;

create table public.job_aptitude_assessments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  job_id uuid not null,
  test_version_id uuid not null,
  is_required boolean not null default false,
  display_order integer not null default 1 check (display_order > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_aptitude_assessments_job_fk
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,
  constraint job_aptitude_assessments_version_fk
    foreign key (workspace_id, test_version_id)
    references public.aptitude_test_versions(workspace_id, id)
    on delete restrict,
  constraint job_aptitude_assessments_job_version_unique
    unique (workspace_id, job_id, test_version_id),
  constraint job_aptitude_assessments_workspace_id_unique
    unique (workspace_id, id),
  constraint job_aptitude_assessments_invitation_key_unique
    unique (workspace_id, id, job_id, test_version_id)
);

create index idx_job_aptitude_assessments_job_order
  on public.job_aptitude_assessments(workspace_id, job_id, display_order);

drop trigger if exists job_aptitude_assessments_set_updated_at
  on public.job_aptitude_assessments;
create trigger job_aptitude_assessments_set_updated_at
before update on public.job_aptitude_assessments
for each row execute function public.set_updated_at();

alter table public.job_aptitude_assessments enable row level security;

create policy "Workspace members can read job aptitude assessments"
on public.job_aptitude_assessments
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can manage job aptitude assessments"
on public.job_aptitude_assessments
for all to authenticated
using (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = job_aptitude_assessments.workspace_id
      and version.id = job_aptitude_assessments.test_version_id
      and version.version_status = 'published'
  )
)
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and (created_by is null or created_by = (select auth.uid()))
  and exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = job_aptitude_assessments.workspace_id
      and version.id = job_aptitude_assessments.test_version_id
      and version.version_status = 'published'
  )
);

revoke all on public.job_aptitude_assessments from public, anon, authenticated;
grant select, insert, update, delete
  on public.job_aptitude_assessments to authenticated;
grant all on public.job_aptitude_assessments to service_role;

alter table public.aptitude_invitations
  add column if not exists job_id uuid,
  add column if not exists job_aptitude_assessment_id uuid;

insert into public.job_aptitude_assessments (
  workspace_id,
  job_id,
  test_version_id,
  is_required,
  display_order,
  created_by
)
select distinct
  application.workspace_id,
  application.job_id,
  invitation.test_version_id,
  false,
  1,
  invitation.invited_by
from public.aptitude_invitations invitation
join public.applications application
  on application.workspace_id = invitation.workspace_id
 and application.id = invitation.application_id
on conflict (workspace_id, job_id, test_version_id) do nothing;

update public.aptitude_invitations invitation
set job_id = application.job_id,
    job_aptitude_assessment_id = configuration.id
from public.applications application
join public.job_aptitude_assessments configuration
  on configuration.workspace_id = application.workspace_id
 and configuration.job_id = application.job_id
where application.workspace_id = invitation.workspace_id
  and application.id = invitation.application_id
  and configuration.test_version_id = invitation.test_version_id
  and (
    invitation.job_id is distinct from application.job_id
    or invitation.job_aptitude_assessment_id is distinct from configuration.id
  );

alter table public.aptitude_invitations
  alter column job_id set not null,
  alter column job_aptitude_assessment_id set not null;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_job_fk'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_job_fk
      foreign key (job_id, workspace_id)
      references public.jobs(id, workspace_id)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_job_configuration_fk'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_job_configuration_fk
      foreign key (
        workspace_id,
        job_aptitude_assessment_id,
        job_id,
        test_version_id
      )
      references public.job_aptitude_assessments(
        workspace_id,
        id,
        job_id,
        test_version_id
      )
      on delete restrict;
  end if;
end;
$migration$;

create table public.aptitude_attempt_questions (
  workspace_id uuid not null,
  attempt_id uuid not null,
  test_version_id uuid not null,
  question_id uuid not null,
  display_order integer not null check (display_order > 0),
  assigned_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  constraint aptitude_attempt_questions_attempt_fk
    foreign key (workspace_id, attempt_id, test_version_id)
    references public.aptitude_attempts(workspace_id, id, test_version_id)
    on delete cascade,
  constraint aptitude_attempt_questions_question_fk
    foreign key (workspace_id, test_version_id, question_id)
    references public.aptitude_questions(workspace_id, test_version_id, id)
    on delete cascade,
  constraint aptitude_attempt_questions_order_unique
    unique (attempt_id, display_order),
  constraint aptitude_attempt_questions_workspace_fk_key
    unique (workspace_id, attempt_id, question_id)
);

create index idx_aptitude_attempt_questions_order
  on public.aptitude_attempt_questions(workspace_id, attempt_id, display_order);

alter table public.aptitude_attempt_questions enable row level security;
revoke all on public.aptitude_attempt_questions from public, anon, authenticated;
grant all on public.aptitude_attempt_questions to service_role;

insert into public.aptitude_attempt_questions (
  workspace_id,
  attempt_id,
  test_version_id,
  question_id,
  display_order
)
select
  attempt.workspace_id,
  attempt.id,
  attempt.test_version_id,
  question.id,
  row_number() over (
    partition by attempt.id
    order by question.display_order, question.id
  )::integer
from public.aptitude_attempts attempt
join public.aptitude_questions question
  on question.workspace_id = attempt.workspace_id
 and question.test_version_id = attempt.test_version_id
on conflict (attempt_id, question_id) do nothing;

create table proofhire_private.aptitude_answer_scores (
  workspace_id uuid not null,
  attempt_id uuid not null,
  question_id uuid not null,
  earned_points numeric(8, 2) not null check (earned_points >= 0),
  maximum_points numeric(8, 2) not null check (maximum_points > 0),
  is_correct boolean not null,
  evaluated_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  constraint aptitude_answer_scores_attempt_question_fk
    foreign key (workspace_id, attempt_id, question_id)
    references public.aptitude_attempt_questions(workspace_id, attempt_id, question_id)
    on delete cascade,
  constraint aptitude_answer_scores_points_check
    check (earned_points <= maximum_points)
);

alter table proofhire_private.aptitude_answer_scores enable row level security;
revoke all on proofhire_private.aptitude_answer_scores
  from public, anon, authenticated;
grant all on proofhire_private.aptitude_answer_scores to service_role;

alter table public.aptitude_attempts
  add column if not exists evaluated_at timestamptz;

insert into proofhire_private.aptitude_answer_scores (
  workspace_id,
  attempt_id,
  question_id,
  earned_points,
  maximum_points,
  is_correct,
  evaluated_at
)
select
  attempt.workspace_id,
  attempt.id,
  question.id,
  case when correctness.is_correct then question.points else 0 end,
  question.points,
  correctness.is_correct,
  coalesce(attempt.evaluated_at, attempt.submitted_at, now())
from public.aptitude_attempts attempt
join public.aptitude_attempt_questions assignment
  on assignment.workspace_id = attempt.workspace_id
 and assignment.attempt_id = attempt.id
join public.aptitude_questions question
  on question.workspace_id = assignment.workspace_id
 and question.test_version_id = assignment.test_version_id
 and question.id = assignment.question_id
join proofhire_private.aptitude_answer_keys answer_key
  on answer_key.workspace_id = question.workspace_id
 and answer_key.question_id = question.id
left join public.aptitude_answers answer
  on answer.workspace_id = attempt.workspace_id
 and answer.attempt_id = attempt.id
 and answer.question_id = question.id
cross join lateral (
  select case
    when answer.answer is null then false
    when question.question_type in ('single_choice', 'multiple_choice') then
      (
        select coalesce(
          array_agg(selected.value order by selected.value),
          array[]::text[]
        )
        from jsonb_array_elements_text(
          coalesce(answer.answer -> 'option_ids', '[]'::jsonb)
        ) as selected(value)
      ) = (
        select coalesce(
          array_agg(selected.value order by selected.value),
          array[]::text[]
        )
        from jsonb_array_elements_text(answer_key.answer_key -> 'option_ids')
          as selected(value)
      )
    else exists (
      select 1
      from jsonb_array_elements_text(
        answer_key.answer_key -> 'accepted_answers'
      ) as accepted(value)
      where lower(trim(accepted.value)) =
        lower(trim(answer.answer #>> '{}'))
    )
  end as is_correct
) correctness
where attempt.status = 'submitted'
on conflict (attempt_id, question_id) do nothing;

create or replace function public.validate_aptitude_invitation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.aptitude_test_versions%rowtype;
  application_job_id uuid;
  configuration_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create aptitude invitations.';
  end if;

  select application.job_id
  into application_job_id
  from public.applications application
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if application_job_id is null then
    raise exception 'The aptitude invitation application was not found.';
  end if;

  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = new.workspace_id
    and version.id = new.test_version_id;
  if not found or version_row.version_status <> 'published' then
    raise exception 'Invitations require a published aptitude test version.';
  end if;
  if new.max_attempts > version_row.max_attempts then
    raise exception 'Invitation attempt limit exceeds its published test version.';
  end if;
  if new.expires_at <= now() then
    raise exception 'Aptitude invitation expiry must be in the future.';
  end if;

  new.job_id := application_job_id;
  insert into public.job_aptitude_assessments (
    workspace_id,
    job_id,
    test_version_id,
    is_required,
    display_order,
    created_by
  )
  values (
    new.workspace_id,
    application_job_id,
    new.test_version_id,
    false,
    1,
    new.invited_by
  )
  on conflict (workspace_id, job_id, test_version_id) do nothing;

  select configuration.id
  into configuration_id
  from public.job_aptitude_assessments configuration
  where configuration.workspace_id = new.workspace_id
    and configuration.job_id = application_job_id
    and configuration.test_version_id = new.test_version_id;
  if configuration_id is null then
    raise exception 'The job aptitude configuration could not be established.';
  end if;
  new.job_aptitude_assessment_id := configuration_id;
  return new;
end;
$$;

revoke all on function public.validate_aptitude_invitation()
  from public, anon, authenticated;

drop trigger if exists aptitude_invitations_require_published_version
  on public.aptitude_invitations;
create trigger aptitude_invitations_require_published_version
before insert or update of workspace_id, application_id, test_version_id,
  max_attempts, expires_at
on public.aptitude_invitations
for each row execute function public.validate_aptitude_invitation();

create or replace function public.get_aptitude_candidate_session(
  target_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  version_row public.aptitude_test_versions%rowtype;
  test_title_value text;
  test_description_value text;
  attempt_count_value integer;
  active_attempt public.aptitude_attempts%rowtype;
  question_list jsonb;
  saved_answers_value jsonb := '{}'::jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to read aptitude sessions.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('pending', 'sent', 'started');
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;

  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = invitation_row.workspace_id
    and version.id = invitation_row.test_version_id
    and version.version_status = 'published';
  if not found then
    raise exception 'The aptitude test version is unavailable.';
  end if;

  select test.title, test.description
  into test_title_value, test_description_value
  from public.aptitude_tests test
  where test.workspace_id = version_row.workspace_id
    and test.id = version_row.test_id;

  select count(*)
  into attempt_count_value
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id;

  select attempt.*
  into active_attempt
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.status = 'in_progress'
  order by attempt.attempt_number desc
  limit 1;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', question.id,
        'display_order', question_order.display_order,
        'question_type', question.question_type,
        'prompt', question.prompt,
        'points', question.points,
        'category', question.category,
        'difficulty', question.difficulty,
        'options', (
          select coalesce(
            jsonb_agg(
              jsonb_build_object('id', option_row.id, 'option_text', option_row.option_text)
              order by option_row.display_order
            ),
            '[]'::jsonb
          )
          from public.aptitude_question_options option_row
          where option_row.workspace_id = question.workspace_id
            and option_row.question_id = question.id
        )
      )
      order by question_order.display_order
    ),
    '[]'::jsonb
  )
  into question_list
  from (
    select assignment.question_id, assignment.display_order
    from public.aptitude_attempt_questions assignment
    where active_attempt.id is not null
      and assignment.workspace_id = invitation_row.workspace_id
      and assignment.attempt_id = active_attempt.id
    union all
    select question.id, question.display_order
    from public.aptitude_questions question
    where active_attempt.id is null
      and question.workspace_id = invitation_row.workspace_id
      and question.test_version_id = invitation_row.test_version_id
  ) question_order
  join public.aptitude_questions question
    on question.workspace_id = invitation_row.workspace_id
   and question.test_version_id = invitation_row.test_version_id
   and question.id = question_order.question_id;

  if active_attempt.id is not null then
    select coalesce(
      jsonb_object_agg(answer.question_id::text, answer.answer),
      '{}'::jsonb
    )
    into saved_answers_value
    from public.aptitude_answers answer
    where answer.workspace_id = invitation_row.workspace_id
      and answer.attempt_id = active_attempt.id;
  end if;

  return jsonb_build_object(
    'invitation_id', invitation_row.id,
    'status', invitation_row.status,
    'expires_at', invitation_row.expires_at,
    'attempts_used', attempt_count_value,
    'max_attempts', invitation_row.max_attempts,
    'time_limit_seconds', version_row.time_limit_seconds,
    'passing_score', version_row.passing_score,
    'title', test_title_value,
    'description', test_description_value,
    'active_attempt_id', case when active_attempt.id is null then null else active_attempt.id end,
    'active_attempt_started_at', active_attempt.started_at,
    'saved_answers', saved_answers_value,
    'questions', question_list
  );
end;
$$;

create or replace function public.start_aptitude_candidate_attempt(
  target_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  active_attempt public.aptitude_attempts%rowtype;
  next_attempt_number integer;
  session_payload jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to start aptitude sessions.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('pending', 'sent', 'started')
  for update;
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;

  select attempt.*
  into active_attempt
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.status = 'in_progress'
  order by attempt.attempt_number desc
  limit 1
  for update;
  if found then
    if active_attempt.started_at + make_interval(
      secs => (
        select version.time_limit_seconds
        from public.aptitude_test_versions version
        where version.id = active_attempt.test_version_id
      )
    ) > now() then
      select public.get_aptitude_candidate_session(target_token_hash)
      into session_payload;
      return session_payload || jsonb_build_object(
        'attempt_id', active_attempt.id,
        'attempt_number', active_attempt.attempt_number,
        'started_at', active_attempt.started_at
      );
    end if;
    update public.aptitude_attempts
    set status = 'expired',
        submitted_at = now(),
        evaluated_at = now(),
        result = jsonb_build_object('reason', 'time_expired')
    where id = active_attempt.id;
    if active_attempt.attempt_number >= invitation_row.max_attempts then
      update public.aptitude_invitations
      set status = 'completed'
      where id = invitation_row.id;
      return jsonb_build_object(
        'status', 'completed',
        'attempts_used', active_attempt.attempt_number,
        'max_attempts', invitation_row.max_attempts
      );
    end if;
  end if;

  select count(*) + 1
  into next_attempt_number
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id;
  if next_attempt_number > invitation_row.max_attempts then
    update public.aptitude_invitations
    set status = 'completed'
    where id = invitation_row.id;
    return jsonb_build_object(
      'status', 'completed',
      'attempts_used', next_attempt_number - 1,
      'max_attempts', invitation_row.max_attempts
    );
  end if;

  insert into public.aptitude_attempts (
    workspace_id,
    invitation_id,
    test_version_id,
    attempt_number
  )
  values (
    invitation_row.workspace_id,
    invitation_row.id,
    invitation_row.test_version_id,
    next_attempt_number
  )
  returning * into active_attempt;

  insert into public.aptitude_attempt_questions (
    workspace_id,
    attempt_id,
    test_version_id,
    question_id,
    display_order
  )
  select
    invitation_row.workspace_id,
    active_attempt.id,
    invitation_row.test_version_id,
    question.id,
    row_number() over (order by random(), question.id)::integer
  from public.aptitude_questions question
  where question.workspace_id = invitation_row.workspace_id
    and question.test_version_id = invitation_row.test_version_id;

  select public.get_aptitude_candidate_session(target_token_hash)
  into session_payload;
  return session_payload || jsonb_build_object(
    'attempt_id', active_attempt.id,
    'attempt_number', active_attempt.attempt_number,
    'started_at', active_attempt.started_at
  );
end;
$$;

create or replace function public.save_aptitude_candidate_answer(
  target_token_hash text,
  target_attempt_id uuid,
  target_question_id uuid,
  target_answer jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  attempt_row public.aptitude_attempts%rowtype;
  question_row public.aptitude_questions%rowtype;
  selected_count integer;
  unique_count integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to save aptitude answers.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('pending', 'sent', 'started');
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;
  select attempt.*
  into attempt_row
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.id = target_attempt_id
    and attempt.status = 'in_progress'
  for update;
  if not found then
    raise exception 'The aptitude attempt is not active.';
  end if;
  select question.*
  into question_row
  from public.aptitude_questions question
  join public.aptitude_test_versions version
    on version.workspace_id = question.workspace_id
   and version.id = question.test_version_id
  join public.aptitude_attempt_questions assignment
    on assignment.workspace_id = question.workspace_id
   and assignment.test_version_id = question.test_version_id
   and assignment.question_id = question.id
   and assignment.attempt_id = attempt_row.id
  where question.workspace_id = invitation_row.workspace_id
    and question.test_version_id = invitation_row.test_version_id
    and question.id = target_question_id
    and attempt_row.started_at + make_interval(secs => version.time_limit_seconds) > now();
  if not found then
    raise exception 'The aptitude question is unavailable or the attempt has expired.';
  end if;

  if question_row.question_type in ('single_choice', 'multiple_choice') then
    if jsonb_typeof(target_answer -> 'option_ids') is distinct from 'array' then
      raise exception 'Select one or more listed options.';
    end if;
    select count(*), count(distinct selected.value)
    into selected_count, unique_count
    from jsonb_array_elements_text(target_answer -> 'option_ids')
      as selected(value);
    if selected_count <> unique_count
       or (question_row.question_type = 'single_choice' and selected_count > 1)
       or exists (
         select 1
         from jsonb_array_elements_text(target_answer -> 'option_ids')
           as selected(value)
         where not exists (
           select 1
           from public.aptitude_question_options option_row
           where option_row.workspace_id = question_row.workspace_id
             and option_row.question_id = question_row.id
             and option_row.id::text = selected.value
         )
       ) then
      raise exception 'The answer contains an invalid option.';
    end if;
  elsif question_row.question_type = 'short_text' then
    if jsonb_typeof(target_answer) is distinct from 'string'
       or char_length(target_answer #>> '{}') > 5000 then
      raise exception 'Enter a short-text answer of at most 5000 characters.';
    end if;
  else
    raise exception 'Unsupported aptitude question type.';
  end if;

  insert into public.aptitude_answers (
    workspace_id,
    attempt_id,
    test_version_id,
    question_id,
    answer,
    saved_at
  )
  values (
    attempt_row.workspace_id,
    attempt_row.id,
    attempt_row.test_version_id,
    question_row.id,
    target_answer,
    now()
  )
  on conflict (attempt_id, question_id)
  do update set answer = excluded.answer, saved_at = now();
  return true;
end;
$$;

create or replace function public.submit_aptitude_candidate_attempt(
  target_token_hash text,
  target_attempt_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  attempt_row public.aptitude_attempts%rowtype;
  version_row public.aptitude_test_versions%rowtype;
  question_row record;
  answer_value jsonb;
  candidate_options text[];
  correct_options text[];
  total_points numeric := 0;
  earned_points numeric := 0;
  question_earned_points numeric;
  answer_count integer := 0;
  question_count integer := 0;
  has_answer boolean;
  is_correct boolean;
  score_value numeric(5, 2);
  passed_value boolean;
  result_value jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to submit aptitude attempts.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
  for update;
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;
  select attempt.*
  into attempt_row
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.id = target_attempt_id
  for update;
  if not found then
    raise exception 'The aptitude attempt was not found.';
  end if;
  if attempt_row.status in ('submitted', 'expired') then
    return jsonb_build_object(
      'attempt_id', attempt_row.id,
      'status', attempt_row.status,
      'score', attempt_row.score,
      'result', attempt_row.result
    );
  end if;
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = invitation_row.workspace_id
    and version.id = invitation_row.test_version_id;
  if not found then
    raise exception 'The aptitude test version was not found.';
  end if;
  if attempt_row.started_at + make_interval(secs => version_row.time_limit_seconds) <= now()
     or invitation_row.expires_at <= now() then
    update public.aptitude_attempts
    set status = 'expired',
        submitted_at = now(),
        evaluated_at = now(),
        result = jsonb_build_object('reason', 'time_expired')
    where id = attempt_row.id;
    update public.aptitude_invitations
    set status = case
      when attempt_row.attempt_number >= invitation_row.max_attempts then 'completed'
      else 'started'
    end
    where id = invitation_row.id;
    return jsonb_build_object(
      'attempt_id', attempt_row.id,
      'status', 'expired',
      'score', null,
      'result', jsonb_build_object('reason', 'time_expired')
    );
  end if;

  for question_row in
    select
      question.id,
      question.question_type,
      question.points,
      answer_key.answer_key
    from public.aptitude_attempt_questions assignment
    join public.aptitude_questions question
      on question.workspace_id = assignment.workspace_id
     and question.test_version_id = assignment.test_version_id
     and question.id = assignment.question_id
    join proofhire_private.aptitude_answer_keys answer_key
      on answer_key.workspace_id = question.workspace_id
     and answer_key.question_id = question.id
    where assignment.workspace_id = invitation_row.workspace_id
      and assignment.attempt_id = attempt_row.id
    order by assignment.display_order
  loop
    question_count := question_count + 1;
    total_points := total_points + question_row.points;
    answer_value := null;
    select answer.answer
    into answer_value
    from public.aptitude_answers answer
    where answer.workspace_id = attempt_row.workspace_id
      and answer.attempt_id = attempt_row.id
      and answer.question_id = question_row.id;
    has_answer := found;
    is_correct := false;

    if has_answer then
      answer_count := answer_count + 1;
      if question_row.question_type in ('single_choice', 'multiple_choice') then
        select coalesce(array_agg(selected.value order by selected.value), array[]::text[])
        into candidate_options
        from jsonb_array_elements_text(answer_value -> 'option_ids') as selected(value);
        select coalesce(array_agg(selected.value order by selected.value), array[]::text[])
        into correct_options
        from jsonb_array_elements_text(question_row.answer_key -> 'option_ids')
          as selected(value);
        is_correct := candidate_options = correct_options;
      else
        is_correct := exists (
          select 1
          from jsonb_array_elements_text(question_row.answer_key -> 'accepted_answers')
            as accepted(value)
          where lower(trim(accepted.value)) = lower(trim(answer_value #>> '{}'))
        );
      end if;
    end if;

    question_earned_points := case
      when is_correct then question_row.points
      else 0
    end;
    earned_points := earned_points + question_earned_points;
    insert into proofhire_private.aptitude_answer_scores (
      workspace_id,
      attempt_id,
      question_id,
      earned_points,
      maximum_points,
      is_correct,
      evaluated_at
    )
    values (
      attempt_row.workspace_id,
      attempt_row.id,
      question_row.id,
      question_earned_points,
      question_row.points,
      is_correct,
      now()
    )
    on conflict (attempt_id, question_id)
    do update set
      earned_points = excluded.earned_points,
      maximum_points = excluded.maximum_points,
      is_correct = excluded.is_correct,
      evaluated_at = excluded.evaluated_at;
  end loop;

  if question_count = 0 then
    raise exception 'The aptitude attempt has no assigned questions.';
  end if;
  score_value := round(earned_points / nullif(total_points, 0) * 100, 2);
  passed_value := case
    when version_row.passing_score is null then null
    else score_value >= version_row.passing_score
  end;
  result_value := jsonb_build_object(
    'earned_points', earned_points,
    'available_points', total_points,
    'answered_questions', answer_count,
    'question_count', question_count,
    'passed', passed_value
  );
  update public.aptitude_attempts
  set status = 'submitted',
      submitted_at = now(),
      evaluated_at = now(),
      score = score_value,
      result = result_value
  where id = attempt_row.id;
  update public.aptitude_invitations
  set status = case
    when attempt_row.attempt_number >= invitation_row.max_attempts then 'completed'
    else 'started'
  end
  where id = invitation_row.id;
  return jsonb_build_object(
    'attempt_id', attempt_row.id,
    'status', 'submitted',
    'score', score_value,
    'result', result_value,
    'passing_score', version_row.passing_score
  );
end;
$$;

create or replace function public.get_aptitude_attempt_question_scores(
  target_workspace_id uuid,
  target_attempt_id uuid
)
returns table (
  question_id uuid,
  display_order integer,
  category text,
  difficulty text,
  earned_points numeric,
  maximum_points numeric,
  is_correct boolean,
  evaluated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_workspace_role(
    target_workspace_id,
    array['admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to read aptitude question scores.';
  end if;
  if not exists (
    select 1
    from public.aptitude_attempts attempt
    where attempt.workspace_id = target_workspace_id
      and attempt.id = target_attempt_id
  ) then
    raise exception 'The aptitude attempt was not found.';
  end if;
  return query
  select
    assignment.question_id,
    assignment.display_order,
    question.category,
    question.difficulty,
    score.earned_points,
    score.maximum_points,
    score.is_correct,
    score.evaluated_at
  from public.aptitude_attempt_questions assignment
  join public.aptitude_questions question
    on question.workspace_id = assignment.workspace_id
   and question.test_version_id = assignment.test_version_id
   and question.id = assignment.question_id
  left join proofhire_private.aptitude_answer_scores score
    on score.workspace_id = assignment.workspace_id
   and score.attempt_id = assignment.attempt_id
   and score.question_id = assignment.question_id
  where assignment.workspace_id = target_workspace_id
    and assignment.attempt_id = target_attempt_id
  order by assignment.display_order;
end;
$$;

revoke all on function public.get_aptitude_attempt_question_scores(uuid, uuid)
  from public, anon;
grant execute on function public.get_aptitude_attempt_question_scores(uuid, uuid)
  to authenticated;

revoke all on function public.get_aptitude_candidate_session(text)
  from public, anon, authenticated;
grant execute on function public.get_aptitude_candidate_session(text)
  to service_role;
revoke all on function public.start_aptitude_candidate_attempt(text)
  from public, anon, authenticated;
grant execute on function public.start_aptitude_candidate_attempt(text)
  to service_role;
revoke all on function public.save_aptitude_candidate_answer(text, uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_aptitude_candidate_answer(text, uuid, uuid, jsonb)
  to service_role;
revoke all on function public.submit_aptitude_candidate_attempt(text, uuid)
  from public, anon, authenticated;
grant execute on function public.submit_aptitude_candidate_attempt(text, uuid)
  to service_role;

-- END SOURCE: 202611020002_aptitude_assessment_foundation_completion.sql


-- BEGIN SOURCE: 202611020003_coding_assessment_and_email_delivery.sql
-- Add a server-only coding assessment foundation and an idempotent email
-- delivery queue. No code execution or email provider is implemented here.
create table public.coding_challenges (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 180),
  description text check (description is null or char_length(description) <= 10000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_challenges_workspace_id_unique unique (workspace_id, id)
);

create table public.coding_challenge_versions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  challenge_id uuid not null,
  version_number integer not null check (version_number > 0),
  prompt text not null check (char_length(trim(prompt)) between 1 and 20000),
  difficulty text not null check (
    difficulty in ('beginner', 'medium', 'advanced', 'expert')
  ),
  supported_languages text[] not null
    check (cardinality(supported_languages) between 1 and 20),
  starter_code jsonb not null default '{}'::jsonb
    check (
      jsonb_typeof(starter_code) = 'object'
      and octet_length(starter_code::text) <= 100000
    ),
  points numeric(8, 2) not null default 1 check (points > 0),
  max_execution_seconds integer not null default 10
    check (max_execution_seconds between 1 and 30),
  version_status text not null default 'draft'
    check (version_status in ('draft', 'published')),
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_challenge_versions_challenge_fk
    foreign key (workspace_id, challenge_id)
    references public.coding_challenges(workspace_id, id)
    on delete cascade,
  constraint coding_challenge_versions_number_unique
    unique (challenge_id, version_number),
  constraint coding_challenge_versions_workspace_id_unique
    unique (workspace_id, id),
  constraint coding_challenge_versions_job_config_unique
    unique (workspace_id, id, challenge_id),
  constraint coding_challenge_versions_published_at_check
    check (
      (version_status = 'draft' and published_at is null)
      or (version_status = 'published' and published_at is not null)
    )
);

create table public.job_coding_assessments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  job_id uuid not null,
  challenge_version_id uuid not null,
  is_required boolean not null default false,
  time_limit_seconds integer not null default 3600
    check (time_limit_seconds between 60 and 21600),
  max_attempts integer not null default 1 check (max_attempts between 1 and 5),
  display_order integer not null default 1 check (display_order > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_coding_assessments_job_fk
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,
  constraint job_coding_assessments_challenge_fk
    foreign key (workspace_id, challenge_version_id)
    references public.coding_challenge_versions(workspace_id, id)
    on delete restrict,
  constraint job_coding_assessments_job_version_unique
    unique (workspace_id, job_id, challenge_version_id),
  constraint job_coding_assessments_workspace_id_unique
    unique (workspace_id, id),
  constraint job_coding_assessments_invitation_key_unique
    unique (workspace_id, id, job_id, challenge_version_id)
);

create index idx_job_coding_assessments_job_order
  on public.job_coding_assessments(workspace_id, job_id, display_order);

create table public.coding_invitations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  job_id uuid not null,
  job_coding_assessment_id uuid not null,
  challenge_version_id uuid not null,
  candidate_email text not null
    check (
      char_length(candidate_email) between 3 and 320
      and candidate_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check (status in ('pending', 'started', 'completed', 'expired', 'revoked', 'failed')),
  expires_at timestamptz not null,
  max_attempts integer not null default 1 check (max_attempts between 1 and 5),
  invited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_invitations_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint coding_invitations_job_configuration_fk
    foreign key (
      workspace_id,
      job_coding_assessment_id,
      job_id,
      challenge_version_id
    )
    references public.job_coding_assessments(
      workspace_id,
      id,
      job_id,
      challenge_version_id
    )
    on delete restrict,
  constraint coding_invitations_token_hash_unique unique (token_hash),
  constraint coding_invitations_workspace_id_unique unique (workspace_id, id),
  constraint coding_invitations_workspace_application_unique
    unique (workspace_id, id, application_id),
  constraint coding_invitations_workspace_attempt_key_unique
    unique (workspace_id, id, challenge_version_id)
);

create table public.coding_attempts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  invitation_id uuid not null,
  challenge_version_id uuid not null,
  attempt_number integer not null check (attempt_number between 1 and 5),
  status text not null default 'in_progress'
    check (
      status in (
        'in_progress',
        'submitted',
        'evaluating',
        'completed',
        'expired',
        'failed'
      )
    ),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  evaluated_at timestamptz,
  completed_at timestamptz,
  score numeric(5, 2) check (score is null or score between 0 and 100),
  error_code text check (error_code is null or char_length(error_code) <= 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_attempts_invitation_fk
    foreign key (workspace_id, invitation_id, challenge_version_id)
    references public.coding_invitations(workspace_id, id, challenge_version_id)
    on delete cascade,
  constraint coding_attempts_number_unique unique (invitation_id, attempt_number),
  constraint coding_attempts_workspace_id_unique unique (workspace_id, id),
  constraint coding_attempts_workspace_version_unique
    unique (workspace_id, id, challenge_version_id),
  constraint coding_attempts_submission_time_check
    check (
      (status = 'in_progress' and submitted_at is null)
      or (status <> 'in_progress' and submitted_at is not null)
    )
);

create table public.coding_submissions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  attempt_id uuid not null,
  challenge_version_id uuid not null,
  submission_number integer not null check (submission_number > 0),
  idempotency_key uuid not null,
  language text not null check (char_length(trim(language)) between 1 and 80),
  is_final boolean not null default true,
  source_reference uuid not null default gen_random_uuid(),
  status text not null default 'queued'
    check (status in ('queued', 'evaluating', 'completed', 'failed', 'rejected')),
  submitted_at timestamptz not null default now(),
  evaluated_at timestamptz,
  created_at timestamptz not null default now(),
  constraint coding_submissions_attempt_fk
    foreign key (workspace_id, attempt_id, challenge_version_id)
    references public.coding_attempts(workspace_id, id, challenge_version_id)
    on delete cascade,
  constraint coding_submissions_attempt_number_unique
    unique (attempt_id, submission_number),
  constraint coding_submissions_idempotency_unique
    unique (workspace_id, attempt_id, idempotency_key),
  constraint coding_submissions_workspace_reference_unique
    unique (workspace_id, source_reference),
  constraint coding_submissions_workspace_id_unique unique (workspace_id, id),
  constraint coding_submissions_workspace_attempt_version_unique
    unique (workspace_id, id, attempt_id, challenge_version_id),
  constraint coding_submissions_workspace_version_unique
    unique (workspace_id, id, challenge_version_id)
);

create table public.coding_question_results (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  attempt_id uuid not null,
  submission_id uuid not null,
  challenge_version_id uuid not null,
  status text not null
    check (status in ('passed', 'failed', 'timeout', 'compile_error', 'runtime_error')),
  score numeric(8, 2) not null check (score >= 0),
  maximum_score numeric(8, 2) not null check (maximum_score > 0),
  test_cases_passed integer not null default 0 check (test_cases_passed >= 0),
  test_case_count integer not null default 0 check (test_case_count >= test_cases_passed),
  execution_time_ms integer check (execution_time_ms is null or execution_time_ms >= 0),
  error_code text check (error_code is null or char_length(error_code) <= 80),
  evaluated_at timestamptz not null default now(),
  constraint coding_question_results_submission_fk
    foreign key (
      workspace_id,
      submission_id,
      attempt_id,
      challenge_version_id
    )
    references public.coding_submissions(
      workspace_id,
      id,
      attempt_id,
      challenge_version_id
    )
    on delete cascade,
  constraint coding_question_results_score_maximum_check
  check (score <= maximum_score),
  constraint coding_question_results_submission_unique unique (submission_id)
);

create table public.coding_evaluation_jobs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  submission_id uuid not null,
  status text not null default 'waiting_configuration'
    check (
      status in (
        'queued',
        'processing',
        'retry_wait',
        'waiting_configuration',
        'completed',
        'failed'
      )
    ),
  attempts integer not null default 0 check (attempts between 0 and 5),
  max_attempts integer not null default 5 check (max_attempts between 1 and 5),
  available_at timestamptz not null default now(),
  lease_token uuid,
  locked_by text,
  locked_until timestamptz,
  last_error_code text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint coding_evaluation_jobs_submission_fk
    foreign key (workspace_id, submission_id)
    references public.coding_submissions(workspace_id, id)
    on delete cascade,
  constraint coding_evaluation_jobs_submission_unique unique (submission_id),
  constraint coding_evaluation_jobs_lease_check
    check (
      (status = 'processing' and lease_token is not null and locked_until is not null)
      or (status <> 'processing' and lease_token is null and locked_until is null)
    )
);

create index idx_coding_evaluation_jobs_claim
  on public.coding_evaluation_jobs(status, available_at, created_at)
  where status in ('queued', 'retry_wait', 'processing');
create index idx_coding_invitations_application_created
  on public.coding_invitations(workspace_id, application_id, created_at desc);
create index idx_coding_attempts_invitation_number
  on public.coding_attempts(workspace_id, invitation_id, attempt_number);
create index idx_coding_submissions_attempt_created
  on public.coding_submissions(workspace_id, attempt_id, submitted_at desc);

create table proofhire_private.coding_test_cases (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  challenge_version_id uuid not null,
  display_order integer not null check (display_order > 0),
  input_text text not null check (octet_length(input_text) <= 20000),
  expected_output text not null check (octet_length(expected_output) <= 20000),
  is_hidden boolean not null default true,
  points numeric(8, 2) not null default 1 check (points > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_test_cases_challenge_fk
    foreign key (workspace_id, challenge_version_id)
    references public.coding_challenge_versions(workspace_id, id)
    on delete cascade,
  constraint coding_test_cases_order_unique
    unique (challenge_version_id, display_order),
  constraint coding_test_cases_workspace_id_unique unique (workspace_id, id),
  constraint coding_test_cases_workspace_version_unique
    unique (workspace_id, id, challenge_version_id)
);

create table proofhire_private.coding_submission_sources (
  source_reference uuid primary key,
  workspace_id uuid not null,
  source_code text not null
    check (octet_length(source_code) between 1 and 262144),
  created_at timestamptz not null default now(),
  constraint coding_submission_sources_submission_fk
    foreign key (workspace_id, source_reference)
    references public.coding_submissions(workspace_id, source_reference)
    on delete cascade
);

create table proofhire_private.coding_test_case_results (
  workspace_id uuid not null,
  submission_id uuid not null,
  challenge_version_id uuid not null,
  test_case_id uuid not null,
  status text not null check (status in ('passed', 'failed', 'timeout', 'error')),
  execution_time_ms integer check (execution_time_ms is null or execution_time_ms >= 0),
  error_code text check (error_code is null or char_length(error_code) <= 80),
  evaluated_at timestamptz not null default now(),
  primary key (submission_id, test_case_id),
  constraint coding_test_case_results_submission_fk
    foreign key (workspace_id, submission_id, challenge_version_id)
    references public.coding_submissions(workspace_id, id, challenge_version_id)
    on delete cascade,
  constraint coding_test_case_results_case_fk
    foreign key (workspace_id, test_case_id, challenge_version_id)
    references proofhire_private.coding_test_cases(
      workspace_id,
      id,
      challenge_version_id
    )
    on delete cascade
);

alter table proofhire_private.coding_test_cases enable row level security;
alter table proofhire_private.coding_submission_sources enable row level security;
alter table proofhire_private.coding_test_case_results enable row level security;
revoke all on proofhire_private.coding_test_cases
  from public, anon, authenticated;
revoke all on proofhire_private.coding_submission_sources
  from public, anon, authenticated;
revoke all on proofhire_private.coding_test_case_results
  from public, anon, authenticated;
grant all on proofhire_private.coding_test_cases to service_role;
grant all on proofhire_private.coding_submission_sources to service_role;
grant all on proofhire_private.coding_test_case_results to service_role;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_workspace_id_unique'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_workspace_id_unique
      unique (workspace_id, id);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_workspace_application_unique'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_workspace_application_unique
      unique (workspace_id, id, application_id);
  end if;
end;
$migration$;

create table public.email_delivery_jobs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  aptitude_invitation_id uuid,
  coding_invitation_id uuid,
  interview_record_id uuid,
  email_type text not null check (
    email_type in (
      'application_update',
      'aptitude_invitation',
      'coding_invitation',
      'interview_invitation',
      'interview_update',
      'rejection',
      'offer'
    )
  ),
  template_key text not null
    check (char_length(trim(template_key)) between 1 and 120),
  recipient_email text not null
    check (
      char_length(recipient_email) between 3 and 320
      and recipient_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),
  idempotency_key text not null
    check (char_length(trim(idempotency_key)) between 1 and 200),
  status text not null default 'manual_required'
    check (
      status in (
        'queued',
        'processing',
        'retry_wait',
        'sent',
        'delivered',
        'failed',
        'blocked_configuration',
        'manual_required',
        'cancelled'
      )
    ),
  attempts integer not null default 0 check (attempts between 0 and 10),
  max_attempts integer not null default 5 check (max_attempts between 1 and 10),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  locked_by text,
  locked_until timestamptz,
  provider_message_id text,
  last_error_code text check (
    last_error_code is null or char_length(last_error_code) <= 100
  ),
  sent_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_delivery_jobs_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint email_delivery_jobs_aptitude_invitation_fk
    foreign key (workspace_id, aptitude_invitation_id, application_id)
    references public.aptitude_invitations(workspace_id, id, application_id)
    on delete cascade,
  constraint email_delivery_jobs_coding_invitation_fk
    foreign key (workspace_id, coding_invitation_id, application_id)
    references public.coding_invitations(workspace_id, id, application_id)
    on delete cascade,
  constraint email_delivery_jobs_interview_fk
    foreign key (workspace_id, interview_record_id, application_id)
    references public.interview_records(workspace_id, id, application_id)
    on delete cascade,
  constraint email_delivery_jobs_target_check check (
    (
      email_type = 'aptitude_invitation'
      and aptitude_invitation_id is not null
      and coding_invitation_id is null
      and interview_record_id is null
    )
    or (
      email_type = 'coding_invitation'
      and aptitude_invitation_id is null
      and coding_invitation_id is not null
      and interview_record_id is null
    )
    or (
      email_type in ('interview_invitation', 'interview_update')
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is not null
    )
    or (
      email_type in ('application_update', 'rejection', 'offer')
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is null
    )
  ),
  constraint email_delivery_jobs_lease_check check (
    (status = 'processing' and lease_token is not null and locked_until is not null)
    or (status <> 'processing' and lease_token is null and locked_until is null)
  ),
  constraint email_delivery_jobs_delivery_time_check
    check (delivered_at is null or sent_at is not null),
  constraint email_delivery_jobs_idempotency_unique unique (idempotency_key),
  constraint email_delivery_jobs_workspace_id_unique unique (workspace_id, id)
);

create index idx_email_delivery_jobs_claim
  on public.email_delivery_jobs(status, next_attempt_at, created_at)
  where status in ('queued', 'retry_wait', 'processing');
create index idx_email_delivery_jobs_application_created
  on public.email_delivery_jobs(workspace_id, application_id, created_at desc);

create table public.email_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  delivery_job_id uuid not null,
  attempt_number integer not null check (attempt_number > 0),
  status text not null check (status in ('sent', 'delivered', 'retry_wait', 'failed')),
  provider_message_id text,
  error_code text check (error_code is null or char_length(error_code) <= 100),
  attempted_at timestamptz not null default now(),
  completed_at timestamptz not null default now(),
  constraint email_delivery_attempts_job_fk
    foreign key (workspace_id, delivery_job_id)
    references public.email_delivery_jobs(workspace_id, id)
    on delete cascade,
  constraint email_delivery_attempts_number_unique
    unique (delivery_job_id, attempt_number)
);

create index idx_email_delivery_attempts_job_number
  on public.email_delivery_attempts(workspace_id, delivery_job_id, attempt_number desc);

drop trigger if exists coding_challenges_set_updated_at
  on public.coding_challenges;
create trigger coding_challenges_set_updated_at
before update on public.coding_challenges
for each row execute function public.set_updated_at();

drop trigger if exists coding_challenge_versions_set_updated_at
  on public.coding_challenge_versions;
create trigger coding_challenge_versions_set_updated_at
before update on public.coding_challenge_versions
for each row execute function public.set_updated_at();

drop trigger if exists job_coding_assessments_set_updated_at
  on public.job_coding_assessments;
create trigger job_coding_assessments_set_updated_at
before update on public.job_coding_assessments
for each row execute function public.set_updated_at();

drop trigger if exists coding_invitations_set_updated_at
  on public.coding_invitations;
create trigger coding_invitations_set_updated_at
before update on public.coding_invitations
for each row execute function public.set_updated_at();

drop trigger if exists coding_attempts_set_updated_at
  on public.coding_attempts;
create trigger coding_attempts_set_updated_at
before update on public.coding_attempts
for each row execute function public.set_updated_at();

drop trigger if exists coding_evaluation_jobs_set_updated_at
  on public.coding_evaluation_jobs;
create trigger coding_evaluation_jobs_set_updated_at
before update on public.coding_evaluation_jobs
for each row execute function public.set_updated_at();

drop trigger if exists email_delivery_jobs_set_updated_at
  on public.email_delivery_jobs;
create trigger email_delivery_jobs_set_updated_at
before update on public.email_delivery_jobs
for each row execute function public.set_updated_at();

alter table public.coding_challenges enable row level security;
alter table public.coding_challenge_versions enable row level security;
alter table public.job_coding_assessments enable row level security;
alter table public.coding_invitations enable row level security;
alter table public.coding_attempts enable row level security;
alter table public.coding_submissions enable row level security;
alter table public.coding_question_results enable row level security;
alter table public.coding_evaluation_jobs enable row level security;
alter table public.email_delivery_jobs enable row level security;
alter table public.email_delivery_attempts enable row level security;

create policy "Workspace members can read coding challenges"
on public.coding_challenges
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create coding challenges"
on public.coding_challenges
for insert to authenticated
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and (created_by is null or created_by = (select auth.uid()))
);

create policy "Recruiters can update coding challenges"
on public.coding_challenges
for update to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']))
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and (created_by is null or created_by = (select auth.uid()))
);

create policy "Workspace members can read coding challenge versions"
on public.coding_challenge_versions
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create coding challenge drafts"
on public.coding_challenge_versions
for insert to authenticated
with check (
  version_status = 'draft'
  and (created_by is null or created_by = (select auth.uid()))
  and public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
);

create policy "Recruiters can update coding challenge drafts"
on public.coding_challenge_versions
for update to authenticated
using (
  version_status = 'draft'
  and public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
)
with check (
  version_status = 'draft'
  and (created_by is null or created_by = (select auth.uid()))
  and public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
);

create policy "Recruiters can read job coding assessments"
on public.job_coding_assessments
for select to authenticated
using (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
);

create policy "Recruiters can manage job coding assessments"
on public.job_coding_assessments
for all to authenticated
using (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and exists (
    select 1
    from public.coding_challenge_versions version
    where version.workspace_id = job_coding_assessments.workspace_id
      and version.id = job_coding_assessments.challenge_version_id
      and version.version_status = 'published'
  )
)
with check (
  public.has_workspace_role(workspace_id, array['admin', 'recruiter'])
  and (created_by is null or created_by = (select auth.uid()))
  and exists (
    select 1
    from public.coding_challenge_versions version
    where version.workspace_id = job_coding_assessments.workspace_id
      and version.id = job_coding_assessments.challenge_version_id
      and version.version_status = 'published'
  )
);

create policy "Recruiters can read coding invitations"
on public.coding_invitations
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Recruiters can read coding attempts"
on public.coding_attempts
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Recruiters can read coding submissions"
on public.coding_submissions
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Recruiters can read coding question results"
on public.coding_question_results
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Recruiters can read email delivery jobs"
on public.email_delivery_jobs
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create policy "Recruiters can read email delivery attempts"
on public.email_delivery_attempts
for select to authenticated
using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

revoke all on public.coding_challenges from public, anon, authenticated;
revoke all on public.coding_challenge_versions from public, anon, authenticated;
revoke all on public.job_coding_assessments from public, anon, authenticated;
revoke all on public.coding_invitations from public, anon, authenticated;
revoke all on public.coding_attempts from public, anon, authenticated;
revoke all on public.coding_submissions from public, anon, authenticated;
revoke all on public.coding_question_results from public, anon, authenticated;
revoke all on public.coding_evaluation_jobs from public, anon, authenticated;
revoke all on public.email_delivery_jobs from public, anon, authenticated;
revoke all on public.email_delivery_attempts from public, anon, authenticated;

grant select, insert, update on public.coding_challenges to authenticated;
grant select, insert, update, delete on public.coding_challenge_versions to authenticated;
grant select, insert, update, delete on public.job_coding_assessments to authenticated;
grant select (
  id,
  workspace_id,
  application_id,
  job_id,
  job_coding_assessment_id,
  challenge_version_id,
  candidate_email,
  status,
  expires_at,
  max_attempts,
  invited_by,
  created_at,
  updated_at
) on public.coding_invitations to authenticated;
grant select on public.coding_attempts to authenticated;
grant select on public.coding_submissions to authenticated;
grant select on public.coding_question_results to authenticated;
grant select on public.email_delivery_jobs to authenticated;
grant select on public.email_delivery_attempts to authenticated;

grant all on public.coding_challenges to service_role;
grant all on public.coding_challenge_versions to service_role;
grant all on public.job_coding_assessments to service_role;
grant all on public.coding_invitations to service_role;
grant all on public.coding_attempts to service_role;
grant all on public.coding_submissions to service_role;
grant all on public.coding_question_results to service_role;
grant all on public.coding_evaluation_jobs to service_role;
grant all on public.email_delivery_jobs to service_role;
grant all on public.email_delivery_attempts to service_role;

create or replace function public.prevent_published_coding_version_changes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  if old.version_status = 'published' then
    raise exception 'Published coding challenge versions are immutable.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger coding_challenge_versions_are_immutable
before update or delete on public.coding_challenge_versions
for each row execute function public.prevent_published_coding_version_changes();

create or replace function public.prevent_published_coding_test_case_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_version uuid;
  target_workspace uuid;
  version_state text;
begin
  if tg_op = 'DELETE' then
    target_version := old.challenge_version_id;
    target_workspace := old.workspace_id;
  else
    target_version := new.challenge_version_id;
    target_workspace := new.workspace_id;
  end if;
  select version.version_status
  into version_state
  from public.coding_challenge_versions version
  where version.workspace_id = target_workspace
    and version.id = target_version
  for update;
  if not found and tg_op = 'DELETE' then
    return old;
  end if;
  if version_state is distinct from 'draft' then
    raise exception 'Coding test cases can only change while the version is a draft.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger coding_test_cases_are_immutable_when_published
before insert or update or delete on proofhire_private.coding_test_cases
for each row execute function public.prevent_published_coding_test_case_changes();

create or replace function public.save_coding_test_case(
  target_workspace_id uuid,
  target_challenge_version_id uuid,
  target_case_id uuid,
  target_input text,
  target_expected_output text,
  target_is_hidden boolean default true,
  target_points numeric default 1
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  next_id uuid;
  next_order integer;
begin
  if not public.has_workspace_role(
    target_workspace_id,
    array['admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to edit coding test cases.';
  end if;
  if not exists (
    select 1
    from public.coding_challenge_versions version
    where version.workspace_id = target_workspace_id
      and version.id = target_challenge_version_id
      and version.version_status = 'draft'
  ) then
    raise exception 'Coding test cases can only be edited on draft versions.';
  end if;
  if target_input is null or octet_length(target_input) > 20000
     or target_expected_output is null
     or octet_length(target_expected_output) > 20000
     or target_points is null or target_points <= 0 then
    raise exception 'The coding test case is invalid.';
  end if;

  if target_case_id is null then
    select coalesce(max(test_case.display_order), 0) + 1
    into next_order
    from proofhire_private.coding_test_cases test_case
    where test_case.workspace_id = target_workspace_id
      and test_case.challenge_version_id = target_challenge_version_id;
    insert into proofhire_private.coding_test_cases (
      workspace_id,
      challenge_version_id,
      display_order,
      input_text,
      expected_output,
      is_hidden,
      points,
      created_by
    )
    values (
      target_workspace_id,
      target_challenge_version_id,
      next_order,
      target_input,
      target_expected_output,
      coalesce(target_is_hidden, true),
      target_points,
      (select auth.uid())
    )
    returning id into next_id;
    return next_id;
  end if;

  update proofhire_private.coding_test_cases
  set input_text = target_input,
      expected_output = target_expected_output,
      is_hidden = coalesce(target_is_hidden, true),
      points = target_points,
      updated_at = now()
  where id = target_case_id
    and workspace_id = target_workspace_id
    and challenge_version_id = target_challenge_version_id
  returning id into next_id;
  if next_id is null then
    raise exception 'The coding test case was not found.';
  end if;
  return next_id;
end;
$$;

create or replace function public.publish_coding_challenge_version(
  target_challenge_version_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.coding_challenge_versions%rowtype;
  test_case_count integer;
begin
  select version.*
  into version_row
  from public.coding_challenge_versions version
  where version.id = target_challenge_version_id
  for update;
  if not found or not public.has_workspace_role(
    version_row.workspace_id,
    array['admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to publish this coding challenge.';
  end if;
  if version_row.version_status <> 'draft' then
    raise exception 'Only a draft coding challenge version can be published.';
  end if;
  select count(*)
  into test_case_count
  from proofhire_private.coding_test_cases test_case
  where test_case.workspace_id = version_row.workspace_id
    and test_case.challenge_version_id = version_row.id;
  if test_case_count = 0 then
    raise exception 'Add at least one private test case before publishing.';
  end if;
  update public.coding_challenge_versions
  set version_status = 'published',
      published_at = now(),
      updated_at = now()
  where id = version_row.id;
  return version_row.id;
end;
$$;

revoke all on function public.prevent_published_coding_version_changes()
  from public, anon, authenticated;
revoke all on function public.prevent_published_coding_test_case_changes()
  from public, anon, authenticated;
revoke all on function public.save_coding_test_case(uuid, uuid, uuid, text, text, boolean, numeric)
  from public, anon;
revoke all on function public.publish_coding_challenge_version(uuid)
  from public, anon;
grant execute on function public.save_coding_test_case(uuid, uuid, uuid, text, text, boolean, numeric)
  to authenticated;
grant execute on function public.publish_coding_challenge_version(uuid)
  to authenticated;

create or replace function public.validate_coding_invitation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_job_id uuid;
  configuration_row public.job_coding_assessments%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create coding invitations.';
  end if;
  select application.job_id
  into application_job_id
  from public.applications application
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if application_job_id is null or application_job_id <> new.job_id then
    raise exception 'The coding invitation application and job do not match.';
  end if;
  select configuration.*
  into configuration_row
  from public.job_coding_assessments configuration
  join public.coding_challenge_versions version
    on version.workspace_id = configuration.workspace_id
   and version.id = configuration.challenge_version_id
  where configuration.workspace_id = new.workspace_id
    and configuration.id = new.job_coding_assessment_id
    and configuration.job_id = new.job_id
    and configuration.challenge_version_id = new.challenge_version_id
    and version.version_status = 'published';
  if not found then
    raise exception 'The coding invitation requires a published job assessment.';
  end if;
  if new.max_attempts > configuration_row.max_attempts
     or new.expires_at <= now() then
    raise exception 'The coding invitation limits or expiry are invalid.';
  end if;
  return new;
end;
$$;

create trigger coding_invitations_validate
before insert or update of workspace_id, application_id, job_id,
  job_coding_assessment_id, challenge_version_id, max_attempts, expires_at
on public.coding_invitations
for each row execute function public.validate_coding_invitation();

create or replace function public.validate_coding_attempt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.coding_invitations%rowtype;
  previous_attempts integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create coding attempts.';
  end if;
  select invitation.*
  into invitation_row
  from public.coding_invitations invitation
  where invitation.workspace_id = new.workspace_id
    and invitation.id = new.invitation_id
    and invitation.challenge_version_id = new.challenge_version_id
  for update;
  if not found
     or invitation_row.status not in ('pending', 'started')
     or invitation_row.expires_at <= now() then
    raise exception 'The coding invitation is unavailable or expired.';
  end if;
  select count(*)
  into previous_attempts
  from public.coding_attempts attempt
  where attempt.workspace_id = new.workspace_id
    and attempt.invitation_id = new.invitation_id;
  if new.attempt_number <> previous_attempts + 1
     or new.attempt_number > invitation_row.max_attempts then
    raise exception 'The coding attempt limit has been reached.';
  end if;
  update public.coding_invitations
  set status = 'started',
      updated_at = now()
  where id = invitation_row.id
    and workspace_id = invitation_row.workspace_id;
  return new;
end;
$$;

create or replace function public.get_coding_test_cases(
  target_workspace_id uuid,
  target_challenge_version_id uuid
)
returns table (
  id uuid,
  display_order integer,
  input_text text,
  expected_output text,
  is_hidden boolean,
  points numeric
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_workspace_role(
    target_workspace_id,
    array['admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to read coding test cases.';
  end if;
  return query
  select
    test_case.id,
    test_case.display_order,
    test_case.input_text,
    test_case.expected_output,
    test_case.is_hidden,
    test_case.points
  from proofhire_private.coding_test_cases test_case
  where test_case.workspace_id = target_workspace_id
    and test_case.challenge_version_id = target_challenge_version_id
  order by test_case.display_order;
end;
$$;

create or replace function public.save_coding_submission(
  target_workspace_id uuid,
  target_attempt_id uuid,
  target_idempotency_key uuid,
  target_language text,
  target_source_code text,
  target_is_final boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  attempt_row public.coding_attempts%rowtype;
  invitation_row public.coding_invitations%rowtype;
  configuration_row public.job_coding_assessments%rowtype;
  version_row public.coding_challenge_versions%rowtype;
  existing_submission public.coding_submissions%rowtype;
  existing_source text;
  next_number integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to save coding submissions.';
  end if;
  if target_idempotency_key is null
     or target_language is null
     or char_length(trim(target_language)) not between 1 and 80
     or target_source_code is null
     or octet_length(target_source_code) not between 1 and 262144 then
    raise exception 'The coding submission is invalid.';
  end if;

  select submission.*
  into existing_submission
  from public.coding_submissions submission
  where submission.workspace_id = target_workspace_id
    and submission.attempt_id = target_attempt_id
    and submission.idempotency_key = target_idempotency_key;
  if found then
    select source.source_code
    into existing_source
    from proofhire_private.coding_submission_sources source
    where source.workspace_id = target_workspace_id
      and source.source_reference = existing_submission.source_reference;
    if existing_source is distinct from target_source_code
       or lower(existing_submission.language) <> lower(trim(target_language))
       or existing_submission.is_final is distinct from coalesce(target_is_final, true) then
      raise exception 'The coding idempotency key was already used for a different submission.';
    end if;
    return existing_submission.id;
  end if;

  select attempt.*
  into attempt_row
  from public.coding_attempts attempt
  where attempt.workspace_id = target_workspace_id
    and attempt.id = target_attempt_id
  for update;
  if not found then
    raise exception 'The coding attempt was not found.';
  end if;

  select submission.*
  into existing_submission
  from public.coding_submissions submission
  where submission.workspace_id = target_workspace_id
    and submission.attempt_id = target_attempt_id
    and submission.idempotency_key = target_idempotency_key;
  if found then
    select source.source_code
    into existing_source
    from proofhire_private.coding_submission_sources source
    where source.workspace_id = target_workspace_id
      and source.source_reference = existing_submission.source_reference;
    if existing_source is distinct from target_source_code
       or lower(existing_submission.language) <> lower(trim(target_language))
       or existing_submission.is_final is distinct from coalesce(target_is_final, true) then
      raise exception 'The coding idempotency key was already used for a different submission.';
    end if;
    return existing_submission.id;
  end if;
  if attempt_row.status <> 'in_progress' then
    raise exception 'The coding attempt is not active.';
  end if;
  select invitation.*
  into invitation_row
  from public.coding_invitations invitation
  where invitation.workspace_id = target_workspace_id
    and invitation.id = attempt_row.invitation_id
    and invitation.challenge_version_id = attempt_row.challenge_version_id
    and invitation.status in ('pending', 'started')
    and invitation.expires_at > now()
  for update;
  if not found then
    raise exception 'The coding invitation is unavailable or expired.';
  end if;
  select configuration.*
  into configuration_row
  from public.job_coding_assessments configuration
  where configuration.workspace_id = target_workspace_id
    and configuration.id = invitation_row.job_coding_assessment_id;
  select version.*
  into version_row
  from public.coding_challenge_versions version
  where version.workspace_id = target_workspace_id
    and version.id = attempt_row.challenge_version_id
    and version.version_status = 'published';
  if not found or configuration_row.id is null then
    raise exception 'The published coding assessment is unavailable.';
  end if;
  if attempt_row.started_at
       + make_interval(secs => configuration_row.time_limit_seconds) <= now() then
    raise exception 'The coding attempt has expired.';
  end if;
  if not exists (
    select 1
    from unnest(version_row.supported_languages) supported(language)
    where lower(supported.language) = lower(trim(target_language))
  ) then
    raise exception 'The selected coding language is not supported.';
  end if;

  select coalesce(max(submission.submission_number), 0) + 1
  into next_number
  from public.coding_submissions submission
  where submission.workspace_id = target_workspace_id
    and submission.attempt_id = attempt_row.id;

  insert into public.coding_submissions (
    workspace_id,
    attempt_id,
    challenge_version_id,
    submission_number,
    idempotency_key,
    language,
    is_final
  )
  values (
    target_workspace_id,
    attempt_row.id,
    attempt_row.challenge_version_id,
    next_number,
    target_idempotency_key,
    trim(target_language),
    coalesce(target_is_final, true)
  )
  returning * into existing_submission;

  insert into proofhire_private.coding_submission_sources (
    source_reference,
    workspace_id,
    source_code
  )
  values (
    existing_submission.source_reference,
    target_workspace_id,
    target_source_code
  );

  if coalesce(target_is_final, true) then
    update public.coding_attempts
    set status = 'submitted',
        submitted_at = now(),
        updated_at = now()
    where id = attempt_row.id;
  end if;
  return existing_submission.id;
end;
$$;

create trigger coding_attempts_enforce_invitation_limits
before insert on public.coding_attempts
for each row execute function public.validate_coding_attempt();

create or replace function public.queue_coding_evaluation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.coding_evaluation_jobs (
    workspace_id,
    submission_id,
    status
  )
  values (
    new.workspace_id,
    new.id,
    'waiting_configuration'
  )
  on conflict (submission_id) do nothing;
  return new;
end;
$$;

create trigger coding_submissions_queue_evaluation
after insert on public.coding_submissions
for each row execute function public.queue_coding_evaluation();

create or replace function public.claim_coding_evaluation_jobs(
  worker_id text,
  lease_seconds integer default 120
)
returns setof public.coding_evaluation_jobs
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if worker_id is null or char_length(trim(worker_id)) not between 1 and 120 then
    raise exception 'Worker identifier is invalid.';
  end if;
  lease_seconds := greatest(30, least(coalesce(lease_seconds, 120), 600));

  update public.coding_evaluation_jobs evaluation
  set status = 'failed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'lease_expired',
      failure_reason = 'Evaluation lease expired after the retry limit.',
      updated_at = now()
  where evaluation.status = 'processing'
    and evaluation.locked_until < now()
    and evaluation.attempts >= evaluation.max_attempts;

  return query
  with next_job as (
    select evaluation.id
    from public.coding_evaluation_jobs evaluation
    where evaluation.attempts < evaluation.max_attempts
      and (
        (evaluation.status in ('queued', 'retry_wait')
          and evaluation.available_at <= now())
        or (
          evaluation.status = 'processing'
          and evaluation.locked_until < now()
        )
      )
    order by evaluation.available_at, evaluation.created_at
    for update skip locked
    limit 1
  )
  update public.coding_evaluation_jobs evaluation
  set status = 'processing',
      attempts = evaluation.attempts + 1,
      lease_token = gen_random_uuid(),
      locked_by = worker_id,
      locked_until = now() + make_interval(secs => lease_seconds),
      updated_at = now()
  from next_job
  where evaluation.id = next_job.id
  returning evaluation.*;
end;
$$;

create or replace function public.resume_coding_evaluation_jobs()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  update public.coding_evaluation_jobs
  set status = 'queued',
      available_at = now(),
      last_error_code = null,
      failure_reason = null,
      updated_at = now()
  where status = 'waiting_configuration';
  get diagnostics changed_rows = row_count;
  return changed_rows;
end;
$$;

create or replace function public.complete_coding_evaluation_job(
  target_job_id uuid,
  target_lease_token uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  evaluation_row public.coding_evaluation_jobs%rowtype;
  submission_row public.coding_submissions%rowtype;
  result_row public.coding_question_results%rowtype;
  score_value numeric(5, 2);
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  select evaluation.*
  into evaluation_row
  from public.coding_evaluation_jobs evaluation
  where evaluation.id = target_job_id
    and evaluation.status = 'processing'
    and evaluation.lease_token = target_lease_token
    and evaluation.locked_until >= now()
  for update;
  if not found then
    raise exception 'Coding evaluation lease is no longer valid.';
  end if;
  select submission.*
  into submission_row
  from public.coding_submissions submission
  where submission.workspace_id = evaluation_row.workspace_id
    and submission.id = evaluation_row.submission_id
  for update;
  select result.*
  into result_row
  from public.coding_question_results result
  where result.workspace_id = evaluation_row.workspace_id
    and result.submission_id = evaluation_row.submission_id;
  if not found then
    raise exception 'Coding evaluation results were not persisted.';
  end if;
  score_value := round(result_row.score / nullif(result_row.maximum_score, 0) * 100, 2);

  update public.coding_submissions
  set status = 'completed',
      evaluated_at = coalesce(evaluated_at, now())
  where id = submission_row.id;
  if submission_row.is_final then
    update public.coding_attempts
    set status = 'completed',
        score = score_value,
        evaluated_at = now(),
        completed_at = now(),
        error_code = null,
        updated_at = now()
    where workspace_id = submission_row.workspace_id
      and id = submission_row.attempt_id;
    update public.coding_invitations invitation
    set status = case
      when (
        select attempt.attempt_number
        from public.coding_attempts attempt
        where attempt.id = submission_row.attempt_id
      ) >= invitation.max_attempts then 'completed'
      else 'started'
    end,
    updated_at = now()
    where invitation.workspace_id = submission_row.workspace_id
      and invitation.id = (
        select attempt.invitation_id
        from public.coding_attempts attempt
        where attempt.id = submission_row.attempt_id
      );
  end if;
  update public.coding_evaluation_jobs
  set status = 'completed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = null,
      failure_reason = null,
      completed_at = now(),
      updated_at = now()
  where id = evaluation_row.id;
  return submission_row.id;
end;
$$;

create or replace function public.fail_coding_evaluation_job(
  target_job_id uuid,
  target_lease_token uuid,
  target_error_code text,
  target_failure_reason text,
  retryable boolean
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  evaluation_row public.coding_evaluation_jobs%rowtype;
  submission_row public.coding_submissions%rowtype;
  next_status text;
  retry_seconds integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  select evaluation.*
  into evaluation_row
  from public.coding_evaluation_jobs evaluation
  where evaluation.id = target_job_id
    and evaluation.status = 'processing'
    and evaluation.lease_token = target_lease_token
    and evaluation.locked_until >= now()
  for update;
  if not found then
    raise exception 'Coding evaluation lease is no longer valid.';
  end if;
  select submission.*
  into submission_row
  from public.coding_submissions submission
  where submission.workspace_id = evaluation_row.workspace_id
    and submission.id = evaluation_row.submission_id
  for update;

  next_status := case
    when retryable and evaluation_row.attempts < evaluation_row.max_attempts
      then 'retry_wait'
    else 'failed'
  end;
  retry_seconds := least(
    3600::numeric,
    15::numeric * power(2::numeric, greatest(evaluation_row.attempts - 1, 0))
  )::integer;
  update public.coding_evaluation_jobs
  set status = next_status,
      available_at = case
        when next_status = 'retry_wait'
          then now() + make_interval(secs => retry_seconds)
        else available_at
      end,
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = left(coalesce(target_error_code, 'evaluation_failed'), 80),
      failure_reason = left(coalesce(target_failure_reason, 'Coding evaluation failed.'), 500),
      updated_at = now()
  where id = evaluation_row.id;
  update public.coding_submissions
  set status = case when next_status = 'failed' then 'failed' else 'queued' end,
      evaluated_at = case when next_status = 'failed' then now() else null end
  where id = submission_row.id;
  if submission_row.is_final and next_status = 'failed' then
    update public.coding_attempts
    set status = 'failed',
        evaluated_at = now(),
        completed_at = now(),
        error_code = left(coalesce(target_error_code, 'evaluation_failed'), 80),
        updated_at = now()
    where workspace_id = submission_row.workspace_id
      and id = submission_row.attempt_id;
    update public.coding_invitations invitation
    set status = case
      when (
        select attempt.attempt_number
        from public.coding_attempts attempt
        where attempt.id = submission_row.attempt_id
      ) >= invitation.max_attempts then 'completed'
      else 'started'
    end,
    updated_at = now()
    where invitation.workspace_id = submission_row.workspace_id
      and invitation.id = (
        select attempt.invitation_id
        from public.coding_attempts attempt
        where attempt.id = submission_row.attempt_id
      );
  end if;
  return next_status;
end;
$$;

revoke all on function public.validate_coding_invitation()
  from public, anon, authenticated;
revoke all on function public.validate_coding_attempt()
  from public, anon, authenticated;
revoke all on function public.get_coding_test_cases(uuid, uuid)
  from public, anon;
revoke all on function public.save_coding_submission(uuid, uuid, uuid, text, text, boolean)
  from public, anon, authenticated;
revoke all on function public.queue_coding_evaluation()
  from public, anon, authenticated;
revoke all on function public.claim_coding_evaluation_jobs(text, integer)
  from public, anon, authenticated;
revoke all on function public.resume_coding_evaluation_jobs()
  from public, anon, authenticated;
revoke all on function public.complete_coding_evaluation_job(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.fail_coding_evaluation_job(uuid, uuid, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.get_coding_test_cases(uuid, uuid)
  to authenticated;
grant execute on function public.save_coding_submission(uuid, uuid, uuid, text, text, boolean)
  to service_role;
grant execute on function public.claim_coding_evaluation_jobs(text, integer)
  to service_role;
grant execute on function public.resume_coding_evaluation_jobs()
  to service_role;
grant execute on function public.complete_coding_evaluation_job(uuid, uuid)
  to service_role;
grant execute on function public.fail_coding_evaluation_job(uuid, uuid, text, text, boolean)
  to service_role;

create or replace function public.capture_email_delivery_status()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  related_email_status text;
begin
  related_email_status := case
    when new.status = 'delivered' then 'delivered'
    when new.status = 'sent' then 'sent'
    when new.status in ('queued', 'processing', 'retry_wait') then 'queued'
    else 'failed'
  end;
  if new.aptitude_invitation_id is not null then
    update public.aptitude_invitations
    set email_status = related_email_status,
        email_provider_message_id = coalesce(
          new.provider_message_id,
          email_provider_message_id
        ),
        email_error_code = case
          when related_email_status = 'failed' then new.last_error_code
          else null
        end,
        sent_at = coalesce(new.sent_at, sent_at)
    where workspace_id = new.workspace_id
      and id = new.aptitude_invitation_id;
  end if;
  return new;
end;
$$;

create trigger email_delivery_jobs_update_invitation_status
after update of status, provider_message_id, last_error_code, sent_at
on public.email_delivery_jobs
for each row
when (
  old.status is distinct from new.status
  or old.provider_message_id is distinct from new.provider_message_id
  or old.last_error_code is distinct from new.last_error_code
  or old.sent_at is distinct from new.sent_at
)
execute function public.capture_email_delivery_status();

create or replace function public.enqueue_manual_aptitude_invitation_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    aptitude_invitation_id,
    email_type,
    template_key,
    recipient_email,
    idempotency_key,
    status,
    attempts,
    max_attempts,
    last_error_code
  )
  values (
    new.workspace_id,
    new.application_id,
    new.id,
    'aptitude_invitation',
    'aptitude-invitation-v1',
    new.candidate_email,
    'aptitude-invitation:' || new.id::text,
    'manual_required',
    0,
    5,
    'email_sender_not_configured'
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger aptitude_invitations_create_email_delivery
after insert on public.aptitude_invitations
for each row execute function public.enqueue_manual_aptitude_invitation_email();

create or replace function public.enqueue_manual_coding_invitation_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    coding_invitation_id,
    email_type,
    template_key,
    recipient_email,
    idempotency_key,
    status,
    attempts,
    max_attempts,
    last_error_code
  )
  values (
    new.workspace_id,
    new.application_id,
    new.id,
    'coding_invitation',
    'coding-invitation-v1',
    new.candidate_email,
    'coding-invitation:' || new.id::text,
    'manual_required',
    0,
    5,
    'email_sender_not_configured'
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger coding_invitations_create_email_delivery
after insert on public.coding_invitations
for each row execute function public.enqueue_manual_coding_invitation_email();

create or replace function public.enqueue_manual_interview_invitation_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate_email_value text;
begin
  if new.interview_status <> 'scheduled' then
    return new;
  end if;
  select candidate.email
  into candidate_email_value
  from public.applications application
  join public.candidates candidate
    on candidate.workspace_id = application.workspace_id
   and candidate.id = application.candidate_id
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if candidate_email_value is null then
    return new;
  end if;
  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    interview_record_id,
    email_type,
    template_key,
    recipient_email,
    idempotency_key,
    status,
    attempts,
    max_attempts,
    last_error_code
  )
  values (
    new.workspace_id,
    new.application_id,
    new.id,
    'interview_invitation',
    'interview-invitation-v1',
    candidate_email_value,
    'interview-invitation:' || new.id::text,
    'manual_required',
    0,
    5,
    'email_sender_not_configured'
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger interview_records_create_email_delivery
after insert on public.interview_records
for each row execute function public.enqueue_manual_interview_invitation_email();

create or replace function public.enqueue_manual_interview_update_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate_email_value text;
begin
  if new.interview_status not in ('scheduled', 'rescheduled', 'cancelled')
     or (
       new.scheduled_at is not distinct from old.scheduled_at
       and new.scheduled_end_at is not distinct from old.scheduled_end_at
       and new.timezone is not distinct from old.timezone
       and new.interview_mode is not distinct from old.interview_mode
       and new.location_or_url is not distinct from old.location_or_url
       and new.interview_status is not distinct from old.interview_status
     ) then
    return new;
  end if;
  select candidate.email
  into candidate_email_value
  from public.applications application
  join public.candidates candidate
    on candidate.workspace_id = application.workspace_id
   and candidate.id = application.candidate_id
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if candidate_email_value is null then
    return new;
  end if;
  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    interview_record_id,
    email_type,
    template_key,
    recipient_email,
    idempotency_key,
    status,
    attempts,
    max_attempts,
    last_error_code
  )
  values (
    new.workspace_id,
    new.application_id,
    new.id,
    'interview_update',
    'interview-update-v1',
    candidate_email_value,
    'interview-update:' || new.id::text || ':' || new.updated_at::text,
    'manual_required',
    0,
    5,
    'email_sender_not_configured'
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger interview_records_z_enqueue_update_email
after update of scheduled_at, scheduled_end_at, timezone, interview_mode,
  location_or_url, interview_status
on public.interview_records
for each row execute function public.enqueue_manual_interview_update_email();

revoke all on function public.capture_email_delivery_status()
  from public, anon, authenticated;
revoke all on function public.enqueue_manual_aptitude_invitation_email()
  from public, anon, authenticated;
revoke all on function public.enqueue_manual_coding_invitation_email()
  from public, anon, authenticated;
revoke all on function public.enqueue_manual_interview_invitation_email()
  from public, anon, authenticated;
revoke all on function public.enqueue_manual_interview_update_email()
  from public, anon, authenticated;

create or replace function public.claim_email_delivery_jobs(
  worker_id text,
  lease_seconds integer default 120
)
returns setof public.email_delivery_jobs
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if worker_id is null or char_length(trim(worker_id)) not between 1 and 120 then
    raise exception 'Worker identifier is invalid.';
  end if;
  lease_seconds := greatest(30, least(coalesce(lease_seconds, 120), 600));

  update public.email_delivery_jobs delivery
  set status = 'failed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'lease_expired',
      updated_at = now()
  where delivery.status = 'processing'
    and delivery.locked_until < now()
    and delivery.attempts >= delivery.max_attempts;

  return query
  with next_job as (
    select delivery.id
    from public.email_delivery_jobs delivery
    where delivery.attempts < delivery.max_attempts
      and (
        (delivery.status in ('queued', 'retry_wait')
          and delivery.next_attempt_at <= now())
        or (
          delivery.status = 'processing'
          and delivery.locked_until < now()
        )
      )
    order by delivery.next_attempt_at, delivery.created_at
    for update skip locked
    limit 1
  )
  update public.email_delivery_jobs delivery
  set status = 'processing',
      attempts = delivery.attempts + 1,
      lease_token = gen_random_uuid(),
      locked_by = worker_id,
      locked_until = now() + make_interval(secs => lease_seconds),
      updated_at = now()
  from next_job
  where delivery.id = next_job.id
  returning delivery.*;
end;
$$;

create or replace function public.complete_email_delivery_job(
  target_job_id uuid,
  target_lease_token uuid,
  target_provider_message_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.email_delivery_jobs%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  update public.email_delivery_jobs
  set status = 'sent',
      provider_message_id = nullif(left(trim(coalesce(target_provider_message_id, '')), 250),
        ''),
      sent_at = coalesce(sent_at, now()),
      delivered_at = null,
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = null,
      updated_at = now()
  where id = target_job_id
    and status = 'processing'
    and lease_token = target_lease_token
    and locked_until >= now()
  returning * into delivery_row;
  if not found then
    raise exception 'Email delivery lease is no longer valid.';
  end if;
  insert into public.email_delivery_attempts (
    workspace_id,
    delivery_job_id,
    attempt_number,
    status,
    provider_message_id
  )
  values (
    delivery_row.workspace_id,
    delivery_row.id,
    delivery_row.attempts,
    'sent',
    delivery_row.provider_message_id
  )
  on conflict (delivery_job_id, attempt_number) do nothing;
  return delivery_row.id;
end;
$$;

create or replace function public.mark_email_delivery_delivered(
  target_job_id uuid,
  target_provider_message_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.email_delivery_jobs%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  update public.email_delivery_jobs
  set status = 'delivered',
      provider_message_id = coalesce(
        nullif(left(trim(coalesce(target_provider_message_id, '')), 250), ''),
        provider_message_id
      ),
      delivered_at = coalesce(delivered_at, now()),
      updated_at = now()
  where id = target_job_id
    and status in ('sent', 'delivered')
    and (
      target_provider_message_id is null
      or provider_message_id is null
      or provider_message_id = target_provider_message_id
    )
  returning * into delivery_row;
  if not found then
    raise exception 'The sent email delivery record was not found.';
  end if;
  update public.email_delivery_attempts
  set status = 'delivered',
      provider_message_id = coalesce(
        delivery_row.provider_message_id,
        provider_message_id
      ),
      completed_at = coalesce(completed_at, now())
  where delivery_job_id = delivery_row.id
    and attempt_number = delivery_row.attempts;
  return delivery_row.id;
end;
$$;

create or replace function public.fail_email_delivery_job(
  target_job_id uuid,
  target_lease_token uuid,
  target_error_code text,
  retryable boolean
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.email_delivery_jobs%rowtype;
  next_status text;
  retry_seconds integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  select delivery.*
  into delivery_row
  from public.email_delivery_jobs delivery
  where delivery.id = target_job_id
    and delivery.status = 'processing'
    and delivery.lease_token = target_lease_token
    and delivery.locked_until >= now()
  for update;
  if not found then
    raise exception 'Email delivery lease is no longer valid.';
  end if;

  next_status := case
    when retryable and delivery_row.attempts < delivery_row.max_attempts
      then 'retry_wait'
    else 'failed'
  end;
  retry_seconds := least(
    3600::numeric,
    30::numeric * power(2::numeric, greatest(delivery_row.attempts - 1, 0))
  )::integer;
  update public.email_delivery_jobs
  set status = next_status,
      next_attempt_at = case
        when next_status = 'retry_wait'
          then now() + make_interval(secs => retry_seconds)
        else next_attempt_at
      end,
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = left(coalesce(target_error_code, 'email_delivery_failed'), 100),
      updated_at = now()
  where id = delivery_row.id
  returning * into delivery_row;

  insert into public.email_delivery_attempts (
    workspace_id,
    delivery_job_id,
    attempt_number,
    status,
    error_code
  )
  values (
    delivery_row.workspace_id,
    delivery_row.id,
    delivery_row.attempts,
    next_status,
    delivery_row.last_error_code
  )
  on conflict (delivery_job_id, attempt_number) do nothing;
  return next_status;
end;
$$;

revoke all on function public.claim_email_delivery_jobs(text, integer)
  from public, anon, authenticated;
revoke all on function public.complete_email_delivery_job(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.mark_email_delivery_delivered(uuid, text)
  from public, anon, authenticated;
revoke all on function public.fail_email_delivery_job(uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function public.claim_email_delivery_jobs(text, integer)
  to service_role;
grant execute on function public.complete_email_delivery_job(uuid, uuid, text)
  to service_role;
grant execute on function public.mark_email_delivery_delivered(uuid, text)
  to service_role;
grant execute on function public.fail_email_delivery_job(uuid, uuid, text, boolean)
  to service_role;

-- Persist a manual-delivery record for existing invitations without creating
-- duplicate records or implying that an email was sent.
insert into public.email_delivery_jobs (
  workspace_id,
  application_id,
  aptitude_invitation_id,
  email_type,
  template_key,
  recipient_email,
  idempotency_key,
  status,
  provider_message_id,
  sent_at,
  last_error_code
)
select
  invitation.workspace_id,
  invitation.application_id,
  invitation.id,
  'aptitude_invitation',
  'aptitude-invitation-v1',
  invitation.candidate_email,
  'aptitude-invitation:' || invitation.id::text,
  case invitation.email_status
    when 'queued' then 'queued'
    when 'sent' then 'sent'
    when 'delivered' then 'delivered'
    when 'failed' then case
      when invitation.email_error_code = 'manual_delivery' then 'manual_required'
      else 'failed'
    end
    else 'manual_required'
  end,
  invitation.email_provider_message_id,
  invitation.sent_at,
  left(case
    when invitation.email_error_code = 'manual_delivery' then 'email_sender_not_configured'
    else invitation.email_error_code
  end, 100)
from public.aptitude_invitations invitation
on conflict (idempotency_key) do nothing;

insert into public.email_delivery_jobs (
  workspace_id,
  application_id,
  interview_record_id,
  email_type,
  template_key,
  recipient_email,
  idempotency_key,
  status,
  last_error_code
)
select
  interview.workspace_id,
  interview.application_id,
  interview.id,
  'interview_invitation',
  'interview-invitation-v1',
  candidate.email,
  'interview-invitation:' || interview.id::text,
  'manual_required',
  'email_sender_not_configured'
from public.interview_records interview
join public.applications application
  on application.workspace_id = interview.workspace_id
 and application.id = interview.application_id
join public.candidates candidate
  on candidate.workspace_id = application.workspace_id
 and candidate.id = application.candidate_id
where interview.interview_status = 'scheduled'
  and interview.scheduled_at >= now()
  and candidate.email is not null
on conflict (idempotency_key) do nothing;

create or replace view public.application_recruitment_stage_summary
with (security_invoker = true)
as
select
  application.id as application_id,
  application.workspace_id,
  application.job_id,
  application.status as application_status,
  coalesce(application.applied_at, application.created_at) as applied_at,
  coalesce(screening.screening_status, 'not_queued') as screening_status,
  screening.match_score as screening_score,
  screening.assessed_at as screening_completed_at,
  coalesce(aptitude.aptitude_status, 'not_invited') as aptitude_status,
  aptitude.score as aptitude_score,
  aptitude.submitted_at as aptitude_completed_at,
  coalesce(coding.coding_status, 'not_invited') as coding_status,
  coding.score as coding_score,
  coding.completed_at as coding_completed_at,
  coalesce(interview.interview_count, 0) as interview_count,
  interview.latest_interview_status,
  interview.latest_interview_outcome,
  interview.latest_interview_at,
  decision.decision as latest_recruiter_decision,
  decision.created_at as latest_decision_at
from public.applications application
left join lateral (
  select
    queue.status as screening_status,
    assessment.match_score,
    assessment.created_at as assessed_at
  from public.application_screening_jobs queue
  left join lateral (
    select current_assessment.match_score, current_assessment.created_at
    from public.application_screening_assessments current_assessment
    where current_assessment.workspace_id = queue.workspace_id
      and current_assessment.screening_job_id = queue.id
    order by current_assessment.assessment_version desc
    limit 1
  ) assessment on true
  where queue.workspace_id = application.workspace_id
    and queue.application_id = application.id
  order by queue.created_at desc
  limit 1
) screening on true
left join lateral (
  select
    coalesce(attempt.status, invitation.status) as aptitude_status,
    attempt.score,
    attempt.submitted_at
  from public.aptitude_invitations invitation
  left join public.aptitude_attempts attempt
    on attempt.workspace_id = invitation.workspace_id
   and attempt.invitation_id = invitation.id
  where invitation.workspace_id = application.workspace_id
    and invitation.application_id = application.id
  order by attempt.submitted_at desc nulls last, attempt.created_at desc
  limit 1
) aptitude on true
left join lateral (
  select
    coalesce(attempt.status, invitation.status) as coding_status,
    attempt.score,
    attempt.completed_at
  from public.coding_invitations invitation
  left join public.coding_attempts attempt
    on attempt.workspace_id = invitation.workspace_id
   and attempt.invitation_id = invitation.id
  where invitation.workspace_id = application.workspace_id
    and invitation.application_id = application.id
  order by attempt.completed_at desc nulls last, attempt.created_at desc
  limit 1
) coding on true
left join lateral (
  select
    count(*)::integer as interview_count,
    (array_agg(record.interview_status order by record.scheduled_at desc))[1]
      as latest_interview_status,
    (array_agg(record.outcome order by record.scheduled_at desc))[1]
      as latest_interview_outcome,
    max(record.scheduled_at) as latest_interview_at
  from public.interview_records record
  where record.workspace_id = application.workspace_id
    and record.application_id = application.id
) interview on true
left join lateral (
  select event.decision, event.created_at
  from public.application_decision_events event
  where event.workspace_id = application.workspace_id
    and event.application_id = application.id
  order by event.created_at desc, event.id desc
  limit 1
) decision on true;

revoke all on public.application_recruitment_stage_summary from public, anon;
grant select on public.application_recruitment_stage_summary to authenticated;

-- END SOURCE: 202611020003_coding_assessment_and_email_delivery.sql

-- Faster recovery of expired screening worker leases.
create index if not exists idx_screening_jobs_expired_lease
  on public.application_screening_jobs(locked_until, created_at)
  where status = 'processing';

commit;
