-- Keep an application-scoped history of resume objects while retaining the
-- existing applications.resume_path field for compatibility.

begin;

create table if not exists public.application_resume_versions (
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

create index if not exists idx_application_resume_versions_application_created
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

create index if not exists idx_screening_jobs_resume_version
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

commit;
