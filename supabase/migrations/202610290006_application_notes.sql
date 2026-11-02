-- Add append-only recruiter notes scoped to an application and workspace.

begin;

create table if not exists public.application_notes (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  note text not null
    check (char_length(trim(note)) between 1 and 10000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint application_notes_application_workspace_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade
);

create index if not exists idx_application_notes_application_created
  on public.application_notes(workspace_id, application_id, created_at desc);

alter table public.application_notes enable row level security;

create policy "Workspace members can read application notes"
on public.application_notes
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create application notes"
on public.application_notes
for insert to authenticated
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and created_by = (select auth.uid())
  and exists (
    select 1
    from public.applications application
    where application.workspace_id = application_notes.workspace_id
      and application.id = application_notes.application_id
  )
);

revoke all on public.application_notes from anon, authenticated;
grant select, insert on public.application_notes to authenticated;
grant all on public.application_notes to service_role;

commit;
