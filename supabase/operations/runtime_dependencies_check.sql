-- Runtime dependency check.
--
-- The React app, the screening engine, the interview evaluator and the email
-- worker each depend on database objects that live in different migrations.
-- This lists every object those runtimes need, so a single paste shows exactly
-- what is missing. Rows with present = false are the blockers.

with required(kind, name) as (
  values
    -- Screening queue (migration 202611030001)
    ('table',    'public.application_screening_jobs'),
    ('table',    'public.job_screening_requirements'),
    ('function', 'enqueue_application_screening'),
    ('function', 'resume_application_screening_jobs'),
    ('function', 'claim_application_screening_job'),
    ('function', 'complete_application_screening_job'),
    ('function', 'fail_application_screening_job'),
    ('function', 'replace_job_screening_requirements'),

    -- Email delivery queue (migration 202611020003)
    ('table',    'public.email_delivery_jobs'),
    ('table',    'public.email_delivery_attempts'),
    ('function', 'set_email_delivery_configuration'),
    ('function', 'claim_email_delivery_jobs'),
    ('function', 'get_email_delivery_context'),
    ('function', 'complete_email_delivery_job'),
    ('function', 'fail_email_delivery_job'),

    -- Coding content the interview engine attaches to sessions
    ('table',    'public.coding_challenges'),
    ('table',    'public.coding_challenge_versions'),
    ('table',    'proofhire_private.coding_test_cases'),

    -- Technical interview engine (migration 202611120001)
    ('table',    'public.interview_questions'),
    ('table',    'public.interview_sessions'),
    ('table',    'public.interview_code_submissions'),
    ('table',    'public.interview_proctor_events'),
    ('function', 'create_interview_session'),
    ('function', 'interview_candidate_state'),
    ('function', 'claim_interview_code_submissions'),
    ('function', 'complete_interview_code_submission')
)
select
  required.kind,
  required.name,
  case required.kind
    when 'table' then to_regclass(required.name) is not null
    else exists (
      select 1
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = required.name
    )
  end as present
from required
order by present, required.kind, required.name;

-- Queue depth: proves whether work is waiting for a worker that never runs.
-- Wrapped in a DO block so a missing table cannot hide the result above.
do $$
declare
  total bigint;
begin
  if to_regclass('public.application_screening_jobs') is not null then
    execute 'select count(*) from public.application_screening_jobs' into total;
    raise notice 'application_screening_jobs rows: %', total;
  end if;

  if to_regclass('public.email_delivery_jobs') is not null then
    execute 'select count(*) from public.email_delivery_jobs' into total;
    raise notice 'email_delivery_jobs rows: %', total;
  end if;

  if to_regclass('public.interview_code_submissions') is not null then
    execute 'select count(*) from public.interview_code_submissions' into total;
    raise notice 'interview_code_submissions rows: %', total;
  end if;
end
$$;
