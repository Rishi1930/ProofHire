import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'

import Button from '../components/Button'
import {
  getCandidateSession,
  recordCandidateEvent,
  saveCandidateAnswer,
  startCandidateAttempt,
  submitCandidateAttempt,
  type AptitudeQuestion,
  type AptitudeSubmission,
  type CandidateAptitudeSession,
} from './api'

function answerOptions(answer: unknown): string[] {
  if (
    typeof answer === 'object' &&
    answer !== null &&
    'option_ids' in answer &&
    Array.isArray(answer.option_ids)
  ) {
    return answer.option_ids.filter(
      (option): option is string => typeof option === 'string',
    )
  }
  return []
}

function answerText(answer: unknown): string {
  return typeof answer === 'string' ? answer : ''
}

function formatTime(seconds: number) {
  const minutes = Math.floor(seconds / 60)
  return `${String(minutes).padStart(2, '0')}:${String(seconds % 60).padStart(2, '0')}`
}

export default function CandidateAssessment() {
  const { token = '' } = useParams<{ token: string }>()
  const [session, setSession] = useState<CandidateAptitudeSession | null>(null)
  const [attemptId, setAttemptId] = useState('')
  const [startedAt, setStartedAt] = useState('')
  const [answers, setAnswers] = useState<Record<string, unknown>>({})
  const [remainingSeconds, setRemainingSeconds] = useState(0)
  const [submission, setSubmission] = useState<AptitudeSubmission | null>(null)
  const [loading, setLoading] = useState(true)
  const [starting, setStarting] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [savingQuestion, setSavingQuestion] = useState('')
  const [consent, setConsent] = useState(false)
  const [error, setError] = useState('')
  const attemptRef = useRef('')
  const pendingSaves = useRef(new Map<string, Promise<void>>())
  const submitLock = useRef(false)
  const lastEventAt = useRef(new Map<string, number>())

  useEffect(() => {
    let active = true
    async function loadSession() {
      setLoading(true)
      setError('')
      try {
        const data = await getCandidateSession(token)
        if (!active) return
        setSession(data)
        setAnswers(data.saved_answers ?? {})
        if (data.active_attempt_id && data.active_attempt_started_at) {
          setAttemptId(data.active_attempt_id)
          attemptRef.current = data.active_attempt_id
          setStartedAt(data.active_attempt_started_at)
        }
      } catch (caughtError) {
        if (active) {
          setError(
            caughtError instanceof Error
              ? caughtError.message
              : 'This assessment link is unavailable.',
          )
        }
      } finally {
        if (active) setLoading(false)
      }
    }
    void loadSession()
    return () => {
      active = false
    }
  }, [token])

  const submit = useCallback(async () => {
    if (!attemptRef.current || submitLock.current) return
    submitLock.current = true
    setSubmitting(true)
    setError('')
    try {
      await Promise.all([...pendingSaves.current.values()])
      for (const question of session?.questions ?? []) {
        const answer = answers[question.id]
        if (answer !== undefined) {
          await saveCandidateAnswer(token, attemptRef.current, question.id, answer)
        }
      }
      const result = await submitCandidateAttempt(token, attemptRef.current)
      setSubmission(result)
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : 'Your assessment could not be submitted. Please retry.',
      )
      submitLock.current = false
    } finally {
      setSubmitting(false)
    }
  }, [answers, session?.questions, token])

  useEffect(() => {
    if (!attemptId || !startedAt || submission) return
    const updateTime = () => {
      const deadline =
        new Date(startedAt).getTime() + (session?.time_limit_seconds ?? 0) * 1000
      setRemainingSeconds(Math.max(0, Math.ceil((deadline - Date.now()) / 1000)))
    }
    updateTime()
    const timer = window.setInterval(updateTime, 1000)
    return () => window.clearInterval(timer)
  }, [attemptId, session?.time_limit_seconds, startedAt, submission])

  useEffect(() => {
    if (
      attemptId &&
      startedAt &&
      !submission &&
      !loading &&
      Date.now() >=
        new Date(startedAt).getTime() +
          (session?.time_limit_seconds ?? 0) * 1000
    ) {
      void submit()
    }
  }, [attemptId, loading, session?.time_limit_seconds, startedAt, submit, submission])

  useEffect(() => {
    if (!attemptId || submission) return
    const sendEvent = (eventType: string) => {
      const now = Date.now()
      if (now - (lastEventAt.current.get(eventType) ?? 0) < 15000) return
      lastEventAt.current.set(eventType, now)
      void recordCandidateEvent(token, attemptId, eventType).catch((caughtError: unknown) => {
        setError(
          caughtError instanceof Error
            ? caughtError.message
            : 'Assessment monitoring could not be recorded.',
        )
      })
    }
    const visibilityChanged = () => {
      if (document.visibilityState === 'hidden') sendEvent('visibility_hidden')
    }
    const lostFocus = () => sendEvent('focus_lost')
    const wentOffline = () => sendEvent('network_disconnected')
    const wentOnline = () => sendEvent('network_reconnected')
    const copied = () => sendEvent('copy_attempt')
    const pasted = () => sendEvent('paste_attempt')

    document.addEventListener('visibilitychange', visibilityChanged)
    window.addEventListener('blur', lostFocus)
    window.addEventListener('offline', wentOffline)
    window.addEventListener('online', wentOnline)
    document.addEventListener('copy', copied)
    document.addEventListener('paste', pasted)
    return () => {
      document.removeEventListener('visibilitychange', visibilityChanged)
      window.removeEventListener('blur', lostFocus)
      window.removeEventListener('offline', wentOffline)
      window.removeEventListener('online', wentOnline)
      document.removeEventListener('copy', copied)
      document.removeEventListener('paste', pasted)
    }
  }, [attemptId, submission, token])

  async function beginAttempt() {
    setStarting(true)
    setError('')
    try {
      const data = await startCandidateAttempt(token)
      setSession(data)
      setAnswers(data.saved_answers ?? {})
      const id = data.attempt_id ?? data.active_attempt_id
      const date = data.started_at ?? data.active_attempt_started_at
      if (!id || !date) {
        setSession((current) =>
          current ? { ...current, status: 'completed' } : current,
        )
        return
      }
      attemptRef.current = id
      setAttemptId(id)
      setStartedAt(date)
    } catch (caughtError) {
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : 'The assessment could not be started.',
      )
    } finally {
      setStarting(false)
    }
  }

  function updateAnswer(question: AptitudeQuestion, nextAnswer: unknown) {
    setAnswers((current) => ({ ...current, [question.id]: nextAnswer }))
    if (!attemptId || question.question_type === 'short_text') return

    setSavingQuestion(question.id)
    const previous = pendingSaves.current.get(question.id) ?? Promise.resolve()
    const next = previous
      .catch(() => undefined)
      .then(async () => {
        await saveCandidateAnswer(token, attemptId, question.id, nextAnswer)
      })
      .then(
        () => {
          setSavingQuestion((current) => current === question.id ? '' : current)
        },
        (caughtError: unknown) => {
          setSavingQuestion((current) => current === question.id ? '' : current)
          setError(
            caughtError instanceof Error
              ? caughtError.message
              : 'Your answer could not be saved.',
          )
        },
      )
    pendingSaves.current.set(question.id, next)
  }

  function onChoiceChange(question: AptitudeQuestion, optionID: string) {
    const currentOptions = answerOptions(answers[question.id])
    let nextOptions: string[]
    if (question.question_type === 'single_choice') {
      nextOptions = currentOptions.includes(optionID) ? [] : [optionID]
    } else {
      nextOptions = currentOptions.includes(optionID)
        ? currentOptions.filter((id) => id !== optionID)
        : [...currentOptions, optionID]
    }
    updateAnswer(question, { option_ids: nextOptions })
  }

  const completedAttempts = session ? session.attempts_used : 0
  const hasAttempt = Boolean(attemptId && !submission)

  return (
    <main className="candidate-assessment-shell">
      <div className="candidate-assessment-card">
        {loading ? (
          <div className="empty-state" aria-live="polite">
            <span className="loading-spinner" />
            <p>Loading assessment...</p>
          </div>
        ) : error && !session ? (
          <div className="empty-state" role="alert">
            <h1>Assessment link unavailable</h1>
            <p>{error}</p>
          </div>
        ) : submission ? (
          <div className="candidate-assessment-result">
            <h1>{submission.status === 'expired' ? 'Time expired' : 'Assessment submitted'}</h1>
            {submission.score == null ? (
              <p>Your attempt expired before it could be scored. Contact the recruiter if you need help.</p>
            ) : (
              <>
                <p className="candidate-assessment-score">{Number(submission.score).toFixed(1)}%</p>
                <p>
                  {submission.result.passed === true
                    ? 'Your result meets the test threshold.'
                    : submission.result.passed === false
                      ? 'Your result is below the test threshold.'
                      : 'Your result has been recorded for recruiter review.'}
                </p>
              </>
            )}
            <p>You may close this page. The recruiter will review the result.</p>
          </div>
        ) : session ? (
          <>
            <header className="candidate-assessment-header">
              <span className="page-eyebrow">PROOFHIRE CANDIDATE ASSESSMENT</span>
              <h1>{session.title}</h1>
              {session.description && <p>{session.description}</p>}
              <p>
                {Math.ceil(session.time_limit_seconds / 60)} minute(s)
                {' · '}{Math.max(0, session.max_attempts - completedAttempts)} attempt(s) remaining
                {session.passing_score != null ? ` · Passing score ${session.passing_score}%` : ''}
              </p>
            </header>

            {error && <div className="form-alert form-alert-error" role="alert">{error}</div>}

            {!hasAttempt ? (
              <div className="candidate-assessment-start">
                {session.status === 'completed' ||
                completedAttempts >= session.max_attempts ? (
                  <p>This invitation has no attempts remaining. Contact the recruiter if you need help.</p>
                ) : (
                  <>
                    <p>
                      Your answers are saved as you go. The test is timed from the
                      moment you begin. Results are scored by the server and shared
                      with the recruiting workspace.
                    </p>
                    <div className="aptitude-monitoring-disclosure">
                      This assessment records browser focus/visibility changes and
                      copy/paste actions. It does not access your camera, microphone,
                      or files.
                    </div>
                    <label className="candidate-consent">
                      <input
                        type="checkbox"
                        checked={consent}
                        onChange={(event) => setConsent(event.target.checked)}
                      />
                      I understand the assessment timing and monitoring notice.
                    </label>
                    <Button
                      loading={starting}
                      disabled={!consent}
                      onClick={() => void beginAttempt()}
                    >
                      {session.active_attempt_id ? 'Resume assessment' : 'Begin assessment'}
                    </Button>
                  </>
                )}
              </div>
            ) : (
              <>
                <div className="candidate-assessment-timer" aria-live="polite">
                  Time remaining <strong>{formatTime(remainingSeconds)}</strong>
                </div>
                <div className="candidate-assessment-questions">
                  {session.questions.map((question) => (
                    <fieldset className="candidate-question" key={question.id}>
                      <legend>
                        {question.display_order}. {question.prompt}
                        <span>{question.points} point(s)</span>
                      </legend>
                      {question.question_type === 'short_text' ? (
                        <textarea
                          className="form-textarea"
                          maxLength={5000}
                          value={answerText(answers[question.id])}
                          onChange={(event) => updateAnswer(question, event.target.value)}
                          onBlur={() => {
                            const answer = answers[question.id]
                            if (answer !== undefined) {
                              setSavingQuestion(question.id)
                              void saveCandidateAnswer(
                                token,
                                attemptId,
                                question.id,
                                answer,
                              ).then(
                                () => setSavingQuestion(''),
                                (caughtError: unknown) => {
                                  setSavingQuestion('')
                                  setError(
                                    caughtError instanceof Error
                                      ? caughtError.message
                                      : 'Your answer could not be saved.',
                                  )
                                },
                              )
                            }
                          }}
                        />
                      ) : (
                        <div className="candidate-question-options">
                          {question.options.map((option) => (
                            <label key={option.id}>
                              <input
                                type={question.question_type === 'single_choice' ? 'radio' : 'checkbox'}
                                name={question.id}
                                checked={answerOptions(answers[question.id]).includes(option.id)}
                                onChange={() => onChoiceChange(question, option.id)}
                              />
                              <span>{option.option_text}</span>
                            </label>
                          ))}
                        </div>
                      )}
                      {savingQuestion === question.id && <small>Saving answer…</small>}
                    </fieldset>
                  ))}
                </div>
                <Button
                  loading={submitting}
                  onClick={() => void submit()}
                >
                  Submit assessment
                </Button>
              </>
            )}
          </>
        ) : (
          <div className="empty-state"><h1>Assessment unavailable</h1></div>
        )}
      </div>
    </main>
  )
}
