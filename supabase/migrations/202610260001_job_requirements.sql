-- Add structured requirements to existing jobs without changing workspace RLS.

begin;

alter table public.jobs
  add column if not exists required_skills text[] not null default '{}'::text[],
  add column if not exists preferred_skills text[] not null default '{}'::text[],
  add column if not exists minimum_experience numeric;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'jobs_minimum_experience_nonnegative'
      and conrelid = 'public.jobs'::regclass
  ) then
    alter table public.jobs
      add constraint jobs_minimum_experience_nonnegative
      check (minimum_experience is null or minimum_experience >= 0);
  end if;
end;
$$;

commit;
