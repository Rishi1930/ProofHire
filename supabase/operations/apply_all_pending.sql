-- Every database change still pending in one paste.
--
-- Generated from:
--   supabase/migrations/202611120002_email_delivery_runtime.sql
--   supabase/migrations/202611120003_resume_profile_submission.sql
--   supabase/migrations/202611120005_openings_and_pipeline_emails.sql
--   supabase/migrations/202611120006_requeue_superseded_screening.sql
--   supabase/migrations/202611120007_align_screening_fingerprint.sql
--   supabase/operations/demo_interview_content.sql
--
-- Each section keeps its own transaction, so a failure in one leaves the other
-- intact. Safe to run more than once.

-- Email delivery runtime.
--
-- The live database has the delivery queue from 202611020003 but never received
-- the two functions added later by the skipped aptitude migration, so the email
-- worker could not start a single job. This re-creates those functions without
-- any aptitude dependency and extends the queue with the two notifications the
-- product actually sends: screening results and technical interview invitations.
--
-- Safe to run more than once.

begin;

-- 1. Queue columns the later notification types need.

alter table public.email_delivery_jobs
  add column if not exists screening_assessment_id uuid
    references public.application_screening_assessments(id) on delete cascade;

alter table public.email_delivery_jobs
  add column if not exists interview_session_id uuid
    references public.interview_sessions(id) on delete cascade;

alter table public.email_delivery_jobs
  add column if not exists template_data jsonb;

-- 2. Allowed email types and the target check that pairs a type with its subject.

alter table public.email_delivery_jobs
  drop constraint if exists email_delivery_jobs_email_type_check;

alter table public.email_delivery_jobs
  add constraint email_delivery_jobs_email_type_check
  check (
    email_type in (
      'application_update',
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
      email_type in ('application_update', 'rejection', 'offer')
      and screening_assessment_id is null
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is null
      and interview_session_id is null
    )
  );

-- 3. Context for each queued message. Only the service role may read it.

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

  if delivery_row.email_type = 'screening_result' then
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

-- 4. Tell the worker whether a transport is configured, so queued mail is not
--    burned while SMTP is unset.

create or replace function public.set_email_delivery_configuration(
  target_available boolean
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.' using errcode = '42501';
  end if;

  if target_available then
    update public.email_delivery_jobs
    set status = 'queued',
        next_attempt_at = now(),
        last_error_code = null,
        updated_at = now()
    where status = 'blocked_configuration';
  else
    update public.email_delivery_jobs
    set status = 'blocked_configuration',
        lease_token = null,
        locked_by = null,
        locked_until = null,
        last_error_code = 'email_configuration_unavailable',
        updated_at = now()
    where status in ('queued', 'retry_wait');
  end if;

  get diagnostics changed_rows = row_count;
  return changed_rows;
end;
$$;

revoke all on function public.set_email_delivery_configuration(boolean)
  from public, anon, authenticated;
grant execute on function public.set_email_delivery_configuration(boolean)
  to service_role;

-- 5. Screening results notify the candidate as soon as the engine records them.

create or replace function public.enqueue_screening_result_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row public.applications%rowtype;
  candidate_row public.candidates%rowtype;
begin
  if new.report ->> 'threshold_met' is null
     or new.report ->> 'threshold_met' not in ('true', 'false') then
    return new;
  end if;

  select application.*
  into application_row
  from public.applications application
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if not found then
    return new;
  end if;

  select candidate.*
  into candidate_row
  from public.candidates candidate
  where candidate.workspace_id = application_row.workspace_id
    and candidate.id = application_row.candidate_id;
  if candidate_row.email is null or btrim(candidate_row.email) = '' then
    return new;
  end if;

  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    screening_assessment_id,
    email_type,
    template_key,
    recipient_email,
    idempotency_key,
    status,
    attempts,
    max_attempts
  )
  values (
    new.workspace_id,
    new.application_id,
    new.id,
    'screening_result',
    'screening-result-v1',
    candidate_row.email,
    'screening-result:' || new.id::text,
    'queued',
    0,
    5
  )
  on conflict (idempotency_key) do update
    set recipient_email = excluded.recipient_email,
        status = 'queued',
        next_attempt_at = now(),
        last_error_code = null,
        lease_token = null,
        locked_by = null,
        locked_until = null,
        updated_at = now()
    where public.email_delivery_jobs.status <> 'sent';

  return new;
end;
$$;

revoke all on function public.enqueue_screening_result_email()
  from public, anon, authenticated;

drop trigger if exists application_screening_assessments_enqueue_followup
  on public.application_screening_assessments;
create trigger application_screening_assessments_enqueue_followup
after insert or update of match_score, report
on public.application_screening_assessments
for each row execute function public.enqueue_screening_result_email();

-- 6. Interview invitations. The raw link is only known to the recruiter who
--    created the session, so it is passed in, verified against the stored hash
--    and kept in template_data until the message is sent.

create or replace function public.send_interview_invitation(
  p_session_id uuid,
  p_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_record public.interview_sessions%rowtype;
  candidate_email text;
  delivery_id uuid;
begin
  if auth.uid() is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;
  if p_token is null or char_length(p_token) <> 64 then
    raise exception 'invalid_interview_token' using errcode = '22023';
  end if;

  select *
  into session_record
  from public.interview_sessions
  where id = p_session_id;

  if session_record.id is null then
    raise exception 'interview_session_not_found' using errcode = 'P0002';
  end if;
  if not public.has_workspace_role(
    session_record.workspace_id,
    array['owner', 'admin', 'recruiter']
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if session_record.access_token_hash <> public.interview_token_digest(p_token) then
    raise exception 'invalid_interview_token' using errcode = '22023';
  end if;

  select candidate.email
  into candidate_email
  from public.candidates candidate
  join public.applications application
    on application.workspace_id = candidate.workspace_id
   and application.candidate_id = candidate.id
  where application.id = session_record.application_id
    and application.workspace_id = session_record.workspace_id;

  if candidate_email is null or btrim(candidate_email) = '' then
    raise exception 'candidate_email_missing' using errcode = 'P0001';
  end if;

  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    interview_session_id,
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
    session_record.workspace_id,
    session_record.application_id,
    session_record.id,
    'interview_invitation',
    'interview-invitation-v1',
    candidate_email,
    'interview-invitation:' || session_record.id::text,
    'queued',
    0,
    5,
    jsonb_build_object(
      'interview_path', '/interview/' || p_token,
      'interview_type', 'Technical interview',
      'duration_seconds',
        session_record.questions_time_limit_seconds
        + session_record.coding_time_limit_seconds
    )
  )
  on conflict (idempotency_key) do update
    set recipient_email = excluded.recipient_email,
        template_data = excluded.template_data,
        status = 'queued',
        next_attempt_at = now(),
        last_error_code = null,
        lease_token = null,
        locked_by = null,
        locked_until = null,
        updated_at = now()
    where public.email_delivery_jobs.status <> 'sent'
  returning id into delivery_id;

  return jsonb_build_object(
    'queued', delivery_id is not null,
    'delivery_id', delivery_id,
    'recipient', candidate_email
  );
end;
$$;

revoke all on function public.send_interview_invitation(uuid, text)
  from public, anon, authenticated;
grant execute on function public.send_interview_invitation(uuid, text)
  to authenticated;

commit;

-- Resume profile on public applications.
--
-- Candidates can let the browser extract text from their resume, review it and
-- submit it with the application. This adds the column and redefines the public
-- submission RPC to accept it. The previous definition lives in
-- 202610260004_public_application_status_and_duplicates.sql; this file is that
-- function plus the new argument.
--
-- Safe to run more than once.

begin;

alter table public.applications
  add column if not exists resume_profile jsonb not null default '{}'::jsonb;

alter table public.applications
  drop constraint if exists applications_resume_profile_object;

alter table public.applications
  add constraint applications_resume_profile_object
  check (jsonb_typeof(resume_profile) = 'object');

create or replace function public.submit_public_application(
  p_job_id uuid,
  p_full_name text,
  p_email text,
  p_resume_profile jsonb,
  p_phone text default null,
  p_cover_letter text default null,
  p_resume_path text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  submission_result jsonb;
  target_workspace_id uuid;
  target_minimum_experience numeric;
  submitted_experience_years numeric;
  normalized_email text;
  updated_rows integer;
begin
  if p_resume_profile is null
     or jsonb_typeof(p_resume_profile) <> 'object'
     or pg_column_size(p_resume_profile) > 32768 then
    raise exception 'Resume details are invalid or too large.';
  end if;

  if p_resume_profile ? 'education'
     and jsonb_typeof(p_resume_profile -> 'education') <> 'string' then
    raise exception 'Education details must be text.';
  end if;
  if p_resume_profile ? 'experience_summary'
     and jsonb_typeof(p_resume_profile -> 'experience_summary') <> 'string' then
    raise exception 'Work-history details must be text.';
  end if;

  if char_length(coalesce(p_resume_profile ->> 'education', '')) > 4000
     or char_length(coalesce(p_resume_profile ->> 'experience_summary', '')) > 6000 then
    raise exception 'Resume details exceed the allowed length.';
  end if;

  if p_resume_profile ? 'skills'
     and jsonb_typeof(p_resume_profile -> 'skills') <> 'array' then
    raise exception 'Skills must be a list.';
  end if;
  if p_resume_profile ? 'skills' then
    if jsonb_array_length(p_resume_profile -> 'skills') > 100 then
      raise exception 'Resume skills exceed the allowed count.';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(p_resume_profile -> 'skills') as skills(value)
      where jsonb_typeof(value) is distinct from 'string'
         or char_length(value #>> '{}') > 100
    ) then
      raise exception 'Resume skills must be short text values.';
    end if;
  end if;

  if p_resume_profile ? 'experience'
     and jsonb_typeof(p_resume_profile -> 'experience') <> 'array' then
    raise exception 'Work experience must be a list.';
  end if;
  if p_resume_profile ? 'experience' then
    if jsonb_array_length(p_resume_profile -> 'experience') > 20 then
      raise exception 'Work experience entries exceed the allowed count.';
    end if;
    if exists (
      select 1
      from jsonb_array_elements(p_resume_profile -> 'experience') as experiences(value)
      where jsonb_typeof(value) <> 'object'
         or jsonb_typeof(value -> 'company') is distinct from 'string'
         or jsonb_typeof(value -> 'role') is distinct from 'string'
         or char_length(value ->> 'company') > 180
         or char_length(value ->> 'role') > 180
    ) then
      raise exception 'Work experience entries must include valid company and role text.';
    end if;
  end if;

  if p_resume_profile ? 'experience_years'
     and p_resume_profile -> 'experience_years' <> 'null'::jsonb then
    if jsonb_typeof(p_resume_profile -> 'experience_years') <> 'number' then
      raise exception 'Experience years must be between 0 and 60.';
    end if;
    if (p_resume_profile ->> 'experience_years')::numeric < 0
       or (p_resume_profile ->> 'experience_years')::numeric > 60 then
      raise exception 'Experience years must be between 0 and 60.';
    end if;
  end if;

  submission_result := public.submit_public_application(
    p_job_id,
    p_full_name,
    p_email,
    p_phone,
    p_cover_letter,
    p_resume_path
  );

  if coalesce((submission_result ->> 'duplicate')::boolean, false) then
    return submission_result;
  end if;

  select j.workspace_id, j.minimum_experience
  into target_workspace_id, target_minimum_experience
  from public.jobs j
  where j.id = p_job_id;

  if p_resume_profile -> 'experience_years' <> 'null'::jsonb then
    submitted_experience_years := (p_resume_profile ->> 'experience_years')::numeric;
  end if;

  if coalesce(target_minimum_experience, 0) > 0
     and submitted_experience_years is null then
    raise exception 'Years of experience are required for this role.';
  end if;

  if submitted_experience_years > 0 then
    if jsonb_array_length(coalesce(p_resume_profile -> 'experience', '[]'::jsonb)) = 0
       or exists (
         select 1
         from jsonb_array_elements(coalesce(p_resume_profile -> 'experience', '[]'::jsonb)) as experiences(value)
         where nullif(trim(value ->> 'company'), '') is null
            or nullif(trim(value ->> 'role'), '') is null
       ) then
      raise exception 'Each reported work experience must include a company and role.';
    end if;
  end if;

  normalized_email := lower(trim(coalesce(p_email, '')));

  update public.applications a
  set resume_profile = p_resume_profile
  from public.candidates c
  where a.workspace_id = target_workspace_id
    and a.job_id = p_job_id
    and a.candidate_id = c.id
    and c.workspace_id = a.workspace_id
    and lower(trim(c.email)) = normalized_email;

  get diagnostics updated_rows = row_count;
  if updated_rows <> 1 then
    raise exception 'Could not save the extracted resume details.';
  end if;

  return submission_result;
end;
$$;

revoke all on function public.submit_public_application(
  uuid, text, text, jsonb, text, text, text
) from public, anon, authenticated;
grant execute on function public.submit_public_application(
  uuid, text, text, jsonb, text, text, text
) to anon, authenticated;

commit;

-- ---------------------------------------------------------------------------
-- Job openings, pipeline emails, automatic closing (202611120005).
-- ---------------------------------------------------------------------------

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


-- ---------------------------------------------------------------------------
-- Demo interview content (one practice challenge + two general questions per job).
-- ---------------------------------------------------------------------------

-- Demo interview content for investor walkthroughs.
--
-- Only the interview/coding content is demonstration material: job-specific
-- questions and graded coding tasks cannot be authored automatically for an
-- arbitrary job, so every workspace gets one published practice challenge and
-- a couple of general questions. Everything else in the pipeline (screening,
-- shortlisting, emails, stage counts, auto-closing jobs) is real.
--
-- Safe to run more than once; it only fills what is missing.

do $$
declare
  ws record;
  job_rec record;
  challenge_id uuid;
  demo_challenge_id uuid;
  version_id uuid;
begin
  for ws in select distinct workspace_id from public.jobs loop
    for job_rec in
      select id from public.jobs where workspace_id = ws.workspace_id order by created_at
    loop
      if not exists (
        select 1 from public.interview_questions where job_id = job_rec.id
      ) then
        insert into public.interview_questions (
          workspace_id, job_id, display_order, prompt, category, expected_keywords, max_points
        )
        values
          (
            ws.workspace_id, job_rec.id, 1,
            'Walk me through how you would build a page that loads data from several APIs. Where does state live, and how do you avoid unnecessary re-renders?',
            'frontend',
            array['component', 'state', 'hook', 'memo', 'effect'],
            5
          ),
          (
            ws.workspace_id, job_rec.id, 2,
            'How would you keep a database-backed endpoint fast as its table grows to millions of rows? Cover indexes, pagination and query plans.',
            'backend',
            array['index', 'pagination', 'query', 'plan', 'cache'],
            5
          );
      end if;

      select id into challenge_id
      from public.coding_challenges
      where workspace_id = ws.workspace_id and title = 'Sum of integers'
      limit 1;

      demo_challenge_id := challenge_id;

      if demo_challenge_id is null then
        insert into public.coding_challenges (workspace_id, title, description)
        values (
          ws.workspace_id,
          'Sum of integers',
          'Read whitespace-separated integers from standard input and print their sum.'
        )
        returning id into challenge_id;
        demo_challenge_id := challenge_id;
      end if;

      select versions.id into version_id
      from public.coding_challenge_versions versions
      where versions.challenge_id = demo_challenge_id
      order by versions.version_number desc
      limit 1;

      if version_id is null then
        insert into public.coding_challenge_versions (
          workspace_id,
          challenge_id,
          version_number,
          prompt,
          difficulty,
          supported_languages,
          starter_code,
          points,
          max_execution_seconds,
          version_status
        )
        values (
          ws.workspace_id,
          demo_challenge_id,
          1,
          E'Read all integers from standard input (whitespace separated) and print their sum.\n\nExample\n-------\nInput: 2 3 5\nOutput: 10',
          'beginner',
          array['python', 'javascript', 'go'],
          jsonb_build_object(
            'python', E'import sys\n\nnumbers = [int(value) for value in sys.stdin.read().split()]\nprint(sum(numbers))\n',
            'javascript', E'const input = require("fs").readFileSync(0, "utf8").trim();\nconst numbers = input ? input.split(/\\s+/).map(Number) : [];\nconsole.log(numbers.reduce((total, value) => total + value, 0));\n',
            'go', E'package main\n\nimport (\n\t"bufio"\n\t"fmt"\n\t"os"\n)\n\nfunc main() {\n\tscanner := bufio.NewScanner(os.Stdin)\n\tscanner.Split(bufio.ScanWords)\n\ttotal := 0\n\tfor scanner.Scan() {\n\t\tvar value int\n\t\tfmt.Sscan(scanner.Text(), &value)\n\t\ttotal += value\n\t}\n\tfmt.Println(total)\n}\n'
          ),
          10,
          10,
          'draft'
        )
        returning id into version_id;

        insert into proofhire_private.coding_test_cases (
          workspace_id, challenge_version_id, display_order, input_text, expected_output, is_hidden, points
        )
        values
          (ws.workspace_id, version_id, 1, '2 3 5', '10', false, 1),
          (ws.workspace_id, version_id, 2, '-4 10 0 7', '13', true, 2),
          (ws.workspace_id, version_id, 3, '1000000 2000000 3000000', '6000000', true, 2);

        update public.coding_challenge_versions
        set version_status = 'published', published_at = now()
        where id = version_id;
      end if;
    end loop;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------------
-- 202611120006_requeue_superseded_screening.sql
-- ---------------------------------------------------------------------------

-- Let a screening job be requeued after it was superseded or cancelled.
--
-- The enqueue function only revived 'failed' and 'waiting_configuration' jobs,
-- so once the worker retired a job as 'superseded' the same application could
-- never be screened again: the insert conflicts with the retired row and the
-- retry branch ignores its status. Retrying now covers every terminal state.
--
-- Safe to run more than once.

begin;

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
  fingerprint text;
  screening_job_id uuid;
begin
  select application.id, application.workspace_id, application.resume_path
  into application_row
  from public.applications application
  where application.id = target_application_id;

  if not found or application_row.resume_path is null then
    return null;
  end if;

  fingerprint := public.application_screening_input_fingerprint(
    target_application_id
  );
  if fingerprint is null then
    return null;
  end if;

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
    update public.application_screening_jobs screening_job
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
      and screening_job.status in (
        'failed',
        'waiting_configuration',
        'superseded',
        'cancelled'
      )
    returning id into screening_job_id;
  end if;

  if screening_job_id is null then
    select screening_job.id
    into screening_job_id
    from public.application_screening_jobs screening_job
    where screening_job.application_id = application_row.id
      and screening_job.input_fingerprint = fingerprint;
  end if;

  return screening_job_id;
end;
$$;

revoke all on function public.enqueue_application_screening(uuid, boolean)
  from public, anon, authenticated;

commit;


-- ---------------------------------------------------------------------------
-- 202611120007_align_screening_fingerprint.sql
-- ---------------------------------------------------------------------------

-- Use one screening fingerprint everywhere.
--
-- claim_application_screening_job still hashed only seven job fields inline
-- (resume path, title, department, description, skills, experience), while
-- enqueue_application_screening and complete_application_screening_job use
-- application_screening_input_fingerprint(), which also covers the screening
-- threshold, the weights and the configured requirements. Every queued job was
-- therefore considered stale the moment it was claimed and was retired as
-- 'superseded' without ever being scored.
--
-- The claim function now calls the same helper as everything else.
--
-- Safe to run more than once.

begin;

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
  where (
      screening_job.status in ('pending', 'retry_wait')
      or (
        screening_job.status = 'processing'
        and screening_job.locked_until < now()
      )
    )
    and screening_job.input_fingerprint is distinct from
      public.application_screening_input_fingerprint(screening_job.application_id);

  return query
  with next_job as (
    select screening_job.id
    from public.application_screening_jobs as screening_job
    where screening_job.attempts < screening_job.max_attempts
      and (
        (
          screening_job.status in ('pending', 'retry_wait')
          and screening_job.available_at <= now()
          and screening_job.input_fingerprint =
            public.application_screening_input_fingerprint(screening_job.application_id)
        )
        or (
          screening_job.status = 'processing'
          and screening_job.locked_until < now()
        )
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

revoke all on function public.claim_application_screening_job(text, integer)
  from public, anon, authenticated;
grant execute on function public.claim_application_screening_job(text, integer)
  to service_role;

commit;

