import { supabase } from '../lib/supabase'

export type InterviewStatus =
  | 'ready'
  | 'in_progress'
  | 'questions_submitted'
  | 'coding'
  | 'submitted'
  | 'completed'
  | 'expired'
  | 'cancelled'

export type CandidateQuestion = {
  question_id: string
  display_order: number
  prompt: string
  category: string
  max_points: number
  answer: string
}

export type CandidateChallenge = {
  challenge_version_id: string
  display_order: number
  points: number
  prompt: string
  difficulty: string
  supported_languages: string[]
  starter_code: Record<string, string>
  max_execution_seconds: number
  draft_language: string | null
  draft_source: string | null
  sample_tests: { display_order: number; input_text: string; expected_output: string }[]
}

export type CandidateState = {
  session_id: string
  status: InterviewStatus
  job_title: string | null
  candidate_name: string | null
  questions_time_limit_seconds: number
  coding_time_limit_seconds: number
  questions_deadline: string | null
  coding_deadline: string | null
  proctor_violations: number
  flagged: boolean
  questions: CandidateQuestion[]
  challenges: CandidateChallenge[]
}

export type SessionOverview = {
  session_id: string
  application_id: string
  job_id: string
  job_title: string
  candidate_name: string
  status: InterviewStatus
  questions_deadline: string | null
  coding_deadline: string | null
  submitted_at: string | null
  questions_score: number | null
  coding_score: number | null
  total_score: number | null
  passing_score: number
  proctor_violations: number
  flagged: boolean
  pending_submissions: number
  created_at: string
}

export type InterviewQuestion = {
  id: string
  workspace_id: string
  job_id: string
  display_order: number
  prompt: string
  category: string
  expected_keywords: string[]
  max_points: number
  is_active: boolean
}

export type CodingChallengeVersion = {
  id: string
  challenge_id: string
  prompt: string
  difficulty: string
  points: number
  supported_languages: string[]
  version_status: string
}

function requireClient() {
  if (!supabase) throw new Error('Supabase is not configured.')
  return supabase
}

function message(error: unknown, fallback: string) {
  if (error && typeof error === 'object' && 'message' in error) {
    const value = (error as { message?: unknown }).message
    if (typeof value === 'string' && value.trim()) return value
  }
  return fallback
}

function interviewError(code: string | undefined) {
  switch (code) {
    case 'interview_token_invalid':
      return 'This interview link is invalid. Ask the recruiter for a new link.'
    case 'interview_questions_closed':
      return 'The question phase is closed. Your saved answers were kept.'
    case 'interview_coding_closed':
      return 'The coding session is closed. The deadline has passed.'
    case 'interview_code_empty':
      return 'Write some code before submitting.'
    default:
      return null
  }
}

export async function loadCandidateState(token: string): Promise<CandidateState> {
  const client = requireClient()
  const { data, error } = await client.rpc('interview_candidate_state', { p_token: token })
  if (error) throw new Error(message(error, 'The interview could not be loaded.'))
  if (!data) throw new Error('The interview could not be loaded.')
  return data as CandidateState
}

export async function startInterview(token: string) {
  const client = requireClient()
  const { data, error } = await client.rpc('interview_start', { p_token: token })
  if (error) throw new Error(interviewError(error.code) ?? message(error, 'The interview could not start.'))
  return data as { status: InterviewStatus; questions_deadline: string | null; coding_deadline: string | null }
}

export async function saveAnswer(token: string, questionId: string, answer: string) {
  const client = requireClient()
  const { error } = await client.rpc('interview_save_answer', {
    p_token: token,
    p_question_id: questionId,
    p_answer: answer,
  })
  if (error) throw new Error(interviewError(error.code) ?? message(error, 'The answer could not be saved.'))
}

export async function submitQuestions(token: string) {
  const client = requireClient()
  const { data, error } = await client.rpc('interview_submit_questions', { p_token: token })
  if (error) throw new Error(interviewError(error.code) ?? message(error, 'The question phase could not be submitted.'))
  return data as { status: InterviewStatus; coding_deadline: string | null }
}

export async function saveCodeDraft(
  token: string,
  challengeVersionId: string,
  language: string,
  source: string,
) {
  const client = requireClient()
  const { error } = await client.rpc('interview_save_code', {
    p_token: token,
    p_challenge_version_id: challengeVersionId,
    p_language: language,
    p_source: source,
  })
  if (error) throw new Error(interviewError(error.code) ?? message(error, 'Your code could not be saved.'))
}

export async function submitCode(
  token: string,
  challengeVersionId: string,
  language: string,
  source: string,
) {
  const client = requireClient()
  const { data, error } = await client.rpc('interview_submit_code', {
    p_token: token,
    p_challenge_version_id: challengeVersionId,
    p_language: language,
    p_source: source,
  })
  if (error) throw new Error(interviewError(error.code) ?? message(error, 'Your solution could not be submitted.'))
  return data as string
}

export async function recordProctorEvent(
  token: string,
  eventType: string,
  metadata: Record<string, unknown> = {},
) {
  const client = requireClient()
  const { data, error } = await client.rpc('interview_record_proctor_event', {
    p_token: token,
    p_event_type: eventType,
    p_metadata: metadata,
  })
  if (error) throw new Error(message(error, 'The proctoring event could not be recorded.'))
  return Number(data ?? 0)
}

export async function finishInterview(token: string) {
  const client = requireClient()
  const { data, error } = await client.rpc('interview_finish', { p_token: token })
  if (error) throw new Error(interviewError(error.code) ?? message(error, 'The interview could not be finished.'))
  return data as { status: InterviewStatus }
}

export async function createInterviewSession(input: {
  applicationId: string
  questionIds: string[]
  challengeVersionIds: string[]
  questionsTimeLimitSeconds: number
  codingTimeLimitSeconds: number
  passingScore: number
}) {
  const client = requireClient()
  const { data, error } = await client.rpc('create_interview_session', {
    p_application_id: input.applicationId,
    p_question_ids: input.questionIds,
    p_challenge_version_ids: input.challengeVersionIds,
    p_questions_time_limit_seconds: input.questionsTimeLimitSeconds,
    p_coding_time_limit_seconds: input.codingTimeLimitSeconds,
    p_passing_score: input.passingScore,
  })
  if (error) throw new Error(message(error, 'The interview session could not be created.'))
  return data as { session_id: string; token: string; questions: number; challenges: number }
}

export async function loadSessionOverview(workspaceId: string): Promise<SessionOverview[]> {
  const client = requireClient()
  const { data, error } = await client.rpc('interview_session_overview', {
    p_workspace_id: workspaceId,
    p_application_ids: null,
  })
  if (error) throw new Error(message(error, 'Interview sessions could not be loaded.'))
  return (data ?? []) as SessionOverview[]
}

export async function scoreSession(
  sessionId: string,
  scores: Record<string, number>,
  comments: Record<string, string> = {},
) {
  const payload: Record<string, number | string> = { ...scores }
  for (const [questionId, comment] of Object.entries(comments)) {
    payload[`${questionId}_comment`] = comment
  }
  const client = requireClient()
  const { data, error } = await client.rpc('score_interview_questions', {
    p_session_id: sessionId,
    p_scores: payload,
  })
  if (error) throw new Error(message(error, 'The interview could not be scored.'))
  return data as {
    questions_score: number | null
    coding_score: number | null
    total_score: number | null
    passed: boolean
  }
}

export async function cancelSession(sessionId: string, reason: string) {
  const client = requireClient()
  const { error } = await client.rpc('cancel_interview_session', {
    p_session_id: sessionId,
    p_reason: reason,
  })
  if (error) throw new Error(message(error, 'The session could not be cancelled.'))
}
