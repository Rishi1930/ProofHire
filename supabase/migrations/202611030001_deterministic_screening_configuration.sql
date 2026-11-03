-- Add recruiter-configurable deterministic screening settings and
-- workspace-scoped supplemental requirements. This migration is additive.

begin;

do $preflight$
begin
  if to_regclass('public.jobs') is null then
    raise exception 'Required table public.jobs is missing.';
  end if;
  if to_regclass('public.workspaces') is null then
    raise exception 'Required table public.workspaces is missing.';
  end if;
  if to_regprocedure('public.is_workspace_member(uuid)') is null
     or to_regprocedure('public.has_workspace_role(uuid,text[])') is null then
    raise exception 'Required workspace authorization functions are missing.';
  end if;
  if not exists (
    select 1
    from pg_constraint constraint_row
    where constraint_row.conrelid = 'public.jobs'::regclass
      and constraint_row.contype = 'u'
      and pg_get_constraintdef(constraint_row.oid) like '%(id, workspace_id)%'
  ) and not exists (
    select 1
    from pg_index index_row
    where index_row.indrelid = 'public.jobs'::regclass
      and index_row.indisunique
      and pg_get_indexdef(index_row.indexrelid) like '%(id, workspace_id)%'
  ) then
    raise exception 'public.jobs must have a unique (id, workspace_id) key.';
  end if;
end;
$preflight$;

alter table public.jobs
  add column if not exists minimum_screening_percentage numeric(5, 2)
    not null default 70,
  add column if not exists screening_weights jsonb
    not null default '{"mandatory":2,"preferred":1,"experience":2}'::jsonb;

do $constraints$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.jobs'::regclass
      and conname = 'jobs_minimum_screening_percentage_check'
  ) then
    alter table public.jobs
      add constraint jobs_minimum_screening_percentage_check
      check (minimum_screening_percentage between 0 and 100);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.jobs'::regclass
      and conname = 'jobs_screening_weights_check'
  ) then
    alter table public.jobs
      add constraint jobs_screening_weights_check
      check (
        jsonb_typeof(screening_weights) = 'object'
        and (
          not (screening_weights ? 'mandatory')
          or (
            jsonb_typeof(screening_weights -> 'mandatory') = 'number'
            and (screening_weights ->> 'mandatory')::numeric > 0
          )
        )
        and (
          not (screening_weights ? 'preferred')
          or (
            jsonb_typeof(screening_weights -> 'preferred') = 'number'
            and (screening_weights ->> 'preferred')::numeric > 0
          )
        )
        and (
          not (screening_weights ? 'experience')
          or (
            jsonb_typeof(screening_weights -> 'experience') = 'number'
            and (screening_weights ->> 'experience')::numeric > 0
          )
        )
      );
  end if;
end;
$constraints$;

create table if not exists public.job_screening_requirements (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  job_id uuid not null,
  requirement_key text not null
    check (requirement_key ~ '^[a-z0-9][a-z0-9_-]{0,79}$'),
  name text not null check (char_length(trim(name)) between 1 and 180),
  description text not null default ''
    check (char_length(description) <= 2000),
  priority text not null check (priority in ('mandatory', 'preferred')),
  category text not null check (
    category in (
      'skill',
      'experience',
      'education',
      'work_experience',
      'project',
      'certification',
      'qualification'
    )
  ),
  weight numeric(8, 2) not null check (weight > 0 and weight <= 1000),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_screening_requirements_job_fk
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,
  constraint job_screening_requirements_job_key_unique
    unique (workspace_id, job_id, requirement_key),
  constraint job_screening_requirements_workspace_id_unique
    unique (workspace_id, id)
);

create index if not exists idx_job_screening_requirements_job_active
  on public.job_screening_requirements(workspace_id, job_id, is_active, created_at);

drop trigger if exists job_screening_requirements_set_updated_at
  on public.job_screening_requirements;
create trigger job_screening_requirements_set_updated_at
before update on public.job_screening_requirements
for each row execute function public.set_updated_at();

alter table public.job_screening_requirements enable row level security;
drop policy if exists "Workspace members can read job screening requirements"
  on public.job_screening_requirements;
create policy "Workspace members can read job screening requirements"
on public.job_screening_requirements
for select to authenticated
using (public.is_workspace_member(workspace_id));

drop policy if exists "Recruiters can manage job screening requirements"
  on public.job_screening_requirements;

revoke all on public.job_screening_requirements from public, anon, authenticated;
grant select on public.job_screening_requirements to authenticated;
grant all on public.job_screening_requirements to service_role;

create or replace function public.application_screening_input_fingerprint(
  target_application_id uuid
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row record;
  job_row public.jobs%rowtype;
  requirements_value jsonb;
  fingerprint_value jsonb;
begin
  select application.id, application.workspace_id, application.job_id,
         application.resume_path
  into application_row
  from public.applications application
  where application.id = target_application_id;

  if not found or application_row.resume_path is null then
    return null;
  end if;

  select job.*
  into job_row
  from public.jobs job
  where job.id = application_row.job_id
    and job.workspace_id = application_row.workspace_id;

  if not found then
    return null;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'requirement_key', requirement.requirement_key,
        'name', requirement.name,
        'description', requirement.description,
        'priority', requirement.priority,
        'category', requirement.category,
        'weight', requirement.weight
      )
      order by requirement.requirement_key
    ),
    '[]'::jsonb
  )
  into requirements_value
  from public.job_screening_requirements requirement
  where requirement.workspace_id = application_row.workspace_id
    and requirement.job_id = application_row.job_id
    and requirement.is_active;

  fingerprint_value := jsonb_build_array(
    application_row.resume_path,
    job_row.title,
    job_row.department,
    job_row.description,
    job_row.required_skills,
    job_row.preferred_skills,
    job_row.minimum_experience,
    job_row.minimum_screening_percentage,
    job_row.screening_weights,
    requirements_value
  );

  return encode(
    extensions.digest(convert_to(fingerprint_value::text, 'UTF8'), 'sha256'),
    'hex'
  );
end;
$$;

revoke all on function public.application_screening_input_fingerprint(uuid)
  from public, anon, authenticated;
grant execute on function public.application_screening_input_fingerprint(uuid)
  to service_role;

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
      and screening_job.status in ('failed', 'waiting_configuration')
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

drop trigger if exists jobs_queue_screening on public.jobs;
create trigger jobs_queue_screening
after update of title, department, description, required_skills,
  preferred_skills, minimum_experience, minimum_screening_percentage,
  screening_weights on public.jobs
for each row execute function public.queue_screening_for_job();

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
  if target_match_score is not null
     and (target_match_score < 0 or target_match_score > 100) then
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
  from public.application_screening_jobs screening_job
  where screening_job.id = target_job_id
  for update;
  if not found or job_row.status <> 'processing'
     or job_row.lease_token <> target_lease_token
     or job_row.locked_until < now() then
    raise exception 'Screening job lease is no longer valid.';
  end if;

  select application.*
  into application_row
  from public.applications application
  where application.id = job_row.application_id
    and application.workspace_id = job_row.workspace_id
  for update;
  if not found then
    raise exception 'Screening application no longer exists.';
  end if;

  perform 1
  from public.jobs job
  where job.id = application_row.job_id
    and job.workspace_id = application_row.workspace_id
  for share;

  current_fingerprint :=
    public.application_screening_input_fingerprint(application_row.id);
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
    from public.job_screening_criteria criteria_row
    where criteria_row.workspace_id = job_row.workspace_id
      and criteria_row.job_id = application_row.job_id
      and criteria_row.input_fingerprint = target_criteria_fingerprint;
  end if;

  select coalesce(max(assessment.assessment_version), 0) + 1
  into next_version
  from public.application_screening_assessments assessment
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
      last_error_code = 'screening_worker_paused',
      failure_reason = 'Resume screening is waiting for the deterministic screening worker.',
      updated_at = now()
  where status in ('pending', 'retry_wait');
  get diagnostics changed_rows = row_count;
  return changed_rows;
end;
$$;

create or replace function public.replace_job_screening_requirements(
  target_job_id uuid,
  target_requirements jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_workspace_id uuid;
  saved_count integer;
begin
  if auth.uid() is null then
    raise exception 'Authentication is required.';
  end if;
  if jsonb_typeof(target_requirements) is distinct from 'array'
     or jsonb_array_length(target_requirements) > 50 then
    raise exception 'Screening requirements must be an array of at most 50 items.';
  end if;

  select job.workspace_id
  into target_workspace_id
  from public.jobs job
  where job.id = target_job_id;
  if not found then
    raise exception 'The job was not found.';
  end if;
  if not public.has_workspace_role(
    target_workspace_id,
    array['owner', 'admin', 'recruiter']
  ) then
    raise exception 'Recruiter access to this job is required.';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(target_requirements) requirement
    where jsonb_typeof(requirement) is distinct from 'object'
       or jsonb_typeof(requirement -> 'requirement_key') is distinct from 'string'
       or jsonb_typeof(requirement -> 'name') is distinct from 'string'
       or jsonb_typeof(requirement -> 'description') is distinct from 'string'
       or jsonb_typeof(requirement -> 'priority') is distinct from 'string'
       or jsonb_typeof(requirement -> 'category') is distinct from 'string'
       or jsonb_typeof(requirement -> 'weight') is distinct from 'number'
  ) then
    raise exception 'A screening requirement has invalid fields.';
  end if;

  delete from public.job_screening_requirements requirement
  where requirement.workspace_id = target_workspace_id
    and requirement.job_id = target_job_id;

  insert into public.job_screening_requirements (
    workspace_id,
    job_id,
    requirement_key,
    name,
    description,
    priority,
    category,
    weight,
    created_by
  )
  select
    target_workspace_id,
    target_job_id,
    requirement.requirement_key,
    requirement.name,
    requirement.description,
    requirement.priority,
    requirement.category,
    requirement.weight,
    auth.uid()
  from jsonb_to_recordset(target_requirements) as requirement(
    requirement_key text,
    name text,
    description text,
    priority text,
    category text,
    weight numeric
  );
  get diagnostics saved_count = row_count;

  perform public.enqueue_application_screening(application.id, false)
  from public.applications application
  where application.workspace_id = target_workspace_id
    and application.job_id = target_job_id
    and application.resume_path is not null;

  return saved_count;
end;
$$;

revoke all on function public.replace_job_screening_requirements(uuid, jsonb)
  from public, anon;
grant execute on function public.replace_job_screening_requirements(uuid, jsonb)
  to authenticated;

commit;
