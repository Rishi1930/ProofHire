-- Align the application default with the current status constraint and index
-- the account-deletion worker's due-request scan.

begin;

alter table public.applications
  alter column status set default 'new';

create index if not exists idx_account_deletions_pending_schedule
  on public.account_deletion_requests(scheduled_for)
  where status = 'pending';

create index if not exists idx_account_deletions_processing_started
  on public.account_deletion_requests(processing_started_at)
  where status = 'processing';

commit;
