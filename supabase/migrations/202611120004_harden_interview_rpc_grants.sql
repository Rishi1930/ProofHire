-- Tighten interview RPC grants.
--
-- 202611120001 granted execute on every interview function to anon,
-- authenticated and service_role, which exposed the evaluation worker's
-- functions to any visitor: an anonymous caller could claim a submission and
-- complete it with an arbitrary score. Candidate functions stay reachable
-- without a session because access is mediated by the hashed token; recruiter
-- and worker functions are restricted to the roles that need them.
--
-- Safe to run more than once.

begin;

revoke all on function public.claim_interview_code_submissions(text, integer)
  from public, anon, authenticated;
grant execute on function public.claim_interview_code_submissions(text, integer)
  to service_role;

revoke all on function public.complete_interview_code_submission(
  uuid, uuid, text, numeric, integer, integer, jsonb, text
) from public, anon, authenticated;
grant execute on function public.complete_interview_code_submission(
  uuid, uuid, text, numeric, integer, integer, jsonb, text
) to service_role;

revoke all on function public.create_interview_session(
  uuid, uuid[], uuid[], integer, integer, numeric
) from public, anon;
grant execute on function public.create_interview_session(
  uuid, uuid[], uuid[], integer, integer, numeric
) to authenticated, service_role;

revoke all on function public.interview_session_overview(uuid, uuid[])
  from public, anon;
grant execute on function public.interview_session_overview(uuid, uuid[])
  to authenticated, service_role;

revoke all on function public.send_interview_invitation(uuid, text)
  from public, anon;
grant execute on function public.send_interview_invitation(uuid, text)
  to authenticated, service_role;

commit;
