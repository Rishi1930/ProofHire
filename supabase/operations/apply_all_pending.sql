-- Every database change still pending in one paste.
--
-- Generated from:
--   supabase/migrations/202611120002_email_delivery_runtime.sql
--   supabase/migrations/202611120003_resume_profile_submission.sql
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
