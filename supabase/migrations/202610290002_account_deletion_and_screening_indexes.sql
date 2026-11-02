-- Preserve recruiter audit records when a user account is deleted, and index
-- the screening worker's expired-lease recovery query.

begin;

alter table public.application_decision_events
  alter column created_by drop not null,
  drop constraint if exists application_decision_events_created_by_fkey,
  add constraint application_decision_events_created_by_fkey
    foreign key (created_by)
    references auth.users(id)
    on delete set null;

alter table public.interview_records
  alter column created_by drop not null,
  drop constraint if exists interview_records_created_by_fkey,
  add constraint interview_records_created_by_fkey
    foreign key (created_by)
    references auth.users(id)
    on delete set null;

create index if not exists idx_screening_jobs_expired_lease
  on public.application_screening_jobs(locked_until, created_at)
  where status = 'processing';

commit;
