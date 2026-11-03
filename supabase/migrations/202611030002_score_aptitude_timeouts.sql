begin;

create or replace function public.valid_aptitude_difficulty_distribution(
  target_distribution jsonb,
  target_question_count integer
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  item record;
  total integer := 0;
  quantity integer;
begin
  if jsonb_typeof(target_distribution) is distinct from 'object' then
    return false;
  end if;

  for item in
    select entry.key, entry.value
    from jsonb_each(target_distribution) entry
  loop
    if item.key not in ('beginner', 'medium', 'advanced', 'expert')
       or jsonb_typeof(item.value) is distinct from 'number'
       or (item.value #>> '{}') !~ '^[0-9]+$' then
      return false;
    end if;
    quantity := (item.value #>> '{}')::integer;
    total := total + quantity;
  end loop;

  if target_question_count is null then
    return total = 0;
  end if;
  return target_question_count > 0 and total = target_question_count;
exception
  when numeric_value_out_of_range then
    return false;
end;
$$;

revoke all on function public.valid_aptitude_difficulty_distribution(jsonb, integer)
  from public, anon, authenticated;
grant execute on function public.valid_aptitude_difficulty_distribution(jsonb, integer)
  to authenticated, service_role;

alter table public.aptitude_questions
  add column if not exists job_roles text[] not null default array['general']::text[],
  add column if not exists competencies text[] not null default array[]::text[],
  add column if not exists is_active boolean not null default true,
  add column if not exists approval_status text not null default 'approved';

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_questions'::regclass
      and conname = 'aptitude_questions_role_tags_check'
  ) then
    alter table public.aptitude_questions
      add constraint aptitude_questions_role_tags_check
      check (cardinality(job_roles) between 1 and 20);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_questions'::regclass
      and conname = 'aptitude_questions_competency_tags_check'
  ) then
    alter table public.aptitude_questions
      add constraint aptitude_questions_competency_tags_check
      check (cardinality(competencies) <= 50);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_questions'::regclass
      and conname = 'aptitude_questions_approval_status_check'
  ) then
    alter table public.aptitude_questions
      add constraint aptitude_questions_approval_status_check
      check (approval_status in ('pending', 'approved', 'rejected'));
  end if;
end;
$migration$;

alter table public.job_aptitude_assessments
  add column if not exists job_role text not null default 'general',
  add column if not exists competencies text[] not null default array[]::text[],
  add column if not exists categories text[] not null default array[]::text[],
  add column if not exists question_count integer,
  add column if not exists difficulty_distribution jsonb not null default '{}'::jsonb;

alter table public.aptitude_invitations
  add column if not exists job_role text not null default 'general',
  add column if not exists competencies text[] not null default array[]::text[],
  add column if not exists categories text[] not null default array[]::text[],
  add column if not exists question_count integer,
  add column if not exists difficulty_distribution jsonb not null default '{}'::jsonb;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_question_count_check'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_question_count_check
      check (question_count is null or question_count between 1 and 1000);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_difficulty_distribution_check'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_difficulty_distribution_check
      check (
        public.valid_aptitude_difficulty_distribution(
          difficulty_distribution,
          question_count
        )
      );
  end if;
end;
$migration$;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.job_aptitude_assessments'::regclass
      and conname = 'job_aptitude_assessments_question_count_check'
  ) then
    alter table public.job_aptitude_assessments
      add constraint job_aptitude_assessments_question_count_check
      check (question_count is null or question_count between 1 and 1000);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.job_aptitude_assessments'::regclass
      and conname = 'job_aptitude_assessments_difficulty_distribution_check'
  ) then
    alter table public.job_aptitude_assessments
      add constraint job_aptitude_assessments_difficulty_distribution_check
      check (
        public.valid_aptitude_difficulty_distribution(
          difficulty_distribution,
          question_count
        )
      );
  end if;
end;
$migration$;

create or replace function public.validate_aptitude_invitation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.aptitude_test_versions%rowtype;
  configuration_row public.job_aptitude_assessments%rowtype;
  application_job_id uuid;
  eligible_count integer;
  difficulty_name text;
  required_count integer;
  available_count integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create aptitude invitations.';
  end if;

  select application.job_id
  into application_job_id
  from public.applications application
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if application_job_id is null then
    raise exception 'The aptitude invitation application was not found.';
  end if;

  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = new.workspace_id
    and version.id = new.test_version_id;
  if not found or version_row.version_status <> 'published' then
    raise exception 'Invitations require a published aptitude test version.';
  end if;
  if new.max_attempts > version_row.max_attempts then
    raise exception 'Invitation attempt limit exceeds its published test version.';
  end if;
  if new.expires_at <= now() then
    raise exception 'Aptitude invitation expiry must be in the future.';
  end if;

  new.job_id := application_job_id;
  insert into public.job_aptitude_assessments (
    workspace_id,
    job_id,
    test_version_id,
    is_required,
    display_order,
    created_by
  )
  values (
    new.workspace_id,
    application_job_id,
    new.test_version_id,
    false,
    1,
    new.invited_by
  )
  on conflict (workspace_id, job_id, test_version_id) do nothing;

  select configuration.*
  into configuration_row
  from public.job_aptitude_assessments configuration
  where configuration.workspace_id = new.workspace_id
    and configuration.job_id = application_job_id
    and configuration.test_version_id = new.test_version_id;
  if not found then
    raise exception 'The job aptitude configuration could not be established.';
  end if;

  new.job_aptitude_assessment_id := configuration_row.id;
  new.job_role := configuration_row.job_role;
  new.competencies := configuration_row.competencies;
  new.categories := configuration_row.categories;
  new.question_count := configuration_row.question_count;
  new.difficulty_distribution := configuration_row.difficulty_distribution;

  select count(*)
  into eligible_count
  from public.aptitude_questions question
  where question.workspace_id = new.workspace_id
    and question.test_version_id = new.test_version_id
    and question.is_active
    and question.approval_status = 'approved'
    and exists (
      select 1
      from unnest(question.job_roles) as role_tag(role_name)
      where lower(role_tag.role_name) in (lower(new.job_role), 'general')
    )
    and (
      cardinality(new.competencies) = 0
      or cardinality(question.competencies) = 0
      or question.competencies && new.competencies
    )
    and (
      cardinality(new.categories) = 0
      or lower(question.category) = any(new.categories)
    );
  if eligible_count = 0 then
    raise exception 'No active, approved questions match this job aptitude configuration.';
  end if;

  if new.question_count is not null then
    foreach difficulty_name in array array['beginner', 'medium', 'advanced', 'expert']
    loop
      required_count := coalesce(
        (new.difficulty_distribution ->> difficulty_name)::integer,
        0
      );
      if required_count = 0 then
        continue;
      end if;

      select count(*)
      into available_count
      from public.aptitude_questions question
      where question.workspace_id = new.workspace_id
        and question.test_version_id = new.test_version_id
        and question.difficulty = difficulty_name
        and question.is_active
        and question.approval_status = 'approved'
        and exists (
          select 1
          from unnest(question.job_roles) as role_tag(role_name)
          where lower(role_tag.role_name) in (lower(new.job_role), 'general')
        )
        and (
          cardinality(new.competencies) = 0
          or cardinality(question.competencies) = 0
          or question.competencies && new.competencies
        )
        and (
          cardinality(new.categories) = 0
          or lower(question.category) = any(new.categories)
        );

      if available_count < required_count then
        raise exception 'The question bank has % eligible % question(s); % required.',
          available_count, difficulty_name, required_count;
      end if;
    end loop;
  end if;
  return new;
end;
$$;

create or replace function public.validate_aptitude_attempt_question_pool()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  eligible_count integer;
  difficulty_name text;
  required_count integer;
  available_count integer;
begin
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.workspace_id = new.workspace_id
    and invitation.id = new.invitation_id;
  if not found then
    raise exception 'The aptitude invitation was not found.';
  end if;

  select count(*)
  into eligible_count
  from public.aptitude_questions question
  where question.workspace_id = new.workspace_id
    and question.test_version_id = new.test_version_id
    and question.is_active
    and question.approval_status = 'approved'
    and exists (
      select 1
      from unnest(question.job_roles) as role_tag(role_name)
      where lower(role_tag.role_name) in (
        lower(invitation_row.job_role),
        'general'
      )
    )
    and (
      cardinality(invitation_row.competencies) = 0
      or cardinality(question.competencies) = 0
      or question.competencies && invitation_row.competencies
    )
    and (
      cardinality(invitation_row.categories) = 0
      or lower(question.category) = any(invitation_row.categories)
    );

  if eligible_count = 0 then
    raise exception 'No active, approved questions match this job aptitude configuration.';
  end if;

  if invitation_row.question_count is not null then
    foreach difficulty_name in array array['beginner', 'medium', 'advanced', 'expert']
    loop
      required_count := coalesce(
        (invitation_row.difficulty_distribution ->> difficulty_name)::integer,
        0
      );
      if required_count = 0 then
        continue;
      end if;

      select count(*)
      into available_count
      from public.aptitude_questions question
      where question.workspace_id = new.workspace_id
        and question.test_version_id = new.test_version_id
        and question.difficulty = difficulty_name
        and question.is_active
        and question.approval_status = 'approved'
        and exists (
          select 1
          from unnest(question.job_roles) as role_tag(role_name)
          where lower(role_tag.role_name) in (
            lower(invitation_row.job_role),
            'general'
          )
        )
        and (
          cardinality(invitation_row.competencies) = 0
          or cardinality(question.competencies) = 0
          or question.competencies && invitation_row.competencies
        )
        and (
          cardinality(invitation_row.categories) = 0
          or lower(question.category) = any(invitation_row.categories)
        );

      if available_count < required_count then
        raise exception 'The question bank has % eligible % question(s); % required.',
          available_count, difficulty_name, required_count;
      end if;
    end loop;
  end if;
  return new;
end;
$$;

revoke all on function public.validate_aptitude_attempt_question_pool()
  from public, anon, authenticated;

drop trigger if exists aptitude_attempts_validate_question_pool
  on public.aptitude_attempts;
create trigger aptitude_attempts_validate_question_pool
before insert on public.aptitude_attempts
for each row execute function public.validate_aptitude_attempt_question_pool();

drop trigger if exists aptitude_attempt_questions_filter_for_job
  on public.aptitude_attempt_questions;
drop function if exists public.filter_aptitude_attempt_question();

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
  if not found then
    raise exception 'The aptitude test version is unavailable.';
  end if;

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
        'display_order', assignment.display_order,
        'question_type', question.question_type,
        'prompt', question.prompt,
        'points', question.points,
        'category', question.category,
        'difficulty', question.difficulty,
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
      order by assignment.display_order
    ),
    '[]'::jsonb
  )
  into question_list
  from public.aptitude_attempt_questions assignment
  join public.aptitude_questions question
    on question.workspace_id = assignment.workspace_id
   and question.test_version_id = assignment.test_version_id
   and question.id = assignment.question_id
  where active_attempt.id is not null
    and assignment.workspace_id = invitation_row.workspace_id
    and assignment.attempt_id = active_attempt.id;

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
        evaluated_at = now(),
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

  with configuration as (
    select
      invitation_row.job_role as job_role,
      invitation_row.competencies as competencies,
      invitation_row.categories as categories,
      invitation_row.question_count as question_count,
      invitation_row.difficulty_distribution as difficulty_distribution
  ),
  eligible_questions as (
    select
      question.id as question_id,
      question.difficulty,
      random() as random_key
    from public.aptitude_questions question
    cross join configuration
    where question.workspace_id = invitation_row.workspace_id
      and question.test_version_id = invitation_row.test_version_id
      and question.is_active
      and question.approval_status = 'approved'
      and exists (
        select 1
        from unnest(question.job_roles) as role_tag(role_name)
        where lower(role_tag.role_name) in (
          lower(configuration.job_role),
          'general'
        )
      )
      and (
        cardinality(configuration.competencies) = 0
        or cardinality(question.competencies) = 0
        or question.competencies && configuration.competencies
      )
      and (
        cardinality(configuration.categories) = 0
        or lower(question.category) = any(configuration.categories)
      )
  ),
  ranked_questions as (
    select
      eligible_questions.*,
      row_number() over (
        partition by eligible_questions.difficulty
        order by eligible_questions.random_key, eligible_questions.question_id
      ) as difficulty_order
    from eligible_questions
  )
  insert into public.aptitude_attempt_questions (
    workspace_id,
    attempt_id,
    test_version_id,
    question_id,
    display_order
  )
  select
    invitation_row.workspace_id,
    active_attempt.id,
    invitation_row.test_version_id,
    ranked_questions.question_id,
    row_number() over (
      order by ranked_questions.random_key, ranked_questions.question_id
    )::integer
  from ranked_questions
  cross join configuration
  where configuration.question_count is null
     or ranked_questions.difficulty_order <= coalesce(
       (configuration.difficulty_distribution ->> ranked_questions.difficulty)::integer,
       0
     );

  select public.get_aptitude_candidate_session(target_token_hash)
  into session_payload;
  return session_payload || jsonb_build_object(
    'attempt_id', active_attempt.id,
    'attempt_number', active_attempt.attempt_number,
    'started_at', active_attempt.started_at
  );
end;
$$;

create or replace function public.score_expired_aptitude_attempt(
  target_workspace_id uuid,
  target_attempt_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
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
  has_answer boolean;
  is_correct boolean;
  score_value numeric(5, 2);
  passed_value boolean;
begin
  select attempt.*
  into attempt_row
  from public.aptitude_attempts attempt
  where attempt.workspace_id = target_workspace_id
    and attempt.id = target_attempt_id
    and attempt.status = 'expired';
  if not found then
    return;
  end if;

  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.workspace_id = attempt_row.workspace_id
    and version.id = attempt_row.test_version_id;
  if not found then
    raise exception 'The aptitude test version was not found for the expired attempt.';
  end if;

  for question_row in
    select
      question.id,
      question.question_type,
      question.points,
      answer_key.answer_key
    from public.aptitude_attempt_questions assignment
    join public.aptitude_questions question
      on question.workspace_id = assignment.workspace_id
     and question.test_version_id = assignment.test_version_id
     and question.id = assignment.question_id
    join proofhire_private.aptitude_answer_keys answer_key
      on answer_key.workspace_id = question.workspace_id
     and answer_key.question_id = question.id
    where assignment.workspace_id = attempt_row.workspace_id
      and assignment.attempt_id = attempt_row.id
    order by assignment.display_order
  loop
    question_count := question_count + 1;
    total_points := total_points + question_row.points;
    answer_value := null;

    select answer.answer
    into answer_value
    from public.aptitude_answers answer
    where answer.workspace_id = attempt_row.workspace_id
      and answer.attempt_id = attempt_row.id
      and answer.question_id = question_row.id;
    has_answer := found;
    is_correct := false;

    if has_answer then
      answer_count := answer_count + 1;
      if question_row.question_type in ('single_choice', 'multiple_choice') then
        select coalesce(array_agg(selected.value order by selected.value), array[]::text[])
        into candidate_options
        from jsonb_array_elements_text(answer_value -> 'option_ids') as selected(value);
        select coalesce(array_agg(selected.value order by selected.value), array[]::text[])
        into correct_options
        from jsonb_array_elements_text(question_row.answer_key -> 'option_ids')
          as selected(value);
        is_correct := candidate_options = correct_options;
      else
        is_correct := exists (
          select 1
          from jsonb_array_elements_text(question_row.answer_key -> 'accepted_answers')
            as accepted(value)
          where lower(trim(accepted.value)) = lower(trim(answer_value #>> '{}'))
        );
      end if;
    end if;

    insert into proofhire_private.aptitude_answer_scores (
      workspace_id,
      attempt_id,
      question_id,
      earned_points,
      maximum_points,
      is_correct,
      evaluated_at
    )
    values (
      attempt_row.workspace_id,
      attempt_row.id,
      question_row.id,
      case when is_correct then question_row.points else 0 end,
      question_row.points,
      is_correct,
      now()
    )
    on conflict (attempt_id, question_id)
    do update set
      earned_points = excluded.earned_points,
      maximum_points = excluded.maximum_points,
      is_correct = excluded.is_correct,
      evaluated_at = excluded.evaluated_at;

    if is_correct then
      earned_points := earned_points + question_row.points;
    end if;
  end loop;

  if question_count = 0 or total_points <= 0 then
    raise exception 'The expired aptitude attempt has no scorable questions.';
  end if;

  score_value := round(earned_points / total_points * 100, 2);
  passed_value := case
    when version_row.passing_score is null then null
    else score_value >= version_row.passing_score
  end;

  update public.aptitude_attempts
  set evaluated_at = now(),
      score = score_value,
      result = jsonb_build_object(
        'reason', 'time_expired',
        'earned_points', earned_points,
        'available_points', total_points,
        'answered_questions', answer_count,
        'question_count', question_count,
        'passed', passed_value
      )
  where workspace_id = attempt_row.workspace_id
    and id = attempt_row.id;
end;
$$;

revoke all on function public.score_expired_aptitude_attempt(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.score_expired_aptitude_attempt(uuid, uuid)
  to service_role;

create or replace function public.score_expired_aptitude_attempt_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'expired' and old.status is distinct from 'expired' then
    perform public.score_expired_aptitude_attempt(new.workspace_id, new.id);
  end if;
  return new;
end;
$$;

revoke all on function public.score_expired_aptitude_attempt_trigger()
  from public, anon, authenticated;

drop trigger if exists aptitude_attempts_score_on_expiry
  on public.aptitude_attempts;
create trigger aptitude_attempts_score_on_expiry
after update of status on public.aptitude_attempts
for each row execute function public.score_expired_aptitude_attempt_trigger();

do $migration$
begin
  if to_regprocedure('public.submit_aptitude_candidate_attempt(text,uuid)') is not null
     and to_regprocedure(
       'public.submit_aptitude_candidate_attempt_before_timeout(text,uuid)'
     ) is null then
    execute 'alter function public.submit_aptitude_candidate_attempt(text, uuid) '
      || 'rename to submit_aptitude_candidate_attempt_before_timeout';
  end if;
end;
$migration$;

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
  submission jsonb;
  attempt_row public.aptitude_attempts%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to submit aptitude attempts.';
  end if;

  submission := public.submit_aptitude_candidate_attempt_before_timeout(
    target_token_hash,
    target_attempt_id
  );
  if submission ->> 'status' is distinct from 'expired' then
    return submission;
  end if;

  select attempt.*
  into attempt_row
  from public.aptitude_attempts attempt
  where attempt.id = target_attempt_id;
  if not found then
    raise exception 'The aptitude attempt was not found after timeout scoring.';
  end if;
  if attempt_row.score is null then
    perform public.score_expired_aptitude_attempt(
      attempt_row.workspace_id,
      attempt_row.id
    );
    select attempt.*
    into attempt_row
    from public.aptitude_attempts attempt
    where attempt.id = target_attempt_id;
  end if;

  return submission || jsonb_build_object(
    'score', attempt_row.score,
    'result', attempt_row.result
  );
end;
$$;

revoke all on function public.submit_aptitude_candidate_attempt(text, uuid)
  from public, anon, authenticated;
grant execute on function public.submit_aptitude_candidate_attempt(text, uuid)
  to service_role;

commit;
