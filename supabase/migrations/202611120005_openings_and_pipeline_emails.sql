-- Job openings, automatic pipeline emails, and closing a filled job.
--
-- Adds the number of positions a job is hiring for, stops public applications
-- once a job is not open, notifies candidates when their application arrives
-- and when they are shortlisted, and closes the job automatically once the
-- requested number of people is hired.
--
-- Safe to run more than once.

begin;

-- 1. Positions per job.

alter table public.jobs
  add column if not exists openings integer not null default 1;

alter table public.jobs
  drop constraint if exists jobs_openings_check;

alter table public.jobs
  add constraint jobs_openings_check check (openings between 1 and 100);

-- 2. A closed or paused job stops accepting public applications, whatever the
--    submission function itself allows.

create or replace function public.require_open_job_for_public_application()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  job_status text;
begin
  if new.source is distinct from 'public' then
    return new;
  end if;

  select status into job_status from public.jobs where id = new.job_id;
  if job_status is distinct from 'open' then
    raise exception 'This job is no longer accepting applications.' using errcode = 'P0001';
  end if;

  return new;
end;
$$;

revoke all on function public.require_open_job_for_public_application()
  from public, anon, authenticated;

drop trigger if exists applications_require_open_job on public.applications;
create trigger applications_require_open_job
before insert on public.applications
for each row execute function public.require_open_job_for_public_application();

-- 3. Two new notification types.

alter table public.email_delivery_jobs
  drop constraint if exists email_delivery_jobs_email_type_check;

alter table public.email_delivery_jobs
  add constraint email_delivery_jobs_email_type_check
  check (
    email_type in (
      'application_update',
      'application_received',
      'shortlisted',
      'aptitude_invitation',
      'coding_invitation',
      'interview_invitation',
      'interview_update',
      'rejection',
      'offer',
      'screening_result'
    )
  );

alter table public.email_delivery_jobs
  drop constraint if exists email_delivery_jobs_target_check;

alter table public.email_delivery_jobs
  add constraint email_delivery_jobs_target_check check (
    (
      email_type = 'screening_result'
      and screening_assessment_id is not null
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is null
      and interview_session_id is null
    )
    or (
      email_type = 'interview_invitation'
      and interview_session_id is not null
      and screening_assessment_id is null
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is null
    )
    or (
      email_type in ('interview_invitation', 'interview_update')
      and interview_record_id is not null
      and screening_assessment_id is null
      and interview_session_id is null
      and aptitude_invitation_id is null
      and coding_invitation_id is null
    )
    or (
      email_type = 'aptitude_invitation'
      and aptitude_invitation_id is not null
      and screening_assessment_id is null
      and coding_invitation_id is null
      and interview_record_id is null
      and interview_session_id is null
    )
    or (
      email_type = 'coding_invitation'
      and coding_invitation_id is not null
      and screening_assessment_id is null
      and aptitude_invitation_id is null
      and interview_record_id is null
      and interview_session_id is null
    )
    or (
      email_type in (
        'application_update',
        'application_received',
        'shortlisted',
        'rejection',
        'offer'
      )
      and screening_assessment_id is null
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is null
      and interview_session_id is null
    )
  );

-- 4. Queue the two notifications as the application moves through the pipeline.

create or replace function public.enqueue_application_pipeline_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate_row public.candidates%rowtype;
  email_kind text;
begin
  if tg_op = 'INSERT' then
    if new.source is distinct from 'public' then
      return new;
    end if;
    email_kind := 'application_received';
  elsif new.status = 'shortlisted' and old.status is distinct from 'shortlisted' then
    email_kind := 'shortlisted';
  else
    return new;
  end if;

  select candidate.*
  into candidate_row
  from public.candidates candidate
  where candidate.workspace_id = new.workspace_id
    and candidate.id = new.candidate_id;

  if candidate_row.email is null or btrim(candidate_row.email) = '' then
    return new;
  end if;

  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    email_type,
    template_key,
    recipient_email,
    idempotency_key,
    status,
    attempts,
    max_attempts,
    template_data
  )
  values (
    new.workspace_id,
    new.id,
    email_kind,
    email_kind || '-v1',
    candidate_row.email,
    email_kind || ':' || new.id::text,
    'queued',
    0,
    5,
    '{}'::jsonb
  )
  on conflict (idempotency_key) do nothing;

  return new;
end;
$$;

revoke all on function public.enqueue_application_pipeline_email()
  from public, anon, authenticated;

drop trigger if exists applications_pipeline_email on public.applications;
create trigger applications_pipeline_email
after insert or update of status on public.applications
for each row execute function public.enqueue_application_pipeline_email();

-- 5. Close the job once the requested number of people is hired.

create or replace function public.close_job_when_filled()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  hired_count integer;
  opening_count integer;
begin
  if new.status is distinct from 'hired' then
    return new;
  end if;

  select count(*)
  into hired_count
  from public.applications application
  where application.workspace_id = new.workspace_id
    and application.job_id = new.job_id
    and application.status = 'hired';

  select coalesce(openings, 1)
  into opening_count
  from public.jobs
  where id = new.job_id;

  if hired_count >= opening_count then
    update public.jobs
    set status = 'closed',
        updated_at = now()
    where id = new.job_id
      and status is distinct from 'closed';
  end if;

  return new;
end;
$$;

revoke all on function public.close_job_when_filled()
  from public, anon, authenticated;

drop trigger if exists applications_close_job_when_filled on public.applications;
create trigger applications_close_job_when_filled
after update of status on public.applications
for each row execute function public.close_job_when_filled();

-- 6. Context for the two new messages.

create or replace function public.get_email_delivery_context(
  target_job_id uuid,
  target_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.email_delivery_jobs%rowtype;
  context_value jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.' using errcode = '42501';
  end if;

  select delivery.*
  into delivery_row
  from public.email_delivery_jobs delivery
  where delivery.id = target_job_id
    and delivery.status = 'processing'
    and delivery.lease_token = target_lease_token
    and delivery.locked_until >= now();

  if not found then
    raise exception 'Email delivery lease is no longer valid.' using errcode = 'P0001';
  end if;

  if delivery_row.email_type in ('application_received', 'shortlisted') then
    select jsonb_build_object(
      'candidate_name', candidate.full_name,
      'job_title', job.title,
      'company_name', workspace.name,
      'openings', coalesce(job.openings, 1)
    )
    into context_value
    from public.applications application
    join public.candidates candidate
      on candidate.workspace_id = application.workspace_id
     and candidate.id = application.candidate_id
    join public.jobs job
      on job.workspace_id = application.workspace_id
     and job.id = application.job_id
    join public.workspaces workspace
      on workspace.id = application.workspace_id
    where application.id = delivery_row.application_id;
  elsif delivery_row.email_type = 'screening_result' then
    select jsonb_build_object(
      'candidate_name', candidate.full_name,
      'job_title', job.title,
      'company_name', workspace.name,
      'passed', coalesce(assessment.report ->> 'threshold_met', 'false') = 'true'
    )
    into context_value
    from public.application_screening_assessments assessment
    join public.applications application
      on application.workspace_id = assessment.workspace_id
     and application.id = assessment.application_id
    join public.candidates candidate
      on candidate.workspace_id = application.workspace_id
     and candidate.id = application.candidate_id
    join public.jobs job
      on job.workspace_id = application.workspace_id
     and job.id = application.job_id
    join public.workspaces workspace
      on workspace.id = application.workspace_id
    where assessment.id = delivery_row.screening_assessment_id;
  elsif delivery_row.email_type = 'interview_invitation' then
    select jsonb_build_object(
      'candidate_name', candidate.full_name,
      'job_title', job.title,
      'company_name', workspace.name,
      'interview_type', coalesce(
        nullif(delivery_row.template_data ->> 'interview_type', ''),
        'Technical interview'
      ),
      'duration_seconds', coalesce(
        (delivery_row.template_data ->> 'duration_seconds')::integer,
        0
      ),
      'interview_path', delivery_row.template_data ->> 'interview_path'
    )
    into context_value
    from public.interview_sessions session_row
    join public.applications application
      on application.workspace_id = session_row.workspace_id
     and application.id = session_row.application_id
    join public.candidates candidate
      on candidate.workspace_id = application.workspace_id
     and candidate.id = application.candidate_id
    join public.jobs job
      on job.workspace_id = session_row.workspace_id
     and job.id = session_row.job_id
    join public.workspaces workspace
      on workspace.id = session_row.workspace_id
    where session_row.id = delivery_row.interview_session_id;
  else
    raise exception 'Email delivery type is not supported by this worker.'
      using errcode = 'P0001';
  end if;

  if context_value is null then
    raise exception 'Email delivery context is unavailable.' using errcode = 'P0001';
  end if;
  return context_value;
end;
$$;

revoke all on function public.get_email_delivery_context(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.get_email_delivery_context(uuid, uuid)
  to service_role;

commit;
