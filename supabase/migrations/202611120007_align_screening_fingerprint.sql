-- Use one screening fingerprint everywhere.
--
-- claim_application_screening_job still hashed only seven job fields inline
-- (resume path, title, department, description, skills, experience), while
-- enqueue_application_screening and complete_application_screening_job use
-- application_screening_input_fingerprint(), which also covers the screening
-- threshold, the weights and the configured requirements. Every queued job was
-- therefore considered stale the moment it was claimed and was retired as
-- 'superseded' without ever being scored.
--
-- The claim function now calls the same helper as everything else.
--
-- Safe to run more than once.

begin;

create or replace function public.claim_application_screening_job(
  worker_id text,
  lease_seconds integer default 120
)
returns setof public.application_screening_jobs
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.role() <> 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if worker_id is null or char_length(trim(worker_id)) not between 1 and 120 then
    raise exception 'Worker identifier is invalid.';
  end if;
  lease_seconds := greatest(30, least(coalesce(lease_seconds, 600), 600));

  update public.application_screening_jobs as screening_job
  set status = 'failed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'lease_expired',
      failure_reason = 'Processing lease expired after the retry limit.',
      updated_at = now()
  where screening_job.status = 'processing'
    and screening_job.locked_until < now()
    and screening_job.attempts >= screening_job.max_attempts;

  update public.application_screening_jobs as screening_job
  set status = 'superseded',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'inputs_changed',
      failure_reason = 'Job or resume changed; a newer screening job is queued.',
      updated_at = now()
  where (
      screening_job.status in ('pending', 'retry_wait')
      or (
        screening_job.status = 'processing'
        and screening_job.locked_until < now()
      )
    )
    and screening_job.input_fingerprint is distinct from
      public.application_screening_input_fingerprint(screening_job.application_id);

  return query
  with next_job as (
    select screening_job.id
    from public.application_screening_jobs as screening_job
    where screening_job.attempts < screening_job.max_attempts
      and (
        (
          screening_job.status in ('pending', 'retry_wait')
          and screening_job.available_at <= now()
          and screening_job.input_fingerprint =
            public.application_screening_input_fingerprint(screening_job.application_id)
        )
        or (
          screening_job.status = 'processing'
          and screening_job.locked_until < now()
        )
      )
    order by screening_job.available_at, screening_job.created_at
    for update skip locked
    limit 1
  )
  update public.application_screening_jobs as screening_job
  set status = 'processing',
      attempts = screening_job.attempts + 1,
      lease_token = gen_random_uuid(),
      locked_by = worker_id,
      locked_until = now() + make_interval(secs => lease_seconds),
      updated_at = now()
  from next_job
  where screening_job.id = next_job.id
  returning screening_job.*;
end;
$$;

revoke all on function public.claim_application_screening_job(text, integer)
  from public, anon, authenticated;
grant execute on function public.claim_application_screening_job(text, integer)
  to service_role;

commit;
