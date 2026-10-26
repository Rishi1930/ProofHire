
-- ProofHire: Private resume storage and access policies
-- Apply after migrations 001, 002 and 003.

begin;

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'candidate-resumes',
  'candidate-resumes',
  false,
  5242880,
  array[
    'application/pdf',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  ]
)
on conflict (id) do update set
  public = false,
  file_size_limit = 5242880,
  allowed_mime_types = excluded.allowed_mime_types;

-- =========================================================
-- PUBLIC APPLICATION UPLOADS
-- Object path: workspace_id/job_id/randomfilename.pdf
-- =========================================================

drop policy if exists "Public applicants can upload resumes to open jobs"
  on storage.objects;

create policy "Public applicants can upload resumes to open jobs"
on storage.objects
for insert
to anon, authenticated
with check (
  bucket_id = 'candidate-resumes'
  and array_length(storage.foldername(name), 1) = 2
  and exists (
    select 1
    from public.jobs j
    where j.workspace_id::text = (storage.foldername(name))[1]
      and j.id::text = (storage.foldername(name))[2]
      and j.status = 'open'
  )
  and storage.filename(name) ~ '^[A-Za-z0-9_-]+\.(pdf|doc|docx)$'
);

-- =========================================================
-- AUTHENTICATED WORKSPACE MEMBERS
-- Private resume reads are allowed only inside the member's
-- workspace. Signed URLs should be short-lived.
-- =========================================================

drop policy if exists "Workspace members can read their resumes"
  on storage.objects;

create policy "Workspace members can read their resumes"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'candidate-resumes'
  and array_length(storage.foldername(name), 1) >= 2
  and exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id::text = (storage.foldername(name))[1]
      and wm.user_id = (select auth.uid())
  )
);

-- Recruiters can upload or replace resumes inside their workspace.
drop policy if exists "Recruiters can upload workspace resumes"
  on storage.objects;

create policy "Recruiters can upload workspace resumes"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'candidate-resumes'
  and array_length(storage.foldername(name), 1) >= 2
  and exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id::text = (storage.foldername(name))[1]
      and wm.user_id = (select auth.uid())
      and wm.role in ('owner', 'admin', 'recruiter')
  )
);

drop policy if exists "Recruiters can update workspace resumes"
  on storage.objects;

create policy "Recruiters can update workspace resumes"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'candidate-resumes'
  and array_length(storage.foldername(name), 1) >= 2
  and exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id::text = (storage.foldername(name))[1]
      and wm.user_id = (select auth.uid())
      and wm.role in ('owner', 'admin', 'recruiter')
  )
)
with check (
  bucket_id = 'candidate-resumes'
  and array_length(storage.foldername(name), 1) >= 2
  and exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id::text = (storage.foldername(name))[1]
      and wm.user_id = (select auth.uid())
      and wm.role in ('owner', 'admin', 'recruiter')
  )
);

drop policy if exists "Workspace admins can delete resumes"
  on storage.objects;

create policy "Workspace admins can delete resumes"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'candidate-resumes'
  and array_length(storage.foldername(name), 1) >= 2
  and exists (
    select 1
    from public.workspace_members wm
    where wm.workspace_id::text = (storage.foldername(name))[1]
      and wm.user_id = (select auth.uid())
      and wm.role in ('owner', 'admin')
  )
);

commit;
