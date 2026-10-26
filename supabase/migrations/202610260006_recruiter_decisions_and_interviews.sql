-- Store recruiter decisions and interview operations separately from the
-- application's current recruitment stage. Apply after migration 005.

begin;

create table if not exists public.application_decision_events (
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

create index if not exists idx_application_decision_events_workspace_created
  on public.application_decision_events(workspace_id, created_at desc);

create index if not exists idx_application_decision_events_application_created
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
    array['owner', 'admin', 'recruiter']::text[]
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

create table if not exists public.interview_records (
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

create index if not exists idx_interview_records_workspace_scheduled
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
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
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
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
)
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
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

commit;
