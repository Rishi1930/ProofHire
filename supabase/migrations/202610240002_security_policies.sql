
BEGIN;

-- 1. Security helper functions

CREATE OR REPLACE FUNCTION public.is_workspace_member(target_workspace uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.workspace_members AS wm
    WHERE wm.workspace_id = target_workspace
      AND wm.user_id = (SELECT auth.uid())
  );
$$;

CREATE OR REPLACE FUNCTION public.has_workspace_role(
  target_workspace_id uuid,
  allowed_roles text[]
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.workspace_members AS wm
    WHERE wm.workspace_id = target_workspace_id
      AND wm.user_id = (SELECT auth.uid())
      AND wm.role = ANY(allowed_roles)
  );
$$;

REVOKE ALL ON FUNCTION public.is_workspace_member(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.has_workspace_role(uuid, text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.is_workspace_member(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.has_workspace_role(uuid, text[]) TO authenticated;

-- 2. Enable RLS

ALTER TABLE public.workspaces ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workspace_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.candidates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.applications ENABLE ROW LEVEL SECURITY;

-- 3. Remove existing policies, including the legacy names

DROP POLICY IF EXISTS "Authenticated users can create workspaces" ON public.workspaces;
DROP POLICY IF EXISTS "Members can view their workspaces" ON public.workspaces;
DROP POLICY IF EXISTS "Members can read their workspaces" ON public.workspaces;
DROP POLICY IF EXISTS "Owners and admins can update workspaces" ON public.workspaces;

DROP POLICY IF EXISTS "Members can view workspace membership" ON public.workspace_members;
DROP POLICY IF EXISTS "Members can read workspace membership" ON public.workspace_members;
DROP POLICY IF EXISTS "Workspace creator can add themselves" ON public.workspace_members;

DROP POLICY IF EXISTS "Members can view workspace jobs" ON public.jobs;
DROP POLICY IF EXISTS "Members can read workspace jobs" ON public.jobs;
DROP POLICY IF EXISTS "Public can view open jobs" ON public.jobs;
DROP POLICY IF EXISTS "Public can read open job listings" ON public.jobs;
DROP POLICY IF EXISTS "Members can create workspace jobs" ON public.jobs;
DROP POLICY IF EXISTS "Recruiters can create jobs" ON public.jobs;
DROP POLICY IF EXISTS "Members can update workspace jobs" ON public.jobs;
DROP POLICY IF EXISTS "Recruiters can update jobs" ON public.jobs;
DROP POLICY IF EXISTS "Members can delete workspace jobs" ON public.jobs;
DROP POLICY IF EXISTS "Workspace admins can delete jobs" ON public.jobs;

DROP POLICY IF EXISTS "Members can view workspace candidates" ON public.candidates;
DROP POLICY IF EXISTS "Members can read workspace candidates" ON public.candidates;
DROP POLICY IF EXISTS "Members can add workspace candidates" ON public.candidates;
DROP POLICY IF EXISTS "Recruiters can create candidates" ON public.candidates;
DROP POLICY IF EXISTS "Recruiters can update candidates" ON public.candidates;
DROP POLICY IF EXISTS "Workspace admins can delete candidates" ON public.candidates;

DROP POLICY IF EXISTS "Members can view workspace applications" ON public.applications;
DROP POLICY IF EXISTS "Members can read workspace applications" ON public.applications;
DROP POLICY IF EXISTS "Members can add workspace applications" ON public.applications;
DROP POLICY IF EXISTS "Members can update workspace applications" ON public.applications;
DROP POLICY IF EXISTS "Recruiters can create applications" ON public.applications;
DROP POLICY IF EXISTS "Recruiters can update applications" ON public.applications;
DROP POLICY IF EXISTS "Workspace admins can delete applications" ON public.applications;

-- 4. Workspaces

CREATE POLICY "Members can read their workspaces"
ON public.workspaces FOR SELECT TO authenticated
USING (public.is_workspace_member(id));

CREATE POLICY "Owners and admins can update workspaces"
ON public.workspaces FOR UPDATE TO authenticated
USING (public.has_workspace_role(id, ARRAY['owner', 'admin']))
WITH CHECK (public.has_workspace_role(id, ARRAY['owner', 'admin']));

-- 5. Workspace membership

CREATE POLICY "Members can read workspace membership"
ON public.workspace_members FOR SELECT TO authenticated
USING (public.is_workspace_member(workspace_id));

-- Workspace creation and membership provisioning remain the responsibility
-- of the trusted auth trigger, not direct client inserts.

-- 6. Jobs

CREATE POLICY "Members can read workspace jobs"
ON public.jobs FOR SELECT TO authenticated
USING (public.is_workspace_member(workspace_id));

CREATE POLICY "Public can read open job listings"
ON public.jobs FOR SELECT TO anon, authenticated
USING (status = 'open');

CREATE POLICY "Recruiters can create jobs"
ON public.jobs FOR INSERT TO authenticated
WITH CHECK (
  public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter'])
  AND created_by = (SELECT auth.uid())
);

CREATE POLICY "Recruiters can update jobs"
ON public.jobs FOR UPDATE TO authenticated
USING (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter']))
WITH CHECK (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter']));

CREATE POLICY "Workspace admins can delete jobs"
ON public.jobs FOR DELETE TO authenticated
USING (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin']));

-- 7. Candidates

CREATE POLICY "Members can read workspace candidates"
ON public.candidates FOR SELECT TO authenticated
USING (public.is_workspace_member(workspace_id));

CREATE POLICY "Recruiters can create candidates"
ON public.candidates FOR INSERT TO authenticated
WITH CHECK (
  public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter'])
  AND created_by = (SELECT auth.uid())
);

CREATE POLICY "Recruiters can update candidates"
ON public.candidates FOR UPDATE TO authenticated
USING (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter']))
WITH CHECK (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter']));

CREATE POLICY "Workspace admins can delete candidates"
ON public.candidates FOR DELETE TO authenticated
USING (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin']));

-- 8. Applications

CREATE POLICY "Members can read workspace applications"
ON public.applications FOR SELECT TO authenticated
USING (public.is_workspace_member(workspace_id));

CREATE POLICY "Recruiters can create applications"
ON public.applications FOR INSERT TO authenticated
WITH CHECK (
  public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter'])
  AND (created_by IS NULL OR created_by = (SELECT auth.uid()))
  AND EXISTS (
    SELECT 1 FROM public.jobs AS j
    WHERE j.id = applications.job_id
      AND j.workspace_id = applications.workspace_id
  )
  AND EXISTS (
    SELECT 1 FROM public.candidates AS c
    WHERE c.id = applications.candidate_id
      AND c.workspace_id = applications.workspace_id
  )
);

CREATE POLICY "Recruiters can update applications"
ON public.applications FOR UPDATE TO authenticated
USING (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter']))
WITH CHECK (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin', 'recruiter']));

CREATE POLICY "Workspace admins can delete applications"
ON public.applications FOR DELETE TO authenticated
USING (public.has_workspace_role(workspace_id, ARRAY['owner', 'admin']));

COMMIT;
