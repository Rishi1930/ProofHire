-- Technical interview engine.
--
-- Replaces the removed aptitude module with a two-phase interview:
--   1. technical questions answered in the browser, autosaved server-side;
--   2. a proctored coding session evaluated by the ProofHire runner worker.
--
-- Candidates never receive table grants. Every candidate action goes through a
-- security-definer RPC that resolves an opaque, hashed, expiring token. Hidden
-- test cases and submitted source stay in proofhire_private and are only
-- visible through service-role worker RPCs.

begin;

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Question bank (recruiter authored, per job)
-- ---------------------------------------------------------------------------

create table if not exists public.interview_questions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  job_id uuid not null,
  display_order integer not null check (display_order between 1 and 100),
  prompt text not null check (char_length(trim(prompt)) between 5 and 2000),
  category text not null default 'general'
    check (char_length(trim(category)) between 1 and 120),
  expected_keywords text[] not null default '{}'::text[]
    check (array_length(expected_keywords, 1) is null or array_length(expected_keywords, 1) <= 20),
  max_points numeric(6, 2) not null default 5 check (max_points > 0 and max_points <= 100),
  is_active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint interview_questions_job_fk
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,
  constraint interview_questions_workspace_id_unique unique (workspace_id, id),
  constraint interview_questions_order_unique unique (workspace_id, job_id, display_order)
);

create index if not exists idx_interview_questions_job_active
  on public.interview_questions(workspace_id, job_id, is_active, display_order);

-- ---------------------------------------------------------------------------
-- Sessions
-- ---------------------------------------------------------------------------

create table if not exists public.interview_sessions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  job_id uuid not null,
  access_token_hash text not null check (access_token_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'ready' check (
    status in (
      'ready',
      'in_progress',
      'questions_submitted',
      'coding',
      'submitted',
      'completed',
      'expired',
      'cancelled'
    )
  ),
  questions_time_limit_seconds integer not null default 1200
    check (questions_time_limit_seconds between 60 and 14400),
  coding_time_limit_seconds integer not null default 3600
    check (coding_time_limit_seconds between 300 and 21600),
  started_at timestamptz,
  questions_started_at timestamptz,
  questions_deadline timestamptz,
  questions_submitted_at timestamptz,
  coding_started_at timestamptz,
  coding_deadline timestamptz,
  submitted_at timestamptz,
  completed_at timestamptz,
  questions_score numeric(5, 2) check (questions_score is null or questions_score between 0 and 100),
  coding_score numeric(5, 2) check (coding_score is null or coding_score between 0 and 100),
  total_score numeric(5, 2) check (total_score is null or total_score between 0 and 100),
  passing_score numeric(5, 2) not null default 60 check (passing_score between 0 and 100),
  proctor_violations integer not null default 0 check (proctor_violations >= 0),
  flagged boolean not null default false,
  cancel_reason text check (cancel_reason is null or char_length(cancel_reason) <= 500),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint interview_sessions_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint interview_sessions_job_fk
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,
  constraint interview_sessions_workspace_id_unique unique (workspace_id, id),
  constraint interview_sessions_token_unique unique (access_token_hash)
);

create index if not exists idx_interview_sessions_application
  on public.interview_sessions(workspace_id, application_id, created_at desc);
create index if not exists idx_interview_sessions_status
  on public.interview_sessions(workspace_id, status);

create table if not exists public.interview_session_questions (
  workspace_id uuid not null,
  session_id uuid not null,
  question_id uuid not null,
  display_order integer not null check (display_order between 1 and 100),
  prompt_snapshot text not null,
  category_snapshot text not null default 'general',
  max_points numeric(6, 2) not null check (max_points > 0),
  awarded_points numeric(6, 2) check (awarded_points is null or awarded_points >= 0),
  reviewer_comment text check (reviewer_comment is null or char_length(reviewer_comment) <= 2000),
  primary key (session_id, question_id),
  constraint interview_session_questions_session_fk
    foreign key (workspace_id, session_id)
    references public.interview_sessions(workspace_id, id)
    on delete cascade,
  constraint interview_session_questions_question_fk
    foreign key (workspace_id, question_id)
    references public.interview_questions(workspace_id, id)
    on delete restrict
);

create index if not exists idx_interview_session_questions_order
  on public.interview_session_questions(session_id, display_order);

create table if not exists public.interview_answers (
  workspace_id uuid not null,
  session_id uuid not null,
  question_id uuid not null,
  answer_text text not null default ''
    check (octet_length(answer_text) <= 20000),
  saved_at timestamptz not null default now(),
  primary key (session_id, question_id),
  constraint interview_answers_session_fk
    foreign key (workspace_id, session_id)
    references public.interview_sessions(workspace_id, id)
    on delete cascade,
  constraint interview_answers_question_fk
    foreign key (session_id, question_id)
    references public.interview_session_questions(session_id, question_id)
    on delete cascade
);

create table if not exists public.interview_session_challenges (
  workspace_id uuid not null,
  session_id uuid not null,
  challenge_version_id uuid not null,
  display_order integer not null check (display_order between 1 and 20),
  points numeric(8, 2) not null default 1 check (points > 0),
  primary key (session_id, challenge_version_id),
  constraint interview_session_challenges_session_fk
    foreign key (workspace_id, session_id)
    references public.interview_sessions(workspace_id, id)
    on delete cascade,
  constraint interview_session_challenges_version_fk
    foreign key (workspace_id, challenge_version_id)
    references public.coding_challenge_versions(workspace_id, id)
    on delete restrict
);

create index if not exists idx_interview_session_challenges_order
  on public.interview_session_challenges(session_id, display_order);

create table if not exists public.interview_code_drafts (
  workspace_id uuid not null,
  session_id uuid not null,
  challenge_version_id uuid not null,
  language text not null check (char_length(trim(language)) between 1 and 40),
  source text not null default '' check (octet_length(source) <= 200000),
  updated_at timestamptz not null default now(),
  primary key (session_id, challenge_version_id),
  constraint interview_code_drafts_session_fk
    foreign key (workspace_id, session_id)
    references public.interview_sessions(workspace_id, id)
    on delete cascade,
  constraint interview_code_drafts_version_fk
    foreign key (session_id, challenge_version_id)
    references public.interview_session_challenges(session_id, challenge_version_id)
    on delete cascade
);

create table if not exists public.interview_code_submissions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  session_id uuid not null,
  challenge_version_id uuid not null,
  submission_number integer not null check (submission_number > 0),
  language text not null check (char_length(trim(language)) between 1 and 40),
  source text not null check (octet_length(source) between 1 and 200000),
  status text not null default 'queued' check (
    status in ('queued', 'evaluating', 'completed', 'failed')
  ),
  score numeric(5, 2) check (score is null or score between 0 and 100),
  passed_tests integer check (passed_tests is null or passed_tests >= 0),
  total_tests integer check (total_tests is null or total_tests >= 0),
  results jsonb,
  error_code text check (error_code is null or char_length(error_code) <= 80),
  lease_token uuid,
  locked_by text,
  locked_until timestamptz,
  submitted_at timestamptz not null default now(),
  evaluated_at timestamptz,
  constraint interview_code_submissions_session_fk
    foreign key (workspace_id, session_id)
    references public.interview_sessions(workspace_id, id)
    on delete cascade,
  constraint interview_code_submissions_challenge_fk
    foreign key (session_id, challenge_version_id)
    references public.interview_session_challenges(session_id, challenge_version_id)
    on delete cascade,
  constraint interview_code_submissions_number_unique
    unique (session_id, challenge_version_id, submission_number)
);

create index if not exists idx_interview_code_submissions_session
  on public.interview_code_submissions(session_id, submitted_at desc);
create index if not exists idx_interview_code_submissions_queue
  on public.interview_code_submissions(status, submitted_at);

create table if not exists public.interview_proctor_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  session_id uuid not null,
  event_type text not null check (
    event_type in (
      'fullscreen_enter',
      'fullscreen_exit',
      'tab_hidden',
      'window_blur',
      'paste',
      'copy',
      'context_menu',
      'network_offline',
      'network_online',
      'resume'
    )
  ),
  severity integer not null default 1 check (severity between 1 and 3),
  metadata jsonb not null default '{}'::jsonb
    check (jsonb_typeof(metadata) = 'object'),
  occurred_at timestamptz not null default now(),
  constraint interview_proctor_events_session_fk
    foreign key (workspace_id, session_id)
    references public.interview_sessions(workspace_id, id)
    on delete cascade
);

create index if not exists idx_interview_proctor_events_session
  on public.interview_proctor_events(session_id, occurred_at);

-- ---------------------------------------------------------------------------
-- Access control
-- ---------------------------------------------------------------------------

alter table public.interview_questions enable row level security;
alter table public.interview_sessions enable row level security;
alter table public.interview_session_questions enable row level security;
alter table public.interview_answers enable row level security;
alter table public.interview_session_challenges enable row level security;
alter table public.interview_code_drafts enable row level security;
alter table public.interview_code_submissions enable row level security;
alter table public.interview_proctor_events enable row level security;

revoke all on public.interview_questions from anon, authenticated;
revoke all on public.interview_sessions from anon, authenticated;
revoke all on public.interview_session_questions from anon, authenticated;
revoke all on public.interview_answers from anon, authenticated;
revoke all on public.interview_session_challenges from anon, authenticated;
revoke all on public.interview_code_drafts from anon, authenticated;
revoke all on public.interview_code_submissions from anon, authenticated;
revoke all on public.interview_proctor_events from anon, authenticated;

grant select, insert, update, delete on public.interview_questions to authenticated;
grant select on public.interview_sessions to authenticated;
grant select on public.interview_session_questions to authenticated;
grant select on public.interview_answers to authenticated;
grant select on public.interview_session_challenges to authenticated;
grant select on public.interview_code_drafts to authenticated;
grant select on public.interview_code_submissions to authenticated;
grant select on public.interview_proctor_events to authenticated;

grant all on public.interview_questions to service_role;
grant all on public.interview_sessions to service_role;
grant all on public.interview_session_questions to service_role;
grant all on public.interview_answers to service_role;
grant all on public.interview_session_challenges to service_role;
grant all on public.interview_code_drafts to service_role;
grant all on public.interview_code_submissions to service_role;
grant all on public.interview_proctor_events to service_role;

drop policy if exists "Members can read interview questions" on public.interview_questions;
create policy "Members can read interview questions"
  on public.interview_questions for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

drop policy if exists "Recruiters can create interview questions" on public.interview_questions;
create policy "Recruiters can create interview questions"
  on public.interview_questions for insert
  to authenticated
  with check (
    public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
    and created_by = auth.uid()
  );

drop policy if exists "Recruiters can update interview questions" on public.interview_questions;
create policy "Recruiters can update interview questions"
  on public.interview_questions for update
  to authenticated
  using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']))
  with check (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

drop policy if exists "Recruiters can delete interview questions" on public.interview_questions;
create policy "Recruiters can delete interview questions"
  on public.interview_questions for delete
  to authenticated
  using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

drop policy if exists "Members can read interview sessions" on public.interview_sessions;
create policy "Members can read interview sessions"
  on public.interview_sessions for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

drop policy if exists "Members can read session questions" on public.interview_session_questions;
create policy "Members can read session questions"
  on public.interview_session_questions for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

drop policy if exists "Members can read interview answers" on public.interview_answers;
create policy "Members can read interview answers"
  on public.interview_answers for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

drop policy if exists "Members can read session challenges" on public.interview_session_challenges;
create policy "Members can read session challenges"
  on public.interview_session_challenges for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

drop policy if exists "Members can read interview code drafts" on public.interview_code_drafts;
create policy "Members can read interview code drafts"
  on public.interview_code_drafts for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

drop policy if exists "Members can read interview code submissions" on public.interview_code_submissions;
create policy "Members can read interview code submissions"
  on public.interview_code_submissions for select
  to authenticated
  using (public.is_workspace_member(workspace_id));

drop policy if exists "Recruiters can read proctor events" on public.interview_proctor_events;
create policy "Recruiters can read proctor events"
  on public.interview_proctor_events for select
  to authenticated
  using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

create or replace function public.interview_token_digest(p_token text)
returns text
language sql
immutable
set search_path = ''
as $$
  select encode(extensions.digest(convert_to(p_token, 'UTF8'), 'sha256'), 'hex')
$$;

-- Resolves an opaque candidate token to a locked session row. Returns null when
-- the token is unknown. Expires the session when its phase deadline has passed.
create or replace function public.interview_session_for_token(p_token text)
returns public.interview_sessions
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
begin
  if p_token is null or char_length(p_token) < 32 or char_length(p_token) > 200 then
    return null;
  end if;

  select * into session_row
  from public.interview_sessions
  where access_token_hash = public.interview_token_digest(p_token)
  for update;

  if not found then
    return null;
  end if;

  if session_row.status in ('submitted', 'completed', 'expired', 'cancelled') then
    return session_row;
  end if;

  if session_row.status = 'in_progress'
     and session_row.questions_deadline is not null
     and now() > session_row.questions_deadline then
    update public.interview_sessions
       set status = 'expired',
           submitted_at = coalesce(submitted_at, now()),
           updated_at = now()
     where id = session_row.id
     returning * into session_row;
  elsif session_row.status = 'coding'
     and session_row.coding_deadline is not null
     and now() > session_row.coding_deadline then
    update public.interview_sessions
       set status = 'submitted',
           submitted_at = coalesce(submitted_at, now()),
           updated_at = now()
     where id = session_row.id
     returning * into session_row;
  end if;

  return session_row;
end;
$$;

revoke all on function public.interview_session_for_token(text) from public;
revoke all on function public.interview_token_digest(text) from public;

-- ---------------------------------------------------------------------------
-- Candidate RPCs (token mediated)
-- ---------------------------------------------------------------------------

create or replace function public.interview_candidate_state(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
  challenge jsonb;
begin
  session_row := public.interview_session_for_token(p_token);
  if session_row.id is null then
    raise exception 'interview_token_invalid' using errcode = 'P0002';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'challenge_version_id', sc.challenge_version_id,
        'display_order', sc.display_order,
        'points', sc.points,
        'prompt', version.prompt,
        'difficulty', version.difficulty,
        'supported_languages', version.supported_languages,
        'starter_code', version.starter_code,
        'max_execution_seconds', version.max_execution_seconds,
        'draft_language', draft.language,
        'draft_source', draft.source,
        'sample_tests', coalesce(
          (
            select jsonb_agg(
              jsonb_build_object(
                'display_order', test_case.display_order,
                'input_text', test_case.input_text,
                'expected_output', test_case.expected_output
              )
              order by test_case.display_order
            )
            from proofhire_private.coding_test_cases test_case
            where test_case.challenge_version_id = sc.challenge_version_id
              and test_case.is_hidden = false
          ),
          '[]'::jsonb
        )
      )
      order by sc.display_order
    ),
    '[]'::jsonb
  )
  into challenge
  from public.interview_session_challenges sc
  join public.coding_challenge_versions version
    on version.workspace_id = sc.workspace_id
   and version.id = sc.challenge_version_id
  left join public.interview_code_drafts draft
    on draft.session_id = sc.session_id
   and draft.challenge_version_id = sc.challenge_version_id
  where sc.session_id = session_row.id;

  return jsonb_build_object(
    'session_id', session_row.id,
    'status', session_row.status,
    'job_title', (
      select job.title from public.jobs job where job.id = session_row.job_id
    ),
    'candidate_name', (
      select candidate.full_name
      from public.applications application
      join public.candidates candidate
        on candidate.workspace_id = application.workspace_id
       and candidate.id = application.candidate_id
      where application.id = session_row.application_id
    ),
    'questions_time_limit_seconds', session_row.questions_time_limit_seconds,
    'coding_time_limit_seconds', session_row.coding_time_limit_seconds,
    'questions_deadline', session_row.questions_deadline,
    'coding_deadline', session_row.coding_deadline,
    'proctor_violations', session_row.proctor_violations,
    'flagged', session_row.flagged,
    'questions', coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'question_id', sq.question_id,
            'display_order', sq.display_order,
            'prompt', sq.prompt_snapshot,
            'category', sq.category_snapshot,
            'max_points', sq.max_points,
            'answer', coalesce(answer.answer_text, '')
          )
          order by sq.display_order
        )
        from public.interview_session_questions sq
        left join public.interview_answers answer
          on answer.session_id = sq.session_id
         and answer.question_id = sq.question_id
        where sq.session_id = session_row.id
      ),
      '[]'::jsonb
    ),
    'challenges', challenge
  );
end;
$$;

create or replace function public.interview_start(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
begin
  session_row := public.interview_session_for_token(p_token);
  if session_row.id is null then
    raise exception 'interview_token_invalid' using errcode = 'P0002';
  end if;
  if session_row.status = 'ready' then
    update public.interview_sessions
       set status = 'in_progress',
           started_at = now(),
           questions_started_at = now(),
           questions_deadline = now() + make_interval(secs => questions_time_limit_seconds),
           updated_at = now()
     where id = session_row.id
     returning * into session_row;
  end if;

  return jsonb_build_object(
    'status', session_row.status,
    'questions_deadline', session_row.questions_deadline,
    'coding_deadline', session_row.coding_deadline
  );
end;
$$;

create or replace function public.interview_save_answer(
  p_token text,
  p_question_id uuid,
  p_answer text
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
begin
  session_row := public.interview_session_for_token(p_token);
  if session_row.id is null then
    raise exception 'interview_token_invalid' using errcode = 'P0002';
  end if;
  if session_row.status <> 'in_progress' then
    raise exception 'interview_questions_closed' using errcode = 'P0001';
  end if;

  insert into public.interview_answers (workspace_id, session_id, question_id, answer_text, saved_at)
  values (session_row.workspace_id, session_row.id, p_question_id, coalesce(p_answer, ''), now())
  on conflict (session_id, question_id)
  do update set answer_text = excluded.answer_text, saved_at = now();

  return now();
end;
$$;

create or replace function public.interview_submit_questions(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
begin
  session_row := public.interview_session_for_token(p_token);
  if session_row.id is null then
    raise exception 'interview_token_invalid' using errcode = 'P0002';
  end if;
  if session_row.status = 'in_progress' then
    update public.interview_sessions
       set status = 'coding',
           questions_submitted_at = now(),
           coding_started_at = now(),
           coding_deadline = now() + make_interval(secs => coding_time_limit_seconds),
           updated_at = now()
     where id = session_row.id
     returning * into session_row;
  end if;

  return jsonb_build_object(
    'status', session_row.status,
    'coding_deadline', session_row.coding_deadline
  );
end;
$$;

create or replace function public.interview_save_code(
  p_token text,
  p_challenge_version_id uuid,
  p_language text,
  p_source text
)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
begin
  session_row := public.interview_session_for_token(p_token);
  if session_row.id is null then
    raise exception 'interview_token_invalid' using errcode = 'P0002';
  end if;
  if session_row.status <> 'coding' then
    raise exception 'interview_coding_closed' using errcode = 'P0001';
  end if;

  insert into public.interview_code_drafts (
    workspace_id, session_id, challenge_version_id, language, source, updated_at
  )
  values (
    session_row.workspace_id,
    session_row.id,
    p_challenge_version_id,
    p_language,
    coalesce(p_source, ''),
    now()
  )
  on conflict (session_id, challenge_version_id)
  do update set
    language = excluded.language,
    source = excluded.source,
    updated_at = now();

  return now();
end;
$$;

create or replace function public.interview_submit_code(
  p_token text,
  p_challenge_version_id uuid,
  p_language text,
  p_source text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
  next_number integer;
  submission_id uuid;
begin
  session_row := public.interview_session_for_token(p_token);
  if session_row.id is null then
    raise exception 'interview_token_invalid' using errcode = 'P0002';
  end if;
  if session_row.status <> 'coding' then
    raise exception 'interview_coding_closed' using errcode = 'P0001';
  end if;
  if p_source is null or char_length(trim(p_source)) = 0 then
    raise exception 'interview_code_empty' using errcode = 'P0001';
  end if;

  perform public.interview_save_code(p_token, p_challenge_version_id, p_language, p_source);

  select coalesce(max(submission_number), 0) + 1
  into next_number
  from public.interview_code_submissions
  where session_id = session_row.id
    and challenge_version_id = p_challenge_version_id;

  insert into public.interview_code_submissions (
    workspace_id, session_id, challenge_version_id, submission_number, language, source
  )
  values (
    session_row.workspace_id,
    session_row.id,
    p_challenge_version_id,
    next_number,
    p_language,
    p_source
  )
  returning id into submission_id;

  return submission_id;
end;
$$;

create or replace function public.interview_finish(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
begin
  session_row := public.interview_session_for_token(p_token);
  if session_row.id is null then
    raise exception 'interview_token_invalid' using errcode = 'P0002';
  end if;

  if session_row.status in ('in_progress', 'coding') then
    update public.interview_sessions
       set status = 'submitted',
           submitted_at = coalesce(submitted_at, now()),
           updated_at = now()
     where id = session_row.id
     returning * into session_row;
  end if;

  return jsonb_build_object('status', session_row.status);
end;
$$;

create or replace function public.interview_record_proctor_event(
  p_token text,
  p_event_type text,
  p_metadata jsonb default '{}'::jsonb
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
  event_severity integer;
  violations integer;
begin
  session_row := public.interview_session_for_token(p_token);
  if session_row.id is null then
    raise exception 'interview_token_invalid' using errcode = 'P0002';
  end if;
  if session_row.status not in ('in_progress', 'coding') then
    return session_row.proctor_violations;
  end if;

  event_severity := case
    when p_event_type in ('paste', 'copy', 'context_menu') then 2
    when p_event_type in ('fullscreen_exit', 'tab_hidden', 'window_blur') then 3
    else 1
  end;

  insert into public.interview_proctor_events (
    workspace_id, session_id, event_type, severity, metadata
  )
  values (
    session_row.workspace_id,
    session_row.id,
    p_event_type,
    event_severity,
    coalesce(p_metadata, '{}'::jsonb)
  );

  if event_severity = 3 then
    update public.interview_sessions
       set proctor_violations = proctor_violations + 1,
           flagged = flagged or (proctor_violations + 1) >= 3,
           updated_at = now()
     where id = session_row.id
     returning proctor_violations into violations;
    return violations;
  end if;

  return session_row.proctor_violations;
end;
$$;

-- ---------------------------------------------------------------------------
-- Recruiter RPCs (caller token, RLS-safe)
-- ---------------------------------------------------------------------------

create or replace function public.create_interview_session(
  p_application_id uuid,
  p_question_ids uuid[],
  p_challenge_version_ids uuid[],
  p_questions_time_limit_seconds integer default 1200,
  p_coding_time_limit_seconds integer default 3600,
  p_passing_score numeric default 60
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_row record;
  raw_token text;
  new_session_id uuid;
  question_count integer;
  inserted_questions integer;
  inserted_challenges integer;
begin
  if auth.uid() is null then
    raise exception 'unauthorized' using errcode = '42501';
  end if;

  select application.id, application.workspace_id, application.job_id
  into application_row
  from public.applications application
  where application.id = p_application_id;

  if application_row.id is null then
    raise exception 'application_not_found' using errcode = 'P0002';
  end if;
  if not public.has_workspace_role(
    application_row.workspace_id,
    array['owner', 'admin', 'recruiter']
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  question_count := coalesce(cardinality(p_question_ids), 0);
  if question_count = 0 and coalesce(cardinality(p_challenge_version_ids), 0) = 0 then
    raise exception 'interview_needs_questions_or_challenges' using errcode = 'P0001';
  end if;

  raw_token := encode(extensions.gen_random_bytes(32), 'hex');

  insert into public.interview_sessions (
    workspace_id,
    application_id,
    job_id,
    access_token_hash,
    questions_time_limit_seconds,
    coding_time_limit_seconds,
    passing_score,
    created_by
  )
  values (
    application_row.workspace_id,
    application_row.id,
    application_row.job_id,
    public.interview_token_digest(raw_token),
    greatest(60, least(coalesce(p_questions_time_limit_seconds, 1200), 14400)),
    greatest(300, least(coalesce(p_coding_time_limit_seconds, 3600), 21600)),
    greatest(0, least(coalesce(p_passing_score, 60), 100)),
    auth.uid()
  )
  returning id into new_session_id;

  insert into public.interview_session_questions (
    workspace_id, session_id, question_id, display_order,
    prompt_snapshot, category_snapshot, max_points
  )
  select
    application_row.workspace_id,
    new_session_id,
    question.id,
    row_number() over (order by question.display_order, question.created_at),
    question.prompt,
    question.category,
    question.max_points
  from public.interview_questions question
  where question.workspace_id = application_row.workspace_id
    and question.job_id = application_row.job_id
    and question.id = any (coalesce(p_question_ids, array[]::uuid[]))
    and question.is_active;

  insert into public.interview_session_challenges (
    workspace_id, session_id, challenge_version_id, display_order, points
  )
  select
    application_row.workspace_id,
    new_session_id,
    version.id,
    row_number() over (order by version.id),
    version.points
  from public.coding_challenge_versions version
  where version.workspace_id = application_row.workspace_id
    and version.id = any (coalesce(p_challenge_version_ids, array[]::uuid[]))
    and version.version_status = 'published';

  select count(*) into inserted_questions
  from public.interview_session_questions
  where session_id = new_session_id;

  select count(*) into inserted_challenges
  from public.interview_session_challenges
  where session_id = new_session_id;

  return jsonb_build_object(
    'session_id', new_session_id,
    'token', raw_token,
    'questions', inserted_questions,
    'challenges', inserted_challenges
  );
end;
$$;

create or replace function public.interview_session_overview(
  p_workspace_id uuid,
  p_application_ids uuid[] default null
)
returns table (
  session_id uuid,
  application_id uuid,
  job_id uuid,
  job_title text,
  candidate_name text,
  status text,
  questions_deadline timestamptz,
  coding_deadline timestamptz,
  submitted_at timestamptz,
  questions_score numeric,
  coding_score numeric,
  total_score numeric,
  passing_score numeric,
  proctor_violations integer,
  flagged boolean,
  pending_submissions bigint,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    session.id,
    session.application_id,
    session.job_id,
    job.title,
    candidate.full_name,
    session.status,
    session.questions_deadline,
    session.coding_deadline,
    session.submitted_at,
    session.questions_score,
    session.coding_score,
    session.total_score,
    session.passing_score,
    session.proctor_violations,
    session.flagged,
    (
      select count(*)
      from public.interview_code_submissions submission
      where submission.session_id = session.id
        and submission.status in ('queued', 'evaluating')
    ),
    session.created_at
  from public.interview_sessions session
  join public.jobs job on job.id = session.job_id
  join public.applications application on application.id = session.application_id
  join public.candidates candidate
    on candidate.workspace_id = application.workspace_id
   and candidate.id = application.candidate_id
  where session.workspace_id = p_workspace_id
    and public.has_workspace_role(
      p_workspace_id,
      array['owner', 'admin', 'recruiter', 'viewer']
    )
    and (
      p_application_ids is null
      or session.application_id = any (p_application_ids)
    )
  order by session.created_at desc
$$;

create or replace function public.score_interview_questions(
  p_session_id uuid,
  p_scores jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
  total_awarded numeric := 0;
  total_possible numeric := 0;
  coding numeric;
  questions_score numeric;
begin
  select * into session_row
  from public.interview_sessions
  where id = p_session_id;

  if session_row.id is null then
    raise exception 'interview_session_not_found' using errcode = 'P0002';
  end if;
  if not public.has_workspace_role(
    session_row.workspace_id,
    array['owner', 'admin', 'recruiter']
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if session_row.status not in ('submitted', 'completed') then
    raise exception 'interview_not_submitted' using errcode = 'P0001';
  end if;

  update public.interview_session_questions question
     set awarded_points = least(
           question.max_points,
           greatest(0, coalesce((p_scores ->> question.question_id::text)::numeric, 0))
         ),
         reviewer_comment = nullif(p_scores ->> (question.question_id::text || '_comment'), '')
   where question.session_id = session_row.id;

  select coalesce(sum(awarded_points), 0), coalesce(sum(max_points), 0)
  into total_awarded, total_possible
  from public.interview_session_questions
  where session_id = session_row.id;

  questions_score := case
    when total_possible > 0 then round(total_awarded / total_possible * 100, 2)
    else null
  end;

  coding := session_row.coding_score;

  update public.interview_sessions
     set questions_score = questions_score,
         total_score = case
           when questions_score is not null and coding is not null
             then round((questions_score + coding) / 2, 2)
           else coalesce(questions_score, coding)
         end,
         status = 'completed',
         completed_at = coalesce(completed_at, now()),
         updated_at = now()
   where id = session_row.id
   returning * into session_row;

  return jsonb_build_object(
    'questions_score', session_row.questions_score,
    'coding_score', session_row.coding_score,
    'total_score', session_row.total_score,
    'passed', session_row.total_score is not null
      and session_row.total_score >= session_row.passing_score
  );
end;
$$;

create or replace function public.cancel_interview_session(
  p_session_id uuid,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  session_row public.interview_sessions;
begin
  select * into session_row from public.interview_sessions where id = p_session_id;
  if session_row.id is null then
    raise exception 'interview_session_not_found' using errcode = 'P0002';
  end if;
  if not public.has_workspace_role(
    session_row.workspace_id,
    array['owner', 'admin', 'recruiter']
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if session_row.status in ('completed', 'cancelled') then
    return;
  end if;

  update public.interview_sessions
     set status = 'cancelled',
         cancel_reason = nullif(left(coalesce(p_reason, ''), 500), ''),
         updated_at = now()
   where id = session_row.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Worker RPCs (service role only)
-- ---------------------------------------------------------------------------

create or replace function public.claim_interview_code_submissions(
  p_worker_id text,
  p_lease_seconds integer default 120
)
returns table (
  submission_id uuid,
  lease_token uuid,
  workspace_id uuid,
  session_id uuid,
  challenge_version_id uuid,
  language text,
  source text,
  max_execution_seconds integer,
  tests jsonb
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with claimed as (
    select submission.id
    from public.interview_code_submissions submission
    where submission.status = 'queued'
       or (
         submission.status = 'evaluating'
         and submission.locked_until is not null
         and submission.locked_until < now()
       )
    order by submission.submitted_at
    for update skip locked
    limit 1
  )
  update public.interview_code_submissions submission
     set status = 'evaluating',
         lease_token = gen_random_uuid(),
         locked_by = left(coalesce(p_worker_id, 'worker'), 120),
         locked_until = now() + make_interval(
           secs => greatest(30, least(coalesce(p_lease_seconds, 120), 900))
         )
   where submission.id in (select id from claimed)
  returning
    submission.id,
    submission.lease_token,
    submission.workspace_id,
    submission.session_id,
    submission.challenge_version_id,
    submission.language,
    submission.source,
    (
      select version.max_execution_seconds
      from public.coding_challenge_versions version
      where version.id = submission.challenge_version_id
    ),
    coalesce(
      (
        select jsonb_agg(
          jsonb_build_object(
            'display_order', test_case.display_order,
            'input_text', test_case.input_text,
            'expected_output', test_case.expected_output,
            'points', test_case.points
          )
          order by test_case.display_order
        )
        from proofhire_private.coding_test_cases test_case
        where test_case.challenge_version_id = submission.challenge_version_id
      ),
      '[]'::jsonb
    );
end;
$$;

create or replace function public.complete_interview_code_submission(
  p_submission_id uuid,
  p_lease_token uuid,
  p_status text,
  p_score numeric,
  p_passed_tests integer,
  p_total_tests integer,
  p_results jsonb,
  p_error_code text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  submission_row public.interview_code_submissions;
  session_coding_score numeric;
begin
  select * into submission_row
  from public.interview_code_submissions
  where id = p_submission_id
  for update;

  if submission_row.id is null then
    raise exception 'submission_not_found' using errcode = 'P0002';
  end if;
  if submission_row.lease_token is distinct from p_lease_token then
    raise exception 'submission_lease_mismatch' using errcode = 'P0001';
  end if;
  if p_status not in ('completed', 'failed') then
    raise exception 'invalid_submission_status' using errcode = 'P0001';
  end if;

  update public.interview_code_submissions
     set status = p_status,
         score = case when p_status = 'completed'
                      then greatest(0, least(coalesce(p_score, 0), 100))
                      else null end,
         passed_tests = p_passed_tests,
         total_tests = p_total_tests,
         results = p_results,
         error_code = p_error_code,
         evaluated_at = now(),
         lease_token = null,
         locked_by = null,
         locked_until = null
   where id = submission_row.id;

  select round(avg(score), 2)
  into session_coding_score
  from public.interview_code_submissions
  where session_id = submission_row.session_id
    and status = 'completed';

  update public.interview_sessions
     set coding_score = session_coding_score,
         total_score = case
           when questions_score is not null and session_coding_score is not null
             then round((questions_score + session_coding_score) / 2, 2)
           else coalesce(questions_score, session_coding_score)
         end,
         updated_at = now()
   where id = submission_row.session_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Function grants
-- ---------------------------------------------------------------------------

revoke all on function public.interview_candidate_state(text) from public;
revoke all on function public.interview_start(text) from public;
revoke all on function public.interview_save_answer(text, uuid, text) from public;
revoke all on function public.interview_submit_questions(text) from public;
revoke all on function public.interview_save_code(text, uuid, text, text) from public;
revoke all on function public.interview_submit_code(text, uuid, text, text) from public;
revoke all on function public.interview_finish(text) from public;
revoke all on function public.interview_record_proctor_event(text, text, jsonb) from public;
revoke all on function public.create_interview_session(uuid, uuid[], uuid[], integer, integer, numeric) from public;
revoke all on function public.interview_session_overview(uuid, uuid[]) from public;
revoke all on function public.score_interview_questions(uuid, jsonb) from public;
revoke all on function public.cancel_interview_session(uuid, text) from public;
revoke all on function public.claim_interview_code_submissions(text, integer) from public;
revoke all on function public.complete_interview_code_submission(uuid, uuid, text, numeric, integer, integer, jsonb, text) from public;

grant execute on function public.interview_candidate_state(text) to anon, authenticated;
grant execute on function public.interview_start(text) to anon, authenticated;
grant execute on function public.interview_save_answer(text, uuid, text) to anon, authenticated;
grant execute on function public.interview_submit_questions(text) to anon, authenticated;
grant execute on function public.interview_save_code(text, uuid, text, text) to anon, authenticated;
grant execute on function public.interview_submit_code(text, uuid, text, text) to anon, authenticated;
grant execute on function public.interview_finish(text) to anon, authenticated;
grant execute on function public.interview_record_proctor_event(text, text, jsonb) to anon, authenticated;

grant execute on function public.create_interview_session(uuid, uuid[], uuid[], integer, integer, numeric) to authenticated;
grant execute on function public.interview_session_overview(uuid, uuid[]) to authenticated;
grant execute on function public.score_interview_questions(uuid, jsonb) to authenticated;
grant execute on function public.cancel_interview_session(uuid, text) to authenticated;

grant execute on function public.claim_interview_code_submissions(text, integer) to service_role;
grant execute on function public.complete_interview_code_submission(uuid, uuid, text, numeric, integer, integer, jsonb, text) to service_role;

-- One active session per application keeps candidate links unambiguous.
create unique index if not exists idx_interview_sessions_one_active
  on public.interview_sessions(workspace_id, application_id)
  where status in ('ready', 'in_progress', 'questions_submitted', 'coding', 'submitted');

commit;
