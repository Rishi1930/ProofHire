import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import { CalendarDays, Plus, RefreshCw } from 'lucide-react'

import Button from '../components/Button'
import StatusBadge from '../components/StatusBadge'
import { useAuth } from '../auth/AuthContext'
import { supabase } from '../lib/supabase'
import { useWorkspaceApplications } from './useWorkspaceApplications'

type InterviewStatus = 'scheduled' | 'completed' | 'cancelled' | 'rescheduled'
type InterviewOutcome = 'pending' | 'positive' | 'negative' | 'next_round' | 'hired'

type InterviewRecord = {
  id: string
  application_id: string
  workspace_id: string
  round_number: number
  scheduled_at: string
  interview_status: InterviewStatus
  outcome: InterviewOutcome
  interviewer_name: string | null
  feedback: string | null
  created_at: string
}

const interviewStatuses: InterviewStatus[] = [
  'scheduled',
  'completed',
  'cancelled',
  'rescheduled',
]

const interviewOutcomes: InterviewOutcome[] = [
  'pending',
  'positive',
  'negative',
  'next_round',
  'hired',
]

function messageFromError(error: unknown) {
  const value = error as { code?: string; message?: string } | null
  if (value?.code === '23505') {
    return 'An interview record already exists for this application and round.'
  }
  return error instanceof Error
    ? error.message
    : 'The interview record could not be saved.'
}

export default function Interviews() {
  const { user } = useAuth()
  const {
    applications,
    workspaceId,
    loading: applicationsLoading,
    error: applicationsError,
    reload: reloadApplications,
  } = useWorkspaceApplications()
  const [interviews, setInterviews] = useState<InterviewRecord[]>([])
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')
  const [applicationId, setApplicationId] = useState('')
  const [scheduledAt, setScheduledAt] = useState('')
  const [round, setRound] = useState('1')
  const [interviewer, setInterviewer] = useState('')
  const [feedbackEdits, setFeedbackEdits] = useState<Record<string, string>>({})

  const loadInterviews = useCallback(async () => {
    if (!workspaceId || !supabase) {
      setInterviews([])
      setLoading(false)
      return
    }

    setLoading(true)
    setError('')
    try {
      const records: InterviewRecord[] = []
      const pageSize = 1000
      for (let start = 0; ; start += pageSize) {
        const { data, error: queryError } = await supabase
          .from('interview_records')
          .select(
            'id, application_id, workspace_id, round_number, scheduled_at, interview_status, outcome, interviewer_name, feedback, created_at',
          )
          .eq('workspace_id', workspaceId)
          .order('scheduled_at', { ascending: true })
          .range(start, start + pageSize - 1)
        if (queryError) throw queryError
        records.push(...((data ?? []) as InterviewRecord[]))
        if ((data ?? []).length < pageSize) break
      }
      setInterviews(records)
    } catch (caughtError) {
      setInterviews([])
      setError(messageFromError(caughtError))
    } finally {
      setLoading(false)
    }
  }, [workspaceId])

  useEffect(() => {
    void loadInterviews()
  }, [loadInterviews])

  const applicationById = useMemo(
    () => new Map(applications.map((application) => [application.id, application])),
    [applications],
  )
  const eligibleApplications = applications.filter(
    (application) => application.status === 'interview',
  )
  const now = Date.now()
  const upcoming = interviews.filter(
    (item) =>
      item.interview_status === 'scheduled' &&
      new Date(item.scheduled_at).getTime() >= now,
  )
  const completed = interviews.filter((item) => item.interview_status === 'completed')
  const feedbackPending = completed.filter((item) => !item.feedback?.trim())

  async function handleSchedule(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setError('')
    setSuccess('')
    if (!supabase || !workspaceId || !user?.id) {
      setError('Sign in and select a workspace before scheduling interviews.')
      return
    }
    if (!applicationId || !scheduledAt) {
      setError('Choose an interview-stage application and a date and time.')
      return
    }
    const roundNumber = Number(round)
    const scheduledDate = new Date(scheduledAt)
    if (!Number.isInteger(roundNumber) || roundNumber < 1 || Number.isNaN(scheduledDate.getTime())) {
      setError('Enter a valid interview round and date.')
      return
    }

    setSaving(true)
    try {
      const { error: insertError } = await supabase
        .from('interview_records')
        .insert({
          workspace_id: workspaceId,
          application_id: applicationId,
          round_number: roundNumber,
          scheduled_at: scheduledDate.toISOString(),
          interviewer_name: interviewer.trim() || null,
          created_by: user.id,
        })
      if (insertError) throw insertError

      setSuccess('Interview schedule saved. No invitation email was sent.')
      setApplicationId('')
      setScheduledAt('')
      setRound('1')
      setInterviewer('')
      await loadInterviews()
    } catch (caughtError) {
      setError(messageFromError(caughtError))
    } finally {
      setSaving(false)
    }
  }

  async function updateInterview(
    interview: InterviewRecord,
    changes: Partial<Pick<InterviewRecord, 'interview_status' | 'outcome' | 'feedback'>>,
  ) {
    if (!supabase) return
    setError('')
    setSuccess('')
    const { data, error: updateError } = await supabase
      .from('interview_records')
      .update(changes)
      .eq('workspace_id', interview.workspace_id)
      .eq('id', interview.id)
      .select('id')
      .maybeSingle()
    if (updateError) {
      setError(messageFromError(updateError))
      return
    }
    if (!data) {
      setError('Interview was not updated. Check recruiter access for this workspace.')
      return
    }
    setSuccess('Interview record updated.')
    await loadInterviews()
  }

  const pageLoading = loading || applicationsLoading
  const pageError = error || applicationsError

  return (
    <section className="page-stack">
      <div className="page-heading-row">
        <div className="page-heading">
          <span className="page-eyebrow">RECRUITER WORKFLOW</span>
          <h1>Interviews</h1>
          <p>Schedule interviews, track outcomes, and capture recruiter feedback.</p>
        </div>
        <Button
          variant="secondary"
          icon={<RefreshCw size={16} />}
          onClick={() => {
            void loadInterviews()
            void reloadApplications()
          }}
          loading={pageLoading}
        >
          Refresh
        </Button>
      </div>

      {pageError && (
        <div className="form-alert form-alert-error" role="alert">
          {pageError}
        </div>
      )}
      {success && <div className="form-alert form-alert-success" role="status">{success}</div>}
      {error && applicationsError && (
        <div className="form-alert form-alert-error" role="alert">{error}</div>
      )}

      <div className="info-banner">
        <CalendarDays size={19} />
        <div>
          <strong>Scheduling is internal only</strong>
          <p>
            Saving a schedule does not send an invitation. Email delivery,
            candidate responses, calendar integrations, recordings, and
            transcripts are not configured.
          </p>
        </div>
      </div>

      <div className="metric-grid">
        <div className="metric-card"><span>Upcoming interviews</span><strong>{pageLoading ? '—' : upcoming.length}</strong><small>Future scheduled records</small></div>
        <div className="metric-card"><span>Completed</span><strong>{pageLoading ? '—' : completed.length}</strong><small>Interview record status</small></div>
        <div className="metric-card"><span>Feedback pending</span><strong>{pageLoading ? '—' : feedbackPending.length}</strong><small>Completed without feedback</small></div>
        <div className="metric-card"><span>Email invitations</span><strong>Unavailable</strong><small>No delivery provider configured</small></div>
      </div>

      <section className="panel interview-schedule-panel">
        <header className="recruitment-list-header">
          <div>
            <h2><Plus size={18} /> Schedule an interview</h2>
            <p>Choose an application already in the Interview stage. This records the schedule only.</p>
          </div>
        </header>
        <form className="interview-schedule-form" onSubmit={(event) => void handleSchedule(event)}>
          <label>
            <span>Candidate and job</span>
            <select
              className="form-select"
              value={applicationId}
              onChange={(event) => setApplicationId(event.target.value)}
              required
            >
              <option value="">Select an interview-stage application</option>
              {eligibleApplications.map((application) => (
                <option key={application.id} value={application.id}>
                  {application.candidates?.full_name ?? 'Candidate'} · {application.jobs?.title ?? 'Job'}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>Date and time</span>
            <input
              className="form-input"
              type="datetime-local"
              value={scheduledAt}
              onChange={(event) => setScheduledAt(event.target.value)}
              required
            />
          </label>
          <label>
            <span>Round</span>
            <input
              className="form-input"
              type="number"
              min="1"
              step="1"
              value={round}
              onChange={(event) => setRound(event.target.value)}
              required
            />
          </label>
          <label>
            <span>Interviewer</span>
            <input
              className="form-input"
              value={interviewer}
              onChange={(event) => setInterviewer(event.target.value)}
              maxLength={180}
              placeholder="Optional"
            />
          </label>
          <Button type="submit" loading={saving} icon={<Plus size={16} />}>Save schedule</Button>
        </form>
        {eligibleApplications.length === 0 && !applicationsLoading && (
          <p className="interview-form-note">No applications are currently in the Interview stage.</p>
        )}
      </section>

      <section className="panel">
        <header className="recruitment-list-header">
          <div>
            <h2>Interview schedule and outcomes</h2>
            <p>{interviews.length} interview records in this workspace.</p>
          </div>
        </header>
        {pageLoading ? (
          <div className="empty-state"><span className="loading-spinner" /><p>Loading interview records...</p></div>
        ) : pageError ? (
          <div className="empty-state">
            <h3>Interview records unavailable</h3>
            <p>
              Resolve the interview records error above and refresh. Apply
              migration 202610260006 first if it has not been run.
            </p>
          </div>
        ) : interviews.length === 0 ? (
          <div className="empty-state">
            <CalendarDays size={28} />
            <h3>No interview schedules yet</h3>
            <p>Interview schedules will appear after a recruiter records one above.</p>
          </div>
        ) : (
          <div className="interview-record-list">
            {interviews.map((interview) => {
              const application = applicationById.get(interview.application_id)
              return (
                <article className="interview-record" key={interview.id}>
                  <div className="interview-record-main">
                    <strong>{application?.candidates?.full_name ?? 'Candidate'}</strong>
                    <span>{application?.jobs?.title ?? 'Job'} · Round {interview.round_number}</span>
                    <span>{new Date(interview.scheduled_at).toLocaleString()}</span>
                    {interview.interviewer_name && <span>Interviewer: {interview.interviewer_name}</span>}
                    <span>Application stage: {application?.status ?? 'Unavailable'}</span>
                  </div>
                  <div className="interview-record-controls">
                    <label>
                      <span>Interview status</span>
                      <select
                        className="form-select"
                        value={interview.interview_status}
                        onChange={(event) => void updateInterview(interview, { interview_status: event.target.value as InterviewStatus })}
                      >
                        {interviewStatuses.map((status) => <option key={status} value={status}>{status}</option>)}
                      </select>
                    </label>
                    <label>
                      <span>Interview outcome</span>
                      <select
                        className="form-select"
                        value={interview.outcome}
                        onChange={(event) => void updateInterview(interview, { outcome: event.target.value as InterviewOutcome })}
                      >
                        {interviewOutcomes.map((outcome) => <option key={outcome} value={outcome}>{outcome.replace('_', ' ')}</option>)}
                      </select>
                    </label>
                    <label className="interview-feedback-field">
                      <span>Structured feedback</span>
                      <textarea
                        className="form-textarea"
                        value={feedbackEdits[interview.id] ?? interview.feedback ?? ''}
                        onChange={(event) => setFeedbackEdits((current) => ({ ...current, [interview.id]: event.target.value }))}
                        rows={2}
                        maxLength={10000}
                      />
                    </label>
                    <Button
                      variant="secondary"
                      onClick={() => void updateInterview(interview, {
                        feedback: feedbackEdits[interview.id] ?? interview.feedback ?? '',
                      })}
                    >
                      Save feedback
                    </Button>
                  </div>
                  <StatusBadge status={interview.interview_status} size="small" />
                </article>
              )
            })}
          </div>
        )}
      </section>
    </section>
  )
}
