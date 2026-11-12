import { useCallback, useEffect, useMemo, useState } from 'react'
import {
  AlertTriangle,
  ClipboardCheck,
  Code2,
  Copy,
  Plus,
  RefreshCw,
  Trash2,
  Video,
} from 'lucide-react'

import Button from '../components/Button'
import { supabase } from '../lib/supabase'
import { useWorkspaceApplications } from '../recruitment/useWorkspaceApplications'
import {
  cancelSession,
  createInterviewSession,
  sendInterviewInvitation,
  loadSessionOverview,
  scoreSession,
  type CodingChallengeVersion,
  type InterviewQuestion,
  type SessionOverview,
} from './api'
import './interview.css'

type JobOption = { id: string; title: string }

type SessionQuestion = {
  question_id: string
  display_order: number
  prompt_snapshot: string
  max_points: number
  awarded_points: number | null
  reviewer_comment: string | null
}

type SessionAnswer = { question_id: string; answer_text: string }

type SessionSubmission = {
  id: string
  challenge_version_id: string
  language: string
  status: string
  score: number | null
  passed_tests: number | null
  total_tests: number | null
  submitted_at: string
}

const DEFAULT_QUESTIONS_LIMIT = 1200
const DEFAULT_CODING_LIMIT = 3600

function errorText(caught: unknown, fallback: string) {
  return caught instanceof Error ? caught.message : fallback
}

export default function InterviewWorkspace() {
  const {
    applications,
    workspaceId,
    loading: applicationsLoading,
    error: applicationsError,
  } = useWorkspaceApplications()

  const [jobs, setJobs] = useState<JobOption[]>([])
  const [selectedJobId, setSelectedJobId] = useState('')
  const [questions, setQuestions] = useState<InterviewQuestion[]>([])
  const [challenges, setChallenges] = useState<CodingChallengeVersion[]>([])
  const [sessions, setSessions] = useState<SessionOverview[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')
  const [busy, setBusy] = useState(false)

  const [newQuestion, setNewQuestion] = useState({
    prompt: '',
    category: 'general',
    maxPoints: '5',
  })

  const [draft, setDraft] = useState({
    applicationId: '',
    questionsTimeLimit: String(DEFAULT_QUESTIONS_LIMIT / 60),
    codingTimeLimit: String(DEFAULT_CODING_LIMIT / 60),
    passingScore: '60',
  })
  const [selectedQuestionIds, setSelectedQuestionIds] = useState<string[]>([])
  const [selectedChallengeIds, setSelectedChallengeIds] = useState<string[]>([])
  const [interviewLink, setInterviewLink] = useState('')

  const [activeSession, setActiveSession] = useState<SessionOverview | null>(null)
  const [sessionQuestions, setSessionQuestions] = useState<SessionQuestion[]>([])
  const [sessionAnswers, setSessionAnswers] = useState<Record<string, string>>({})
  const [sessionSubmissions, setSessionSubmissions] = useState<SessionSubmission[]>([])
  const [scores, setScores] = useState<Record<string, string>>({})
  const [comments, setComments] = useState<Record<string, string>>({})
  const [sessionLoading, setSessionLoading] = useState(false)

  const loadWorkspace = useCallback(async () => {
    if (!workspaceId || !supabase) {
      setLoading(false)
      return
    }
    setLoading(true)
    setError('')
    try {
      const [jobsResult, challengeResult, overview] = await Promise.all([
        supabase
          .from('jobs')
          .select('id, title')
          .eq('workspace_id', workspaceId)
          .order('created_at', { ascending: false }),
        supabase
          .from('coding_challenge_versions')
          .select('id, challenge_id, prompt, difficulty, points, supported_languages, version_status')
          .eq('workspace_id', workspaceId)
          .eq('version_status', 'published')
          .order('created_at', { ascending: false }),
        loadSessionOverview(workspaceId),
      ])
      if (jobsResult.error) throw jobsResult.error
      if (challengeResult.error) throw challengeResult.error
      setJobs((jobsResult.data ?? []) as JobOption[])
      setSelectedJobId((current) => current || (jobsResult.data?.[0] as JobOption | undefined)?.id || '')
      setChallenges((challengeResult.data ?? []) as CodingChallengeVersion[])
      setSessions(overview)
    } catch (caught) {
      setError(errorText(caught, 'The interview workspace could not be loaded.'))
    } finally {
      setLoading(false)
    }
  }, [workspaceId])

  useEffect(() => {
    void loadWorkspace()
  }, [loadWorkspace])

  const loadQuestions = useCallback(async () => {
    if (!workspaceId || !selectedJobId || !supabase) {
      setQuestions([])
      return
    }
    const { data, error: queryError } = await supabase
      .from('interview_questions')
      .select('id, workspace_id, job_id, display_order, prompt, category, expected_keywords, max_points, is_active')
      .eq('workspace_id', workspaceId)
      .eq('job_id', selectedJobId)
      .order('display_order', { ascending: true })
    if (queryError) {
      setError(queryError.message)
      return
    }
    setQuestions((data ?? []) as InterviewQuestion[])
  }, [selectedJobId, workspaceId])

  useEffect(() => {
    void loadQuestions()
  }, [loadQuestions])

  const eligibleApplications = useMemo(
    () =>
      applications.filter((application) =>
        ['interview', 'shortlisted', 'screening', 'new'].includes(application.status),
      ),
    [applications],
  )

  useEffect(() => {
    setSelectedQuestionIds(questions.filter((question) => question.is_active).map((question) => question.id))
  }, [questions])

  useEffect(() => {
    if (draft.applicationId || eligibleApplications.length === 0) return
    setDraft((current) => ({ ...current, applicationId: eligibleApplications[0].id }))
  }, [draft.applicationId, eligibleApplications])

  const selectedApplication = eligibleApplications.find(
    (application) => application.id === draft.applicationId,
  )
  const applicationJobId = selectedApplication?.job_id ?? ''

  useEffect(() => {
    if (applicationJobId) setSelectedJobId(applicationJobId)
  }, [applicationJobId])

  async function addQuestion() {
    if (!supabase || !workspaceId || !selectedJobId) return
    const { data: userData } = await supabase.auth.getUser()
    if (!userData.user) {
      setError('Sign in again to author questions.')
      return
    }
    const prompt = newQuestion.prompt.trim()
    const points = Number(newQuestion.maxPoints)
    if (prompt.length < 5) {
      setError('A question needs at least 5 characters.')
      return
    }
    if (!Number.isFinite(points) || points <= 0 || points > 100) {
      setError('Points must be between 0 and 100.')
      return
    }
    setBusy(true)
    setError('')
    try {
      const nextOrder = (questions.at(-1)?.display_order ?? 0) + 1
      const { error: insertError } = await supabase.from('interview_questions').insert({
        workspace_id: workspaceId,
        job_id: selectedJobId,
        display_order: nextOrder,
        prompt,
        category: newQuestion.category.trim() || 'general',
        max_points: points,
        created_by: userData.user.id,
      })
      if (insertError) throw insertError
      setNewQuestion({ prompt: '', category: 'general', maxPoints: '5' })
      await loadQuestions()
      setSuccess('Question added to this job.')
    } catch (caught) {
      setError(errorText(caught, 'The question could not be saved.'))
    } finally {
      setBusy(false)
    }
  }

  async function removeQuestion(questionId: string) {
    if (!supabase) return
    setBusy(true)
    setError('')
    try {
      const { error: deleteError } = await supabase
        .from('interview_questions')
        .delete()
        .eq('id', questionId)
      if (deleteError) throw deleteError
      await loadQuestions()
      setSuccess('Question removed.')
    } catch (caught) {
      setError(errorText(caught, 'The question could not be removed. It may already be used by a session.'))
    } finally {
      setBusy(false)
    }
  }

  async function createSession() {
    if (!draft.applicationId) {
      setError('Choose the application to interview.')
      return
    }
    if (selectedQuestionIds.length === 0 && selectedChallengeIds.length === 0) {
      setError('Select at least one question or one coding challenge.')
      return
    }
    setBusy(true)
    setError('')
    setSuccess('')
    try {
      const result = await createInterviewSession({
        applicationId: draft.applicationId,
        questionIds: selectedQuestionIds,
        challengeVersionIds: selectedChallengeIds,
        questionsTimeLimitSeconds: Math.max(1, Number(draft.questionsTimeLimit) || 20) * 60,
        codingTimeLimitSeconds: Math.max(5, Number(draft.codingTimeLimit) || 60) * 60,
        passingScore: Math.min(100, Math.max(0, Number(draft.passingScore) || 60)),
      })
      const link = `${window.location.origin}/interview/${result.token}`
      setInterviewLink(link)
      let delivery = ''
      try {
        const queued = await sendInterviewInvitation(result.session_id, result.token)
        delivery = queued.queued
          ? ` An invitation email is queued for ${queued.recipient}.`
          : ' The invitation email was already sent to this candidate.'
      } catch (caught) {
        delivery = ` The invitation email was not queued: ${errorText(caught, 'unknown error')}. Send the link manually.`
      }
      try {
        await navigator.clipboard.writeText(link)
        setSuccess(`Interview created. The single-use link was copied to your clipboard.${delivery}`)
      } catch {
        setSuccess(`Interview created. Copy the link below and send it to the candidate.${delivery}`)
      }
      await loadWorkspace()
    } catch (caught) {
      setError(errorText(caught, 'The interview session could not be created.'))
    } finally {
      setBusy(false)
    }
  }

  async function openSession(session: SessionOverview) {
    if (!supabase) return
    setActiveSession(session)
    setSessionLoading(true)
    setError('')
    try {
      const [questionResult, answerResult, submissionResult] = await Promise.all([
        supabase
          .from('interview_session_questions')
          .select('question_id, display_order, prompt_snapshot, max_points, awarded_points, reviewer_comment')
          .eq('session_id', session.session_id)
          .order('display_order', { ascending: true }),
        supabase
          .from('interview_answers')
          .select('question_id, answer_text')
          .eq('session_id', session.session_id),
        supabase
          .from('interview_code_submissions')
          .select('id, challenge_version_id, language, status, score, passed_tests, total_tests, submitted_at')
          .eq('session_id', session.session_id)
          .order('submitted_at', { ascending: false }),
      ])
      if (questionResult.error) throw questionResult.error
      if (answerResult.error) throw answerResult.error
      if (submissionResult.error) throw submissionResult.error
      const nextQuestions = (questionResult.data ?? []) as SessionQuestion[]
      setSessionQuestions(nextQuestions)
      const answerMap: Record<string, string> = {}
      for (const answer of (answerResult.data ?? []) as SessionAnswer[]) {
        answerMap[answer.question_id] = answer.answer_text
      }
      setSessionAnswers(answerMap)
      setSessionSubmissions((submissionResult.data ?? []) as SessionSubmission[])
      const scoreMap: Record<string, string> = {}
      const commentMap: Record<string, string> = {}
      for (const question of nextQuestions) {
        scoreMap[question.question_id] = String(question.awarded_points ?? '')
        commentMap[question.question_id] = question.reviewer_comment ?? ''
      }
      setScores(scoreMap)
      setComments(commentMap)
    } catch (caught) {
      setError(errorText(caught, 'The session detail could not be loaded.'))
    } finally {
      setSessionLoading(false)
    }
  }

  async function saveScores() {
    if (!activeSession) return
    setBusy(true)
    setError('')
    try {
      const numericScores: Record<string, number> = {}
      for (const [questionId, value] of Object.entries(scores)) {
        numericScores[questionId] = Number(value) || 0
      }
      const result = await scoreSession(activeSession.session_id, numericScores, comments)
      setSuccess(
        `Saved. Question score ${result.questions_score ?? '—'}%, coding ${result.coding_score ?? '—'}%, total ${result.total_score ?? '—'}% — ${result.passed ? 'meets' : 'below'} the threshold.`,
      )
      await loadWorkspace()
      setActiveSession(null)
    } catch (caught) {
      setError(errorText(caught, 'Scores could not be saved.'))
    } finally {
      setBusy(false)
    }
  }

  async function copyLink(sessionId: string) {
    const existing = sessions.find((item) => item.session_id === sessionId)
    if (!existing) return
    setError('Interview links are shown once, when the session is created. Create a new session to issue another link.')
  }

  const applicationById = useMemo(
    () => new Map(applications.map((application) => [application.id, application])),
    [applications],
  )

  return (
    <section className="page-stack">
      <div className="page-heading-row">
        <div className="page-heading">
          <span className="page-eyebrow">TECHNICAL INTERVIEW</span>
          <h1>Interview engine</h1>
          <p>
            Author job questions, attach coding tasks, and review proctored interview results.
            Questions are answered first, then candidates write code that is scored against hidden
            tests by your own runner.
          </p>
        </div>
        <Button
          variant="secondary"
          icon={<RefreshCw size={16} />}
          loading={loading}
          onClick={() => void loadWorkspace()}
        >
          Refresh
        </Button>
      </div>

      {(error || applicationsError) && (
        <div className="form-alert form-alert-error" role="alert">
          {error || applicationsError}
        </div>
      )}
      {success && (
        <div className="form-alert form-alert-success" role="status">
          {success}
        </div>
      )}
      {interviewLink && (
        <div className="form-alert form-alert-success" role="status">
          <strong>Single-use candidate link:</strong>{' '}
          <code>{interviewLink}</code>
        </div>
      )}

      <div className="interview-admin-grid">
        <article className="panel">
          <header className="recruitment-list-header">
            <div>
              <h2>Question bank</h2>
              <p>Questions are scoped to a job and snapshotted into each session.</p>
            </div>
          </header>
          <label className="interview-field">
            <span>Job</span>
            <select
              className="form-select"
              value={selectedJobId}
              onChange={(event) => setSelectedJobId(event.target.value)}
            >
              <option value="">Select a job</option>
              {jobs.map((job) => (
                <option key={job.id} value={job.id}>{job.title}</option>
              ))}
            </select>
          </label>

          {selectedJobId && (
            <>
              <div className="interview-question-list">
                {questions.length === 0 ? (
                  <p className="interview-muted">No questions yet for this job.</p>
                ) : (
                  questions.map((question) => (
                    <div key={question.id} className="interview-question-row">
                      <span className="interview-question-index">{question.display_order}</span>
                      <div>
                        <p>{question.prompt}</p>
                        <span className="interview-muted">
                          {question.category} · {question.max_points} pts
                        </span>
                      </div>
                      <button
                        type="button"
                        className="icon-button"
                        aria-label="Delete question"
                        onClick={() => void removeQuestion(question.id)}
                      >
                        <Trash2 size={16} />
                      </button>
                    </div>
                  ))
                )}
              </div>

              <div className="interview-question-form">
                <label className="interview-field">
                  <span>New question</span>
                  <textarea
                    rows={3}
                    value={newQuestion.prompt}
                    placeholder="e.g. Explain how you would diagnose a slow SQL query in production."
                    onChange={(event) =>
                      setNewQuestion((current) => ({ ...current, prompt: event.target.value }))
                    }
                  />
                </label>
                <div className="interview-form-row">
                  <label className="interview-field">
                    <span>Category</span>
                    <input
                      value={newQuestion.category}
                      onChange={(event) =>
                        setNewQuestion((current) => ({ ...current, category: event.target.value }))
                      }
                    />
                  </label>
                  <label className="interview-field">
                    <span>Points</span>
                    <input
                      type="number"
                      min={1}
                      max={100}
                      value={newQuestion.maxPoints}
                      onChange={(event) =>
                        setNewQuestion((current) => ({ ...current, maxPoints: event.target.value }))
                      }
                    />
                  </label>
                </div>
                <Button icon={<Plus size={16} />} loading={busy} onClick={() => void addQuestion()}>
                  Add question
                </Button>
              </div>
            </>
          )}
        </article>

        <article className="panel">
          <header className="recruitment-list-header">
            <div>
              <h2>Start an interview</h2>
              <p>Pick the application, questions and coding tasks. The link is shown once.</p>
            </div>
          </header>

          <label className="interview-field">
            <span>Application</span>
            <select
              className="form-select"
              value={draft.applicationId}
              onChange={(event) =>
                setDraft((current) => ({ ...current, applicationId: event.target.value }))
              }
              disabled={applicationsLoading}
            >
              <option value="">Select an application</option>
              {eligibleApplications.map((application) => {
                const record = applicationById.get(application.id)
                return (
                  <option key={application.id} value={application.id}>
                    {record?.candidates?.full_name ?? 'Candidate'} · {record?.jobs?.title ?? 'Job'} · {application.status}
                  </option>
                )
              })}
            </select>
          </label>

          <div className="interview-form-row">
            <label className="interview-field">
              <span>Questions (minutes)</span>
              <input
                type="number"
                min={1}
                max={240}
                value={draft.questionsTimeLimit}
                onChange={(event) =>
                  setDraft((current) => ({ ...current, questionsTimeLimit: event.target.value }))
                }
              />
            </label>
            <label className="interview-field">
              <span>Coding (minutes)</span>
              <input
                type="number"
                min={5}
                max={360}
                value={draft.codingTimeLimit}
                onChange={(event) =>
                  setDraft((current) => ({ ...current, codingTimeLimit: event.target.value }))
                }
              />
            </label>
            <label className="interview-field">
              <span>Pass mark (%)</span>
              <input
                type="number"
                min={0}
                max={100}
                value={draft.passingScore}
                onChange={(event) =>
                  setDraft((current) => ({ ...current, passingScore: event.target.value }))
                }
              />
            </label>
          </div>

          <fieldset className="interview-picker">
            <legend><ClipboardCheck size={15} /> Questions ({selectedQuestionIds.length})</legend>
            {questions.length === 0 && (
              <p className="interview-muted">Add questions for this job first.</p>
            )}
            {questions.map((question) => (
              <label key={question.id} className="interview-check">
                <input
                  type="checkbox"
                  checked={selectedQuestionIds.includes(question.id)}
                  onChange={(event) =>
                    setSelectedQuestionIds((current) =>
                      event.target.checked
                        ? [...current, question.id]
                        : current.filter((id) => id !== question.id),
                    )
                  }
                />
                <span>{question.prompt}</span>
              </label>
            ))}
          </fieldset>

          <fieldset className="interview-picker">
            <legend><Code2 size={15} /> Coding tasks ({selectedChallengeIds.length})</legend>
            {challenges.length === 0 && (
              <p className="interview-muted">
                No published coding challenges in this workspace yet.
              </p>
            )}
            {challenges.map((challenge) => (
              <label key={challenge.id} className="interview-check">
                <input
                  type="checkbox"
                  checked={selectedChallengeIds.includes(challenge.id)}
                  onChange={(event) =>
                    setSelectedChallengeIds((current) =>
                      event.target.checked
                        ? [...current, challenge.id]
                        : current.filter((id) => id !== challenge.id),
                    )
                  }
                />
                <span>
                  {challenge.prompt.slice(0, 90)}
                  {challenge.prompt.length > 90 ? '…' : ''} · {challenge.difficulty} · {challenge.points} pts
                </span>
              </label>
            ))}
          </fieldset>

          <Button loading={busy} onClick={() => void createSession()}>
            <Video size={16} /> Create interview link
          </Button>
        </article>
      </div>

      <article className="panel">
        <header className="recruitment-list-header">
          <div>
            <h2>Interview sessions</h2>
            <p>Codes are evaluated by the runner; question scores are yours to award.</p>
          </div>
        </header>
        {sessions.length === 0 ? (
          <div className="empty-state">
            <p>No technical interviews yet.</p>
          </div>
        ) : (
          <div className="table-scroll">
            <table className="data-table">
              <thead>
                <tr>
                  <th>Candidate</th>
                  <th>Job</th>
                  <th>Status</th>
                  <th>Questions</th>
                  <th>Coding</th>
                  <th>Total</th>
                  <th>Integrity</th>
                  <th />
                </tr>
              </thead>
              <tbody>
                {sessions.map((session) => (
                  <tr key={session.session_id}>
                    <td><strong>{session.candidate_name}</strong></td>
                    <td>{session.job_title}</td>
                    <td>{session.status.replace(/_/g, ' ')}</td>
                    <td>{session.questions_score === null ? '—' : `${session.questions_score}%`}</td>
                    <td>
                      {session.coding_score === null ? '—' : `${session.coding_score}%`}
                      {session.pending_submissions > 0 ? ` · ${session.pending_submissions} queued` : ''}
                    </td>
                    <td>
                      {session.total_score === null ? '—' : `${session.total_score}%`}
                      <span className="interview-muted"> / {session.passing_score}%</span>
                    </td>
                    <td>
                      {session.flagged ? (
                        <span className="interview-flag">
                          <AlertTriangle size={14} /> {session.proctor_violations}
                        </span>
                      ) : (
                        session.proctor_violations || '—'
                      )}
                    </td>
                    <td>
                      <div className="interview-row-actions">
                        <Button
                          variant="secondary"
                          onClick={() => void openSession(session)}
                          disabled={session.status !== 'submitted' && session.status !== 'completed'}
                        >
                          Review
                        </Button>
                        <button
                          type="button"
                          className="icon-button"
                          aria-label="Copy interview link"
                          onClick={() => void copyLink(session.session_id)}
                        >
                          <Copy size={15} />
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </article>

      {activeSession && (
        <article className="panel interview-review">
          <header className="recruitment-list-header">
            <div>
              <h2>Review · {activeSession.candidate_name}</h2>
              <p>{activeSession.job_title} · submitted {activeSession.submitted_at
                ? new Date(activeSession.submitted_at).toLocaleString()
                : '—'}</p>
            </div>
            <div className="interview-row-actions">
              <Button
                variant="secondary"
                onClick={() => {
                  void cancelSession(activeSession.session_id, 'Cancelled by recruiter')
                    .then(() => loadWorkspace())
                    .then(() => setActiveSession(null))
                    .catch((caught: unknown) =>
                      setError(errorText(caught, 'The session could not be cancelled.')),
                    )
                }}
              >
                Cancel session
              </Button>
              <Button onClick={() => void saveScores()} loading={busy}>Save scores</Button>
            </div>
          </header>

          {sessionLoading ? (
            <div className="empty-state"><span className="loading-spinner" /></div>
          ) : (
            <>
              {sessionQuestions.map((question) => (
                <div key={question.question_id} className="interview-review-block">
                  <div className="interview-review-head">
                    <span className="interview-question-index">Q{question.display_order}</span>
                    <p>{question.prompt_snapshot}</p>
                  </div>
                  <pre className="interview-answer">
{sessionAnswers[question.question_id] || '(no answer)'}
                  </pre>
                  <div className="interview-form-row">
                    <label className="interview-field">
                      <span>Awarded / {question.max_points}</span>
                      <input
                        type="number"
                        min={0}
                        max={question.max_points}
                        value={scores[question.question_id] ?? ''}
                        onChange={(event) =>
                          setScores((current) => ({
                            ...current,
                            [question.question_id]: event.target.value,
                          }))
                        }
                      />
                    </label>
                    <label className="interview-field interview-field-wide">
                      <span>Comment</span>
                      <input
                        value={comments[question.question_id] ?? ''}
                        onChange={(event) =>
                          setComments((current) => ({
                            ...current,
                            [question.question_id]: event.target.value,
                          }))
                        }
                      />
                    </label>
                  </div>
                </div>
              ))}

              <h3 className="interview-review-subhead">Coding submissions</h3>
              {sessionSubmissions.length === 0 ? (
                <p className="interview-muted">No code was submitted.</p>
              ) : (
                <ul className="interview-submission-list">
                  {sessionSubmissions.map((submission) => (
                    <li key={submission.id}>
                      <strong>{submission.language}</strong> · {submission.status} ·{' '}
                      {submission.score === null ? 'not scored' : `${submission.score}%`} ·{' '}
                      {submission.passed_tests ?? '—'}/{submission.total_tests ?? '—'} tests ·{' '}
                      {new Date(submission.submitted_at).toLocaleString()}
                    </li>
                  ))}
                </ul>
              )}
            </>
          )}
        </article>
      )}
    </section>
  )
}
