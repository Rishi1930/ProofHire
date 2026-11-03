export type AptitudeOption = {
  id: string
  option_text: string
}

export type AptitudeQuestion = {
  id: string
  display_order: number
  question_type: 'single_choice' | 'multiple_choice' | 'short_text'
  prompt: string
  points: number
  category: string
  difficulty: 'beginner' | 'medium' | 'advanced' | 'expert'
  options: AptitudeOption[]
}

export type CandidateAptitudeSession = {
  invitation_id: string
  status: string
  expires_at: string
  attempts_used: number
  max_attempts: number
  time_limit_seconds: number
  passing_score: number | null
  title: string
  description: string | null
  active_attempt_id: string | null
  active_attempt_started_at: string | null
  saved_answers: Record<string, unknown>
  questions: AptitudeQuestion[]
  current_question_index?: number
  current_question_updated_at?: string | null
  server_now?: string
  deadline_at?: string | null
  saved_answer_timestamps?: Record<string, string>
  attempt_id?: string
  attempt_number?: number
  started_at?: string
}

export type AptitudeSubmission = {
  attempt_id: string
  status: 'submitted' | 'expired'
  score: number | null
  passing_score?: number | null
  result: {
    earned_points?: number
    available_points?: number
    answered_questions?: number
    question_count?: number
    passed?: boolean | null
    reason?: string
  }
}

type APIError = { error?: string }

async function request<T>(
  path: string,
  method: 'POST',
  body: unknown,
  accessToken?: string,
): Promise<T> {
  let response: Response
  try {
    response = await fetch(
      path.startsWith('/') ? path : `/api/v1/aptitude/${path}`,
      {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
      },
      body: JSON.stringify(body),
      cache: 'no-store',
      referrerPolicy: 'no-referrer',
      },
    )
  } catch {
    throw new Error('The aptitude service could not be reached.')
  }

  const payload = (await response.json().catch(() => null)) as
    | (T & APIError)
    | null
  if (!response.ok || payload == null) {
    const errors: Record<string, string> = {
      aptitude_service_unavailable:
        'Aptitude testing is not configured on the server yet.',
      invitation_creation_failed:
        'The invitation could not be created. Check the selected application and published test.',
      aptitude_session_unavailable:
        'This invitation is invalid, expired, or no longer available.',
      answer_save_failed:
        'Your answer could not be saved. Check your connection and try again.',
      progress_save_failed:
        'Your progress could not be synced. It is saved on this device and will retry when your connection returns.',
      email_delivery_unavailable:
        'Email delivery controls are not configured on the server.',
      email_delivery_action_failed:
        'The email could not be sent or retried. Refresh the delivery status and try again.',
      monitoring_event_failed:
        'Assessment monitoring could not be recorded. Contact the recruiter before continuing.',
    }
    throw new Error(
      (payload?.error && errors[payload.error]) ||
        'The aptitude request could not be completed.',
    )
  }
  return payload
}

export function createAptitudeInvitation(
  body: {
    workspace_id: string
    application_id: string
    test_version_id: string
    expires_at: string
    max_attempts: number
  },
  accessToken: string,
) {
  return request<{
    invitation: {
      id: string
      candidate_email: string
      test_title: string
      expires_at: string
      email_status: string
    }
    token: string
    delivery: 'queued'
  }>('invitations', 'POST', body, accessToken)
}

export function getCandidateSession(token: string) {
  return request<CandidateAptitudeSession>(
    'candidate/session',
    'POST',
    { token },
  )
}

export function startCandidateAttempt(token: string) {
  return request<CandidateAptitudeSession>(
    'candidate/start',
    'POST',
    { token },
  )
}

export function saveCandidateAnswer(
  token: string,
  attemptId: string,
  questionId: string,
  answer: unknown,
) {
  return request<{ saved: boolean }>('candidate/answer', 'POST', {
    token,
    attempt_id: attemptId,
    question_id: questionId,
    answer,
  })
}

export function saveCandidateProgress(
  token: string,
  attemptId: string,
  questionId: string,
  questionIndex: number,
  answer?: unknown,
) {
  return request<{ saved: boolean }>('candidate/progress', 'POST', {
    token,
    attempt_id: attemptId,
    question_id: questionId,
    question_index: questionIndex,
    ...(answer === undefined ? {} : { answer }),
  })
}

export function submitCandidateAttempt(token: string, attemptId: string) {
  return request<AptitudeSubmission>('candidate/submit', 'POST', {
    token,
    attempt_id: attemptId,
  })
}

export function recordCandidateEvent(
  token: string,
  attemptId: string,
  eventType: string,
) {
  return request<{ recorded: boolean }>('candidate/event', 'POST', {
    token,
    attempt_id: attemptId,
    event_type: eventType,
    event_data: {},
  })
}

export function requestEmailDeliveryAction(
  jobId: string,
  body: { workspace_id: string; action: 'send' | 'retry' | 'resend'; request_id: string },
  accessToken: string,
) {
  return request<{ id: string; status: string }>(
    `/api/v1/email-delivery/${jobId}/action`,
    'POST',
    body,
    accessToken,
  )
}
