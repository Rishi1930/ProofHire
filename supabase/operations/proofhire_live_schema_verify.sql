-- Read-only verification queries for the ProofHire completion migration.

with expected_objects(schema_name, object_name, object_kind) as (
  values
    ('public', 'application_decision_events', 'table'),
    ('public', 'application_resume_versions', 'table'),
    ('public', 'job_screening_criteria', 'table'),
    ('public', 'application_screening_jobs', 'table'),
    ('public', 'application_screening_assessments', 'table'),
    ('public', 'aptitude_tests', 'table'),
    ('public', 'aptitude_test_versions', 'table'),
    ('public', 'aptitude_questions', 'table'),
    ('public', 'aptitude_question_options', 'table'),
    ('public', 'aptitude_invitations', 'table'),
    ('public', 'aptitude_attempts', 'table'),
    ('public', 'aptitude_answers', 'table'),
    ('public', 'aptitude_monitoring_events', 'table'),
    ('public', 'job_aptitude_assessments', 'table'),
    ('public', 'aptitude_attempt_questions', 'table'),
    ('public', 'coding_challenges', 'table'),
    ('public', 'coding_challenge_versions', 'table'),
    ('public', 'job_coding_assessments', 'table'),
    ('public', 'coding_invitations', 'table'),
    ('public', 'coding_attempts', 'table'),
    ('public', 'coding_submissions', 'table'),
    ('public', 'coding_question_results', 'table'),
    ('public', 'coding_evaluation_jobs', 'table'),
    ('public', 'interview_records', 'table'),
    ('public', 'interview_schedule_events', 'table'),
    ('public', 'interview_assignments', 'table'),
    ('public', 'interview_feedback', 'table'),
    ('public', 'interview_feedback_criteria', 'table'),
    ('public', 'application_stage_history', 'table'),
    ('public', 'email_delivery_jobs', 'table'),
    ('public', 'email_delivery_attempts', 'table'),
    ('proofhire_private', 'aptitude_answer_keys', 'table'),
    ('proofhire_private', 'aptitude_answer_scores', 'table'),
    ('proofhire_private', 'coding_test_cases', 'table'),
    ('proofhire_private', 'coding_submission_sources', 'table'),
    ('proofhire_private', 'coding_test_case_results', 'table'),
    ('public', 'application_recruitment_stage_summary', 'view')
)
select
  expected_objects.schema_name || '.' || expected_objects.object_name as object_name,
  expected_objects.object_kind,
  relation.relname is not null as exists,
  relation.relrowsecurity as rls_enabled,
  relation.relforcerowsecurity as rls_forced
from expected_objects
left join pg_class relation
  on relation.oid = to_regclass(
    format('%I.%I', expected_objects.schema_name, expected_objects.object_name)
  )
order by expected_objects.schema_name, expected_objects.object_name;

-- Verify representative worker/API routines and automation triggers.
select 'function' as object_kind, routine.routine_schema || '.' || routine.routine_name
  as object_name, true as exists
from information_schema.routines routine
where routine.routine_schema = 'public'
  and routine.routine_name in (
    'claim_application_screening_job',
    'complete_application_screening_job',
    'fail_application_screening_job',
    'create_aptitude_invitation',
    'get_aptitude_candidate_session',
    'start_aptitude_candidate_attempt',
    'save_aptitude_candidate_answer',
    'submit_aptitude_candidate_attempt',
    'claim_coding_evaluation_jobs',
    'complete_coding_evaluation_job',
    'claim_email_delivery_jobs',
    'complete_email_delivery_job',
    'record_application_decision'
  )
union all
select 'trigger', trigger_schema || '.' || event_object_table || '.' || trigger_name, true
from information_schema.triggers
where trigger_schema = 'public'
  and trigger_name in (
    'applications_capture_stage_history',
    'applications_capture_resume_version',
    'applications_queue_screening',
    'interview_records_capture_schedule_history',
    'coding_submissions_queue_evaluation',
    'aptitude_invitations_create_email_delivery'
  )
order by object_kind, object_name;

-- Confirm core policies were narrowed without removing workspace read access.
select schemaname, tablename, policyname, cmd, roles
from pg_policies
where schemaname = 'public'
  and policyname in (
    'Members can create workspace applications',
    'Members can update workspace applications',
    'Members can delete workspace applications',
    'Members can create workspace candidates',
    'Members can update workspace candidates',
    'Members can delete workspace candidates',
    'Members can read workspace applications',
    'Members can read workspace candidates',
    'Recruiters can create applications',
    'Recruiters can update applications',
    'Workspace admins can delete applications',
    'Recruiters can create candidates',
    'Recruiters can update candidates',
    'Workspace admins can delete candidates'
  )
order by tablename, policyname;

-- Verify private resume storage remains configured and its object policies exist.
select
  bucket.id,
  bucket.public,
  bucket.file_size_limit,
  bucket.allowed_mime_types,
  count(policy.policyname) as storage_object_policy_count
from storage.buckets bucket
left join pg_policies policy
  on policy.schemaname = 'storage'
 and policy.tablename = 'objects'
where bucket.id = 'candidate-resumes'
group by bucket.id, bucket.public, bucket.file_size_limit, bucket.allowed_mime_types;
