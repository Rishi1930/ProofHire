-- Keep public submissions compatible with the current application statuses
-- and avoid changing candidate details when an application is a duplicate.

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
  candidate_created boolean := false;
  duplicate_application boolean := false;
  resume_object_exists boolean := false;
begin
  normalized_name := trim(coalesce(p_full_name, ''));
  normalized_email := lower(
    regexp_replace(
      coalesce(p_email, ''),
      '^[[:space:]]+|[[:space:]]+$',
      '',
      'g'
    )
  );

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

  if p_resume_path !~ (
    '^' || job_record.workspace_id::text || '/'
    || job_record.id::text || '/[A-Za-z0-9_-]+\.(pdf|doc|docx)$'
  ) then
    raise exception 'The resume storage path is invalid.';
  end if;

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

  -- Serialize public submissions for the same normalized workspace email.
  -- Existing unique constraints remain the final protection against races.
  perform pg_advisory_xact_lock(
    hashtextextended(
      job_record.workspace_id::text || ':' || normalized_email,
      0::bigint
    )
  );

  -- Legacy rows may have mixed-case or surrounding whitespace in email.
  -- Detect duplicates across all such rows before selecting or changing one.
  if exists (
    select 1
    from public.applications a
    join public.candidates c
      on c.workspace_id = a.workspace_id
     and c.id = a.candidate_id
    where a.workspace_id = job_record.workspace_id
      and a.job_id = job_record.id
      and lower(
        regexp_replace(
          c.email,
          '^[[:space:]]+|[[:space:]]+$',
          '',
          'g'
        )
      ) = normalized_email
  ) then
    return jsonb_build_object(
      'success', true,
      'duplicate', true
    );
  end if;

  select c.*
  into candidate_record
  from public.candidates c
  where c.workspace_id = job_record.workspace_id
    and lower(
      regexp_replace(
        c.email,
        '^[[:space:]]+|[[:space:]]+$',
        '',
        'g'
      )
    ) = normalized_email
  order by c.created_at, c.id
  limit 1
  for update;

  candidate_created := false;

  if not found then
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
    on conflict (workspace_id, email) do nothing
    returning * into candidate_record;

    candidate_created := found;

    if not candidate_created then
      select c.*
      into candidate_record
      from public.candidates c
      where c.workspace_id = job_record.workspace_id
        and lower(
          regexp_replace(
            c.email,
            '^[[:space:]]+|[[:space:]]+$',
            '',
            'g'
          )
        ) = normalized_email
      order by c.created_at, c.id
      limit 1
      for update;

      if not found then
        raise exception 'Unable to resolve the candidate record for this submission.';
      end if;
    end if;
  end if;

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
    'new',
    'public',
    nullif(trim(coalesce(p_cover_letter, '')), ''),
    p_resume_path,
    null
  )
  on conflict (job_id, candidate_id) do nothing
  returning id into new_application_id;

  if new_application_id is null then
    duplicate_application := true;

    return jsonb_build_object(
      'success', true,
      'duplicate', duplicate_application
    );
  end if;

  if not candidate_created then
    update public.candidates
    set
      full_name = normalized_name,
      phone = coalesce(
        nullif(trim(coalesce(p_phone, '')), ''),
        public.candidates.phone
      ),
      resume_path = p_resume_path,
      updated_at = now()
    where id = candidate_record.id
      and workspace_id = job_record.workspace_id;
  end if;

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
