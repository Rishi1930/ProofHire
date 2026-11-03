import { useCallback, useEffect, useRef, useState } from 'react'
import { useParams } from 'react-router-dom'

import Button from '../components/Button'
import {
  getCandidateSession,
  recordCandidateEvent,
  saveCandidateProgress,
  startCandidateAttempt,
  submitCandidateAttempt,
  type AptitudeQuestion,
  type AptitudeSubmission,
  type CandidateAptitudeSession,
} from './api'

type LocalAnswer = {
  value: unknown
  updatedAt: string
  synced: boolean
  questionIndex: number
}

type LocalProgress = {
  answers: Record<string, LocalAnswer>
  attemptId: string
  currentQuestionIndex: number
  positionUpdatedAt: string
  positionSynced: boolean
}

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
  const [currentQuestionIndex, setCurrentQuestionIndex] = useState(0)
  const [remainingSeconds, setRemainingSeconds] = useState(0)
  const [submission, setSubmission] = useState<AptitudeSubmission | null>(null)
  const [loading, setLoading] = useState(true)
  const [starting, setStarting] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const [savingQuestion, setSavingQuestion] = useState('')
  const [syncState, setSyncState] = useState<'saved' | 'saving' | 'offline' | 'error'>('saved')
  const [consent, setConsent] = useState(false)
  const [error, setError] = useState('')
  const attemptRef = useRef('')
  const answersRef = useRef<Record<string, unknown>>({})
  const pendingSaves = useRef(new Map<string, Promise<void>>())
  const shortTextTimers = useRef(new Map<string, number>())
  const unsyncedAnswers = useRef(new Map<string, LocalAnswer>())
  const localProgress = useRef<LocalProgress>({
    answers: {},
    attemptId: '',
    currentQuestionIndex: 0,
    positionUpdatedAt: '',
    positionSynced: true,
  })
  const backupKey = useRef('')
  const deadlineMonotonic = useRef<number | null>(null)
  const submitLock = useRef(false)
  const lastEventAt = useRef(new Map<string, number>())

  function persistLocalProgress(progress: LocalProgress) {
    localProgress.current = progress
    if (!backupKey.current) return
    try {
      window.localStorage.setItem(backupKey.current, JSON.stringify(progress))
    } catch {
      setError('The offline backup could not be saved in this browser.')
      setSyncState('error')
    }
  }

  function readLocalProgress(key: string): LocalProgress | null {
    try {
      const raw = window.localStorage.getItem(key)
      if (!raw) return null
      const value = JSON.parse(raw) as Partial<LocalProgress>
      if (
        typeof value !== 'object' ||
        value === null ||
        typeof value.answers !== 'object' ||
        value.answers === null ||
        !Number.isInteger(value.currentQuestionIndex)
      ) {
        return null
      }
      return {
        answers: value.answers as Record<string, LocalAnswer>,
        attemptId: value.attemptId ?? '',
        currentQuestionIndex: value.currentQuestionIndex as number,
        positionUpdatedAt: value.positionUpdatedAt ?? '',
        positionSynced: value.positionSynced ?? true,
      }
    } catch {
      setError('The local progress backup could not be read.')
      setSyncState('error')
      return null
    }
  }

  function updateDeadline(data: CandidateAptitudeSession) {
    if (data.deadline_at && data.server_now) {
      const remaining =
        new Date(data.deadline_at).getTime() - new Date(data.server_now).getTime()
      deadlineMonotonic.current = performance.now() + Math.max(0, remaining)
    } else {
      deadlineMonotonic.current = null
    }
  }

  useEffect(() => {
    let active = true
    async function loadSession() {
      setLoading(true)
      setError('')
      try {
        const data = await getCandidateSession(token)
        if (!active) return
        backupKey.current = `proofhire-aptitude-${data.invitation_id}`
        const storedProgress = readLocalProgress(backupKey.current)
        const savedProgress =
          storedProgress?.attemptId === data.active_attempt_id ? storedProgress : null
        const serverAnswers = data.saved_answers ?? {}
        const mergedAnswers = { ...serverAnswers }
        unsyncedAnswers.current.clear()
        if (savedProgress) {
          for (const [questionId, answer] of Object.entries(savedProgress.answers)) {
            if (answer.synced === false && data.questions.some((question) => question.id === questionId)) {
              mergedAnswers[questionId] = answer.value
              unsyncedAnswers.current.set(questionId, answer)
            }
          }
        }
        const serverIndex = data.current_question_index ?? 0
        const currentIndex =
          savedProgress && !savedProgress.positionSynced &&
          data.questions[savedProgress.currentQuestionIndex]
            ? savedProgress.currentQuestionIndex
            : serverIndex
        localProgress.current = savedProgress ?? {
          answers: {},
          attemptId: data.active_attempt_id ?? '',
          currentQuestionIndex: serverIndex,
          positionUpdatedAt: data.current_question_updated_at ?? '',
          positionSynced: true,
        }
        answersRef.current = mergedAnswers
        updateDeadline(data)
        setSession(data)
        setAnswers(mergedAnswers)
        setCurrentQuestionIndex(currentIndex)
        if (data.active_attempt_id && data.active_attempt_started_at) {
          setAttemptId(data.active_attempt_id)
          attemptRef.current = data.active_attempt_id
          setStartedAt(data.active_attempt_started_at)
          if (unsyncedAnswers.current.size > 0 ||
            (savedProgress && !savedProgress.positionSynced)) {
            setSyncState(navigator.onLine ? 'saving' : 'offline')
          }
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

  function markAnswerSynced(questionId: string, updatedAt: string) {
    const current = localProgress.current.answers[questionId]
    if (!current || current.updatedAt !== updatedAt) return
    const nextAnswer = { ...current, synced: true }
    const nextAnswers = { ...localProgress.current.answers, [questionId]: nextAnswer }
    persistLocalProgress({
      ...localProgress.current,
      answers: nextAnswers,
      positionSynced:
        localProgress.current.positionUpdatedAt === updatedAt
          ? true
          : localProgress.current.positionSynced,
    })
    unsyncedAnswers.current.delete(questionId)
    if (unsyncedAnswers.current.size === 0 && localProgress.current.positionSynced) {
      setSyncState('saved')
    }
  }

  function sendAnswerProgress(question: AptitudeQuestion, answer: LocalAnswer) {
    if (!navigator.onLine) {
      setSyncState('offline')
      return
    }
    setSyncState('saving')
    setSavingQuestion(question.id)
    const previous = pendingSaves.current.get(question.id) ?? Promise.resolve()
    const next = previous
      .catch(() => undefined)
      .then(() =>
        saveCandidateProgress(
          token,
          attemptRef.current,
          question.id,
          answer.questionIndex,
          answer.value,
        ),
      )
      .then(
        () => {
          markAnswerSynced(question.id, answer.updatedAt)
          setSavingQuestion((current) => current === question.id ? '' : current)
        },
        (caughtError: unknown) => {
          setSavingQuestion((current) => current === question.id ? '' : current)
          setSyncState(navigator.onLine ? 'error' : 'offline')
          setError(
            caughtError instanceof Error
              ? caughtError.message
              : 'Your progress could not be synced. It will retry when your connection returns.',
          )
        },
      )
      .finally(() => {
        if (pendingSaves.current.get(question.id) === next) {
          pendingSaves.current.delete(question.id)
        }
      })
    pendingSaves.current.set(question.id, next)
  }

  async function flushUnsyncedProgress() {
    for (const timer of shortTextTimers.current.values()) {
      window.clearTimeout(timer)
    }
    shortTextTimers.current.clear()
    await Promise.all([...pendingSaves.current.values()])
    if (!navigator.onLine) {
      setSyncState('offline')
      throw new Error('You are offline. Your answers are saved on this device and will sync when reconnected.')
    }
    for (const [questionId, answer] of [...unsyncedAnswers.current.entries()]) {
      const question = session?.questions.find((item) => item.id === questionId)
      if (!question) continue
      await saveCandidateProgress(
        token,
        attemptRef.current,
        questionId,
        answer.questionIndex,
        answer.value,
      )
      markAnswerSynced(questionId, answer.updatedAt)
    }
    if (!localProgress.current.positionSynced) {
      const index = localProgress.current.currentQuestionIndex
      const question = session?.questions[index]
      if (question) {
        await saveCandidateProgress(
          token,
          attemptRef.current,
          question.id,
          index,
        )
        persistLocalProgress({
          ...localProgress.current,
          positionSynced: true,
        })
      }
    }
    setSyncState('saved')
  }

  const submit = useCallback(async () => {
    if (!attemptRef.current || submitLock.current) return
    submitLock.current = true
    setSubmitting(true)
    setError('')
    try {
      await flushUnsyncedProgress()
      const result = await submitCandidateAttempt(token, attemptRef.current)
      setSubmission(result)
      unsyncedAnswers.current.clear()
      try {
        if (backupKey.current) window.localStorage.removeItem(backupKey.current)
      } catch {
        setError('The assessment was submitted, but the local backup could not be cleared.')
      }
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
  }, [session?.questions, token])

  useEffect(() => {
    if (!attemptId || !startedAt || submission) return
    const updateTime = () => {
      const deadline = deadlineMonotonic.current ??
        performance.now() +
          Math.max(
            0,
            new Date(startedAt).getTime() +
              (session?.time_limit_seconds ?? 0) * 1000 -
              Date.now(),
          )
      deadlineMonotonic.current = deadline
      setRemainingSeconds(Math.max(0, Math.ceil((deadline - performance.now()) / 1000)))
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
      deadlineMonotonic.current !== null &&
      performance.now() >= deadlineMonotonic.current
    ) {
      void submit()
    }
  }, [attemptId, loading, remainingSeconds, startedAt, submit, submission])

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
    const wentOnline = () => {
      sendEvent('network_reconnected')
      void flushUnsyncedProgress().catch(() => undefined)
    }
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
  }, [attemptId, flushUnsyncedProgress, submission, token])

  useEffect(() => {
    if (!attemptId || submission) return
    const warnBeforeUnload = (event: BeforeUnloadEvent) => {
      const hasUnsynced =
        unsyncedAnswers.current.size > 0 ||
        !localProgress.current.positionSynced ||
        pendingSaves.current.size > 0
      if (hasUnsynced || !navigator.onLine) {
        event.preventDefault()
        event.returnValue = ''
      }
    }
    window.addEventListener('beforeunload', warnBeforeUnload)
    return () => window.removeEventListener('beforeunload', warnBeforeUnload)
  }, [attemptId, submission, syncState])

  async function beginAttempt() {
    setStarting(true)
    setError('')
    try {
      const data = await startCandidateAttempt(token)
      updateDeadline(data)
      setSession(data)
      const restoredAnswers = data.saved_answers ?? {}
      answersRef.current = restoredAnswers
      setAnswers(restoredAnswers)
      const id = data.attempt_id ?? data.active_attempt_id
      const date = data.started_at ?? data.active_attempt_started_at
      if (!id || !date) {
        setSession((current) =>
          current ? { ...current, status: 'completed' } : current,
        )
        return
      }
      attemptRef.current = id
      const index = data.current_question_index ?? 0
      setCurrentQuestionIndex(index)
      persistLocalProgress({
        answers: {},
        attemptId: id,
        currentQuestionIndex: index,
        positionUpdatedAt: data.current_question_updated_at ?? '',
        positionSynced: true,
      })
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
    const updatedAnswers = { ...answersRef.current, [question.id]: nextAnswer }
    answersRef.current = updatedAnswers
    setAnswers(updatedAnswers)
    if (!attemptRef.current) return

    const questionIndex = session?.questions.findIndex((item) => item.id === question.id) ?? -1
    if (questionIndex < 0) return
    const updatedAt = new Date().toISOString()
    const record: LocalAnswer = {
      value: nextAnswer,
      updatedAt,
      synced: false,
      questionIndex,
    }
    unsyncedAnswers.current.set(question.id, record)
    const nextAnswers = { ...localProgress.current.answers, [question.id]: record }
    persistLocalProgress({
      ...localProgress.current,
      answers: nextAnswers,
      attemptId: attemptRef.current,
      currentQuestionIndex: questionIndex,
      positionUpdatedAt: updatedAt,
      positionSynced: false,
    })
    setCurrentQuestionIndex(questionIndex)
    if (!navigator.onLine) {
      setSyncState('offline')
      return
    }
    const existingTimer = shortTextTimers.current.get(question.id)
    if (existingTimer) window.clearTimeout(existingTimer)
    if (question.question_type === 'short_text') {
      shortTextTimers.current.set(
        question.id,
        window.setTimeout(() => {
          shortTextTimers.current.delete(question.id)
          sendAnswerProgress(question, record)
        }, 500),
      )
    } else {
      sendAnswerProgress(question, record)
    }
  }

  function updateQuestionPosition(index: number) {
    const question = session?.questions[index]
    if (!question || !attemptRef.current) return
    const updatedAt = new Date().toISOString()
    setCurrentQuestionIndex(index)
    persistLocalProgress({
      ...localProgress.current,
      attemptId: attemptRef.current,
      currentQuestionIndex: index,
      positionUpdatedAt: updatedAt,
      positionSynced: false,
    })
    if (!navigator.onLine) {
      setSyncState('offline')
      return
    }
    const pending = [...pendingSaves.current.entries()]
      .filter(([key]) => key !== '__position')
      .map(([, promise]) => promise)
    const previous = pendingSaves.current.get('__position') ?? Promise.resolve()
    const next = previous
      .catch(() => undefined)
      .then(async () => {
        await Promise.all(pending)
        await saveCandidateProgress(token, attemptRef.current, question.id, index)
      })
      .then(
        () => {
          if (localProgress.current.positionUpdatedAt === updatedAt) {
            persistLocalProgress({ ...localProgress.current, positionSynced: true })
          }
          setSyncState(unsyncedAnswers.current.size ? 'saving' : 'saved')
        },
        () => {
          setSyncState(navigator.onLine ? 'error' : 'offline')
          setError('Your current question could not be synced. It will retry when your connection returns.')
        },
      )
      .finally(() => {
        if (pendingSaves.current.get('__position') === next) {
          pendingSaves.current.delete('__position')
        }
      })
    pendingSaves.current.set('__position', next)
  }

  function onChoiceChange(question: AptitudeQuestion, optionID: string) {
    const currentOptions = answerOptions(answersRef.current[question.id])
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
                <label className="candidate-question-position">
                  Current question
                  <select
                    value={currentQuestionIndex}
                    onChange={(event) =>
                      updateQuestionPosition(Number(event.target.value))
                    }
                  >
                    {session.questions.map((question, index) => (
                      <option key={question.id} value={index}>
                        {question.display_order} of {session.questions.length}
                      </option>
                    ))}
                  </select>
                </label>
                <p className="candidate-assessment-sync" aria-live="polite">
                  {syncState === 'offline'
                    ? 'Offline — progress is saved on this device and will sync when reconnected.'
                    : syncState === 'saving'
                      ? 'Syncing your progress…'
                      : syncState === 'error'
                        ? 'Progress sync needs attention.'
                        : 'Progress saved to your account.'}
                </p>
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
