
-- ProofHire: Initial database schema
-- Apply this migration to a fresh Supabase project.

begin;

create extension if not exists pgcrypto;

-- =========================================================
-- 1. WORKSPACES
-- =========================================================

create table if not exists public.workspaces (
  id uuid primary key default gen_random_uuid(),
  name text not null
    check (char_length(trim(name)) between 1 and 120),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.workspace_members (
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  user_id uuid not null
    references auth.users(id) on delete cascade,
  role text not null default 'owner'
    check (role in ('owner', 'admin', 'recruiter', 'viewer')),
  created_at timestamptz not null default now(),
  primary key (workspace_id, user_id)
);

create index if not exists idx_workspace_members_user
  on public.workspace_members(user_id);

-- =========================================================
-- 2. JOBS
-- =========================================================

create table if not exists public.jobs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  title text not null
    check (char_length(trim(title)) between 1 and 180),
  department text,
  location text,
  employment_type text not null default 'full-time'
    check (
      employment_type in (
        'full-time',
        'part-time',
        'contract',
        'internship',
        'temporary'
      )
    ),
  workplace_type text not null default 'onsite'
    check (workplace_type in ('onsite', 'remote', 'hybrid')),
  description text,
  status text not null default 'draft'
    check (status in ('draft', 'open', 'paused', 'closed')),
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists idx_jobs_workspace_created
  on public.jobs(workspace_id, created_at desc);

create index if not exists idx_jobs_workspace_status
  on public.jobs(workspace_id, status);

-- =========================================================
-- 3. CANDIDATES
-- =========================================================

create table if not exists public.candidates (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  full_name text not null
    check (char_length(trim(full_name)) between 1 and 180),
  email text not null
    check (char_length(trim(email)) between 3 and 320),
  phone text,
  resume_path text,
  created_by uuid not null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workspace_id, email),
  unique (workspace_id, id)
);

create index if not exists idx_candidates_workspace_created
  on public.candidates(workspace_id, created_at desc);

create index if not exists idx_candidates_workspace_name
  on public.candidates(workspace_id, full_name);

-- =========================================================
-- 4. APPLICATIONS
-- =========================================================

create table if not exists public.applications (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  job_id uuid not null,
  candidate_id uuid not null,
  status text not null default 'applied'
    check (
      status in (
        'applied',
        'screening',
        'shortlisted',
        'interview',
        'selected',
        'rejected'
      )
    ),
  source text not null default 'manual'
    check (source in ('manual', 'public', 'import')),
  cover_letter text,
  resume_path text,
  applied_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint applications_candidate_same_workspace
    foreign key (workspace_id, candidate_id)
    references public.candidates(workspace_id, id)
    on delete cascade,

  constraint applications_job_same_workspace
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,

  constraint applications_unique_candidate_job
    unique (job_id, candidate_id),

  unique (workspace_id, id)
);

create index if not exists idx_applications_workspace_created
  on public.applications(workspace_id, created_at desc);

create index if not exists idx_applications_workspace_status
  on public.applications(workspace_id, status);

create index if not exists idx_applications_job
  on public.applications(job_id);

create index if not exists idx_applications_candidate
  on public.applications(candidate_id);

-- Required composite key for application-to-job workspace integrity.
create unique index if not exists idx_jobs_id_workspace_unique
  on public.jobs(id, workspace_id);

-- =========================================================
-- 5. UPDATED-AT TRIGGER
-- =========================================================

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists workspaces_set_updated_at
  on public.workspaces;

create trigger workspaces_set_updated_at
before update on public.workspaces
for each row execute function public.set_updated_at();

drop trigger if exists jobs_set_updated_at
  on public.jobs;

create trigger jobs_set_updated_at
before update on public.jobs
for each row execute function public.set_updated_at();

drop trigger if exists candidates_set_updated_at
  on public.candidates;

create trigger candidates_set_updated_at
before update on public.candidates
for each row execute function public.set_updated_at();

drop trigger if exists applications_set_updated_at
  on public.applications;

create trigger applications_set_updated_at
before update on public.applications
for each row execute function public.set_updated_at();

-- =========================================================
-- 6. CREATE A WORKSPACE FOR NEW USERS
-- =========================================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_workspace_id uuid;
  workspace_name text;
begin
  workspace_name := coalesce(
    nullif(trim(new.raw_user_meta_data ->> 'workspace_name'), ''),
    nullif(trim(new.raw_user_meta_data ->> 'full_name'), ''),
    'My Workspace'
  );

  insert into public.workspaces (name, created_by)
  values (workspace_name, new.id)
  returning id into new_workspace_id;

  insert into public.workspace_members (
    workspace_id,
    user_id,
    role
  )
  values (
    new_workspace_id,
    new.id,
    'owner'
  );

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

commit;
