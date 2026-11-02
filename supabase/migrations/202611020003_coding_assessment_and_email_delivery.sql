-- Add a server-only coding assessment foundation and an idempotent email
-- delivery queue. No code execution or email provider is implemented here.

begin;

create table if not exists public.coding_challenges (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null references public.workspaces(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 180),
  description text check (description is null or char_length(description) <= 10000),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_challenges_workspace_id_unique unique (workspace_id, id)
);

create table if not exists public.coding_challenge_versions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  challenge_id uuid not null,
  version_number integer not null check (version_number > 0),
  prompt text not null check (char_length(trim(prompt)) between 1 and 20000),
  difficulty text not null check (
    difficulty in ('beginner', 'medium', 'advanced', 'expert')
  ),
  supported_languages text[] not null
    check (cardinality(supported_languages) between 1 and 20),
  starter_code jsonb not null default '{}'::jsonb
    check (
      jsonb_typeof(starter_code) = 'object'
      and octet_length(starter_code::text) <= 100000
    ),
  points numeric(8, 2) not null default 1 check (points > 0),
  max_execution_seconds integer not null default 10
    check (max_execution_seconds between 1 and 30),
  version_status text not null default 'draft'
    check (version_status in ('draft', 'published')),
  published_at timestamptz,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_challenge_versions_challenge_fk
    foreign key (workspace_id, challenge_id)
    references public.coding_challenges(workspace_id, id)
    on delete cascade,
  constraint coding_challenge_versions_number_unique
    unique (challenge_id, version_number),
  constraint coding_challenge_versions_workspace_id_unique
    unique (workspace_id, id),
  constraint coding_challenge_versions_job_config_unique
    unique (workspace_id, id, challenge_id),
  constraint coding_challenge_versions_published_at_check
    check (
      (version_status = 'draft' and published_at is null)
      or (version_status = 'published' and published_at is not null)
    )
);

create table if not exists public.job_coding_assessments (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  job_id uuid not null,
  challenge_version_id uuid not null,
  is_required boolean not null default false,
  time_limit_seconds integer not null default 3600
    check (time_limit_seconds between 60 and 21600),
  max_attempts integer not null default 1 check (max_attempts between 1 and 5),
  display_order integer not null default 1 check (display_order > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_coding_assessments_job_fk
    foreign key (job_id, workspace_id)
    references public.jobs(id, workspace_id)
    on delete cascade,
  constraint job_coding_assessments_challenge_fk
    foreign key (workspace_id, challenge_version_id)
    references public.coding_challenge_versions(workspace_id, id)
    on delete restrict,
  constraint job_coding_assessments_job_version_unique
    unique (workspace_id, job_id, challenge_version_id),
  constraint job_coding_assessments_workspace_id_unique
    unique (workspace_id, id),
  constraint job_coding_assessments_invitation_key_unique
    unique (workspace_id, id, job_id, challenge_version_id)
);

create index if not exists idx_job_coding_assessments_job_order
  on public.job_coding_assessments(workspace_id, job_id, display_order);

create table if not exists public.coding_invitations (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  job_id uuid not null,
  job_coding_assessment_id uuid not null,
  challenge_version_id uuid not null,
  candidate_email text not null
    check (
      char_length(candidate_email) between 3 and 320
      and candidate_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),
  token_hash text not null check (token_hash ~ '^[0-9a-f]{64}$'),
  status text not null default 'pending'
    check (status in ('pending', 'started', 'completed', 'expired', 'revoked', 'failed')),
  expires_at timestamptz not null,
  max_attempts integer not null default 1 check (max_attempts between 1 and 5),
  invited_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_invitations_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint coding_invitations_job_configuration_fk
    foreign key (
      workspace_id,
      job_coding_assessment_id,
      job_id,
      challenge_version_id
    )
    references public.job_coding_assessments(
      workspace_id,
      id,
      job_id,
      challenge_version_id
    )
    on delete restrict,
  constraint coding_invitations_token_hash_unique unique (token_hash),
  constraint coding_invitations_workspace_id_unique unique (workspace_id, id),
  constraint coding_invitations_workspace_application_unique
    unique (workspace_id, id, application_id),
  constraint coding_invitations_workspace_attempt_key_unique
    unique (workspace_id, id, challenge_version_id)
);

create table if not exists public.coding_attempts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  invitation_id uuid not null,
  challenge_version_id uuid not null,
  attempt_number integer not null check (attempt_number between 1 and 5),
  status text not null default 'in_progress'
    check (
      status in (
        'in_progress',
        'submitted',
        'evaluating',
        'completed',
        'expired',
        'failed'
      )
    ),
  started_at timestamptz not null default now(),
  submitted_at timestamptz,
  evaluated_at timestamptz,
  completed_at timestamptz,
  score numeric(5, 2) check (score is null or score between 0 and 100),
  error_code text check (error_code is null or char_length(error_code) <= 80),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_attempts_invitation_fk
    foreign key (workspace_id, invitation_id, challenge_version_id)
    references public.coding_invitations(workspace_id, id, challenge_version_id)
    on delete cascade,
  constraint coding_attempts_number_unique unique (invitation_id, attempt_number),
  constraint coding_attempts_workspace_id_unique unique (workspace_id, id),
  constraint coding_attempts_workspace_version_unique
    unique (workspace_id, id, challenge_version_id),
  constraint coding_attempts_submission_time_check
    check (
      (status = 'in_progress' and submitted_at is null)
      or (status <> 'in_progress' and submitted_at is not null)
    )
);

create table if not exists public.coding_submissions (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  attempt_id uuid not null,
  challenge_version_id uuid not null,
  submission_number integer not null check (submission_number > 0),
  idempotency_key uuid not null,
  language text not null check (char_length(trim(language)) between 1 and 80),
  is_final boolean not null default true,
  source_reference uuid not null default gen_random_uuid(),
  status text not null default 'queued'
    check (status in ('queued', 'evaluating', 'completed', 'failed', 'rejected')),
  submitted_at timestamptz not null default now(),
  evaluated_at timestamptz,
  created_at timestamptz not null default now(),
  constraint coding_submissions_attempt_fk
    foreign key (workspace_id, attempt_id, challenge_version_id)
    references public.coding_attempts(workspace_id, id, challenge_version_id)
    on delete cascade,
  constraint coding_submissions_attempt_number_unique
    unique (attempt_id, submission_number),
  constraint coding_submissions_idempotency_unique
    unique (workspace_id, attempt_id, idempotency_key),
  constraint coding_submissions_workspace_reference_unique
    unique (workspace_id, source_reference),
  constraint coding_submissions_workspace_id_unique unique (workspace_id, id),
  constraint coding_submissions_workspace_attempt_version_unique
    unique (workspace_id, id, attempt_id, challenge_version_id),
  constraint coding_submissions_workspace_version_unique
    unique (workspace_id, id, challenge_version_id)
);

create table if not exists public.coding_question_results (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  attempt_id uuid not null,
  submission_id uuid not null,
  challenge_version_id uuid not null,
  status text not null
    check (status in ('passed', 'failed', 'timeout', 'compile_error', 'runtime_error')),
  score numeric(8, 2) not null check (score >= 0),
  maximum_score numeric(8, 2) not null check (maximum_score > 0),
  test_cases_passed integer not null default 0 check (test_cases_passed >= 0),
  test_case_count integer not null default 0 check (test_case_count >= test_cases_passed),
  execution_time_ms integer check (execution_time_ms is null or execution_time_ms >= 0),
  error_code text check (error_code is null or char_length(error_code) <= 80),
  evaluated_at timestamptz not null default now(),
  constraint coding_question_results_submission_fk
    foreign key (
      workspace_id,
      submission_id,
      attempt_id,
      challenge_version_id
    )
    references public.coding_submissions(
      workspace_id,
      id,
      attempt_id,
      challenge_version_id
    )
    on delete cascade,
  constraint coding_question_results_score_check check (score <= maximum_score),
  constraint coding_question_results_submission_unique unique (submission_id)
);

create table if not exists public.coding_evaluation_jobs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  submission_id uuid not null,
  status text not null default 'waiting_configuration'
    check (
      status in (
        'queued',
        'processing',
        'retry_wait',
        'waiting_configuration',
        'completed',
        'failed'
      )
    ),
  attempts integer not null default 0 check (attempts between 0 and 5),
  max_attempts integer not null default 5 check (max_attempts between 1 and 5),
  available_at timestamptz not null default now(),
  lease_token uuid,
  locked_by text,
  locked_until timestamptz,
  last_error_code text,
  failure_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  completed_at timestamptz,
  constraint coding_evaluation_jobs_submission_fk
    foreign key (workspace_id, submission_id)
    references public.coding_submissions(workspace_id, id)
    on delete cascade,
  constraint coding_evaluation_jobs_submission_unique unique (submission_id),
  constraint coding_evaluation_jobs_lease_check
    check (
      (status = 'processing' and lease_token is not null and locked_until is not null)
      or (status <> 'processing' and lease_token is null and locked_until is null)
    )
);

create index if not exists idx_coding_evaluation_jobs_claim
  on public.coding_evaluation_jobs(status, available_at, created_at)
  where status in ('queued', 'retry_wait', 'processing');
create index if not exists idx_coding_invitations_application_created
  on public.coding_invitations(workspace_id, application_id, created_at desc);
create index if not exists idx_coding_attempts_invitation_number
  on public.coding_attempts(workspace_id, invitation_id, attempt_number);
create index if not exists idx_coding_submissions_attempt_created
  on public.coding_submissions(workspace_id, attempt_id, submitted_at desc);

create table if not exists proofhire_private.coding_test_cases (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  challenge_version_id uuid not null,
  display_order integer not null check (display_order > 0),
  input_text text not null check (octet_length(input_text) <= 20000),
  expected_output text not null check (octet_length(expected_output) <= 20000),
  is_hidden boolean not null default true,
  points numeric(8, 2) not null default 1 check (points > 0),
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint coding_test_cases_challenge_fk
    foreign key (workspace_id, challenge_version_id)
    references public.coding_challenge_versions(workspace_id, id)
    on delete cascade,
  constraint coding_test_cases_order_unique
    unique (challenge_version_id, display_order),
  constraint coding_test_cases_workspace_id_unique unique (workspace_id, id),
  constraint coding_test_cases_workspace_version_unique
    unique (workspace_id, id, challenge_version_id)
);

create table if not exists proofhire_private.coding_submission_sources (
  source_reference uuid primary key,
  workspace_id uuid not null,
  source_code text not null
    check (octet_length(source_code) between 1 and 262144),
  created_at timestamptz not null default now(),
  constraint coding_submission_sources_submission_fk
    foreign key (workspace_id, source_reference)
    references public.coding_submissions(workspace_id, source_reference)
    on delete cascade
);

create table if not exists proofhire_private.coding_test_case_results (
  workspace_id uuid not null,
  submission_id uuid not null,
  challenge_version_id uuid not null,
  test_case_id uuid not null,
  status text not null check (status in ('passed', 'failed', 'timeout', 'error')),
  execution_time_ms integer check (execution_time_ms is null or execution_time_ms >= 0),
  error_code text check (error_code is null or char_length(error_code) <= 80),
  evaluated_at timestamptz not null default now(),
  primary key (submission_id, test_case_id),
  constraint coding_test_case_results_submission_fk
    foreign key (workspace_id, submission_id, challenge_version_id)
    references public.coding_submissions(workspace_id, id, challenge_version_id)
    on delete cascade,
  constraint coding_test_case_results_case_fk
    foreign key (workspace_id, test_case_id, challenge_version_id)
    references proofhire_private.coding_test_cases(
      workspace_id,
      id,
      challenge_version_id
    )
    on delete cascade
);

alter table proofhire_private.coding_test_cases enable row level security;
alter table proofhire_private.coding_submission_sources enable row level security;
alter table proofhire_private.coding_test_case_results enable row level security;
revoke all on proofhire_private.coding_test_cases
  from public, anon, authenticated;
revoke all on proofhire_private.coding_submission_sources
  from public, anon, authenticated;
revoke all on proofhire_private.coding_test_case_results
  from public, anon, authenticated;
grant all on proofhire_private.coding_test_cases to service_role;
grant all on proofhire_private.coding_submission_sources to service_role;
grant all on proofhire_private.coding_test_case_results to service_role;

do $migration$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_workspace_id_unique'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_workspace_id_unique
      unique (workspace_id, id);
  end if;
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.aptitude_invitations'::regclass
      and conname = 'aptitude_invitations_workspace_application_unique'
  ) then
    alter table public.aptitude_invitations
      add constraint aptitude_invitations_workspace_application_unique
      unique (workspace_id, id, application_id);
  end if;
end;
$migration$;

create table if not exists public.email_delivery_jobs (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  application_id uuid not null,
  aptitude_invitation_id uuid,
  coding_invitation_id uuid,
  interview_record_id uuid,
  email_type text not null check (
    email_type in (
      'application_update',
      'aptitude_invitation',
      'coding_invitation',
      'interview_invitation',
      'interview_update',
      'rejection',
      'offer'
    )
  ),
  template_key text not null
    check (char_length(trim(template_key)) between 1 and 120),
  recipient_email text not null
    check (
      char_length(recipient_email) between 3 and 320
      and recipient_email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    ),
  idempotency_key text not null
    check (char_length(trim(idempotency_key)) between 1 and 200),
  status text not null default 'manual_required'
    check (
      status in (
        'queued',
        'processing',
        'retry_wait',
        'sent',
        'delivered',
        'failed',
        'blocked_configuration',
        'manual_required',
        'cancelled'
      )
    ),
  attempts integer not null default 0 check (attempts between 0 and 10),
  max_attempts integer not null default 5 check (max_attempts between 1 and 10),
  next_attempt_at timestamptz not null default now(),
  lease_token uuid,
  locked_by text,
  locked_until timestamptz,
  provider_message_id text,
  last_error_code text check (
    last_error_code is null or char_length(last_error_code) <= 100
  ),
  sent_at timestamptz,
  delivered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint email_delivery_jobs_application_fk
    foreign key (workspace_id, application_id)
    references public.applications(workspace_id, id)
    on delete cascade,
  constraint email_delivery_jobs_aptitude_invitation_fk
    foreign key (workspace_id, aptitude_invitation_id, application_id)
    references public.aptitude_invitations(workspace_id, id, application_id)
    on delete cascade,
  constraint email_delivery_jobs_coding_invitation_fk
    foreign key (workspace_id, coding_invitation_id, application_id)
    references public.coding_invitations(workspace_id, id, application_id)
    on delete cascade,
  constraint email_delivery_jobs_interview_fk
    foreign key (workspace_id, interview_record_id, application_id)
    references public.interview_records(workspace_id, id, application_id)
    on delete cascade,
  constraint email_delivery_jobs_target_check check (
    (
      email_type = 'aptitude_invitation'
      and aptitude_invitation_id is not null
      and coding_invitation_id is null
      and interview_record_id is null
    )
    or (
      email_type = 'coding_invitation'
      and aptitude_invitation_id is null
      and coding_invitation_id is not null
      and interview_record_id is null
    )
    or (
      email_type in ('interview_invitation', 'interview_update')
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is not null
    )
    or (
      email_type in ('application_update', 'rejection', 'offer')
      and aptitude_invitation_id is null
      and coding_invitation_id is null
      and interview_record_id is null
    )
  ),
  constraint email_delivery_jobs_lease_check check (
    (status = 'processing' and lease_token is not null and locked_until is not null)
    or (status <> 'processing' and lease_token is null and locked_until is null)
  ),
  constraint email_delivery_jobs_delivery_time_check
    check (delivered_at is null or sent_at is not null),
  constraint email_delivery_jobs_idempotency_unique unique (idempotency_key),
  constraint email_delivery_jobs_workspace_id_unique unique (workspace_id, id)
);

create index if not exists idx_email_delivery_jobs_claim
  on public.email_delivery_jobs(status, next_attempt_at, created_at)
  where status in ('queued', 'retry_wait', 'processing');
create index if not exists idx_email_delivery_jobs_application_created
  on public.email_delivery_jobs(workspace_id, application_id, created_at desc);

create table if not exists public.email_delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  workspace_id uuid not null,
  delivery_job_id uuid not null,
  attempt_number integer not null check (attempt_number > 0),
  status text not null check (status in ('sent', 'delivered', 'retry_wait', 'failed')),
  provider_message_id text,
  error_code text check (error_code is null or char_length(error_code) <= 100),
  attempted_at timestamptz not null default now(),
  completed_at timestamptz not null default now(),
  constraint email_delivery_attempts_job_fk
    foreign key (workspace_id, delivery_job_id)
    references public.email_delivery_jobs(workspace_id, id)
    on delete cascade,
  constraint email_delivery_attempts_number_unique
    unique (delivery_job_id, attempt_number)
);

create index if not exists idx_email_delivery_attempts_job_number
  on public.email_delivery_attempts(workspace_id, delivery_job_id, attempt_number desc);

drop trigger if exists coding_challenges_set_updated_at
  on public.coding_challenges;
create trigger coding_challenges_set_updated_at
before update on public.coding_challenges
for each row execute function public.set_updated_at();

drop trigger if exists coding_challenge_versions_set_updated_at
  on public.coding_challenge_versions;
create trigger coding_challenge_versions_set_updated_at
before update on public.coding_challenge_versions
for each row execute function public.set_updated_at();

drop trigger if exists job_coding_assessments_set_updated_at
  on public.job_coding_assessments;
create trigger job_coding_assessments_set_updated_at
before update on public.job_coding_assessments
for each row execute function public.set_updated_at();

drop trigger if exists coding_invitations_set_updated_at
  on public.coding_invitations;
create trigger coding_invitations_set_updated_at
before update on public.coding_invitations
for each row execute function public.set_updated_at();

drop trigger if exists coding_attempts_set_updated_at
  on public.coding_attempts;
create trigger coding_attempts_set_updated_at
before update on public.coding_attempts
for each row execute function public.set_updated_at();

drop trigger if exists coding_evaluation_jobs_set_updated_at
  on public.coding_evaluation_jobs;
create trigger coding_evaluation_jobs_set_updated_at
before update on public.coding_evaluation_jobs
for each row execute function public.set_updated_at();

drop trigger if exists email_delivery_jobs_set_updated_at
  on public.email_delivery_jobs;
create trigger email_delivery_jobs_set_updated_at
before update on public.email_delivery_jobs
for each row execute function public.set_updated_at();

alter table public.coding_challenges enable row level security;
alter table public.coding_challenge_versions enable row level security;
alter table public.job_coding_assessments enable row level security;
alter table public.coding_invitations enable row level security;
alter table public.coding_attempts enable row level security;
alter table public.coding_submissions enable row level security;
alter table public.coding_question_results enable row level security;
alter table public.coding_evaluation_jobs enable row level security;
alter table public.email_delivery_jobs enable row level security;
alter table public.email_delivery_attempts enable row level security;

create policy "Workspace members can read coding challenges"
on public.coding_challenges
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create coding challenges"
on public.coding_challenges
for insert to authenticated
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and (created_by is null or created_by = (select auth.uid()))
);

create policy "Recruiters can update coding challenges"
on public.coding_challenges
for update to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']))
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and (created_by is null or created_by = (select auth.uid()))
);

create policy "Workspace members can read coding challenge versions"
on public.coding_challenge_versions
for select to authenticated
using (public.is_workspace_member(workspace_id));

create policy "Recruiters can create coding challenge drafts"
on public.coding_challenge_versions
for insert to authenticated
with check (
  version_status = 'draft'
  and (created_by is null or created_by = (select auth.uid()))
  and public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
);

create policy "Recruiters can update coding challenge drafts"
on public.coding_challenge_versions
for update to authenticated
using (
  version_status = 'draft'
  and public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
)
with check (
  version_status = 'draft'
  and (created_by is null or created_by = (select auth.uid()))
  and public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
);

create policy "Recruiters can read job coding assessments"
on public.job_coding_assessments
for select to authenticated
using (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
);

create policy "Recruiters can manage job coding assessments"
on public.job_coding_assessments
for all to authenticated
using (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and exists (
    select 1
    from public.coding_challenge_versions version
    where version.workspace_id = job_coding_assessments.workspace_id
      and version.id = job_coding_assessments.challenge_version_id
      and version.version_status = 'published'
  )
)
with check (
  public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter'])
  and (created_by is null or created_by = (select auth.uid()))
  and exists (
    select 1
    from public.coding_challenge_versions version
    where version.workspace_id = job_coding_assessments.workspace_id
      and version.id = job_coding_assessments.challenge_version_id
      and version.version_status = 'published'
  )
);

create policy "Recruiters can read coding invitations"
on public.coding_invitations
for select to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Recruiters can read coding attempts"
on public.coding_attempts
for select to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Recruiters can read coding submissions"
on public.coding_submissions
for select to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Recruiters can read coding question results"
on public.coding_question_results
for select to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Recruiters can read email delivery jobs"
on public.email_delivery_jobs
for select to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

create policy "Recruiters can read email delivery attempts"
on public.email_delivery_attempts
for select to authenticated
using (public.has_workspace_role(workspace_id, array['owner', 'admin', 'recruiter']));

revoke all on public.coding_challenges from public, anon, authenticated;
revoke all on public.coding_challenge_versions from public, anon, authenticated;
revoke all on public.job_coding_assessments from public, anon, authenticated;
revoke all on public.coding_invitations from public, anon, authenticated;
revoke all on public.coding_attempts from public, anon, authenticated;
revoke all on public.coding_submissions from public, anon, authenticated;
revoke all on public.coding_question_results from public, anon, authenticated;
revoke all on public.coding_evaluation_jobs from public, anon, authenticated;
revoke all on public.email_delivery_jobs from public, anon, authenticated;
revoke all on public.email_delivery_attempts from public, anon, authenticated;

grant select, insert, update on public.coding_challenges to authenticated;
grant select, insert, update, delete on public.coding_challenge_versions to authenticated;
grant select, insert, update, delete on public.job_coding_assessments to authenticated;
grant select (
  id,
  workspace_id,
  application_id,
  job_id,
  job_coding_assessment_id,
  challenge_version_id,
  candidate_email,
  status,
  expires_at,
  max_attempts,
  invited_by,
  created_at,
  updated_at
) on public.coding_invitations to authenticated;
grant select on public.coding_attempts to authenticated;
grant select on public.coding_submissions to authenticated;
grant select on public.coding_question_results to authenticated;
grant select on public.email_delivery_jobs to authenticated;
grant select on public.email_delivery_attempts to authenticated;

grant all on public.coding_challenges to service_role;
grant all on public.coding_challenge_versions to service_role;
grant all on public.job_coding_assessments to service_role;
grant all on public.coding_invitations to service_role;
grant all on public.coding_attempts to service_role;
grant all on public.coding_submissions to service_role;
grant all on public.coding_question_results to service_role;
grant all on public.coding_evaluation_jobs to service_role;
grant all on public.email_delivery_jobs to service_role;
grant all on public.email_delivery_attempts to service_role;

create or replace function public.prevent_published_coding_version_changes()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' and pg_trigger_depth() > 1 then
    return old;
  end if;
  if old.version_status = 'published' then
    raise exception 'Published coding challenge versions are immutable.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger coding_challenge_versions_are_immutable
before update or delete on public.coding_challenge_versions
for each row execute function public.prevent_published_coding_version_changes();

create or replace function public.prevent_published_coding_test_case_changes()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  target_version uuid;
  target_workspace uuid;
  version_state text;
begin
  if tg_op = 'DELETE' then
    target_version := old.challenge_version_id;
    target_workspace := old.workspace_id;
  else
    target_version := new.challenge_version_id;
    target_workspace := new.workspace_id;
  end if;
  select version.version_status
  into version_state
  from public.coding_challenge_versions version
  where version.workspace_id = target_workspace
    and version.id = target_version
  for update;
  if not found and tg_op = 'DELETE' then
    return old;
  end if;
  if version_state is distinct from 'draft' then
    raise exception 'Coding test cases can only change while the version is a draft.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create trigger coding_test_cases_are_immutable_when_published
before insert or update or delete on proofhire_private.coding_test_cases
for each row execute function public.prevent_published_coding_test_case_changes();

create or replace function public.save_coding_test_case(
  target_workspace_id uuid,
  target_challenge_version_id uuid,
  target_case_id uuid,
  target_input text,
  target_expected_output text,
  target_is_hidden boolean default true,
  target_points numeric default 1
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  next_id uuid;
  next_order integer;
begin
  if not public.has_workspace_role(
    target_workspace_id,
    array['owner', 'admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to edit coding test cases.';
  end if;
  if not exists (
    select 1
    from public.coding_challenge_versions version
    where version.workspace_id = target_workspace_id
      and version.id = target_challenge_version_id
      and version.version_status = 'draft'
  ) then
    raise exception 'Coding test cases can only be edited on draft versions.';
  end if;
  if target_input is null or octet_length(target_input) > 20000
     or target_expected_output is null
     or octet_length(target_expected_output) > 20000
     or target_points is null or target_points <= 0 then
    raise exception 'The coding test case is invalid.';
  end if;

  if target_case_id is null then
    select coalesce(max(test_case.display_order), 0) + 1
    into next_order
    from proofhire_private.coding_test_cases test_case
    where test_case.workspace_id = target_workspace_id
      and test_case.challenge_version_id = target_challenge_version_id;
    insert into proofhire_private.coding_test_cases (
      workspace_id,
      challenge_version_id,
      display_order,
      input_text,
      expected_output,
      is_hidden,
      points,
      created_by
    )
    values (
      target_workspace_id,
      target_challenge_version_id,
      next_order,
      target_input,
      target_expected_output,
      coalesce(target_is_hidden, true),
      target_points,
      (select auth.uid())
    )
    returning id into next_id;
    return next_id;
  end if;

  update proofhire_private.coding_test_cases
  set input_text = target_input,
      expected_output = target_expected_output,
      is_hidden = coalesce(target_is_hidden, true),
      points = target_points,
      updated_at = now()
  where id = target_case_id
    and workspace_id = target_workspace_id
    and challenge_version_id = target_challenge_version_id
  returning id into next_id;
  if next_id is null then
    raise exception 'The coding test case was not found.';
  end if;
  return next_id;
end;
$$;

create or replace function public.publish_coding_challenge_version(
  target_challenge_version_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  version_row public.coding_challenge_versions%rowtype;
  test_case_count integer;
begin
  select version.*
  into version_row
  from public.coding_challenge_versions version
  where version.id = target_challenge_version_id
  for update;
  if not found or not public.has_workspace_role(
    version_row.workspace_id,
    array['owner', 'admin', 'recruiter']::text[]
  ) then
    raise exception 'You do not have permission to publish this coding challenge.';
  end if;
  if version_row.version_status <> 'draft' then
    raise exception 'Only a draft coding challenge version can be published.';
  end if;
  select count(*)
  into test_case_count
  from proofhire_private.coding_test_cases test_case
  where test_case.workspace_id = version_row.workspace_id
    and test_case.challenge_version_id = version_row.id;
  if test_case_count = 0 then
    raise exception 'Add at least one private test case before publishing.';
  end if;
  update public.coding_challenge_versions
  set version_status = 'published',
      published_at = now(),
      updated_at = now()
  where id = version_row.id;
  return version_row.id;
end;
$$;

revoke all on function public.prevent_published_coding_version_changes()
  from public, anon, authenticated;
revoke all on function public.prevent_published_coding_test_case_changes()
  from public, anon, authenticated;
revoke all on function public.save_coding_test_case(uuid, uuid, uuid, text, text, boolean, numeric)
  from public, anon;
revoke all on function public.publish_coding_challenge_version(uuid)
  from public, anon;
grant execute on function public.save_coding_test_case(uuid, uuid, uuid, text, text, boolean, numeric)
  to authenticated;
grant execute on function public.publish_coding_challenge_version(uuid)
  to authenticated;

create or replace function public.validate_coding_invitation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  application_job_id uuid;
  configuration_row public.job_coding_assessments%rowtype;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create coding invitations.';
  end if;
  select application.job_id
  into application_job_id
  from public.applications application
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if application_job_id is null or application_job_id <> new.job_id then
    raise exception 'The coding invitation application and job do not match.';
  end if;
  select configuration.*
  into configuration_row
  from public.job_coding_assessments configuration
  join public.coding_challenge_versions version
    on version.workspace_id = configuration.workspace_id
   and version.id = configuration.challenge_version_id
  where configuration.workspace_id = new.workspace_id
    and configuration.id = new.job_coding_assessment_id
    and configuration.job_id = new.job_id
    and configuration.challenge_version_id = new.challenge_version_id
    and version.version_status = 'published';
  if not found then
    raise exception 'The coding invitation requires a published job assessment.';
  end if;
  if new.max_attempts > configuration_row.max_attempts
     or new.expires_at <= now() then
    raise exception 'The coding invitation limits or expiry are invalid.';
  end if;
  return new;
end;
$$;

create trigger coding_invitations_validate
before insert or update of workspace_id, application_id, job_id,
  job_coding_assessment_id, challenge_version_id, max_attempts, expires_at
on public.coding_invitations
for each row execute function public.validate_coding_invitation();

create or replace function public.validate_coding_attempt()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_row public.coding_invitations%rowtype;
  previous_attempts integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to create coding attempts.';
  end if;
  select invitation.*
  into invitation_row
  from public.coding_invitations invitation
  where invitation.workspace_id = new.workspace_id
    and invitation.id = new.invitation_id
    and invitation.challenge_version_id = new.challenge_version_id
  for update;
  if not found
     or invitation_row.status not in ('pending', 'started')
     or invitation_row.expires_at <= now() then
    raise exception 'The coding invitation is unavailable or expired.';
  end if;
  select count(*)
  into previous_attempts
  from public.coding_attempts attempt
  where attempt.workspace_id = new.workspace_id
    and attempt.invitation_id = new.invitation_id;
  if new.attempt_number <> previous_attempts + 1
     or new.attempt_number > invitation_row.max_attempts then
    raise exception 'The coding attempt limit has been reached.';
  end if;
  update public.coding_invitations
  set status = 'started',
      updated_at = now()
  where id = invitation_row.id
    and workspace_id = invitation_row.workspace_id;
  return new;
end;
$$;

create or replace function public.get_coding_test_cases(
  target_workspace_id uuid,
  target_challenge_version_id uuid
)
returns table (
  id uuid,
  display_order integer,
  input_text text,
  expected_output text,
  is_hidden boolean,
  points numeric
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
    raise exception 'You do not have permission to read coding test cases.';
  end if;
  return query
  select
    test_case.id,
    test_case.display_order,
    test_case.input_text,
    test_case.expected_output,
    test_case.is_hidden,
    test_case.points
  from proofhire_private.coding_test_cases test_case
  where test_case.workspace_id = target_workspace_id
    and test_case.challenge_version_id = target_challenge_version_id
  order by test_case.display_order;
end;
$$;

create or replace function public.save_coding_submission(
  target_workspace_id uuid,
  target_attempt_id uuid,
  target_idempotency_key uuid,
  target_language text,
  target_source_code text,
  target_is_final boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  attempt_row public.coding_attempts%rowtype;
  invitation_row public.coding_invitations%rowtype;
  configuration_row public.job_coding_assessments%rowtype;
  version_row public.coding_challenge_versions%rowtype;
  existing_submission public.coding_submissions%rowtype;
  existing_source text;
  next_number integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required to save coding submissions.';
  end if;
  if target_idempotency_key is null
     or target_language is null
     or char_length(trim(target_language)) not between 1 and 80
     or target_source_code is null
     or octet_length(target_source_code) not between 1 and 262144 then
    raise exception 'The coding submission is invalid.';
  end if;

  select submission.*
  into existing_submission
  from public.coding_submissions submission
  where submission.workspace_id = target_workspace_id
    and submission.attempt_id = target_attempt_id
    and submission.idempotency_key = target_idempotency_key;
  if found then
    select source.source_code
    into existing_source
    from proofhire_private.coding_submission_sources source
    where source.workspace_id = target_workspace_id
      and source.source_reference = existing_submission.source_reference;
    if existing_source is distinct from target_source_code
       or lower(existing_submission.language) <> lower(trim(target_language))
       or existing_submission.is_final is distinct from coalesce(target_is_final, true) then
      raise exception 'The coding idempotency key was already used for a different submission.';
    end if;
    return existing_submission.id;
  end if;

  select attempt.*
  into attempt_row
  from public.coding_attempts attempt
  where attempt.workspace_id = target_workspace_id
    and attempt.id = target_attempt_id
  for update;
  if not found then
    raise exception 'The coding attempt was not found.';
  end if;

  select submission.*
  into existing_submission
  from public.coding_submissions submission
  where submission.workspace_id = target_workspace_id
    and submission.attempt_id = target_attempt_id
    and submission.idempotency_key = target_idempotency_key;
  if found then
    select source.source_code
    into existing_source
    from proofhire_private.coding_submission_sources source
    where source.workspace_id = target_workspace_id
      and source.source_reference = existing_submission.source_reference;
    if existing_source is distinct from target_source_code
       or lower(existing_submission.language) <> lower(trim(target_language))
       or existing_submission.is_final is distinct from coalesce(target_is_final, true) then
      raise exception 'The coding idempotency key was already used for a different submission.';
    end if;
    return existing_submission.id;
  end if;
  if attempt_row.status <> 'in_progress' then
    raise exception 'The coding attempt is not active.';
  end if;
  select invitation.*
  into invitation_row
  from public.coding_invitations invitation
  where invitation.workspace_id = target_workspace_id
    and invitation.id = attempt_row.invitation_id
    and invitation.challenge_version_id = attempt_row.challenge_version_id
    and invitation.status in ('pending', 'started')
    and invitation.expires_at > now()
  for update;
  if not found then
    raise exception 'The coding invitation is unavailable or expired.';
  end if;
  select configuration.*
  into configuration_row
  from public.job_coding_assessments configuration
  where configuration.workspace_id = target_workspace_id
    and configuration.id = invitation_row.job_coding_assessment_id;
  select version.*
  into version_row
  from public.coding_challenge_versions version
  where version.workspace_id = target_workspace_id
    and version.id = attempt_row.challenge_version_id
    and version.version_status = 'published';
  if not found or configuration_row.id is null then
    raise exception 'The published coding assessment is unavailable.';
  end if;
  if attempt_row.started_at
       + make_interval(secs => configuration_row.time_limit_seconds) <= now() then
    raise exception 'The coding attempt has expired.';
  end if;
  if not exists (
    select 1
    from unnest(version_row.supported_languages) supported(language)
    where lower(supported.language) = lower(trim(target_language))
  ) then
    raise exception 'The selected coding language is not supported.';
  end if;

  select coalesce(max(submission.submission_number), 0) + 1
  into next_number
  from public.coding_submissions submission
  where submission.workspace_id = target_workspace_id
    and submission.attempt_id = attempt_row.id;

  insert into public.coding_submissions (
    workspace_id,
    attempt_id,
    challenge_version_id,
    submission_number,
    idempotency_key,
    language,
    is_final
  )
  values (
    target_workspace_id,
    attempt_row.id,
    attempt_row.challenge_version_id,
    next_number,
    target_idempotency_key,
    trim(target_language),
    coalesce(target_is_final, true)
  )
  returning * into existing_submission;

  insert into proofhire_private.coding_submission_sources (
    source_reference,
    workspace_id,
    source_code
  )
  values (
    existing_submission.source_reference,
    target_workspace_id,
    target_source_code
  );

  if coalesce(target_is_final, true) then
    update public.coding_attempts
    set status = 'submitted',
        submitted_at = now(),
        updated_at = now()
    where id = attempt_row.id;
  end if;
  return existing_submission.id;
end;
$$;

create trigger coding_attempts_enforce_invitation_limits
before insert on public.coding_attempts
for each row execute function public.validate_coding_attempt();

create or replace function public.queue_coding_evaluation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.coding_evaluation_jobs (
    workspace_id,
    submission_id,
    status
  )
  values (
    new.workspace_id,
    new.id,
    'waiting_configuration'
  )
  on conflict (submission_id) do nothing;
  return new;
end;
$$;

create trigger coding_submissions_queue_evaluation
after insert on public.coding_submissions
for each row execute function public.queue_coding_evaluation();

create or replace function public.claim_coding_evaluation_jobs(
  worker_id text,
  lease_seconds integer default 120
)
returns setof public.coding_evaluation_jobs
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if worker_id is null or char_length(trim(worker_id)) not between 1 and 120 then
    raise exception 'Worker identifier is invalid.';
  end if;
  lease_seconds := greatest(30, least(coalesce(lease_seconds, 120), 600));

  update public.coding_evaluation_jobs evaluation
  set status = 'failed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'lease_expired',
      failure_reason = 'Evaluation lease expired after the retry limit.',
      updated_at = now()
  where evaluation.status = 'processing'
    and evaluation.locked_until < now()
    and evaluation.attempts >= evaluation.max_attempts;

  return query
  with next_job as (
    select evaluation.id
    from public.coding_evaluation_jobs evaluation
    where evaluation.attempts < evaluation.max_attempts
      and (
        (evaluation.status in ('queued', 'retry_wait')
          and evaluation.available_at <= now())
        or (
          evaluation.status = 'processing'
          and evaluation.locked_until < now()
        )
      )
    order by evaluation.available_at, evaluation.created_at
    for update skip locked
    limit 1
  )
  update public.coding_evaluation_jobs evaluation
  set status = 'processing',
      attempts = evaluation.attempts + 1,
      lease_token = gen_random_uuid(),
      locked_by = worker_id,
      locked_until = now() + make_interval(secs => lease_seconds),
      updated_at = now()
  from next_job
  where evaluation.id = next_job.id
  returning evaluation.*;
end;
$$;

create or replace function public.resume_coding_evaluation_jobs()
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
  update public.coding_evaluation_jobs
  set status = 'queued',
      available_at = now(),
      last_error_code = null,
      failure_reason = null,
      updated_at = now()
  where status = 'waiting_configuration';
  get diagnostics changed_rows = row_count;
  return changed_rows;
end;
$$;

create or replace function public.complete_coding_evaluation_job(
  target_job_id uuid,
  target_lease_token uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  evaluation_row public.coding_evaluation_jobs%rowtype;
  submission_row public.coding_submissions%rowtype;
  result_row public.coding_question_results%rowtype;
  score_value numeric(5, 2);
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  select evaluation.*
  into evaluation_row
  from public.coding_evaluation_jobs evaluation
  where evaluation.id = target_job_id
    and evaluation.status = 'processing'
    and evaluation.lease_token = target_lease_token
    and evaluation.locked_until >= now()
  for update;
  if not found then
    raise exception 'Coding evaluation lease is no longer valid.';
  end if;
  select submission.*
  into submission_row
  from public.coding_submissions submission
  where submission.workspace_id = evaluation_row.workspace_id
    and submission.id = evaluation_row.submission_id
  for update;
  select result.*
  into result_row
  from public.coding_question_results result
  where result.workspace_id = evaluation_row.workspace_id
    and result.submission_id = evaluation_row.submission_id;
  if not found then
    raise exception 'Coding evaluation results were not persisted.';
  end if;
  score_value := round(result_row.score / nullif(result_row.maximum_score, 0) * 100, 2);

  update public.coding_submissions
  set status = 'completed',
      evaluated_at = coalesce(evaluated_at, now())
  where id = submission_row.id;
  if submission_row.is_final then
    update public.coding_attempts
    set status = 'completed',
        score = score_value,
        evaluated_at = now(),
        completed_at = now(),
        error_code = null,
        updated_at = now()
    where workspace_id = submission_row.workspace_id
      and id = submission_row.attempt_id;
    update public.coding_invitations invitation
    set status = case
      when (
        select attempt.attempt_number
        from public.coding_attempts attempt
        where attempt.id = submission_row.attempt_id
      ) >= invitation.max_attempts then 'completed'
      else 'started'
    end,
    updated_at = now()
    where invitation.workspace_id = submission_row.workspace_id
      and invitation.id = (
        select attempt.invitation_id
        from public.coding_attempts attempt
        where attempt.id = submission_row.attempt_id
      );
  end if;
  update public.coding_evaluation_jobs
  set status = 'completed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = null,
      failure_reason = null,
      completed_at = now(),
      updated_at = now()
  where id = evaluation_row.id;
  return submission_row.id;
end;
$$;

create or replace function public.fail_coding_evaluation_job(
  target_job_id uuid,
  target_lease_token uuid,
  target_error_code text,
  target_failure_reason text,
  retryable boolean
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  evaluation_row public.coding_evaluation_jobs%rowtype;
  submission_row public.coding_submissions%rowtype;
  next_status text;
  retry_seconds integer;
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  select evaluation.*
  into evaluation_row
  from public.coding_evaluation_jobs evaluation
  where evaluation.id = target_job_id
    and evaluation.status = 'processing'
    and evaluation.lease_token = target_lease_token
    and evaluation.locked_until >= now()
  for update;
  if not found then
    raise exception 'Coding evaluation lease is no longer valid.';
  end if;
  select submission.*
  into submission_row
  from public.coding_submissions submission
  where submission.workspace_id = evaluation_row.workspace_id
    and submission.id = evaluation_row.submission_id
  for update;

  next_status := case
    when retryable and evaluation_row.attempts < evaluation_row.max_attempts
      then 'retry_wait'
    else 'failed'
  end;
  retry_seconds := least(
    3600::numeric,
    15::numeric * power(2::numeric, greatest(evaluation_row.attempts - 1, 0))
  )::integer;
  update public.coding_evaluation_jobs
  set status = next_status,
      available_at = case
        when next_status = 'retry_wait'
          then now() + make_interval(secs => retry_seconds)
        else available_at
      end,
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = left(coalesce(target_error_code, 'evaluation_failed'), 80),
      failure_reason = left(coalesce(target_failure_reason, 'Coding evaluation failed.'), 500),
      updated_at = now()
  where id = evaluation_row.id;
  update public.coding_submissions
  set status = case when next_status = 'failed' then 'failed' else 'queued' end,
      evaluated_at = case when next_status = 'failed' then now() else null end
  where id = submission_row.id;
  if submission_row.is_final and next_status = 'failed' then
    update public.coding_attempts
    set status = 'failed',
        evaluated_at = now(),
        completed_at = now(),
        error_code = left(coalesce(target_error_code, 'evaluation_failed'), 80),
        updated_at = now()
    where workspace_id = submission_row.workspace_id
      and id = submission_row.attempt_id;
    update public.coding_invitations invitation
    set status = case
      when (
        select attempt.attempt_number
        from public.coding_attempts attempt
        where attempt.id = submission_row.attempt_id
      ) >= invitation.max_attempts then 'completed'
      else 'started'
    end,
    updated_at = now()
    where invitation.workspace_id = submission_row.workspace_id
      and invitation.id = (
        select attempt.invitation_id
        from public.coding_attempts attempt
        where attempt.id = submission_row.attempt_id
      );
  end if;
  return next_status;
end;
$$;

revoke all on function public.validate_coding_invitation()
  from public, anon, authenticated;
revoke all on function public.validate_coding_attempt()
  from public, anon, authenticated;
revoke all on function public.get_coding_test_cases(uuid, uuid)
  from public, anon;
revoke all on function public.save_coding_submission(uuid, uuid, uuid, text, text, boolean)
  from public, anon, authenticated;
revoke all on function public.queue_coding_evaluation()
  from public, anon, authenticated;
revoke all on function public.claim_coding_evaluation_jobs(text, integer)
  from public, anon, authenticated;
revoke all on function public.resume_coding_evaluation_jobs()
  from public, anon, authenticated;
revoke all on function public.complete_coding_evaluation_job(uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.fail_coding_evaluation_job(uuid, uuid, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.get_coding_test_cases(uuid, uuid)
  to authenticated;
grant execute on function public.save_coding_submission(uuid, uuid, uuid, text, text, boolean)
  to service_role;
grant execute on function public.claim_coding_evaluation_jobs(text, integer)
  to service_role;
grant execute on function public.resume_coding_evaluation_jobs()
  to service_role;
grant execute on function public.complete_coding_evaluation_job(uuid, uuid)
  to service_role;
grant execute on function public.fail_coding_evaluation_job(uuid, uuid, text, text, boolean)
  to service_role;

create or replace function public.capture_email_delivery_status()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  related_email_status text;
begin
  related_email_status := case
    when new.status = 'delivered' then 'delivered'
    when new.status = 'sent' then 'sent'
    when new.status in ('queued', 'processing', 'retry_wait') then 'queued'
    else 'failed'
  end;
  if new.aptitude_invitation_id is not null then
    update public.aptitude_invitations
    set email_status = related_email_status,
        email_provider_message_id = coalesce(
          new.provider_message_id,
          email_provider_message_id
        ),
        email_error_code = case
          when related_email_status = 'failed' then new.last_error_code
          else null
        end,
        sent_at = coalesce(new.sent_at, sent_at)
    where workspace_id = new.workspace_id
      and id = new.aptitude_invitation_id;
  end if;
  return new;
end;
$$;

create trigger email_delivery_jobs_update_invitation_status
after update of status, provider_message_id, last_error_code, sent_at
on public.email_delivery_jobs
for each row
when (
  old.status is distinct from new.status
  or old.provider_message_id is distinct from new.provider_message_id
  or old.last_error_code is distinct from new.last_error_code
  or old.sent_at is distinct from new.sent_at
)
execute function public.capture_email_delivery_status();

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
    'manual_required',
    0,
    5,
    'email_sender_not_configured'
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger aptitude_invitations_create_email_delivery
after insert on public.aptitude_invitations
for each row execute function public.enqueue_manual_aptitude_invitation_email();

create or replace function public.enqueue_manual_coding_invitation_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    coding_invitation_id,
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
    'coding_invitation',
    'coding-invitation-v1',
    new.candidate_email,
    'coding-invitation:' || new.id::text,
    'manual_required',
    0,
    5,
    'email_sender_not_configured'
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger coding_invitations_create_email_delivery
after insert on public.coding_invitations
for each row execute function public.enqueue_manual_coding_invitation_email();

create or replace function public.enqueue_manual_interview_invitation_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate_email_value text;
begin
  if new.interview_status <> 'scheduled' then
    return new;
  end if;
  select candidate.email
  into candidate_email_value
  from public.applications application
  join public.candidates candidate
    on candidate.workspace_id = application.workspace_id
   and candidate.id = application.candidate_id
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if candidate_email_value is null then
    return new;
  end if;
  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    interview_record_id,
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
    'interview_invitation',
    'interview-invitation-v1',
    candidate_email_value,
    'interview-invitation:' || new.id::text,
    'manual_required',
    0,
    5,
    'email_sender_not_configured'
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger interview_records_create_email_delivery
after insert on public.interview_records
for each row execute function public.enqueue_manual_interview_invitation_email();

create or replace function public.enqueue_manual_interview_update_email()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  candidate_email_value text;
begin
  if new.interview_status not in ('scheduled', 'rescheduled', 'cancelled')
     or (
       new.scheduled_at is not distinct from old.scheduled_at
       and new.scheduled_end_at is not distinct from old.scheduled_end_at
       and new.timezone is not distinct from old.timezone
       and new.interview_mode is not distinct from old.interview_mode
       and new.location_or_url is not distinct from old.location_or_url
       and new.interview_status is not distinct from old.interview_status
     ) then
    return new;
  end if;
  select candidate.email
  into candidate_email_value
  from public.applications application
  join public.candidates candidate
    on candidate.workspace_id = application.workspace_id
   and candidate.id = application.candidate_id
  where application.workspace_id = new.workspace_id
    and application.id = new.application_id;
  if candidate_email_value is null then
    return new;
  end if;
  insert into public.email_delivery_jobs (
    workspace_id,
    application_id,
    interview_record_id,
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
    'interview_update',
    'interview-update-v1',
    candidate_email_value,
    'interview-update:' || new.id::text || ':' || new.updated_at::text,
    'manual_required',
    0,
    5,
    'email_sender_not_configured'
  )
  on conflict (idempotency_key) do nothing;
  return new;
end;
$$;

create trigger interview_records_z_enqueue_update_email
after update of scheduled_at, scheduled_end_at, timezone, interview_mode,
  location_or_url, interview_status
on public.interview_records
for each row execute function public.enqueue_manual_interview_update_email();

revoke all on function public.capture_email_delivery_status()
  from public, anon, authenticated;
revoke all on function public.enqueue_manual_aptitude_invitation_email()
  from public, anon, authenticated;
revoke all on function public.enqueue_manual_coding_invitation_email()
  from public, anon, authenticated;
revoke all on function public.enqueue_manual_interview_invitation_email()
  from public, anon, authenticated;
revoke all on function public.enqueue_manual_interview_update_email()
  from public, anon, authenticated;

create or replace function public.claim_email_delivery_jobs(
  worker_id text,
  lease_seconds integer default 120
)
returns setof public.email_delivery_jobs
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.role() is distinct from 'service_role' then
    raise exception 'Service role is required.';
  end if;
  if worker_id is null or char_length(trim(worker_id)) not between 1 and 120 then
    raise exception 'Worker identifier is invalid.';
  end if;
  lease_seconds := greatest(30, least(coalesce(lease_seconds, 120), 600));

  update public.email_delivery_jobs delivery
  set status = 'failed',
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = 'lease_expired',
      updated_at = now()
  where delivery.status = 'processing'
    and delivery.locked_until < now()
    and delivery.attempts >= delivery.max_attempts;

  return query
  with next_job as (
    select delivery.id
    from public.email_delivery_jobs delivery
    where delivery.attempts < delivery.max_attempts
      and (
        (delivery.status in ('queued', 'retry_wait')
          and delivery.next_attempt_at <= now())
        or (
          delivery.status = 'processing'
          and delivery.locked_until < now()
        )
      )
    order by delivery.next_attempt_at, delivery.created_at
    for update skip locked
    limit 1
  )
  update public.email_delivery_jobs delivery
  set status = 'processing',
      attempts = delivery.attempts + 1,
      lease_token = gen_random_uuid(),
      locked_by = worker_id,
      locked_until = now() + make_interval(secs => lease_seconds),
      updated_at = now()
  from next_job
  where delivery.id = next_job.id
  returning delivery.*;
end;
$$;

create or replace function public.complete_email_delivery_job(
  target_job_id uuid,
  target_lease_token uuid,
  target_provider_message_id text default null
)
returns uuid
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
  update public.email_delivery_jobs
  set status = 'sent',
      provider_message_id = nullif(left(trim(coalesce(target_provider_message_id, '')), 250),
        ''),
      sent_at = coalesce(sent_at, now()),
      delivered_at = null,
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = null,
      updated_at = now()
  where id = target_job_id
    and status = 'processing'
    and lease_token = target_lease_token
    and locked_until >= now()
  returning * into delivery_row;
  if not found then
    raise exception 'Email delivery lease is no longer valid.';
  end if;
  insert into public.email_delivery_attempts (
    workspace_id,
    delivery_job_id,
    attempt_number,
    status,
    provider_message_id
  )
  values (
    delivery_row.workspace_id,
    delivery_row.id,
    delivery_row.attempts,
    'sent',
    delivery_row.provider_message_id
  )
  on conflict (delivery_job_id, attempt_number) do nothing;
  return delivery_row.id;
end;
$$;

create or replace function public.mark_email_delivery_delivered(
  target_job_id uuid,
  target_provider_message_id text default null
)
returns uuid
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
  update public.email_delivery_jobs
  set status = 'delivered',
      provider_message_id = coalesce(
        nullif(left(trim(coalesce(target_provider_message_id, '')), 250), ''),
        provider_message_id
      ),
      delivered_at = coalesce(delivered_at, now()),
      updated_at = now()
  where id = target_job_id
    and status in ('sent', 'delivered')
    and (
      target_provider_message_id is null
      or provider_message_id is null
      or provider_message_id = target_provider_message_id
    )
  returning * into delivery_row;
  if not found then
    raise exception 'The sent email delivery record was not found.';
  end if;
  update public.email_delivery_attempts
  set status = 'delivered',
      provider_message_id = coalesce(
        delivery_row.provider_message_id,
        provider_message_id
      ),
      completed_at = coalesce(completed_at, now())
  where delivery_job_id = delivery_row.id
    and attempt_number = delivery_row.attempts;
  return delivery_row.id;
end;
$$;

create or replace function public.fail_email_delivery_job(
  target_job_id uuid,
  target_lease_token uuid,
  target_error_code text,
  retryable boolean
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  delivery_row public.email_delivery_jobs%rowtype;
  next_status text;
  retry_seconds integer;
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
    and delivery.locked_until >= now()
  for update;
  if not found then
    raise exception 'Email delivery lease is no longer valid.';
  end if;

  next_status := case
    when retryable and delivery_row.attempts < delivery_row.max_attempts
      then 'retry_wait'
    else 'failed'
  end;
  retry_seconds := least(
    3600::numeric,
    30::numeric * power(2::numeric, greatest(delivery_row.attempts - 1, 0))
  )::integer;
  update public.email_delivery_jobs
  set status = next_status,
      next_attempt_at = case
        when next_status = 'retry_wait'
          then now() + make_interval(secs => retry_seconds)
        else next_attempt_at
      end,
      lease_token = null,
      locked_by = null,
      locked_until = null,
      last_error_code = left(coalesce(target_error_code, 'email_delivery_failed'), 100),
      updated_at = now()
  where id = delivery_row.id
  returning * into delivery_row;

  insert into public.email_delivery_attempts (
    workspace_id,
    delivery_job_id,
    attempt_number,
    status,
    error_code
  )
  values (
    delivery_row.workspace_id,
    delivery_row.id,
    delivery_row.attempts,
    next_status,
    delivery_row.last_error_code
  )
  on conflict (delivery_job_id, attempt_number) do nothing;
  return next_status;
end;
$$;

revoke all on function public.claim_email_delivery_jobs(text, integer)
  from public, anon, authenticated;
revoke all on function public.complete_email_delivery_job(uuid, uuid, text)
  from public, anon, authenticated;
revoke all on function public.mark_email_delivery_delivered(uuid, text)
  from public, anon, authenticated;
revoke all on function public.fail_email_delivery_job(uuid, uuid, text, boolean)
  from public, anon, authenticated;
grant execute on function public.claim_email_delivery_jobs(text, integer)
  to service_role;
grant execute on function public.complete_email_delivery_job(uuid, uuid, text)
  to service_role;
grant execute on function public.mark_email_delivery_delivered(uuid, text)
  to service_role;
grant execute on function public.fail_email_delivery_job(uuid, uuid, text, boolean)
  to service_role;

-- Persist a manual-delivery record for existing invitations without creating
-- duplicate records or implying that an email was sent.
insert into public.email_delivery_jobs (
  workspace_id,
  application_id,
  aptitude_invitation_id,
  email_type,
  template_key,
  recipient_email,
  idempotency_key,
  status,
  provider_message_id,
  sent_at,
  last_error_code
)
select
  invitation.workspace_id,
  invitation.application_id,
  invitation.id,
  'aptitude_invitation',
  'aptitude-invitation-v1',
  invitation.candidate_email,
  'aptitude-invitation:' || invitation.id::text,
  case invitation.email_status
    when 'queued' then 'queued'
    when 'sent' then 'sent'
    when 'delivered' then 'delivered'
    when 'failed' then case
      when invitation.email_error_code = 'manual_delivery' then 'manual_required'
      else 'failed'
    end
    else 'manual_required'
  end,
  invitation.email_provider_message_id,
  invitation.sent_at,
  left(case
    when invitation.email_error_code = 'manual_delivery' then 'email_sender_not_configured'
    else invitation.email_error_code
  end, 100)
from public.aptitude_invitations invitation
on conflict (idempotency_key) do nothing;

insert into public.email_delivery_jobs (
  workspace_id,
  application_id,
  interview_record_id,
  email_type,
  template_key,
  recipient_email,
  idempotency_key,
  status,
  last_error_code
)
select
  interview.workspace_id,
  interview.application_id,
  interview.id,
  'interview_invitation',
  'interview-invitation-v1',
  candidate.email,
  'interview-invitation:' || interview.id::text,
  'manual_required',
  'email_sender_not_configured'
from public.interview_records interview
join public.applications application
  on application.workspace_id = interview.workspace_id
 and application.id = interview.application_id
join public.candidates candidate
  on candidate.workspace_id = application.workspace_id
 and candidate.id = application.candidate_id
where interview.interview_status = 'scheduled'
  and interview.scheduled_at >= now()
  and candidate.email is not null
on conflict (idempotency_key) do nothing;

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
  coalesce(aptitude.aptitude_status, 'not_invited') as aptitude_status,
  aptitude.score as aptitude_score,
  aptitude.submitted_at as aptitude_completed_at,
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
    coalesce(attempt.status, invitation.status) as aptitude_status,
    attempt.score,
    attempt.submitted_at
  from public.aptitude_invitations invitation
  left join public.aptitude_attempts attempt
    on attempt.workspace_id = invitation.workspace_id
   and attempt.invitation_id = invitation.id
  where invitation.workspace_id = application.workspace_id
    and invitation.application_id = application.id
  order by attempt.submitted_at desc nulls last, attempt.created_at desc
  limit 1
) aptitude on true
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

commit;
