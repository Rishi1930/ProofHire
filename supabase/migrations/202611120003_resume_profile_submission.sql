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
