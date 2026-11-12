import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { AlertTriangle, CheckCircle2, Code2, Maximize2, Send, ShieldCheck } from 'lucide-react'
import { useParams } from 'react-router-dom'

import Button from '../components/Button'
import {
  finishInterview,
  loadCandidateState,
  recordProctorEvent,
  saveAnswer,
  saveCodeDraft,
  startInterview,
  submitCode,
  submitQuestions,
  type CandidateChallenge,
  type CandidateQuestion,
  type CandidateState,
} from './api'
import './interview.css'

const LANGUAGE_LABELS: Record<string, string> = {
  python: 'Python 3',
  javascript: 'JavaScript (Node 22)',
  go: 'Go 1.23',
  cpp: 'C++ 17',
  java: 'Java 21',
}

function formatRemaining(deadline: string | null) {
  if (!deadline) return '—'
  const remaining = new Date(deadline).getTime() - Date.now()
  if (remaining <= 0) return '00:00'
  const total = Math.floor(remaining / 1000)
  const hours = Math.floor(total / 3600)
  const minutes = Math.floor((total % 3600) / 60)
  const seconds = total % 60
  const pad = (value: number) => String(value).padStart(2, '0')
  return hours > 0 ? `${pad(hours)}:${pad(minutes)}:${pad(seconds)}` : `${pad(minutes)}:${pad(seconds)}`
}

function starterFor(challenge: CandidateChallenge, language: string) {
  const starter = challenge.starter_code ?? {}
  return starter[language] ?? Object.values(starter)[0] ?? ''
}

export default function CandidateInterview() {
  const { token = '' } = useParams()
  const [state, setState] = useState<CandidateState | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [busy, setBusy] = useState(false)
  const [fullscreen, setFullscreen] = useState(false)
  const [answers, setAnswers] = useState<Record<string, string>>({})
  const [activeChallengeId, setActiveChallengeId] = useState('')
  const [language, setLanguage] = useState('')
  const [source, setSource] = useState('')
  const [saveState, setSaveState] = useState<'idle' | 'saving' | 'saved'>('idle')
  const [submittedSolutions, setSubmittedSolutions] = useState<string[]>([])
  const [remaining, setRemaining] = useState('—')

  const saveTimers = useRef<Record<string, number>>({})
  const lastEvent = useRef<number>(0)
  const autoSubmitted = useRef(false)

  const refresh = useCallback(async () => {
    if (!token) {
      setError('This interview link is incomplete.')
      setLoading(false)
      return
    }
    try {
      const next = await loadCandidateState(token)
      setState(next)
      setAnswers((current) => {
        const merged = { ...current }
        for (const question of next.questions) {
          if (merged[question.question_id] === undefined) {
            merged[question.question_id] = question.answer ?? ''
          }
        }
        return merged
      })
      if (next.challenges.length > 0) {
        setActiveChallengeId((current) => current || next.challenges[0].challenge_version_id)
      }
      setError('')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The interview could not be loaded.')
    } finally {
      setLoading(false)
    }
  }, [token])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const activeChallenge = useMemo(
    () =>
      state?.challenges.find((challenge) => challenge.challenge_version_id === activeChallengeId) ??
      state?.challenges[0] ??
      null,
    [activeChallengeId, state],
  )

  useEffect(() => {
    if (!activeChallenge) return
    const chosen = activeChallenge.draft_language || activeChallenge.supported_languages[0] || 'python'
    setLanguage(chosen)
    setSource(activeChallenge.draft_source ?? starterFor(activeChallenge, chosen))
  }, [activeChallenge])

  const phase: 'questions' | 'coding' | 'closed' | 'done' = useMemo(() => {
    if (!state) return 'questions'
    if (state.status === 'ready' || state.status === 'in_progress') return 'questions'
    if (state.status === 'coding' || state.status === 'questions_submitted') return 'coding'
    if (state.status === 'submitted' || state.status === 'completed') return 'done'
    return 'closed'
  }, [state])

  useEffect(() => {
    const deadline = phase === 'coding' ? state?.coding_deadline : state?.questions_deadline
    setRemaining(formatRemaining(deadline ?? null))
    const interval = window.setInterval(() => {
      setRemaining(formatRemaining(deadline ?? null))
    }, 1000)
    return () => window.clearInterval(interval)
  }, [phase, state?.coding_deadline, state?.questions_deadline])

  // Proctoring signals. These are deterrents and an audit trail, not proof.
  useEffect(() => {
    if (!state || (state.status !== 'in_progress' && state.status !== 'coding')) return

    const report = (eventType: string, metadata: Record<string, unknown> = {}) => {
      const now = Date.now()
      if (now - lastEvent.current < 400 && eventType !== 'fullscreen_enter') return
      lastEvent.current = now
      void recordProctorEvent(token, eventType, metadata)
        .then((violations) => {
          setState((current) => (current ? { ...current, proctor_violations: violations } : current))
        })
        .catch(() => undefined)
    }

    const onFullscreen = () => {
      const active = Boolean(document.fullscreenElement)
      setFullscreen(active)
      report(active ? 'fullscreen_enter' : 'fullscreen_exit')
    }
    const onVisibility = () => {
      if (document.visibilityState === 'hidden') report('tab_hidden')
    }
    const onBlur = () => report('window_blur')
    const onPaste = () => report('paste')
    const onCopy = () => report('copy')
    const onContextMenu = (event: MouseEvent) => {
      event.preventDefault()
      report('context_menu')
    }
    const onOffline = () => report('network_offline')

    document.addEventListener('fullscreenchange', onFullscreen)
    document.addEventListener('visibilitychange', onVisibility)
    window.addEventListener('blur', onBlur)
    document.addEventListener('paste', onPaste, true)
    document.addEventListener('copy', onCopy, true)
    document.addEventListener('contextmenu', onContextMenu)
    window.addEventListener('offline', onOffline)
    setFullscreen(Boolean(document.fullscreenElement))
    return () => {
      document.removeEventListener('fullscreenchange', onFullscreen)
      document.removeEventListener('visibilitychange', onVisibility)
      window.removeEventListener('blur', onBlur)
      document.removeEventListener('paste', onPaste, true)
      document.removeEventListener('copy', onCopy, true)
      document.removeEventListener('contextmenu', onContextMenu)
      window.removeEventListener('offline', onOffline)
    }
  }, [state, token])

  async function enterFullscreen() {
    try {
      await document.documentElement.requestFullscreen()
      setFullscreen(Boolean(document.fullscreenElement))
    } catch {
      setError('Full screen is required. Allow full screen access in your browser and try again.')
    }
  }

  async function handleStart() {
    setBusy(true)
    setError('')
    try {
      if (!document.fullscreenElement) await enterFullscreen()
      await startInterview(token)
      await refresh()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The interview could not start.')
    } finally {
      setBusy(false)
    }
  }

  function queueSave(question: CandidateQuestion, value: string) {
    setAnswers((current) => ({ ...current, [question.question_id]: value }))
    setSaveState('saving')
    const existing = saveTimers.current[question.question_id]
    if (existing) window.clearTimeout(existing)
    saveTimers.current[question.question_id] = window.setTimeout(() => {
      void saveAnswer(token, question.question_id, value)
        .then(() => setSaveState('saved'))
        .catch(() => setSaveState('idle'))
    }, 1200)
  }

  const finishQuestions = useCallback(
    async (automatic: boolean) => {
      if (autoSubmitted.current) return
      autoSubmitted.current = true
      try {
        for (const [questionId, value] of Object.entries(answers)) {
          await saveAnswer(token, questionId, value).catch(() => undefined)
        }
        await submitQuestions(token)
        setNotice(automatic ? 'Time is up. Your answers were submitted.' : 'Answers submitted.')
        await refresh()
      } catch (caught) {
        setError(caught instanceof Error ? caught.message : 'The answers could not be submitted.')
      }
    },
    [answers, refresh, token],
  )

  useEffect(() => {
    if (!state || state.status !== 'in_progress' || !state.questions_deadline) return
    const deadline = new Date(state.questions_deadline).getTime()
    const interval = window.setInterval(() => {
      if (Date.now() >= deadline && !autoSubmitted.current) {
        void finishQuestions(true)
      }
    }, 1000)
    return () => window.clearInterval(interval)
  }, [finishQuestions, state])

  async function handleQuestionsSubmit() {
    setBusy(true)
    setError('')
    autoSubmitted.current = false
    await finishQuestions(false)
    setBusy(false)
  }

  useEffect(() => {
    if (!activeChallenge || phase !== 'coding') return
    const timer = window.setTimeout(() => {
      void saveCodeDraft(token, activeChallenge.challenge_version_id, language, source)
        .then(() => setSaveState('saved'))
        .catch(() => undefined)
    }, 1500)
    return () => window.clearTimeout(timer)
  }, [activeChallenge, language, phase, source, token])

  async function handleSubmitSolution() {
    if (!activeChallenge) return
    setBusy(true)
    setError('')
    try {
      await submitCode(token, activeChallenge.challenge_version_id, language, source)
      setSubmittedSolutions((current) =>
        current.includes(activeChallenge.challenge_version_id)
          ? current
          : [...current, activeChallenge.challenge_version_id],
      )
      setNotice('Solution submitted for evaluation.')
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The solution could not be submitted.')
    } finally {
      setBusy(false)
    }
  }

  async function handleFinish() {
    setBusy(true)
    try {
      await finishInterview(token)
      await refresh()
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : 'The interview could not be finished.')
    } finally {
      setBusy(false)
    }
  }

  if (loading) {
    return (
      <main className="auth-loading" aria-live="polite">
        <div className="loading-spinner" />
        <p>Preparing your interview…</p>
      </main>
    )
  }

  if (error && !state) {
    return (
      <main className="interview-shell">
        <div className="interview-card">
          <h1>Interview unavailable</h1>
          <p className="interview-muted">{error}</p>
        </div>
      </main>
    )
  }

  if (!state) return null

  if (phase === 'done' || phase === 'closed') {
    return (
      <main className="interview-shell">
        <div className="interview-card interview-complete">
          <CheckCircle2 size={40} />
          <h1>{phase === 'done' ? 'Interview submitted' : 'Interview closed'}</h1>
          <p className="interview-muted">
            {phase === 'done'
              ? 'Your responses and code are recorded. The hiring team will review them and contact you about next steps.'
              : 'This session is no longer accepting answers. Please contact the recruiter if you believe this is a mistake.'}
          </p>
          {state.proctor_violations > 0 && (
            <p className="interview-warning">
              <AlertTriangle size={16} /> {state.proctor_violations} integrity signal
              {state.proctor_violations === 1 ? '' : 's'} recorded on this session.
            </p>
          )}
        </div>
      </main>
    )
  }

  const showProctorWall = !fullscreen && state.status !== 'ready'

  return (
    <main className="interview-shell">
      <header className="interview-header">
        <div>
          <p className="interview-eyebrow">PROOFHIRE TECHNICAL INTERVIEW</p>
          <h1>{state.job_title ?? 'Technical interview'}</h1>
          <p className="interview-muted">
            {state.candidate_name ? `Candidate: ${state.candidate_name}` : ''}
          </p>
        </div>
        <div className="interview-clock" aria-live="polite">
          <span>{phase === 'coding' ? 'Coding time left' : 'Question time left'}</span>
          <strong>{remaining}</strong>
        </div>
      </header>

      {error && (
        <div className="form-alert form-alert-error" role="alert">
          {error}
        </div>
      )}
      {notice && (
        <div className="form-alert form-alert-success" role="status">
          {notice}
        </div>
      )}
      {state.proctor_violations > 0 && (
        <div className="interview-warning" role="status">
          <AlertTriangle size={16} />
          {state.proctor_violations} integrity signal{state.proctor_violations === 1 ? '' : 's'} recorded.
          Stay in full screen and keep this tab focused.
        </div>
      )}

      {showProctorWall && (
        <div className="interview-wall" role="dialog" aria-modal="true">
          <ShieldCheck size={32} />
          <h2>Full screen required</h2>
          <p>
            This interview runs in full screen. Leaving full screen or switching tabs is recorded and
            may be reviewed by the hiring team.
          </p>
          <Button onClick={() => void enterFullscreen()}>
            <Maximize2 size={16} /> Return to full screen
          </Button>
        </div>
      )}

      {phase === 'questions' && state.status === 'ready' && (
        <section className="interview-card">
          <h2>Before you begin</h2>
          <ul className="interview-rules">
            <li>{state.questions.length} short technical questions, then {state.challenges.length} coding task{state.challenges.length === 1 ? '' : 's'}.</li>
            <li>Answers save automatically. You can refresh without losing work.</li>
            <li>The timer is controlled by the server and starts when you begin.</li>
            <li>Stay in full screen. Tab switches and pasted answers are flagged.</li>
            <li>Write your own code. Hidden tests score each solution.</li>
          </ul>
          <Button loading={busy} onClick={() => void handleStart()}>
            <Maximize2 size={16} /> Enter full screen and start
          </Button>
        </section>
      )}

      {phase === 'questions' && state.status === 'in_progress' && (
        <section className="interview-section">
          <div className="interview-section-heading">
            <div>
              <h2>Technical questions</h2>
              <p className="interview-muted">Answer in your own words. Saved automatically.</p>
            </div>
            <span className={`interview-save interview-save-${saveState}`}>
              {saveState === 'saving' ? 'Saving…' : saveState === 'saved' ? 'Saved' : 'Autosave on'}
            </span>
          </div>
          {state.questions.map((question) => (
            <article key={question.question_id} className="interview-question">
              <header>
                <span className="interview-question-index">Q{question.display_order}</span>
                <span className="interview-tag">{question.category}</span>
                <span className="interview-muted">{question.max_points} pts</span>
              </header>
              <p className="interview-prompt">{question.prompt}</p>
              <textarea
                className="interview-textarea"
                value={answers[question.question_id] ?? ''}
                onChange={(event) => queueSave(question, event.target.value)}
                onPaste={() => undefined}
                rows={5}
                placeholder="Type your answer…"
                aria-label={`Answer for question ${question.display_order}`}
              />
            </article>
          ))}
          <Button loading={busy} onClick={() => void handleQuestionsSubmit()}>
            <Send size={16} /> Submit answers and continue
          </Button>
        </section>
      )}

      {phase === 'coding' && (
        <section className="interview-section">
          <div className="interview-section-heading">
            <div>
              <h2>Coding session</h2>
              <p className="interview-muted">
                Sample tests are shown. Hidden tests score your submission.
              </p>
            </div>
            <span className={`interview-save interview-save-${saveState}`}>
              {saveState === 'saving' ? 'Saving…' : saveState === 'saved' ? 'Draft saved' : 'Autosave on'}
            </span>
          </div>

          {state.challenges.length === 0 ? (
            <div className="interview-card">
              <p className="interview-muted">
                No coding task is configured for this interview. You can finish the session.
              </p>
              <Button loading={busy} onClick={() => void handleFinish()}>Finish interview</Button>
            </div>
          ) : (
            <>
              {state.challenges.length > 1 && (
                <div className="interview-challenge-tabs">
                  {state.challenges.map((challenge, index) => (
                    <button
                      key={challenge.challenge_version_id}
                      type="button"
                      className={
                        challenge.challenge_version_id === activeChallenge?.challenge_version_id
                          ? 'interview-challenge-tab active'
                          : 'interview-challenge-tab'
                      }
                      onClick={() => setActiveChallengeId(challenge.challenge_version_id)}
                    >
                      Task {index + 1}
                      {submittedSolutions.includes(challenge.challenge_version_id) && ' ✓'}
                    </button>
                  ))}
                </div>
              )}

              {activeChallenge && (
                <div className="interview-coding-layout">
                  <article className="interview-card interview-brief">
                    <div className="interview-brief-meta">
                      <span className="interview-tag">{activeChallenge.difficulty}</span>
                      <span className="interview-muted">{activeChallenge.points} pts</span>
                      <span className="interview-muted">{activeChallenge.max_execution_seconds}s limit</span>
                    </div>
                    <pre className="interview-brief-prompt">{activeChallenge.prompt}</pre>
                    {activeChallenge.sample_tests.length > 0 && (
                      <div className="interview-samples">
                        <h3>Sample tests</h3>
                        {activeChallenge.sample_tests.map((sample) => (
                          <div key={sample.display_order} className="interview-sample">
                            <div>
                              <span>Input</span>
                              <pre>{sample.input_text || '(empty)'}</pre>
                            </div>
                            <div>
                              <span>Expected output</span>
                              <pre>{sample.expected_output}</pre>
                            </div>
                          </div>
                        ))}
                      </div>
                    )}
                  </article>

                  <article className="interview-card interview-editor-card">
                    <div className="interview-editor-toolbar">
                      <label>
                        <span>Language</span>
                        <select
                          value={language}
                          onChange={(event) => {
                            setLanguage(event.target.value)
                            setSource(starterFor(activeChallenge, event.target.value))
                          }}
                        >
                          {activeChallenge.supported_languages.map((name) => (
                            <option key={name} value={name}>
                              {LANGUAGE_LABELS[name] ?? name}
                            </option>
                          ))}
                        </select>
                      </label>
                      <span className="interview-muted">
                        <Code2 size={14} /> {source.split('\n').length} lines
                      </span>
                    </div>
                    <div className="interview-editor">
                      <div className="interview-gutter" aria-hidden="true">
                        {source.split('\n').map((_, index) => (
                          <span key={index}>{index + 1}</span>
                        ))}
                      </div>
                      <textarea
                        className="interview-code"
                        value={source}
                        spellCheck={false}
                        onChange={(event) => setSource(event.target.value)}
                        onKeyDown={(event) => {
                          if (event.key !== 'Tab') return
                          event.preventDefault()
                          const target = event.currentTarget
                          const start = target.selectionStart
                          const end = target.selectionEnd
                          const next = `${source.slice(0, start)}  ${source.slice(end)}`
                          setSource(next)
                          window.requestAnimationFrame(() => {
                            target.selectionStart = start + 2
                            target.selectionEnd = start + 2
                          })
                        }}
                        aria-label="Code editor"
                      />
                    </div>
                    <div className="interview-editor-actions">
                      <Button loading={busy} onClick={() => void handleSubmitSolution()}>
                        <Send size={16} /> Submit for evaluation
                      </Button>
                      <Button variant="secondary" loading={busy} onClick={() => void handleFinish()}>
                        Finish interview
                      </Button>
                    </div>
                  </article>
                </div>
              )}
            </>
          )}
        </section>
      )}
    </main>
  )
}
