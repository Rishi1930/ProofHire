-- Add append-only stage history and structured, workspace-scoped interview
-- scheduling/feedback without replacing existing application or interview data.

begin;

create table if not exists public.application_stage_history (
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

create index if not exists idx_application_stage_history_application_created
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

create table if not exists public.interview_schedule_events (
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

create index if not exists idx_interview_schedule_events_interview_created
  on public.interview_schedule_events(workspace_id, interview_id, created_at desc);

create table if not exists public.interview_assignments (
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

create unique index if not exists idx_interview_assignments_user_unique
  on public.interview_assignments(interview_id, user_id)
  where user_id is not null;

create unique index if not exists idx_interview_assignments_email_unique
  on public.interview_assignments(interview_id, lower(btrim(email)))
  where user_id is null and email is not null;

create table if not exists public.interview_feedback (
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
  constraint interview_feedback_interview_fk
    foreign key (workspace_id, interview_id)
    references public.interview_records(workspace_id, id)
    on delete cascade,
  constraint interview_feedback_assignment_fk
    foreign key (workspace_id, interview_id, assignment_id)
    references public.interview_assignments(workspace_id, interview_id, id)
    on delete set null (assignment_id)
);

create index if not exists idx_interview_feedback_interview_submitted
  on public.interview_feedback(workspace_id, interview_id, submitted_at desc);

create table if not exists public.interview_feedback_criteria (
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

create index if not exists idx_interview_feedback_criteria_feedback
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
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Recruiters can manage interview assignments"
on public.interview_assignments
for all to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']))
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
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
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Recruiters can add interview feedback"
on public.interview_feedback
for insert to authenticated
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and submitted_by = (select auth.uid())
);

create policy "Recruiters can read interview feedback criteria"
on public.interview_feedback_criteria
for select to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Recruiters can add interview feedback criteria"
on public.interview_feedback_criteria
for insert to authenticated
with check (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

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

commit;
