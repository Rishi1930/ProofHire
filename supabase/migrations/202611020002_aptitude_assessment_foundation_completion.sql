-- Complete the existing aptitude foundation with job configuration,
-- per-attempt question ordering, question-level scores, and recruiter metadata.

begin;

alter table public.aptitude_questions
  add column if not exists category text not null default 'general',
  add column if not exists difficulty text not null default 'medium';

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_questions'::regclass
      and conname = 'aptitude_questions_category_check'
  ) then
    alter table public.aptitude_questions
      add constraint aptitude_questions_category_check
      check (char_length(trim(category)) between 1 and 120);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_questions'::regclass
      and conname = 'aptitude_questions_difficulty_check'
  ) then
    alter table public.aptitude_questions
      add constraint aptitude_questions_difficulty_check
      check (difficulty in ('beginner', 'medium', 'advanced', 'expert'));
  end if;
end;
$migration$;

create table if not exists public.job_aptitude_assessments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  job_id uuid not null,
  test_version_id uuid not null,
  is_required boolean not null default false,
  display_order integer not null default 1 check (display_order > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_aptitude_assessments_job_fk
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,
  constraint job_aptitude_assessments_version_fk
    foreign key (workspace_id, test_version_id)
    references public.aptitude_test_versions(workspace_id, id)
    on delete restrict,
  constraint job_aptitude_assessments_job_version_unique
    unique (workspace_id, job_id, test_version_id),
  constraint job_aptitude_assessments_workspace_id_unique
    unique (workspace_id, id),
  constraint job_aptitude_assessments_invitation_key_unique
    unique (workspace_id, id, job_id, test_version_id)
);

create index if not exists idx_job_aptitude_assessments_job_order
  on public.job_aptitude_assessments(workspace_id, job_id, display_order);

drop trigger if exists job_aptitude_assessments_set_updated_at
  on public.job_aptitude_assessments;
create trigger job_aptitude_assessments_set_updated_at
before update on public.job_aptitude_assessments
for each row execute function public.set_updated_at();

alter table public.job_aptitude_assessments enable row level security;

create policy "Workspace members can read job aptitude assessments"
on public.job_aptitude_assessments
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can manage job aptitude assessments"
on public.job_aptitude_assessments
for all to authenticated
using (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = job_aptitude_assessments.workspace_id
      and version.id = job_aptitude_assessments.test_version_id
      and version.version_status = 'published'
  )
)
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and (created_by is null or created_by = (select auth.uid()))
  and exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = job_aptitude_assessments.workspace_id
      and version.id = job_aptitude_assessments.test_version_id
      and version.version_status = 'published'
  )
);

revoke all on public.job_aptitude_assessments from public, anon, authenticated;
grant select, insert, update, delete
  on public.job_aptitude_assessments to authenticated;
grant all on public.job_aptitude_assessments to service_role;

alter table public.aptitude_invitations
  add column if not exists job_id uuid,
  add column if not exists job_aptitude_assessment_id uuid;

insert into public.job_aptitude_assessments (
  workspace_id,
  job_id,
  test_version_id,
  is_required,
  display_order,
  created_by
)
select distinct
  application.workspace_id,
  application.job_id,
  invitation.test_version_id,
  false,
  1,
  invitation.invited_by
from public.aptitude_invitations invitation
join public.applications application
  on application.workspace_id = invitation.workspace_id
 and application.id = invitation.application_id
on conflict (workspace_id, job_id, test_version_id) do nothing;

update public.aptitude_invitations invitation
set job_id = application.job_id,
    job_aptitude_assessment_id = configuration.id
from public.applications application
join public.job_aptitude_assessments configuration
  on configuration.workspace_id = application.workspace_id
 and configuration.job_id = application.job_id
where application.workspace_id = invitation.workspace_id
  and application.id = invitation.application_id
  and configuration.test_version_id = invitation.test_version_id
  and (
    invitation.job_id is distinct from application.job_id
    or invitation.job_aptitude_assessment_id is distinct from configuration.id
  );

alter table public.aptitude_invitations
  alter column job_id set not null,
  alter column job_aptitude_assessment_id set not null;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_job_fk'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_job_fk
      foreign key (job_id, workspace_id)
      references public.jobs(id, workspace_id)
      on delete cascade;
  end if;

  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_job_configuration_fk'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_job_configuration_fk
      foreign key (
        workspace_id,
        job_aptitude_assessment_id,
        job_id,
        test_version_id
      )
      references public.job_aptitude_assessments(
        workspace_id,
        id,
        job_id,
        test_version_id
      )
      on delete restrict;
  end if;
end;
$migration$;

create table if not exists public.aptitude_attempt_questions (
  workspace_id uuid not null,
  attempt_id uuid not null,
  test_version_id uuid not null,
  question_id uuid not null,
  display_order integer not null check (display_order > 0),
  assigned_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  constraint aptitude_attempt_questions_attempt_fk
    foreign key (workspace_id, attempt_id, test_version_id)
    references public.aptitude_attempts(workspace_id, id, test_version_id)
    on delete cascade,
  constraint aptitude_attempt_questions_question_fk
    foreign key (workspace_id, test_version_id, question_id)
    references public.aptitude_questions(workspace_id, test_version_id, id)
    on delete cascade,
  constraint aptitude_attempt_questions_order_unique
    unique (attempt_id, display_order),
  constraint aptitude_attempt_questions_workspace_fk_key
    unique (workspace_id, attempt_id, question_id)
);

create index if not exists idx_aptitude_attempt_questions_order
  on public.aptitude_attempt_questions(workspace_id, attempt_id, display_order);

alter table public.aptitude_attempt_questions enable row level security;
revoke all on public.aptitude_attempt_questions from public, anon, authenticated;
grant all on public.aptitude_attempt_questions to service_role;

insert into public.aptitude_attempt_questions (
  workspace_id,
  attempt_id,
  test_version_id,
  question_id,
  display_order
)
select
  attempt.workspace_id,
  attempt.id,
  attempt.test_version_id,
  question.id,
  row_number() over (
    partition by attempt.id
    order by question.display_order, question.id
  )::integer
from public.aptitude_attempts attempt
join public.aptitude_questions question
  on question.workspace_id = attempt.workspace_id
 and question.test_version_id = attempt.test_version_id
on conflict (attempt_id, question_id) do nothing;

create table if not exists proofhire_private.aptitude_answer_scores (
  workspace_id uuid not null,
  attempt_id uuid not null,
  question_id uuid not null,
  earned_points numeric(8, 2) not null check (earned_points >= 0),
  maximum_points numeric(8, 2) not null check (maximum_points > 0),
  is_correct boolean not null,
  evaluated_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  constraint aptitude_answer_scores_attempt_question_fk
    foreign key (workspace_id, attempt_id, question_id)
    references public.aptitude_attempt_questions(workspace_id, attempt_id, question_id)
    on delete cascade,
  constraint aptitude_answer_scores_points_check
    check (earned_points <= maximum_points)
);

alter table proofhire_private.aptitude_answer_scores enable row level security;
revoke all on proofhire_private.aptitude_answer_scores
  from public, anon, authenticated;
grant all on proofhire_private.aptitude_answer_scores to service_role;

alter table public.aptitude_attempts
  add column if not exists evaluated_at timestamptz;

insert into proofhire_private.aptitude_answer_scores (
  workspace_id,
  attempt_id,
  question_id,
  earned_points,
  maximum_points,
  is_correct,
  evaluated_at
)
select
  attempt.workspace_id,
  attempt.id,
  question.id,
  case when correctness.is_correct then question.points else 0 end,
  question.points,
  correctness.is_correct,
  coalesce(attempt.evaluated_at, attempt.submitted_at, now())
from public.aptitude_attempts attempt
join public.aptitude_attempt_questions assignment
  on assignment.workspace_id = attempt.workspace_id
 and assignment.attempt_id = attempt.id
join public.aptitude_questions question
  on question.workspace_id = assignment.workspace_id
 and question.test_version_id = assignment.test_version_id
 and question.id = assignment.question_id
join proofhire_private.aptitude_answer_keys answer_key
  on answer_key.workspace_id = question.workspace_id
 and answer_key.question_id = question.id
left join public.aptitude_answers answer
  on answer.workspace_id = attempt.workspace_id
 and answer.attempt_id = attempt.id
 and answer.question_id = question.id
cross join lateral (
  select case
    when answer.answer is null then false
    when question.question_type in ('single_choice', 'multiple_choice') then
      (
        select coalesce(
          array_agg(selected.value order by selected.value),
          array[]::text[]
        )
        from jsonb_array_elements_text(
          coalesce(answer.answer -> 'option_ids', '[]'::jsonb)
        ) as selected(value)
      ) = (
        select coalesce(
          array_agg(selected.value order by selected.value),
          array[]::text[]
        )
        from jsonb_array_elements_text(answer_key.answer_key -> 'option_ids')
          as selected(value)
      )
    else exists (
      select 1
      from jsonb_array_elements_text(
        answer_key.answer_key -> 'accepted_answers'
      ) as accepted(value)
      where lower(trim(accepted.value)) =
        lower(trim(answer.answer #>> '{}'))
    )
  end as is_correct
) correctness
where attempt.status = 'submitted'
on conflict (attempt_id, question_id) do nothing;

create or replace function public.validate_aptitude_invitation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.aptitude_test_versions%rowtype;
  application_job_id uuid;
  configuration_id uuid;
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

  select configuration.id
  into configuration_id
  from public.job_aptitude_assessments configuration
  where configuration.workspace_id = new.workspace_id
    and configuration.job_id = application_job_id
    and configuration.test_version_id = new.test_version_id;
  if configuration_id is null then
    raise exception 'The job aptitude configuration could not be established.';
  end if;
  new.job_aptitude_assessment_id := configuration_id;
  return new;
end;
$$;

revoke all on function public.validate_aptitude_invitation()
  from public, anon, authenticated;

drop trigger if exists aptitude_invitations_require_published_version
  on public.aptitude_invitations;
create trigger aptitude_invitations_require_published_version
before insert or update of workspace_id, application_id, test_version_id,
  max_attempts, expires_at
on public.aptitude_invitations
for each row execute function public.validate_aptitude_invitation();

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
        'display_order', question_order.display_order,
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
      order by question_order.display_order
    ),
    '[]'::jsonb
  )
  into question_list
  from (
    select assignment.question_id, assignment.display_order
    from public.aptitude_attempt_questions assignment
    where active_attempt.id is not null
      and assignment.workspace_id = invitation_row.workspace_id
      and assignment.attempt_id = active_attempt.id
    union all
    select question.id, question.display_order
    from public.aptitude_questions question
    where active_attempt.id is null
      and question.workspace_id = invitation_row.workspace_id
      and question.test_version_id = invitation_row.test_version_id
  ) question_order
  join public.aptitude_questions question
    on question.workspace_id = invitation_row.workspace_id
   and question.test_version_id = invitation_row.test_version_id
   and question.id = question_order.question_id;

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
    question.id,
    row_number() over (order by random(), question.id)::integer
  from public.aptitude_questions question
  where question.workspace_id = invitation_row.workspace_id
    and question.test_version_id = invitation_row.test_version_id;

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
  join public.aptitude_attempt_questions assignment
    on assignment.workspace_id = question.workspace_id
   and assignment.test_version_id = question.test_version_id
   and assignment.question_id = question.id
   and assignment.attempt_id = attempt_row.id
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
  question_earned_points numeric;
  answer_count integer := 0;
  question_count integer := 0;
  has_answer boolean;
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
  if not found then
    raise exception 'The aptitude test version was not found.';
  end if;
  if attempt_row.started_at + make_interval(secs => version_row.time_limit_seconds) <= now()
     or invitation_row.expires_at <= now() then
    update public.aptitude_attempts
    set status = 'expired',
        submitted_at = now(),
        evaluated_at = now(),
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
    from public.aptitude_attempt_questions assignment
    join public.aptitude_questions question
      on question.workspace_id = assignment.workspace_id
     and question.test_version_id = assignment.test_version_id
     and question.id = assignment.question_id
    join proofhire_private.aptitude_answer_keys answer_key
      on answer_key.workspace_id = question.workspace_id
     and answer_key.question_id = question.id
    where assignment.workspace_id = invitation_row.workspace_id
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

    question_earned_points := case
      when is_correct then question_row.points
      else 0
    end;
    earned_points := earned_points + question_earned_points;
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
      question_earned_points,
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
  end loop;

  if question_count = 0 then
    raise exception 'The aptitude attempt has no assigned questions.';
  end if;
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
      evaluated_at = now(),
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

create or replace function public.get_aptitude_attempt_question_scores(
  target_workspace_id uuid,
  target_attempt_id uuid
)
returns table (
  question_id uuid,
  display_order integer,
  category text,
  difficulty text,
  earned_points numeric,
  maximum_points numeric,
  is_correct boolean,
  evaluated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.has_workspace_role(
    target_workspace_id,
    array['owner', 'admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to read aptitude question scores.';
  end if;
  if not exists (
    select 1
    from public.aptitude_attempts attempt
    where attempt.workspace_id = target_workspace_id
      and attempt.id = target_attempt_id
  ) then
    raise exception 'The aptitude attempt was not found.';
  end if;
  return query
  select
    assignment.question_id,
    assignment.display_order,
    question.category,
    question.difficulty,
    score.earned_points,
    score.maximum_points,
    score.is_correct,
    score.evaluated_at
  from public.aptitude_attempt_questions assignment
  join public.aptitude_questions question
    on question.workspace_id = assignment.workspace_id
   and question.test_version_id = assignment.test_version_id
   and question.id = assignment.question_id
  left join proofhire_private.aptitude_answer_scores score
    on score.workspace_id = assignment.workspace_id
   and score.attempt_id = assignment.attempt_id
   and score.question_id = assignment.question_id
  where assignment.workspace_id = target_workspace_id
    and assignment.attempt_id = target_attempt_id
  order by assignment.display_order;
end;
$$;

revoke all on function public.get_aptitude_attempt_question_scores(uuid, uuid)
  from public, anon;
grant execute on function public.get_aptitude_attempt_question_scores(uuid, uuid)
  to authenticated;

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

commit;
