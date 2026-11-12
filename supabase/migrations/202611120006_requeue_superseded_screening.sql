-- Let a screening job be requeued after it was superseded or cancelled.
--
-- The enqueue function only revived 'failed' and 'waiting_configuration' jobs,
-- so once the worker retired a job as 'superseded' the same application could
-- never be screened again: the insert conflicts with the retired row and the
-- retry branch ignores its status. Retrying now covers every terminal state.
--
-- Safe to run more than once.

begin;

create or replace function public.enqueue_application_screening(
  target_application_id uuid,
  allow_failed_retry boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row record;
  fingerprint text;
  screening_job_id uuid;
begin
  select application.id, application.workspace_id, application.resume_path
  into application_row
  from public.applications application
  where application.id = target_application_id;

  if not found or application_row.resume_path is null then
    return null;
  end if;

  fingerprint := public.application_screening_input_fingerprint(
    target_application_id
  );
  if fingerprint is null then
    return null;
  end if;

  insert into public.application_screening_jobs (
    workspace_id,
    application_id,
    input_fingerprint
  )
  values (
    application_row.workspace_id,
    application_row.id,
    fingerprint
  )
  on conflict (application_id, input_fingerprint) do nothing
  returning id into screening_job_id;

  if screening_job_id is null and allow_failed_retry then
    update public.application_screening_jobs screening_job
    set status = 'pending',
        attempts = 0,
        available_at = now(),
        lease_token = null,
        locked_by = null,
        locked_until = null,
        last_error_code = null,
        failure_reason = null,
        completed_at = null,
        updated_at = now()
    where screening_job.application_id = application_row.id
      and screening_job.input_fingerprint = fingerprint
      and screening_job.status in (
        'failed',
        'waiting_configuration',
        'superseded',
        'cancelled'
      )
    returning id into screening_job_id;
  end if;

  if screening_job_id is null then
    select screening_job.id
    into screening_job_id
    from public.application_screening_jobs screening_job
    where screening_job.application_id = application_row.id
      and screening_job.input_fingerprint = fingerprint;
  end if;

  return screening_job_id;
end;
$$;

revoke all on function public.enqueue_application_screening(uuid, boolean)
  from public, anon, authenticated;

commit;
