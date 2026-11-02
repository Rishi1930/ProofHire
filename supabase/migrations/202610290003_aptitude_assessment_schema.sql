-- Versioned aptitude assessments. Candidate-facing access is intentionally
-- service-mediated; answer keys and candidate answers are never exposed via
-- authenticated or anonymous table access.

begin;

create schema if not exists proofhire_private;
revoke all on schema proofhire_private from public, anon, authenticated;
grant usage on schema proofhire_private to service_role;

create table if not exists public.aptitude_tests (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null
    references public.workspaces(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 180),
  description text check (description is null or char_length(description) <= 5000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_tests_workspace_id_unique unique (workspace_id, id)
);

create table if not exists public.aptitude_test_versions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  test_id uuid not null,
  version_number integer not null check (version_number > 0),
  version_title text not null
    check (char_length(trim(version_title)) between 1 and 180),
  version_description text
    check (version_description is null or char_length(version_description) <= 5000),
  version_status text not null default 'draft'
    check (version_status in ('draft', 'published')),
  time_limit_seconds integer not null
    check (time_limit_seconds between 60 and 21600),
  max_attempts integer not null default 1
    check (max_attempts between 1 and 5),
  passing_score numeric(5, 2)
    check (passing_score is null or passing_score between 0 and 100),
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_test_versions_test_fk
    foreign key (workspace_id, test_id)
    references public.aptitude_tests(workspace_id, id)
    on delete cascade,
  constraint aptitude_test_versions_test_number_unique
    unique (test_id, version_number),
  constraint aptitude_test_versions_workspace_id_unique
    unique (workspace_id, id),
  constraint aptitude_test_versions_publication_timestamp_check
    check (
      (version_status = 'draft' and published_at is null)
      or (version_status = 'published' and published_at is not null)
    )
);

create table if not exists public.aptitude_questions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  test_version_id uuid not null,
  display_order integer not null check (display_order > 0),
  question_type text not null
    check (question_type in ('single_choice', 'multiple_choice', 'short_text')),
  prompt text not null check (char_length(trim(prompt)) between 1 and 10000),
  points numeric(6, 2) not null default 1 check (points > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_questions_version_fk
    foreign key (workspace_id, test_version_id)
    references public.aptitude_test_versions(workspace_id, id)
    on delete cascade,
  constraint aptitude_questions_version_order_unique
    unique (test_version_id, display_order),
  constraint aptitude_questions_workspace_id_unique
    unique (workspace_id, id),
  constraint aptitude_questions_workspace_version_id_unique
    unique (workspace_id, test_version_id, id)
);

create table if not exists public.aptitude_question_options (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  question_id uuid not null,
  display_order integer not null check (display_order > 0),
  option_text text not null
    check (char_length(trim(option_text)) between 1 and 2000),
  created_at timestamptz not null default now(),
  constraint aptitude_question_options_question_fk
    foreign key (workspace_id, question_id)
    references public.aptitude_questions(workspace_id, id)
    on delete cascade,
  constraint aptitude_question_options_question_order_unique
    unique (question_id, display_order),
  constraint aptitude_question_options_workspace_id_unique
    unique (workspace_id, id)
);

create table if not exists proofhire_private.aptitude_answer_keys (
  workspace_id uuid not null,
  question_id uuid not null,
  answer_key jsonb not null
    check (jsonb_typeof(answer_key) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (workspace_id, question_id),
  constraint aptitude_answer_keys_question_fk
    foreign key (workspace_id, question_id)
    references public.aptitude_questions(workspace_id, id)
    on delete cascade
);

create table if not exists public.aptitude_invitations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  test_version_id uuid not null,
  candidate_email text not null
    check (
      char_length(candidate_email) between 3 and 320
      and candidate_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),
  token_hash text not null
    check (token_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check (status in ('pending', 'sent', 'started', 'completed', 'expired', 'revoked', 'failed')),
  email_status text not null default 'queued'
    check (email_status in ('queued', 'sent', 'delivered', 'failed')),
  email_provider_message_id text,
  email_error_code text,
  expires_at timestamptz not null,
  max_attempts integer not null default 1
    check (max_attempts between 1 and 5),
  invited_by uuid references auth.users(id) on delete set null,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_invitations_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint aptitude_invitations_version_fk
    foreign key (workspace_id, test_version_id)
    references public.aptitude_test_versions(workspace_id, id)
    on delete restrict,
  constraint aptitude_invitations_token_hash_unique unique (token_hash),
  constraint aptitude_invitations_workspace_id_version_unique
    unique (workspace_id, id, test_version_id)
);

create table if not exists public.aptitude_attempts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  invitation_id uuid not null,
  test_version_id uuid not null,
  attempt_number integer not null check (attempt_number between 1 and 5),
  status text not null default 'in_progress'
    check (status in ('in_progress', 'submitted', 'expired', 'abandoned')),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  score numeric(5, 2) check (score is null or score between 0 and 100),
  result jsonb check (result is null or jsonb_typeof(result) = 'object'),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint aptitude_attempts_invitation_fk
    foreign key (workspace_id, invitation_id, test_version_id)
    references public.aptitude_invitations(workspace_id, id, test_version_id)
    on delete cascade,
  constraint aptitude_attempts_invitation_number_unique
    unique (invitation_id, attempt_number),
  constraint aptitude_attempts_workspace_id_unique
    unique (workspace_id, id),
  constraint aptitude_attempts_workspace_version_id_unique
    unique (workspace_id, id, test_version_id),
  constraint aptitude_attempts_submission_timestamp_check
    check (
      (status = 'in_progress' and submitted_at is null)
      or (status <> 'in_progress' and submitted_at is not null)
    )
);

create table if not exists public.aptitude_answers (
  workspace_id uuid not null,
  attempt_id uuid not null,
  test_version_id uuid not null,
  question_id uuid not null,
  answer jsonb not null,
  saved_at timestamptz not null default now(),
  primary key (attempt_id, question_id),
  constraint aptitude_answers_attempt_version_fk
    foreign key (workspace_id, attempt_id, test_version_id)
    references public.aptitude_attempts(workspace_id, id, test_version_id)
    on delete cascade,
  constraint aptitude_answers_question_version_fk
    foreign key (workspace_id, test_version_id, question_id)
    references public.aptitude_questions(workspace_id, test_version_id, id)
    on delete cascade
);

create table if not exists public.aptitude_monitoring_events (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  attempt_id uuid not null,
  event_type text not null
    check (
      event_type in (
        'focus_lost',
        'visibility_hidden',
        'fullscreen_exit',
        'copy_attempt',
        'paste_attempt',
        'network_disconnected',
        'network_reconnected',
        'heartbeat_timeout',
        'candidate_reported_issue'
      )
    ),
  event_data jsonb not null default '{}'::jsonb
    check (jsonb_typeof(event_data) = 'object'),
  created_at timestamptz not null default now(),
  constraint aptitude_monitoring_events_attempt_fk
    foreign key (workspace_id, attempt_id)
    references public.aptitude_attempts(workspace_id, id)
    on delete cascade
);

create index if not exists idx_aptitude_tests_workspace_created
  on public.aptitude_tests(workspace_id, created_at desc);
create index if not exists idx_aptitude_versions_test_status
  on public.aptitude_test_versions(workspace_id, test_id, version_status);
create index if not exists idx_aptitude_questions_version_order
  on public.aptitude_questions(workspace_id, test_version_id, display_order);
create index if not exists idx_aptitude_invitations_application_created
  on public.aptitude_invitations(workspace_id, application_id, created_at desc);
create index if not exists idx_aptitude_invitations_expiry
  on public.aptitude_invitations(status, expires_at)
  where status in ('pending', 'sent', 'started');
create index if not exists idx_aptitude_attempts_invitation
  on public.aptitude_attempts(workspace_id, invitation_id, attempt_number);
create index if not exists idx_aptitude_attempts_workspace_created
  on public.aptitude_attempts(workspace_id, created_at desc);
create index if not exists idx_aptitude_monitoring_attempt_created
  on public.aptitude_monitoring_events(workspace_id, attempt_id, created_at);

alter table public.aptitude_tests enable row level security;
alter table public.aptitude_test_versions enable row level security;
alter table public.aptitude_questions enable row level security;
alter table public.aptitude_question_options enable row level security;
alter table proofhire_private.aptitude_answer_keys enable row level security;
alter table public.aptitude_invitations enable row level security;
alter table public.aptitude_attempts enable row level security;
alter table public.aptitude_answers enable row level security;
alter table public.aptitude_monitoring_events enable row level security;

create policy "Workspace members can read aptitude tests"
on public.aptitude_tests
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create aptitude tests"
on public.aptitude_tests
for insert to authenticated
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and created_by = (select auth.uid())
);

create policy "Recruiters can update aptitude tests"
on public.aptitude_tests
for update to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']))
with check (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Workspace admins can delete aptitude tests"
on public.aptitude_tests
for delete to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin']));

create policy "Workspace members can read aptitude test versions"
on public.aptitude_test_versions
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create aptitude test drafts"
on public.aptitude_test_versions
for insert to authenticated
with check (
  version_status = 'draft'
  and created_by = (select auth.uid())
  and public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
);

create policy "Recruiters can update aptitude test drafts"
on public.aptitude_test_versions
for update to authenticated
using (
  version_status = 'draft'
  and public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
)
with check (
  version_status = 'draft'
  and public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
);

create policy "Workspace admins can delete aptitude test drafts"
on public.aptitude_test_versions
for delete to authenticated
using (
  version_status = 'draft'
  and public.has_workspace_role(workspace_id, array['owner', 'admin'])
);

create policy "Workspace members can read aptitude questions"
on public.aptitude_questions
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can manage aptitude questions in drafts"
on public.aptitude_questions
for all to authenticated
using (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = aptitude_questions.workspace_id
      and version.id = aptitude_questions.test_version_id
      and version.version_status = 'draft'
  )
)
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_test_versions version
    where version.workspace_id = aptitude_questions.workspace_id
      and version.id = aptitude_questions.test_version_id
      and version.version_status = 'draft'
  )
);

create policy "Workspace members can read aptitude question options"
on public.aptitude_question_options
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can manage aptitude options in drafts"
on public.aptitude_question_options
for all to authenticated
using (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_questions question
    join public.aptitude_test_versions version
      on version.workspace_id = question.workspace_id
     and version.id = question.test_version_id
    where question.workspace_id = aptitude_question_options.workspace_id
      and question.id = aptitude_question_options.question_id
      and version.version_status = 'draft'
  )
)
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and exists (
    select 1
    from public.aptitude_questions question
    join public.aptitude_test_versions version
      on version.workspace_id = question.workspace_id
     and version.id = question.test_version_id
    where question.workspace_id = aptitude_question_options.workspace_id
      and question.id = aptitude_question_options.question_id
      and version.version_status = 'draft'
  )
);

create policy "Service role manages private aptitude answer keys"
on proofhire_private.aptitude_answer_keys
for all to service_role
using (true)
with check (true);

create policy "Workspace members can read aptitude invitations"
on public.aptitude_invitations
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Workspace members can read aptitude attempts"
on public.aptitude_attempts
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can read aptitude monitoring events"
on public.aptitude_monitoring_events
for select to authenticated
using (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
);

revoke all on public.aptitude_tests from anon, authenticated;
revoke all on public.aptitude_test_versions from anon, authenticated;
revoke all on public.aptitude_questions from anon, authenticated;
revoke all on public.aptitude_question_options from anon, authenticated;
revoke all on proofhire_private.aptitude_answer_keys from public, anon, authenticated;
revoke all on public.aptitude_invitations from anon, authenticated;
revoke all on public.aptitude_attempts from anon, authenticated;
revoke all on public.aptitude_answers from public, anon, authenticated;
revoke all on public.aptitude_monitoring_events from anon, authenticated;

grant select, insert, update, delete
  on public.aptitude_tests to authenticated;
grant select, insert, update, delete
  on public.aptitude_test_versions to authenticated;
grant select, insert, update, delete
  on public.aptitude_questions to authenticated;
grant select, insert, update, delete
  on public.aptitude_question_options to authenticated;
grant select (
  id,
  workspace_id,
  application_id,
  test_version_id,
  candidate_email,
  status,
  email_status,
  email_provider_message_id,
  email_error_code,
  expires_at,
  max_attempts,
  invited_by,
  sent_at,
  created_at,
  updated_at
) on public.aptitude_invitations to authenticated;
grant select on public.aptitude_attempts to authenticated;
grant select on public.aptitude_monitoring_events to authenticated;

grant all on public.aptitude_tests to service_role;
grant all on public.aptitude_test_versions to service_role;
grant all on public.aptitude_questions to service_role;
grant all on public.aptitude_question_options to service_role;
grant all on proofhire_private.aptitude_answer_keys to service_role;
grant all on public.aptitude_invitations to service_role;
grant all on public.aptitude_attempts to service_role;
grant all on public.aptitude_answers to service_role;
grant all on public.aptitude_monitoring_events to service_role;

create or replace function public.prevent_published_aptitude_version_changes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.version_status = 'published' then
    raise exception 'Published aptitude test versions are immutable.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger aptitude_test_versions_are_immutable
before update or delete on public.aptitude_test_versions
for each row execute function public.prevent_published_aptitude_version_changes();

create or replace function public.prevent_published_aptitude_content_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  row_data jsonb;
  target_workspace_id uuid;
  target_question_id uuid;
  target_version_id uuid;
  version_state text;
begin
  row_data := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  target_workspace_id := (row_data ->> 'workspace_id')::uuid;

  if tg_table_name = 'aptitude_questions' then
    target_version_id := (row_data ->> 'test_version_id')::uuid;
  else
    target_question_id := (row_data ->> 'question_id')::uuid;
    select question.test_version_id
    into target_version_id
    from public.aptitude_questions question
    where question.workspace_id = target_workspace_id
      and question.id = target_question_id;
  end if;

  select version.version_status
  into version_state
  from public.aptitude_test_versions version
  where version.workspace_id = target_workspace_id
    and version.id = target_version_id;

  if version_state is null and tg_op = 'DELETE' then
    return old;
  end if;
  if version_state is distinct from 'draft' then
    raise exception 'Aptitude content can only change while its version is a draft.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger aptitude_questions_are_immutable_when_published
before insert or update or delete on public.aptitude_questions
for each row execute function public.prevent_published_aptitude_content_changes();

create trigger aptitude_options_are_immutable_when_published
before insert or update or delete on public.aptitude_question_options
for each row execute function public.prevent_published_aptitude_content_changes();

create trigger aptitude_answer_keys_are_immutable_when_published
before insert or update or delete on proofhire_private.aptitude_answer_keys
for each row execute function public.prevent_published_aptitude_content_changes();

create or replace function public.publish_aptitude_test_version(
  target_version_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.aptitude_test_versions%rowtype;
  question_row record;
  option_count integer;
  distinct_option_count integer;
  matched_option_count integer;
  question_option_count integer;
  accepted_answer_count integer;
begin
  select version.*
  into version_row
  from public.aptitude_test_versions version
  where version.id = target_version_id
  for update;

  if not found then
    raise exception 'Aptitude test version was not found.';
  end if;
  if not public.has_workspace_role(
    version_row.workspace_id,
    array['owner', 'admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to publish this aptitude test.';
  end if;
  if version_row.version_status <> 'draft' then
    raise exception 'Only a draft aptitude test version can be published.';
  end if;
  if not exists (
    select 1
    from public.aptitude_questions question
    where question.workspace_id = version_row.workspace_id
      and question.test_version_id = version_row.id
  ) then
    raise exception 'Add at least one question before publishing.';
  end if;

  for question_row in
    select
      question.id,
      question.question_type,
      answer_key.answer_key
    from public.aptitude_questions question
    left join proofhire_private.aptitude_answer_keys answer_key
      on answer_key.workspace_id = question.workspace_id
     and answer_key.question_id = question.id
    where question.workspace_id = version_row.workspace_id
      and question.test_version_id = version_row.id
  loop
    if question_row.answer_key is null then
      raise exception 'Every aptitude question must have a private answer key.';
    end if;

    if question_row.question_type in ('single_choice', 'multiple_choice') then
      if jsonb_typeof(question_row.answer_key -> 'option_ids') is distinct from 'array' then
        raise exception 'Choice-question answer keys must contain an option_ids array.';
      end if;
      select
        count(*),
        count(distinct selected.value)
      into option_count, distinct_option_count
      from jsonb_array_elements_text(question_row.answer_key -> 'option_ids')
        as selected(value);

      if option_count = 0 or option_count <> distinct_option_count then
        raise exception 'Choice-question answer keys must contain unique option IDs.';
      end if;
      if question_row.question_type = 'single_choice' and option_count <> 1 then
        raise exception 'A single-choice question must have exactly one correct option.';
      end if;
      select count(*)
      into question_option_count
      from public.aptitude_question_options option_row
      where option_row.workspace_id = version_row.workspace_id
        and option_row.question_id = question_row.id;
      if question_option_count < 2 then
        raise exception 'Choice questions must have at least two options.';
      end if;
      select count(*)
      into matched_option_count
      from jsonb_array_elements_text(question_row.answer_key -> 'option_ids')
        as selected(value)
      join public.aptitude_question_options option_row
        on option_row.workspace_id = version_row.workspace_id
       and option_row.question_id = question_row.id
       and option_row.id::text = selected.value;
      if matched_option_count <> option_count then
        raise exception 'An answer key refers to an option outside its question.';
      end if;
    elsif question_row.question_type = 'short_text' then
      if jsonb_typeof(question_row.answer_key -> 'accepted_answers') is distinct from 'array' then
        raise exception 'Short-text answer keys must contain an accepted_answers array.';
      end if;
      select count(*)
      into accepted_answer_count
      from jsonb_array_elements_text(question_row.answer_key -> 'accepted_answers')
        as accepted(value)
      where char_length(trim(accepted.value)) > 0;
      if accepted_answer_count = 0 then
        raise exception 'A short-text question must have at least one accepted answer.';
      end if;
    end if;
  end loop;

  update public.aptitude_test_versions
  set version_status = 'published',
      published_at = now(),
      updated_at = now()
  where id = version_row.id
    and workspace_id = version_row.workspace_id;

  return version_row.id;
end;
$$;

create or replace function public.validate_aptitude_invitation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.aptitude_test_versions%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create aptitude invitations.';
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
  return new;
end;
$$;

create trigger aptitude_invitations_require_published_version
before insert or update of workspace_id, test_version_id, max_attempts, expires_at
on public.aptitude_invitations
for each row execute function public.validate_aptitude_invitation();

create or replace function public.validate_aptitude_attempt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.aptitude_invitations%rowtype;
  previous_attempts integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create aptitude attempts.';
  end if;
  select invitation.*
  into invitation_row
  from public.aptitude_invitations invitation
  where invitation.workspace_id = new.workspace_id
    and invitation.id = new.invitation_id
    and invitation.test_version_id = new.test_version_id
  for update;
  if not found
     or invitation_row.status not in ('pending', 'sent', 'started')
     or invitation_row.expires_at <= now() then
    raise exception 'Aptitude invitation is unavailable or expired.';
  end if;
  select count(*)
  into previous_attempts
  from public.aptitude_attempts attempt
  where attempt.workspace_id = new.workspace_id
    and attempt.invitation_id = new.invitation_id;
  if new.attempt_number <> previous_attempts + 1
     or new.attempt_number > invitation_row.max_attempts then
    raise exception 'Aptitude attempt limit has been reached.';
  end if;
  update public.aptitude_invitations
  set status = 'started',
      updated_at = now()
  where id = invitation_row.id
    and workspace_id = invitation_row.workspace_id;
  return new;
end;
$$;

create trigger aptitude_attempts_enforce_invitation_limits
before insert on public.aptitude_attempts
for each row execute function public.validate_aptitude_attempt();

revoke all on function public.publish_aptitude_test_version(uuid)
  from public, anon;
grant execute on function public.publish_aptitude_test_version(uuid)
  to authenticated;

revoke all on function public.validate_aptitude_invitation()
  from public, anon, authenticated;
revoke all on function public.validate_aptitude_attempt()
  from public, anon, authenticated;
revoke all on function public.prevent_published_aptitude_version_changes()
  from public, anon, authenticated;
revoke all on function public.prevent_published_aptitude_content_changes()
  from public, anon, authenticated;

create trigger aptitude_tests_set_updated_at
before update on public.aptitude_tests
for each row execute function public.set_updated_at();

create trigger aptitude_test_versions_set_updated_at
before update on public.aptitude_test_versions
for each row execute function public.set_updated_at();

create trigger aptitude_questions_set_updated_at
before update on public.aptitude_questions
for each row execute function public.set_updated_at();

create trigger aptitude_invitations_set_updated_at
before update on public.aptitude_invitations
for each row execute function public.set_updated_at();

create trigger aptitude_attempts_set_updated_at
before update on public.aptitude_attempts
for each row execute function public.set_updated_at();

create trigger aptitude_answer_keys_set_updated_at
before update on proofhire_private.aptitude_answer_keys
for each row execute function public.set_updated_at();

commit;
