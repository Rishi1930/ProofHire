begin;

drop view if exists public.application_recruitment_stage_summary cascade;

drop table if exists public.application_assessment_reviews cascade;
drop table if exists public.application_workflow_failures cascade;

do $$
declare
  object_record record;
begin
  for object_record in
    select namespace.nspname, relation.relname
    from pg_class relation
    join pg_namespace namespace on namespace.oid = relation.relnamespace
    where namespace.nspname in ('public', 'proofhire_private')
      and relation.relkind in ('r', 'p')
      and relation.relname ilike '%aptitude%'
  loop
    execute format(
      'drop table if exists %I.%I cascade',
      object_record.nspname,
      object_record.relname
    );
  end loop;

  for object_record in
    select
      namespace.nspname,
      routine_proc.proname,
      pg_get_function_identity_arguments(routine_proc.oid) as arguments
    from pg_proc routine_proc
    join pg_namespace namespace on namespace.oid = routine_proc.pronamespace
    where namespace.nspname in ('public', 'proofhire_private')
      and routine_proc.prokind = 'f'
      and (
        routine_proc.proname ilike '%aptitude%'
        or routine_proc.prosrc ilike '%aptitude%'
      )
  loop
    execute format(
      'drop function if exists %I.%I(%s) cascade',
      object_record.nspname,
      object_record.proname,
      object_record.arguments
    );
  end loop;
end;
$$;

drop trigger if exists email_delivery_jobs_update_invitation_status
  on public.email_delivery_jobs;
drop trigger if exists application_screening_assessments_enqueue_followup
  on public.application_screening_assessments;

delete from public.email_delivery_jobs
where email_type = 'aptitude_invitation';

alter table public.email_delivery_jobs
  drop constraint if exists email_delivery_jobs_aptitude_invitation_fk,
  drop constraint if exists email_delivery_jobs_email_type_check,
  drop constraint if exists email_delivery_jobs_target_check,
  drop column if exists aptitude_invitation_id;

alter table public.email_delivery_jobs
  add constraint email_delivery_jobs_email_type_check
    check (email_type in (
      'application_update',
      'coding_invitation',
      'interview_invitation',
      'interview_update',
      'rejection',
      'offer',
      'screening_result'
    )),
  add constraint email_delivery_jobs_target_check check (
    (
      email_type = 'coding_invitation'
      and coding_invitation_id is not null
      and interview_record_id is null
      and screening_assessment_id is null
    )
    or (
      email_type in ('interview_invitation', 'interview_update')
      and coding_invitation_id is null
      and interview_record_id is not null
      and screening_assessment_id is null
    )
    or (
      email_type in ('application_update', 'rejection', 'offer')
      and coding_invitation_id is null
      and interview_record_id is null
      and screening_assessment_id is null
    )
    or (
      email_type = 'screening_result'
      and coding_invitation_id is null
      and interview_record_id is null
      and screening_assessment_id is not null
    )
  );

create or replace function public.enqueue_screening_result_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row public.applications%rowtype;
  candidate_row public.candidates%rowtype;
begin
  if new.report ->> 'threshold_met' is null
     or new.report ->> 'threshold_met' not in ('true', 'false') then
    return new;
  end if;

  select application.*
  into application_row
  from public.applications application
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if not found then
    return new;
  end if;

  select candidate.*
  into candidate_row
  from public.candidates candidate
  where candidate.workspace_id = application_row.workspace_id
    and candidate.id = application_row.candidate_id;
  if candidate_row.email is null or btrim(candidate_row.email) = '' then
    return new;
  end if;

  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    screening_assessment_id,
    email_type,
    template_key,
    recipient_email,
    idempotency_key,
    status,
    attempts,
    max_attempts
  )
  values (
    new.workspace_id,
    new.application_id,
    new.id,
    'screening_result',
    'screening-result-v1',
    candidate_row.email,
    'screening-result:' || new.id::text,
    'queued',
    0,
    5
  )
  on conflict (idempotency_key) do nothing;

  return new;
end;
$$;

revoke all on function public.enqueue_screening_result_email()
  from public, anon, authenticated;

create trigger application_screening_assessments_enqueue_followup
after insert or update of match_score, report
on public.application_screening_assessments
for each row execute function public.enqueue_screening_result_email();

create or replace function public.get_email_delivery_context(
  target_job_id uuid,
  target_lease_token uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.email_delivery_jobs%rowtype;
  context_value jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;

  select delivery.*
  into delivery_row
  from public.email_delivery_jobs delivery
  where delivery.id = target_job_id
    and delivery.status = 'processing'
    and delivery.lease_token = target_lease_token
    and delivery.locked_until >= now();
  if not found then
    raise exception 'Email delivery lease is no longer valid.';
  end if;
  if delivery_row.email_type <> 'screening_result' then
    raise exception 'Email delivery type is not supported by this worker.';
  end if;

  select jsonb_build_object(
    'candidate_name', candidate.full_name,
    'job_title', job.title,
    'company_name', workspace.name,
    'passed', assessment.report ->> 'threshold_met' = 'true'
  )
  into context_value
  from public.application_screening_assessments assessment
  join public.applications application
    on application.workspace_id = assessment.workspace_id
   and application.id = assessment.application_id
  join public.candidates candidate
    on candidate.workspace_id = application.workspace_id
   and candidate.id = application.candidate_id
  join public.jobs job
    on job.workspace_id = application.workspace_id
   and job.id = application.job_id
  join public.workspaces workspace
    on workspace.id = application.workspace_id
  where assessment.id = delivery_row.screening_assessment_id;

  if context_value is null then
    raise exception 'Email delivery context is unavailable.';
  end if;
  return context_value;
end;
$$;

revoke all on function public.get_email_delivery_context(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.get_email_delivery_context(uuid, uuid)
  to service_role;

create or replace view public.application_recruitment_stage_summary
with (security_invoker = true)
as
select
  application.id as application_id,
  application.workspace_id,
  application.job_id,
  application.status as application_status,
  coalesce(application.applied_at, application.created_at) as applied_at,
  coalesce(screening.screening_status, 'not_queued') as screening_status,
  screening.match_score as screening_score,
  screening.assessed_at as screening_completed_at,
  coalesce(coding.coding_status, 'not_invited') as coding_status,
  coding.score as coding_score,
  coding.completed_at as coding_completed_at,
  coalesce(interview.interview_count, 0) as interview_count,
  interview.latest_interview_status,
  interview.latest_interview_outcome,
  interview.latest_interview_at,
  decision.decision as latest_recruiter_decision,
  decision.created_at as latest_decision_at
from public.applications application
left join lateral (
  select
    queue.status as screening_status,
    assessment.match_score,
    assessment.created_at as assessed_at
  from public.application_screening_jobs queue
  left join lateral (
    select current_assessment.match_score, current_assessment.created_at
    from public.application_screening_assessments current_assessment
    where current_assessment.workspace_id = queue.workspace_id
      and current_assessment.screening_job_id = queue.id
    order by current_assessment.assessment_version desc
    limit 1
  ) assessment on true
  where queue.workspace_id = application.workspace_id
    and queue.application_id = application.id
  order by queue.created_at desc
  limit 1
) screening on true
left join lateral (
  select
    coalesce(attempt.status, invitation.status) as coding_status,
    attempt.score,
    attempt.completed_at
  from public.coding_invitations invitation
  left join public.coding_attempts attempt
    on attempt.workspace_id = invitation.workspace_id
   and attempt.invitation_id = invitation.id
  where invitation.workspace_id = application.workspace_id
    and invitation.application_id = application.id
  order by attempt.completed_at desc nulls last, attempt.created_at desc
  limit 1
) coding on true
left join lateral (
  select
    count(*)::integer as interview_count,
    (array_agg(record.interview_status order by record.scheduled_at desc))[1]
      as latest_interview_status,
    (array_agg(record.outcome order by record.scheduled_at desc))[1]
      as latest_interview_outcome,
    max(record.scheduled_at) as latest_interview_at
  from public.interview_records record
  where record.workspace_id = application.workspace_id
    and record.application_id = application.id
) interview on true
left join lateral (
  select event.decision, event.created_at
  from public.application_decision_events event
  where event.workspace_id = application.workspace_id
    and event.application_id = application.id
  order by event.created_at desc, event.id desc
  limit 1
) decision on true;

revoke all on public.application_recruitment_stage_summary from public, anon;
grant select on public.application_recruitment_stage_summary to authenticated;

update public.application_screening_jobs
set status = 'pending',
    available_at = now(),
    lease_token = null,
    locked_by = null,
    locked_until = null,
    last_error_code = null,
    failure_reason = null,
    updated_at = now()
where status = 'waiting_configuration'
  and last_error_code = 'gemini_not_configured';

commit;
