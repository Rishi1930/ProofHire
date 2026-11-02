-- Service-mediated aptitude invitations, candidate sessions, autosave, scoring,
-- and low-detail monitoring. Candidate APIs never return private answer keys.

begin;

create or replace function public.save_aptitude_answer_key(
  target_question_id uuid,
  target_answer_key jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  question_row public.aptitude_questions%rowtype;
  selected_option text;
  selected_count integer;
  unique_count integer;
begin
  select question.*
  into question_row
  from public.aptitude_questions question
  where question.id = target_question_id;
  if not found or not public.has_workspace_role(
    question_row.workspace_id,
    array['owner', 'admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to edit this aptitude answer key.';
  end if;
  if not exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = question_row.workspace_id
      and version.id = question_row.test_version_id
      and version.version_status = 'draft'
  ) then
    raise exception 'Answer keys can only be changed on draft aptitude tests.';
  end if;
  if jsonb_typeof(target_answer_key) is distinct from 'object' then
    raise exception 'A valid aptitude answer key is required.';
  end if;

  if question_row.question_type in ('single_choice', 'multiple_choice') then
    if jsonb_typeof(target_answer_key -> 'option_ids') is distinct from 'array' then
      raise exception 'Choice answer keys must contain option IDs.';
    end if;
    select count(*), count(distinct selected.value)
    into selected_count, unique_count
    from jsonb_array_elements_text(target_answer_key -> 'option_ids')
      as selected(value);
    if selected_count = 0 or selected_count <> unique_count then
      raise exception 'Select at least one unique correct option.';
    end if;
    if question_row.question_type = 'single_choice' and selected_count <> 1 then
      raise exception 'Select exactly one correct option.';
    end if;
    for selected_option in
      select selected.value
      from jsonb_array_elements_text(target_answer_key -> 'option_ids')
        as selected(value)
    loop
      if not exists (
        select 1
        from public.aptitude_question_options option_row
        where option_row.workspace_id = question_row.workspace_id
          and option_row.question_id = question_row.id
          and option_row.id::text = selected_option
      ) then
        raise exception 'An answer key option does not belong to this question.';
      end if;
    end loop;
  elsif question_row.question_type = 'short_text' then
    if jsonb_typeof(target_answer_key -> 'accepted_answers') is distinct from 'array'
       or not exists (
         select 1
         from jsonb_array_elements_text(target_answer_key -> 'accepted_answers')
           as accepted(value)
         where char_length(trim(accepted.value)) > 0
       ) then
      raise exception 'Add at least one accepted short-text answer.';
    end if;
  else
    raise exception 'Unsupported aptitude question type.';
  end if;

  insert into proofhire_private.aptitude_answer_keys (
    workspace_id,
    question_id,
    answer_key
  )
  values (
    question_row.workspace_id,
    question_row.id,
    target_answer_key
  )
  on conflict (workspace_id, question_id)
  do update set answer_key = excluded.answer_key,
                updated_at = now();
end;
$$;

create or replace function public.create_aptitude_invitation(
  target_user_id uuid,
  target_workspace_id uuid,
  target_application_id uuid,
  target_test_version_id uuid,
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
  candidate_email_value text;
  invitation_row public.aptitude_invitations%rowtype;
  test_title_value text;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create aptitude invitations.';
  end if;
  if not exists (
    select 1
    from public.workspace_members workspace_member
    where workspace_member.workspace_id = target_workspace_id
      and workspace_member.user_id = target_user_id
      and workspace_member.role = any(array['owner', 'admin', 'recruiter']::text[])
  ) then
    raise exception 'You do not have permission to invite this candidate.';
  end if;
  if target_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'A valid invitation token hash is required.';
  end if;
  select candidate.email
  into candidate_email_value
  from public.applications application
  join public.candidates candidate
    on candidate.workspace_id = application.workspace_id
   and candidate.id = application.candidate_id
  where application.workspace_id = target_workspace_id
    and application.id = target_application_id;
  if candidate_email_value is null then
    raise exception 'The application does not have a candidate email address.';
  end if;
  select test.title
  into test_title_value
  from public.aptitude_test_versions version
  join public.aptitude_tests test
    on test.workspace_id = version.workspace_id
   and test.id = version.test_id
  where version.workspace_id = target_workspace_id
    and version.id = target_test_version_id
    and version.version_status = 'published';
  if test_title_value is null then
    raise exception 'Select a published aptitude test.';
  end if;

  insert into public.aptitude_invitations (
    workspace_id,
    application_id,
    test_version_id,
    candidate_email,
    token_hash,
    status,
    email_status,
    email_error_code,
    expires_at,
    max_attempts,
    invited_by
  )
  select
    target_workspace_id,
    target_application_id,
    target_test_version_id,
    candidate_email_value,
    target_token_hash,
    'pending',
    'failed',
    'manual_delivery',
    target_expires_at,
    target_max_attempts,
    target_user_id
  from public.aptitude_test_versions version
  where version.workspace_id = target_workspace_id
    and version.id = target_test_version_id
    and version.version_status = 'published'
    and target_max_attempts between 1 and version.max_attempts;
  if not found then
    raise exception 'The invitation attempt limit is invalid.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash;
  return jsonb_build_object(
    'id', invitation_row.id,
    'workspace_id', invitation_row.workspace_id,
    'application_id', invitation_row.application_id,
    'test_version_id', invitation_row.test_version_id,
    'candidate_email', invitation_row.candidate_email,
    'test_title', test_title_value,
    'status', invitation_row.status,
    'expires_at', invitation_row.expires_at,
    'max_attempts', invitation_row.max_attempts,
    'email_status', invitation_row.email_status
  );
end;
$$;

create or replace function public.get_aptitude_candidate_session(
  target_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  version_row public.aptitude_test_versions%rowtype;
  test_title_value text;
  test_description_value text;
  attempt_count_value integer;
  active_attempt public.aptitude_attempts%rowtype;
  question_list jsonb;
  saved_answers_value jsonb := '{}'::jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to read aptitude sessions.';
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
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = invitation_row.workspace_id
    and version.id = invitation_row.test_version_id
    and version.version_status = 'published';
  select test.title, test.description
  into test_title_value, test_description_value
  from public.aptitude_tests test
  where test.workspace_id = version_row.workspace_id
    and test.id = version_row.test_id;
  select count(*)
  into attempt_count_value
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id;
  select attempt.*
  into active_attempt
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.status = 'in_progress'
  order by attempt.attempt_number desc
  limit 1;
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', question.id,
        'display_order', question.display_order,
        'question_type', question.question_type,
        'prompt', question.prompt,
        'points', question.points,
        'options', (
          select coalesce(
            jsonb_agg(
              jsonb_build_object('id', option_row.id, 'option_text', option_row.option_text)
              order by option_row.display_order
            ),
            '[]'::jsonb
          )
          from public.aptitude_question_options option_row
          where option_row.workspace_id = question.workspace_id
            and option_row.question_id = question.id
        )
      )
      order by question.display_order
    ),
    '[]'::jsonb
  )
  into question_list
  from public.aptitude_questions question
  where question.workspace_id = invitation_row.workspace_id
    and question.test_version_id = invitation_row.test_version_id;
  if active_attempt.id is not null then
    select coalesce(
      jsonb_object_agg(answer.question_id::text, answer.answer),
      '{}'::jsonb
    )
    into saved_answers_value
    from public.aptitude_answers answer
    where answer.workspace_id = invitation_row.workspace_id
      and answer.attempt_id = active_attempt.id;
  end if;

  return jsonb_build_object(
    'invitation_id', invitation_row.id,
    'status', invitation_row.status,
    'expires_at', invitation_row.expires_at,
    'attempts_used', attempt_count_value,
    'max_attempts', invitation_row.max_attempts,
    'time_limit_seconds', version_row.time_limit_seconds,
    'passing_score', version_row.passing_score,
    'title', test_title_value,
    'description', test_description_value,
    'active_attempt_id', case when active_attempt.id is null then null else active_attempt.id end,
    'active_attempt_started_at', active_attempt.started_at,
    'saved_answers', saved_answers_value,
    'questions', question_list
  );
end;
$$;

create or replace function public.start_aptitude_candidate_attempt(
  target_token_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  active_attempt public.aptitude_attempts%rowtype;
  next_attempt_number integer;
  session_payload jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to start aptitude sessions.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('pending', 'sent', 'started')
  for update;
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;
  select attempt.*
  into active_attempt
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.status = 'in_progress'
  order by attempt.attempt_number desc
  limit 1
  for update;
  if found then
    if active_attempt.started_at + make_interval(
      secs => (
        select version.time_limit_seconds
        from public.aptitude_test_versions version
        where version.id = active_attempt.test_version_id
      )
    ) > now() then
      select public.get_aptitude_candidate_session(target_token_hash)
      into session_payload;
      return session_payload || jsonb_build_object(
        'attempt_id', active_attempt.id,
        'attempt_number', active_attempt.attempt_number,
        'started_at', active_attempt.started_at
      );
    end if;
    update public.aptitude_attempts
    set status = 'expired',
        submitted_at = now(),
        result = jsonb_build_object('reason', 'time_expired')
    where id = active_attempt.id;
    if active_attempt.attempt_number >= invitation_row.max_attempts then
      update public.aptitude_invitations
      set status = 'completed'
      where id = invitation_row.id;
      return jsonb_build_object(
        'status', 'completed',
        'attempts_used', active_attempt.attempt_number,
        'max_attempts', invitation_row.max_attempts
      );
    end if;
  end if;

  select count(*) + 1
  into next_attempt_number
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id;
  if next_attempt_number > invitation_row.max_attempts then
    update public.aptitude_invitations
    set status = 'completed'
    where id = invitation_row.id;
    return jsonb_build_object(
      'status', 'completed',
      'attempts_used', next_attempt_number - 1,
      'max_attempts', invitation_row.max_attempts
    );
  end if;
  insert into public.aptitude_attempts (
    workspace_id,
    invitation_id,
    test_version_id,
    attempt_number
  )
  values (
    invitation_row.workspace_id,
    invitation_row.id,
    invitation_row.test_version_id,
    next_attempt_number
  )
  returning * into active_attempt;
  select public.get_aptitude_candidate_session(target_token_hash)
  into session_payload;
  return session_payload || jsonb_build_object(
    'attempt_id', active_attempt.id,
    'attempt_number', active_attempt.attempt_number,
    'started_at', active_attempt.started_at
  );
end;
$$;

create or replace function public.save_aptitude_candidate_answer(
  target_token_hash text,
  target_attempt_id uuid,
  target_question_id uuid,
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
  question_row public.aptitude_questions%rowtype;
  selected_count integer;
  unique_count integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to save aptitude answers.';
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
    raise exception 'The aptitude attempt is not active.';
  end if;
  select question.*
  into question_row
  from public.aptitude_questions question
  join public.aptitude_test_versions version
    on version.workspace_id = question.workspace_id
   and version.id = question.test_version_id
  where question.workspace_id = invitation_row.workspace_id
    and question.test_version_id = invitation_row.test_version_id
    and question.id = target_question_id
    and attempt_row.started_at + make_interval(secs => version.time_limit_seconds) > now();
  if not found then
    raise exception 'The aptitude question is unavailable or the attempt has expired.';
  end if;
  if question_row.question_type in ('single_choice', 'multiple_choice') then
    if jsonb_typeof(target_answer -> 'option_ids') is distinct from 'array' then
      raise exception 'Select one or more listed options.';
    end if;
    select count(*), count(distinct selected.value)
    into selected_count, unique_count
    from jsonb_array_elements_text(target_answer -> 'option_ids')
      as selected(value);
    if selected_count <> unique_count
       or (question_row.question_type = 'single_choice' and selected_count > 1)
       or exists (
         select 1
         from jsonb_array_elements_text(target_answer -> 'option_ids')
           as selected(value)
         where not exists (
           select 1
           from public.aptitude_question_options option_row
           where option_row.workspace_id = question_row.workspace_id
             and option_row.question_id = question_row.id
             and option_row.id::text = selected.value
         )
       ) then
      raise exception 'The answer contains an invalid option.';
    end if;
  elsif question_row.question_type = 'short_text' then
    if jsonb_typeof(target_answer) is distinct from 'string'
       or char_length(target_answer #>> '{}') > 5000 then
      raise exception 'Enter a short-text answer of at most 5000 characters.';
    end if;
  else
    raise exception 'Unsupported aptitude question type.';
  end if;

  insert into public.aptitude_answers (
    workspace_id,
    attempt_id,
    test_version_id,
    question_id,
    answer,
    saved_at
  )
  values (
    attempt_row.workspace_id,
    attempt_row.id,
    attempt_row.test_version_id,
    question_row.id,
    target_answer,
    now()
  )
  on conflict (attempt_id, question_id)
  do update set answer = excluded.answer, saved_at = now();
  return true;
end;
$$;

create or replace function public.submit_aptitude_candidate_attempt(
  target_token_hash text,
  target_attempt_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  attempt_row public.aptitude_attempts%rowtype;
  version_row public.aptitude_test_versions%rowtype;
  question_row record;
  answer_value jsonb;
  candidate_options text[];
  correct_options text[];
  total_points numeric := 0;
  earned_points numeric := 0;
  answer_count integer := 0;
  question_count integer := 0;
  is_correct boolean;
  score_value numeric(5, 2);
  passed_value boolean;
  result_value jsonb;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to submit aptitude attempts.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.token_hash = target_token_hash
  for update;
  if not found then
    raise exception 'The aptitude invitation is unavailable.';
  end if;
  select attempt.*
  into attempt_row
  from public.aptitude_attempts attempt
  where attempt.workspace_id = invitation_row.workspace_id
    and attempt.invitation_id = invitation_row.id
    and attempt.id = target_attempt_id
  for update;
  if not found then
    raise exception 'The aptitude attempt was not found.';
  end if;
  if attempt_row.status in ('submitted', 'expired') then
    return jsonb_build_object(
      'attempt_id', attempt_row.id,
      'status', attempt_row.status,
      'score', attempt_row.score,
      'result', attempt_row.result
    );
  end if;
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = invitation_row.workspace_id
    and version.id = invitation_row.test_version_id;
  if attempt_row.started_at + make_interval(secs => version_row.time_limit_seconds) <= now()
     or invitation_row.expires_at <= now() then
    update public.aptitude_attempts
    set status = 'expired',
        submitted_at = now(),
        result = jsonb_build_object('reason', 'time_expired')
    where id = attempt_row.id;
    update public.aptitude_invitations
    set status = case
      when attempt_row.attempt_number >= invitation_row.max_attempts then 'completed'
      else 'started'
    end
    where id = invitation_row.id;
    return jsonb_build_object(
      'attempt_id', attempt_row.id,
      'status', 'expired',
      'score', null,
      'result', jsonb_build_object('reason', 'time_expired')
    );
  end if;

  for question_row in
    select
      question.id,
      question.question_type,
      question.points,
      answer_key.answer_key
    from public.aptitude_questions question
    join proofhire_private.aptitude_answer_keys answer_key
      on answer_key.workspace_id = question.workspace_id
     and answer_key.question_id = question.id
    where question.workspace_id = invitation_row.workspace_id
      and question.test_version_id = invitation_row.test_version_id
    order by question.display_order
  loop
    question_count := question_count + 1;
    total_points := total_points + question_row.points;
    select answer.answer
    into answer_value
    from public.aptitude_answers answer
    where answer.workspace_id = attempt_row.workspace_id
      and answer.attempt_id = attempt_row.id
      and answer.question_id = question_row.id;
    if found then
      answer_count := answer_count + 1;
      if question_row.question_type in ('single_choice', 'multiple_choice') then
        select coalesce(array_agg(selected.value order by selected.value), array[]::text[])
        into candidate_options
        from jsonb_array_elements_text(answer_value -> 'option_ids') as selected(value);
        select coalesce(array_agg(selected.value order by selected.value), array[]::text[])
        into correct_options
        from jsonb_array_elements_text(question_row.answer_key -> 'option_ids') as selected(value);
        is_correct := candidate_options = correct_options;
      else
        is_correct := exists (
          select 1
          from jsonb_array_elements_text(question_row.answer_key -> 'accepted_answers')
            as accepted(value)
          where lower(trim(accepted.value)) = lower(trim(answer_value #>> '{}'))
        );
      end if;
      if is_correct then
        earned_points := earned_points + question_row.points;
      end if;
    end if;
  end loop;
  score_value := round(earned_points / nullif(total_points, 0) * 100, 2);
  passed_value := case
    when version_row.passing_score is null then null
    else score_value >= version_row.passing_score
  end;
  result_value := jsonb_build_object(
    'earned_points', earned_points,
    'available_points', total_points,
    'answered_questions', answer_count,
    'question_count', question_count,
    'passed', passed_value
  );
  update public.aptitude_attempts
  set status = 'submitted',
      submitted_at = now(),
      score = score_value,
      result = result_value
  where id = attempt_row.id;
  update public.aptitude_invitations
  set status = case
    when attempt_row.attempt_number >= invitation_row.max_attempts then 'completed'
    else 'started'
  end
  where id = invitation_row.id;
  return jsonb_build_object(
    'attempt_id', attempt_row.id,
    'status', 'submitted',
    'score', score_value,
    'result', result_value,
    'passing_score', version_row.passing_score
  );
end;
$$;

create or replace function public.record_aptitude_candidate_event(
  target_token_hash text,
  target_attempt_id uuid,
  target_event_type text,
  target_event_data jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  event_id uuid;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to record aptitude events.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  join public.aptitude_attempts attempt
    on attempt.workspace_id = invitation.workspace_id
   and attempt.invitation_id = invitation.id
  where invitation.token_hash = target_token_hash
    and invitation.expires_at > now()
    and invitation.status in ('started', 'completed')
    and attempt.id = target_attempt_id
    and attempt.status = 'in_progress';
  if not found or jsonb_typeof(target_event_data) is distinct from 'object'
     or octet_length(target_event_data::text) > 2048 then
    raise exception 'The aptitude monitoring event is invalid.';
  end if;
  insert into public.aptitude_monitoring_events (
    workspace_id,
    attempt_id,
    event_type,
    event_data
  )
  values (
    invitation_row.workspace_id,
    target_attempt_id,
    target_event_type,
    target_event_data
  )
  returning id into event_id;
  return event_id;
end;
$$;

revoke all on function public.save_aptitude_answer_key(uuid, jsonb)
  from public, anon;
grant execute on function public.save_aptitude_answer_key(uuid, jsonb)
  to authenticated;
revoke all on function public.create_aptitude_invitation(uuid, uuid, uuid, uuid, text, timestamptz, integer)
  from public, anon, authenticated;
grant execute on function public.create_aptitude_invitation(uuid, uuid, uuid, uuid, text, timestamptz, integer)
  to service_role;
revoke all on function public.get_aptitude_candidate_session(text)
  from public, anon, authenticated;
grant execute on function public.get_aptitude_candidate_session(text)
  to service_role;
revoke all on function public.start_aptitude_candidate_attempt(text)
  from public, anon, authenticated;
grant execute on function public.start_aptitude_candidate_attempt(text)
  to service_role;
revoke all on function public.save_aptitude_candidate_answer(text, uuid, uuid, jsonb)
  from public, anon, authenticated;
grant execute on function public.save_aptitude_candidate_answer(text, uuid, uuid, jsonb)
  to service_role;
revoke all on function public.submit_aptitude_candidate_attempt(text, uuid)
  from public, anon, authenticated;
grant execute on function public.submit_aptitude_candidate_attempt(text, uuid)
  to service_role;
revoke all on function public.record_aptitude_candidate_event(text, uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.record_aptitude_candidate_event(text, uuid, text, jsonb)
  to service_role;

commit;
