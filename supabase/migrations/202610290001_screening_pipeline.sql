-- Persist application-specific screening work and immutable assessment history.
-- Apply after migrations 001 through 006; do not apply without reviewing the target.

begin;

create table if not exists public.job_screening_criteria (
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

create table if not exists public.application_screening_jobs (
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

create index if not exists idx_screening_jobs_claim
  on public.application_screening_jobs(status, available_at, created_at)
  where status in ('pending', 'retry_wait', 'processing');
create index if not exists idx_screening_jobs_workspace_created
  on public.application_screening_jobs(workspace_id, created_at desc);
create index if not exists idx_screening_jobs_application_created
  on public.application_screening_jobs(application_id, created_at desc);

create table if not exists public.application_screening_assessments (
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

create index if not exists idx_screening_assessments_application_created
  on public.application_screening_assessments(application_id, created_at desc);
create index if not exists idx_screening_assessments_job_score
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
    array['owner', 'admin', 'recruiter']::text[]
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

commit;
