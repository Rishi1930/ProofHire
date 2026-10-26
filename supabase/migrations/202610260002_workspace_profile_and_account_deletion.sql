-- Workspace profile fields and a recoverable, 15-day account deletion flow.

begin;

alter table public.workspaces
  add column if not exists company_website text,
  add column if not exists company_industry text,
  add column if not exists company_size text,
  add column if not exists company_location text,
  add column if not exists company_phone text;

create table if not exists public.account_deletion_requests (
  user_id uuid primary key references auth.users(id) on delete cascade,
  requested_at timestamptz not null default now(),
  scheduled_for timestamptz not null,
  status text not null default 'pending'
    check (status in ('pending', 'processing')),
  processing_started_at timestamptz
);

alter table public.account_deletion_requests enable row level security;

drop policy if exists "Users can read their own deletion request"
  on public.account_deletion_requests;

create policy "Users can read their own deletion request"
on public.account_deletion_requests
for select
to authenticated
using (user_id = (select auth.uid()));

revoke all on public.account_deletion_requests from anon, authenticated;
grant select on public.account_deletion_requests to authenticated;

create or replace function public.request_account_deletion()
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  requesting_user uuid := (select auth.uid());
  deletion_date timestamptz;
begin
  if requesting_user is null then
    raise exception 'Sign in before requesting account deletion.';
  end if;

  insert into public.account_deletion_requests (
    user_id,
    requested_at,
    scheduled_for,
    status,
    processing_started_at
  )
  values (
    requesting_user,
    now(),
    now() + interval '15 days',
    'pending',
    null
  )
  on conflict (user_id) do update
    set requested_at = excluded.requested_at,
        scheduled_for = excluded.scheduled_for,
        status = 'pending',
        processing_started_at = null
    where public.account_deletion_requests.status = 'pending'
  returning scheduled_for into deletion_date;

  if deletion_date is null then
    raise exception 'Account deletion has already started and can no longer be canceled.';
  end if;

  return deletion_date;
end;
$$;

create or replace function public.cancel_account_deletion()
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  requesting_user uuid := (select auth.uid());
begin
  if requesting_user is null then
    raise exception 'Sign in before canceling account deletion.';
  end if;

  delete from public.account_deletion_requests
  where user_id = requesting_user
    and status = 'pending';

  return found;
end;
$$;

create or replace function public.claim_due_account_deletions()
returns table (user_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with due_requests as (
    select request.user_id
    from public.account_deletion_requests as request
    where (
        request.status = 'pending'
        and request.scheduled_for <= now()
      )
      or (
        request.status = 'processing'
        and request.processing_started_at < now() - interval '1 hour'
      )
    order by request.scheduled_for
    limit 100
    for update skip locked
  )
  update public.account_deletion_requests as request
  set status = 'processing',
      processing_started_at = now()
  from due_requests
  where request.user_id = due_requests.user_id
  returning request.user_id;
end;
$$;

revoke all on function public.request_account_deletion() from public, anon;
revoke all on function public.cancel_account_deletion() from public, anon;
revoke all on function public.claim_due_account_deletions()
  from public, anon, authenticated;

grant execute on function public.request_account_deletion() to authenticated;
grant execute on function public.cancel_account_deletion() to authenticated;
grant execute on function public.claim_due_account_deletions() to service_role;

commit;
