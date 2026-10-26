-- Align the candidate and application schema with the recruiter workflow.

begin;

alter table public.candidates
  add column if not exists linkedin_url text,
  alter column email drop not null;

do $$
declare
  status_constraint record;
begin
  for status_constraint in
    select constraint_row.conname
    from pg_constraint as constraint_row
    where constraint_row.conrelid = 'public.applications'::regclass
      and constraint_row.contype = 'c'
      and pg_get_constraintdef(constraint_row.oid) ilike '%status%'
  loop
    execute format(
      'alter table public.applications drop constraint %I',
      status_constraint.conname
    );
  end loop;
end;
$$;

update public.applications
set status = case status
  when 'applied' then 'new'
  when 'selected' then 'hired'
  else status
end;

alter table public.applications
  add constraint applications_status_check
  check (status in ('new', 'screening', 'shortlisted', 'rejected', 'interview', 'hired'));

commit;
