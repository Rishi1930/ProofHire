
-- ProofHire: Secure public application submission
-- Apply after migrations 001 and 002.

begin;

create or replace function public.submit_public_application(
  p_job_id uuid,
  p_full_name text,
  p_email text,
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
  job_record record;
  candidate_record public.candidates%rowtype;
  new_application_id uuid;
  normalized_email text;
  normalized_name text;
  duplicate_application boolean := false;
  resume_object_exists boolean := false;
begin
  -- Validate the supplied information.
  normalized_name := trim(coalesce(p_full_name, ''));
  normalized_email := lower(trim(coalesce(p_email, '')));

  if char_length(normalized_name) < 2
     or char_length(normalized_name) > 180 then
    raise exception 'Enter a valid full name.';
  end if;

  if char_length(normalized_email) < 3
     or char_length(normalized_email) > 320
     or normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Enter a valid email address.';
  end if;

  if p_phone is not null and char_length(trim(p_phone)) > 40 then
    raise exception 'The phone number is too long.';
  end if;

  if p_cover_letter is not null
     and char_length(p_cover_letter) > 10000 then
    raise exception 'The cover letter exceeds the allowed length.';
  end if;

  if p_resume_path is null or trim(p_resume_path) = '' then
    raise exception 'A resume is required.';
  end if;

  -- Lock the job row while checking that applications are accepted.
  select
    j.id,
    j.workspace_id,
    j.created_by,
    j.status
  into job_record
  from public.jobs j
  where j.id = p_job_id
  for share;

  if not found or job_record.status <> 'open' then
    raise exception 'This job is unavailable or no longer accepting applications.';
  end if;

  -- Require the resume to be stored under this exact workspace/job.
  if p_resume_path !~ (
    '^' || job_record.workspace_id::text || '/'
    || job_record.id::text || '/[A-Za-z0-9_-]+\.(pdf|doc|docx)$'
  ) then
    raise exception 'The resume storage path is invalid.';
  end if;

  -- Confirm the private storage object exists.
  select exists (
    select 1
    from storage.objects o
    where o.bucket_id = 'candidate-resumes'
      and o.name = p_resume_path
  )
  into resume_object_exists;

  if not resume_object_exists then
    raise exception 'Upload your resume before submitting the application.';
  end if;

  -- Create the candidate or reuse the existing workspace candidate.
  insert into public.candidates (
    workspace_id,
    full_name,
    email,
    phone,
    resume_path,
    created_by
  )
  values (
    job_record.workspace_id,
    normalized_name,
    normalized_email,
    nullif(trim(coalesce(p_phone, '')), ''),
    p_resume_path,
    job_record.created_by
  )
  on conflict (workspace_id, email)
  do update set
    full_name = excluded.full_name,
    phone = coalesce(excluded.phone, public.candidates.phone),
    resume_path = coalesce(
      excluded.resume_path,
      public.candidates.resume_path
    ),
    updated_at = now()
  returning * into candidate_record;

  -- Prevent multiple applications to the same job by the same candidate.
  insert into public.applications (
    workspace_id,
    job_id,
    candidate_id,
    status,
    source,
    cover_letter,
    resume_path,
    created_by
  )
  values (
    job_record.workspace_id,
    job_record.id,
    candidate_record.id,
    'applied',
    'public',
    nullif(trim(coalesce(p_cover_letter, '')), ''),
    p_resume_path,
    null
  )
  on conflict (job_id, candidate_id) do nothing
  returning id into new_application_id;

  if new_application_id is null then
    duplicate_application := true;

    select a.id
    into new_application_id
    from public.applications a
    where a.job_id = job_record.id
      and a.candidate_id = candidate_record.id;
  end if;

  -- Return only submission status; do not expose candidate records.
  return jsonb_build_object(
    'success', true,
    'duplicate', duplicate_application
  );
end;
$$;

revoke all on function public.submit_public_application(
  uuid, text, text, text, text, text
) from public;

grant execute on function public.submit_public_application(
  uuid, text, text, text, text, text
) to anon, authenticated;

commit;
