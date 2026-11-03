begin;

alter table public.aptitude_attempts
  add column if not exists current_question_index integer not null default 0
    check (current_question_index >= 0),
  add column if not exists current_question_updated_at timestamptz not null default now();

create table if not exists proofhire_private.aptitude_invitation_tokens (
  invitation_id uuid primary key
    references public.aptitude_invitations(id) on delete cascade,
  token text not null check (char_length(token) = 43),
  created_at timestamptz not null default now()
);

alter table proofhire_private.aptitude_invitation_tokens enable row level security;
revoke all on proofhire_private.aptitude_invitation_tokens
  from public, anon, authenticated;
grant all on proofhire_private.aptitude_invitation_tokens to service_role;

alter table public.email_delivery_jobs
  add column if not exists screening_assessment_id uuid
    references public.application_screening_assessments(id) on delete cascade;

alter table public.email_delivery_jobs
  drop constraint if exists email_delivery_jobs_email_type_check,
  add constraint email_delivery_jobs_email_type_check
    check (email_type in (
      'application_update',
      'aptitude_invitation',
      'coding_invitation',
      'interview_invitation',
      'interview_update',
      'rejection',
      'offer',
      'screening_result'
    ));

alter table public.email_delivery_jobs
  drop constraint if exists email_delivery_jobs_target_check;
alter table public.email_delivery_jobs
  add constraint email_delivery_jobs_target_check check (
    (
      email_type = 'aptitude_invitation'
      and aptitude_invitation_id is not null
      and coding_invitation_id is null
      and interview_record_id is null
      and screening_assessment_id is null
    )
    or (
      email_type = 'coding_invitation'
      and aptitude_invitation_id is null
      and coding_invitation_id is not null
      and interview_record_id is null
      and screening_assessment_id is null
    )
    or (
      email_type in ('interview_invitation', 'interview_update')
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is not null
      and screening_assessment_id is null
    )
    or (
      email_type in ('application_update', 'rejection', 'offer')
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is null
      and screening_assessment_id is null
    )
    or (
      email_type = 'screening_result'
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is null
      and screening_assessment_id is not null
    )
  );

create table if not exists public.application_assessment_reviews (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  attempt_id uuid not null,
  review_status text not null default 'pending'
    check (review_status in ('pending', 'cleared', 'overridden')),
  reason text not null default 'aptitude_threshold_not_met',
  resolved_by uuid references auth.users(id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint application_assessment_reviews_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id) on delete cascade,
  constraint application_assessment_reviews_attempt_fk
    foreign key (workspace_id, attempt_id)
    references public.aptitude_attempts(workspace_id, id) on delete cascade,
  constraint application_assessment_reviews_attempt_unique unique (attempt_id)
);

create table if not exists public.aptitude_reinvitation_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  invitation_id uuid not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  previous_attempt_limit integer not null,
  new_attempt_limit integer not null,
  created_at timestamptz not null default now(),
  constraint aptitude_reinvitation_events_invitation_fk
    foreign key (workspace_id, invitation_id)
    references public.aptitude_invitations(workspace_id, id) on delete cascade
);

create table if not exists public.application_workflow_failures (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  screening_assessment_id uuid not null unique
    references public.application_screening_assessments(id) on delete cascade,
  failure_code text not null,
  created_at timestamptz not null default now(),
  constraint application_workflow_failures_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id) on delete cascade
);

alter table public.application_assessment_reviews enable row level security;
alter table public.aptitude_reinvitation_events enable row level security;
alter table public.application_workflow_failures enable row level security;
revoke all on public.application_assessment_reviews from public, anon, authenticated;
grant select on public.application_assessment_reviews to authenticated;
grant all on public.application_assessment_reviews to service_role;
revoke all on public.aptitude_reinvitation_events from public, anon, authenticated;
grant select on public.aptitude_reinvitation_events to authenticated;
grant all on public.aptitude_reinvitation_events to service_role;
revoke all on public.application_workflow_failures from public, anon, authenticated;
grant select on public.application_workflow_failures to authenticated;
grant all on public.application_workflow_failures to service_role;
drop policy if exists application_assessment_reviews_recruiter_read
  on public.application_assessment_reviews;
create policy application_assessment_reviews_recruiter_read
  on public.application_assessment_reviews
  for select to authenticated
  using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));
drop policy if exists aptitude_reinvitation_events_recruiter_read
  on public.aptitude_reinvitation_events;
create policy aptitude_reinvitation_events_recruiter_read
  on public.aptitude_reinvitation_events
  for select to authenticated
  using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));
drop policy if exists application_workflow_failures_recruiter_read
  on public.application_workflow_failures;
create policy application_workflow_failures_recruiter_read
  on public.application_workflow_failures
  for select to authenticated
  using (public.has_workspace_role(workspace_id, array['admin', 'recruiter']));

create or replace function public.resolve_application_assessment_review(
  target_workspace_id uuid,
  target_review_id uuid,
  target_resolution text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  review_row public.application_assessment_reviews%rowtype;
begin
  if auth.role() is distinct from 'authenticated'
     or target_resolution is null
     or target_resolution not in ('cleared', 'overridden')
     or not public.has_workspace_role(
       target_workspace_id,
       array['admin', 'recruiter']
     ) then
    raise exception 'Assessment review action is not authorized.';
  end if;
  select review.*
  into review_row
  from public.application_assessment_reviews review
  where review.workspace_id = target_workspace_id
    and review.id = target_review_id
    and review.review_status = 'pending'
  for update;
  if not found then
    raise exception 'Assessment review is no longer pending.';
  end if;
  if target_resolution = 'overridden'
     and exists (
       select 1
       from public.applications application
       where application.workspace_id = review_row.workspace_id
         and application.id = review_row.application_id
         and application.status in ('rejected', 'hired')
     ) then
    raise exception 'A rejected or hired application cannot be overridden.';
  end if;
  update public.application_assessment_reviews
  set review_status = target_resolution,
      resolved_by = auth.uid(),
      resolved_at = now(),
      updated_at = now()
  where id = review_row.id;
  if target_resolution = 'overridden' then
    update public.applications
    set status = 'interview',
        updated_at = now()
    where workspace_id = review_row.workspace_id
      and id = review_row.application_id
      and status not in ('rejected', 'hired', 'interview');
  end if;
  return review_row.id;
end;
$$;

revoke all on function public.resolve_application_assessment_review(uuid, uuid, text)
  from public, anon;
grant execute on function public.resolve_application_assessment_review(uuid, uuid, text)
  to authenticated;

create or replace function public.grant_aptitude_reinvitation(
  target_workspace_id uuid,
  target_invitation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  version_row public.aptitude_test_versions%rowtype;
  delivery_row public.email_delivery_jobs%rowtype;
  updated_limit integer;
begin
  if auth.role() is distinct from 'authenticated'
     or not public.has_workspace_role(
       target_workspace_id,
       array['admin', 'recruiter']
     ) then
    raise exception 'Aptitude reinvitation is not authorized.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.workspace_id = target_workspace_id
    and invitation.id = target_invitation_id
  for update;
  if not found then
    raise exception 'Aptitude invitation was not found.';
  end if;
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = invitation_row.workspace_id
    and version.id = invitation_row.test_version_id;
  if not found or invitation_row.max_attempts >= version_row.max_attempts then
    raise exception 'The published attempt policy does not allow another attempt.';
  end if;
  if not exists (
    select 1
    from proofhire_private.aptitude_invitation_tokens token_row
    where token_row.invitation_id = invitation_row.id
  ) then
    raise exception 'This invitation does not have a resendable link.';
  end if;

  updated_limit := invitation_row.max_attempts + 1;
  update public.aptitude_invitations
  set max_attempts = updated_limit,
      status = 'pending',
      expires_at = now() + interval '7 days',
      updated_at = now()
  where id = invitation_row.id;
  insert into public.aptitude_reinvitation_events (
    workspace_id,
    invitation_id,
    actor_id,
    previous_attempt_limit,
    new_attempt_limit
  )
  values (
    target_workspace_id,
    invitation_row.id,
    auth.uid(),
    invitation_row.max_attempts,
    updated_limit
  );

  select delivery.*
  into delivery_row
  from public.email_delivery_jobs delivery
  where delivery.workspace_id = target_workspace_id
    and delivery.aptitude_invitation_id = invitation_row.id
    and delivery.email_type = 'aptitude_invitation'
  order by delivery.created_at desc
  limit 1
  for update;
  if found and delivery_row.status in ('queued', 'retry_wait', 'failed', 'blocked_configuration') then
    update public.email_delivery_jobs
    set status = 'queued',
        max_attempts = greatest(max_attempts, attempts + 1),
        next_attempt_at = now(),
        lease_token = null,
        locked_by = null,
        locked_until = null,
        last_error_code = null,
        updated_at = now()
    where id = delivery_row.id;
  elsif found and delivery_row.status in ('sent', 'delivered') then
    insert into public.email_delivery_jobs (
      workspace_id,
      application_id,
      aptitude_invitation_id,
      email_type,
      template_key,
      recipient_email,
      idempotency_key,
      status,
      attempts,
      max_attempts
    )
    values (
      delivery_row.workspace_id,
      delivery_row.application_id,
      delivery_row.aptitude_invitation_id,
      delivery_row.email_type,
      delivery_row.template_key,
      delivery_row.recipient_email,
      left(delivery_row.idempotency_key, 120)
        || ':reinvite:' || gen_random_uuid()::text,
      'queued',
      0,
      5
    );
  end if;
  return jsonb_build_object(
    'invitation_id', invitation_row.id,
    'max_attempts', updated_limit,
    'expires_at', now() + interval '7 days'
  );
end;
$$;

revoke all on function public.grant_aptitude_reinvitation(uuid, uuid)
  from public, anon;
grant execute on function public.grant_aptitude_reinvitation(uuid, uuid)
  to authenticated;

do $migration$
begin
  if to_regprocedure('public.get_aptitude_candidate_session(text)') is not null
     and to_regprocedure(
       'public.get_aptitude_candidate_session_before_progress(text)'
     ) is null then
    execute 'alter function public.get_aptitude_candidate_session(text) '
      || 'rename to get_aptitude_candidate_session_before_progress';
  end if;
end;
$migration$;

create or replace function public.get_aptitude_candidate_session(
  target_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_payload jsonb;
  active_attempt_id_value uuid;
  current_index_value integer := 0;
  position_updated_at_value timestamptz;
  answer_timestamps_value jsonb := '{}'::jsonb;
  started_at_value timestamptz;
  server_now_value timestamptz := clock_timestamp();
  deadline_value timestamptz;
begin
  session_payload :=
    public.get_aptitude_candidate_session_before_progress(target_token_hash);
  active_attempt_id_value := nullif(
    session_payload ->> 'active_attempt_id',
    ''
  )::uuid;
  started_at_value := nullif(
    session_payload ->> 'active_attempt_started_at',
    ''
  )::timestamptz;

  if active_attempt_id_value is not null then
    select attempt.current_question_index, attempt.current_question_updated_at
    into current_index_value, position_updated_at_value
    from public.aptitude_attempts attempt
    where attempt.id = active_attempt_id_value;

    select coalesce(jsonb_object_agg(answer.question_id::text, answer.saved_at), '{}'::jsonb)
    into answer_timestamps_value
    from public.aptitude_answers answer
    where answer.attempt_id = active_attempt_id_value;

    if started_at_value is not null then
      deadline_value := started_at_value + make_interval(
        secs => (session_payload ->> 'time_limit_seconds')::integer
      );
    end if;
  end if;

  return session_payload || jsonb_build_object(
    'current_question_index', current_index_value,
    'current_question_updated_at', position_updated_at_value,
    'saved_answer_timestamps', answer_timestamps_value,
    'server_now', server_now_value,
    'deadline_at', deadline_value
  );
end;
$$;

revoke all on function public.get_aptitude_candidate_session(text)
  from public, anon, authenticated;
grant execute on function public.get_aptitude_candidate_session(text)
  to service_role;

create or replace function public.save_aptitude_candidate_progress(
  target_token_hash text,
  target_attempt_id uuid,
  target_question_id uuid,
  target_question_index integer,
  target_answer jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  attempt_row public.aptitude_attempts%rowtype;
  version_row public.aptitude_test_versions%rowtype;
  question_total integer;
  question_order integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to save candidate progress.';
  end if;
  if target_attempt_id is null or target_question_id is null
     or target_question_index is null then
    raise exception 'The current aptitude question is invalid.';
  end if;

  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('pending', 'sent', 'started');
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;

  select attempt.*
  into attempt_row
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.id = target_attempt_id
    and attempt.status = 'in_progress'
  for update;
  if not found then
    raise exception 'The aptitude attempt is unavailable.';
  end if;

  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = attempt_row.workspace_id
    and version.id = attempt_row.test_version_id;
  if not found or attempt_row.started_at
    + make_interval(secs => version_row.time_limit_seconds) <= now() then
    raise exception 'The aptitude attempt has expired.';
  end if;

  select count(*)::integer
  into question_total
  from public.aptitude_attempt_questions assignment
  where assignment.workspace_id = attempt_row.workspace_id
    and assignment.attempt_id = attempt_row.id;
  if target_question_index < 0 or target_question_index >= question_total then
    raise exception 'The current aptitude question is invalid.';
  end if;

  select assignment.display_order
  into question_order
  from public.aptitude_attempt_questions assignment
  where assignment.workspace_id = attempt_row.workspace_id
    and assignment.attempt_id = attempt_row.id
    and assignment.question_id = target_question_id;
  if not found or question_order <> target_question_index + 1 then
    raise exception 'The current aptitude question is invalid.';
  end if;

  if target_answer is not null and target_answer <> 'null'::jsonb then
    perform public.save_aptitude_candidate_answer(
      target_token_hash,
      target_attempt_id,
      target_question_id,
      target_answer
    );
  end if;

  update public.aptitude_attempts
  set current_question_index = target_question_index,
      current_question_updated_at = now(),
      updated_at = now()
  where id = target_attempt_id;
  return true;
end;
$$;

revoke all on function public.save_aptitude_candidate_progress(
  text, uuid, uuid, integer, jsonb
) from public, anon, authenticated;
grant execute on function public.save_aptitude_candidate_progress(
  text, uuid, uuid, integer, jsonb
) to service_role;

create or replace function public.enqueue_manual_aptitude_invitation_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    aptitude_invitation_id,
    email_type,
    template_key,
    recipient_email,
    idempotency_key,
    status,
    attempts,
    max_attempts,
    last_error_code
  )
  values (
    new.workspace_id,
    new.application_id,
    new.id,
    'aptitude_invitation',
    'aptitude-invitation-v1',
    new.candidate_email,
    'aptitude-invitation:' || new.id::text,
    'queued',
    0,
    5,
    null
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create or replace function public.create_automated_aptitude_invitation(
  target_user_id uuid,
  target_workspace_id uuid,
  target_application_id uuid,
  target_test_version_id uuid,
  target_token text,
  target_token_hash text,
  target_expires_at timestamptz,
  target_max_attempts integer
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_payload jsonb;
  invitation_id_value uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if target_token is null or char_length(target_token) <> 43
     or target_token !~ '^[A-Za-z0-9_-]+$'
     or target_token_hash is distinct from encode(
       extensions.digest(convert_to(target_token, 'UTF8'), 'sha256'),
       'hex'
     ) then
    raise exception 'Invitation token is invalid.';
  end if;

  invitation_payload := public.create_aptitude_invitation(
    target_user_id,
    target_workspace_id,
    target_application_id,
    target_test_version_id,
    target_token_hash,
    target_expires_at,
    target_max_attempts
  );
  invitation_id_value := (invitation_payload ->> 'id')::uuid;

  insert into proofhire_private.aptitude_invitation_tokens(invitation_id, token)
  values (invitation_id_value, target_token)
  on conflict (invitation_id) do update
    set token = excluded.token, created_at = now();

  update public.aptitude_invitations
  set email_status = 'queued',
      email_error_code = null
  where id = invitation_id_value;

  return invitation_payload || jsonb_build_object('email_status', 'queued');
end;
$$;

revoke all on function public.create_automated_aptitude_invitation(
  uuid, uuid, uuid, uuid, text, text, timestamptz, integer
) from public, anon, authenticated;
grant execute on function public.create_automated_aptitude_invitation(
  uuid, uuid, uuid, uuid, text, text, timestamptz, integer
) to service_role;

create or replace function public.enqueue_screening_result_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row public.applications%rowtype;
  version_row public.job_aptitude_assessments%rowtype;
  test_version_row public.aptitude_test_versions%rowtype;
  candidate_row public.candidates%rowtype;
  invitation_row public.aptitude_invitations%rowtype;
  raw_token text;
  token_hash_value text;
  failure_state text;
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

  if new.report ->> 'threshold_met' <> 'true'
     or application_row.status in ('rejected', 'hired') then
    return new;
  end if;

  select configuration.*
  into version_row
  from public.job_aptitude_assessments configuration
  join public.aptitude_test_versions test_version
    on test_version.workspace_id = configuration.workspace_id
   and test_version.id = configuration.test_version_id
  where configuration.workspace_id = application_row.workspace_id
    and configuration.job_id = application_row.job_id
    and configuration.is_required
    and test_version.version_status = 'published'
  order by configuration.display_order
  limit 1;
  if not found then
    return new;
  end if;

  select test_version.*
  into test_version_row
  from public.aptitude_test_versions test_version
  where test_version.workspace_id = version_row.workspace_id
    and test_version.id = version_row.test_version_id;

  raw_token := translate(
    rtrim(encode(extensions.gen_random_bytes(32), 'base64'), '='),
    '+/',
    '-_'
  );
  token_hash_value := encode(
    extensions.digest(convert_to(raw_token, 'UTF8'), 'sha256'),
    'hex'
  );

  begin
    insert into public.aptitude_invitations (
      workspace_id,
      application_id,
      test_version_id,
      candidate_email,
      token_hash,
      status,
      email_status,
      expires_at,
      max_attempts,
      invited_by
    )
    values (
      application_row.workspace_id,
      application_row.id,
      test_version_row.id,
      candidate_row.email,
      token_hash_value,
      'pending',
      'queued',
      now() + interval '7 days',
      test_version_row.max_attempts,
      null
    )
    on conflict (workspace_id, application_id) do nothing
    returning * into invitation_row;

    if found then
      insert into proofhire_private.aptitude_invitation_tokens(invitation_id, token)
      values (invitation_row.id, raw_token);
    end if;
  exception when others then
    get stacked diagnostics failure_state = returned_sqlstate;
    insert into public.application_workflow_failures (
      workspace_id,
      application_id,
      screening_assessment_id,
      failure_code
    )
    values (
      application_row.workspace_id,
      application_row.id,
      new.id,
      'aptitude_invitation_setup_failed:' || failure_state
    )
    on conflict (screening_assessment_id) do nothing;
  end;
  return new;
end;
$$;

revoke all on function public.enqueue_screening_result_email()
  from public, anon, authenticated;
drop trigger if exists application_screening_assessments_enqueue_followup
  on public.application_screening_assessments;
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

  if delivery_row.email_type = 'aptitude_invitation' then
    select jsonb_build_object(
      'candidate_name', candidate.full_name,
      'job_title', job.title,
      'company_name', workspace.name,
      'duration_seconds', test_version.time_limit_seconds,
      'question_count', coalesce(invitation.question_count, (
        select count(*)::integer
        from public.aptitude_questions question
        where question.workspace_id = invitation.workspace_id
          and question.test_version_id = invitation.test_version_id
      )),
      'deadline', invitation.expires_at,
      'token', token_row.token
    )
    into context_value
    from public.aptitude_invitations invitation
    join public.applications application
      on application.workspace_id = invitation.workspace_id
     and application.id = invitation.application_id
    join public.candidates candidate
      on candidate.workspace_id = application.workspace_id
     and candidate.id = application.candidate_id
    join public.jobs job
      on job.workspace_id = application.workspace_id
     and job.id = application.job_id
    join public.workspaces workspace
      on workspace.id = application.workspace_id
    join public.aptitude_test_versions test_version
      on test_version.workspace_id = invitation.workspace_id
     and test_version.id = invitation.test_version_id
    join proofhire_private.aptitude_invitation_tokens token_row
      on token_row.invitation_id = invitation.id
    where invitation.id = delivery_row.aptitude_invitation_id;
  elsif delivery_row.email_type = 'screening_result' then
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
  else
    raise exception 'Email delivery type is not supported by this worker.';
  end if;

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

create or replace function public.set_email_delivery_configuration(
  target_available boolean
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if target_available then
    update public.email_delivery_jobs
    set status = 'queued',
        next_attempt_at = now(),
        last_error_code = null,
        updated_at = now()
    where status = 'blocked_configuration';
  else
    update public.email_delivery_jobs
    set status = 'blocked_configuration',
        lease_token = null,
        locked_by = null,
        locked_until = null,
        last_error_code = 'email_configuration_unavailable',
        updated_at = now()
    where status in ('queued', 'retry_wait');
  end if;
  get diagnostics changed_rows = row_count;
  return changed_rows;
end;
$$;

revoke all on function public.set_email_delivery_configuration(boolean)
  from public, anon, authenticated;
grant execute on function public.set_email_delivery_configuration(boolean)
  to service_role;

create or replace function public.finalize_expired_aptitude_attempts()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  changed_rows integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  with expired as (
    select attempt.id
    from public.aptitude_attempts attempt
    join public.aptitude_test_versions version
      on version.workspace_id = attempt.workspace_id
     and version.id = attempt.test_version_id
    where attempt.status = 'in_progress'
      and attempt.started_at + make_interval(secs => version.time_limit_seconds) <= now()
    order by attempt.started_at
    for update of attempt skip locked
    limit 100
  )
  update public.aptitude_attempts attempt
  set status = 'expired',
      submitted_at = now(),
      result = jsonb_build_object('reason', 'time_expired'),
      updated_at = now()
  from expired
  where attempt.id = expired.id;
  get diagnostics changed_rows = row_count;
  return changed_rows;
end;
$$;

revoke all on function public.finalize_expired_aptitude_attempts()
  from public, anon, authenticated;
grant execute on function public.finalize_expired_aptitude_attempts()
  to service_role;

create or replace function public.request_email_delivery_action(
  target_user_id uuid,
  target_workspace_id uuid,
  target_job_id uuid,
  target_action text,
  target_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.email_delivery_jobs%rowtype;
  resulting_job_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if target_action is null
     or target_action not in ('send', 'retry', 'resend')
     or target_request_id is null
     or not exists (
       select 1
       from public.workspace_members workspace_member
       where workspace_member.workspace_id = target_workspace_id
         and workspace_member.user_id = target_user_id
         and workspace_member.role in ('owner', 'admin', 'recruiter')
     ) then
    raise exception 'Email delivery action is not authorized.';
  end if;

  select delivery.*
  into delivery_row
  from public.email_delivery_jobs delivery
  where delivery.workspace_id = target_workspace_id
    and delivery.id = target_job_id
  for update;
  if not found then
    raise exception 'Email delivery record was not found.';
  end if;

  if target_action = 'send' then
    if delivery_row.status not in ('queued', 'retry_wait') then
      raise exception 'Only queued email can be sent now.';
    end if;
    update public.email_delivery_jobs
    set status = 'queued',
        next_attempt_at = now(),
        updated_at = now()
    where id = delivery_row.id;
    resulting_job_id := delivery_row.id;
  elsif target_action = 'retry' then
    if delivery_row.status not in ('failed', 'blocked_configuration', 'retry_wait')
       or delivery_row.attempts >= 10 then
      raise exception 'This email is not eligible for retry.';
    end if;
    update public.email_delivery_jobs
    set status = 'queued',
        max_attempts = greatest(max_attempts, attempts + 1),
        next_attempt_at = now(),
        lease_token = null,
        locked_by = null,
        locked_until = null,
        last_error_code = null,
        updated_at = now()
    where id = delivery_row.id;
    resulting_job_id := delivery_row.id;
  else
    if delivery_row.status not in ('sent', 'delivered') then
      raise exception 'Only sent email can be resent.';
    end if;
    if delivery_row.email_type = 'aptitude_invitation'
       and not exists (
         select 1
         from proofhire_private.aptitude_invitation_tokens token_row
         where token_row.invitation_id = delivery_row.aptitude_invitation_id
       ) then
      raise exception 'This invitation does not have a resendable link.';
    end if;
    insert into public.email_delivery_jobs (
      workspace_id,
      application_id,
      aptitude_invitation_id,
      coding_invitation_id,
      interview_record_id,
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
      delivery_row.workspace_id,
      delivery_row.application_id,
      delivery_row.aptitude_invitation_id,
      delivery_row.coding_invitation_id,
      delivery_row.interview_record_id,
      delivery_row.screening_assessment_id,
      delivery_row.email_type,
      delivery_row.template_key,
      delivery_row.recipient_email,
      left(delivery_row.idempotency_key, 120)
        || ':resend:' || target_request_id::text,
      'queued',
      0,
      5
    )
    on conflict (idempotency_key) do update
      set idempotency_key = excluded.idempotency_key
    returning id into resulting_job_id;
  end if;

  return jsonb_build_object(
    'id', resulting_job_id,
    'status', (select status from public.email_delivery_jobs where id = resulting_job_id)
  );
end;
$$;

revoke all on function public.request_email_delivery_action(
  uuid, uuid, uuid, text, uuid
) from public, anon, authenticated;
grant execute on function public.request_email_delivery_action(
  uuid, uuid, uuid, text, uuid
) to service_role;

create or replace function public.record_email_delivery_provider_event(
  target_provider_message_id text,
  target_event_type text
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.email_delivery_jobs%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if target_event_type is null
     or target_event_type not in (
    'email.delivered',
    'email.bounced',
    'email.complained',
    'email.failed'
  ) then
    raise exception 'Email provider event is invalid.';
  end if;
  select delivery.*
  into delivery_row
  from public.email_delivery_jobs delivery
  where delivery.provider_message_id = target_provider_message_id
  for update;
  if not found then
    return false;
  end if;

  if target_event_type = 'email.delivered' then
    if delivery_row.status in ('sent', 'delivered') then
      perform public.mark_email_delivery_delivered(
        delivery_row.id,
        target_provider_message_id
      );
    end if;
    return true;
  end if;

  if delivery_row.status = 'sent' then
    update public.email_delivery_jobs
    set status = 'failed',
        last_error_code = case target_event_type
          when 'email.bounced' then 'provider_bounced'
          when 'email.complained' then 'provider_complaint'
          else 'provider_delivery_failed'
        end,
        updated_at = now()
    where id = delivery_row.id;
    update public.email_delivery_attempts
    set status = 'failed',
        error_code = case target_event_type
          when 'email.bounced' then 'provider_bounced'
          when 'email.complained' then 'provider_complaint'
          else 'provider_delivery_failed'
        end,
        completed_at = now()
    where delivery_job_id = delivery_row.id
      and attempt_number = delivery_row.attempts;
  end if;
  return true;
end;
$$;

revoke all on function public.record_email_delivery_provider_event(text, text)
  from public, anon, authenticated;
grant execute on function public.record_email_delivery_provider_event(text, text)
  to service_role;

create or replace function public.advance_application_after_aptitude_result()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
begin
  if new.status not in ('submitted', 'expired')
     or new.score is null
     or new.result ->> 'passed' is null
     or new.result ->> 'passed' not in ('true', 'false') then
    return new;
  end if;

  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.workspace_id = new.workspace_id
    and invitation.id = new.invitation_id;
  if not found then
    return new;
  end if;

  if new.result ->> 'passed' = 'true' then
    update public.applications
    set status = 'interview',
        updated_at = now()
    where workspace_id = invitation_row.workspace_id
      and id = invitation_row.application_id
      and status not in ('rejected', 'hired', 'interview');
    update public.application_assessment_reviews
    set review_status = 'cleared',
        updated_at = now()
    where attempt_id = new.id
      and review_status = 'pending';
  else
    insert into public.application_assessment_reviews (
      workspace_id,
      application_id,
      attempt_id
    )
    values (
      invitation_row.workspace_id,
      invitation_row.application_id,
      new.id
    )
    on conflict (attempt_id) do nothing;
  end if;
  return new;
end;
$$;

revoke all on function public.advance_application_after_aptitude_result()
  from public, anon, authenticated;
drop trigger if exists aptitude_attempts_advance_application
  on public.aptitude_attempts;
create trigger aptitude_attempts_advance_application
after update of score, result on public.aptitude_attempts
for each row
when (
  new.status in ('submitted', 'expired')
  and new.score is not null
  and new.result ->> 'passed' in ('true', 'false')
)
execute function public.advance_application_after_aptitude_result();

commit;
