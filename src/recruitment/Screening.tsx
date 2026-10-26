import { useCallback, useEffect, useMemo, useState } from 'react'
import { ArrowRight, BrainCircuit, RefreshCw } from 'lucide-react'
import { Link } from 'react-router-dom'

import Button from '../components/Button'
import ExportActions from '../components/ExportActions'
import RecruitmentApplicationList from './RecruitmentApplicationList'
import {
  getDecisionEvents,
  type ApplicationDecisionEvent,
  type ApplicationRecord,
} from './applicationData'
import { useWorkspaceApplications } from './useWorkspaceApplications'

function actionsFor(application: ApplicationRecord) {
  if (application.status === 'new') {
    return [
      { label: 'Begin review', status: 'screening' as const },
      {
        label: 'Confirm & Shortlist',
        status: 'shortlisted' as const,
        decision: 'shortlist' as const,
        variant: 'primary' as const,
      },
      { label: 'Reject', status: 'rejected' as const, decision: 'reject' as const, variant: 'danger' as const },
    ]
  }
  if (application.status === 'screening') {
    return [
      {
        label: 'Confirm & Shortlist',
        status: 'shortlisted' as const,
        decision: 'shortlist' as const,
        variant: 'primary' as const,
      },
      { label: 'Reject', status: 'rejected' as const, decision: 'reject' as const, variant: 'danger' as const },
    ]
  }
  return [
    {
      label: 'Mark as hired',
      status: 'hired' as const,
      decision: 'mark_hired' as const,
      variant: 'primary' as const,
    },
    { label: 'Move to interview stage', status: 'interview' as const, decision: 'advance_to_interview' as const, variant: 'primary' as const },
    { label: 'Return to screening', status: 'screening' as const, decision: 'return_to_screening' as const },
  ]
}

export default function Screening() {
  const {
    applications,
    workspaceId,
    loading,
    error,
    reload,
    updateStatus,
    recordDecision,
  } =
    useWorkspaceApplications()
  const [success, setSuccess] = useState('')
  const [decisionEvents, setDecisionEvents] = useState<ApplicationDecisionEvent[]>([])
  const [decisionHistoryError, setDecisionHistoryError] = useState('')
  const [selectedJobId, setSelectedJobId] = useState('')

  const reloadDecisionHistory = useCallback(async () => {
    if (!workspaceId) return
    try {
      setDecisionHistoryError('')
      setDecisionEvents(await getDecisionEvents(workspaceId))
    } catch (caughtError) {
      setDecisionEvents([])
      setDecisionHistoryError(
        caughtError instanceof Error
          ? caughtError.message
          : 'Decision history is unavailable.',
      )
    }
  }, [workspaceId])

  useEffect(() => {
    void reloadDecisionHistory()
  }, [reloadDecisionHistory])
  const queuedApplications = useMemo(
    () =>
      applications.filter((application) =>
        ['new', 'screening', 'shortlisted'].includes(application.status),
      ),
    [applications],
  )
  const screeningJobs = useMemo(
    () => [
      ...new Map(
        applications.map((application) => [
          application.job_id,
          { id: application.job_id, title: application.jobs?.title ?? 'Untitled job' },
        ]),
      ).values(),
    ],
    [applications],
  )
  const assessmentExportOptions = [
    {
      label: 'Export Results for This Job (CSV)',
      format: 'csv' as const,
      disabled: true,
      reason: 'No persisted screening assessments are available.',
    },
    {
      label: 'Export Top Candidates (CSV)',
      format: 'csv' as const,
      disabled: true,
      reason: 'Ranking requires persisted assessment scores; none exist.',
    },
    {
      label: 'Export Needs Confirmation (CSV)',
      format: 'csv' as const,
      disabled: true,
      reason: 'No persisted assessment confirmation categories exist.',
    },
    {
      label: 'Export Not Matched (CSV)',
      format: 'csv' as const,
      disabled: true,
      reason: 'No persisted assessment categories exist.',
    },
    {
      label: 'Export Assessment Report (PDF)',
      format: 'pdf' as const,
      disabled: true,
      reason: 'Assessment evidence and explanations are not stored.',
    },
    {
      label: 'Export Assessment Workbook (XLSX)',
      format: 'xlsx' as const,
      disabled: true,
      reason: 'Assessment evidence and explanations are not stored.',
    },
  ]

  async function handleStatusChange(
    applicationId: string,
    status: Parameters<typeof updateStatus>[1],
  ) {
    await updateStatus(applicationId, status)
    setSuccess(`Application moved to ${status}.`)
  }

  async function handleDecision(
    applicationId: string,
    decision: Parameters<typeof recordDecision>[1],
  ) {
    await recordDecision(applicationId, decision)
    setSuccess('Recruiter decision recorded.')
    await reloadDecisionHistory()
  }

  return (
    <section className="page-stack">
      <div className="page-heading-row">
        <div className="page-heading">
          <span className="page-eyebrow">RECRUITER WORKFLOW</span>
          <h1>Resume Screening</h1>
          <p>Review submitted applications and record a human decision.</p>
        </div>
        <Button
          variant="secondary"
          icon={<RefreshCw size={16} />}
          onClick={() => {
            void reload()
            void reloadDecisionHistory()
          }}
          loading={loading}
        >
          Refresh
        </Button>
      </div>

      <div className="recruitment-export-toolbar">
        <label className="recruitment-export-job">
          <span>Job for assessment export</span>
          <select
            className="form-select"
            value={selectedJobId}
            onChange={(event) => setSelectedJobId(event.target.value)}
            aria-label="Select a job for screening assessment export"
          >
            <option value="">Select a job</option>
            {screeningJobs.map((job) => (
              <option key={job.id} value={job.id}>{job.title}</option>
            ))}
          </select>
        </label>
        <ExportActions
          scope={selectedJobId ? screeningJobs.find((job) => job.id === selectedJobId)?.title ?? 'selected job' : 'select a job'}
          disabled={loading || !selectedJobId}
          options={assessmentExportOptions}
        />
      </div>

      <div className="info-banner">
        <BrainCircuit size={19} />
        <div>
          <strong>Manual review only</strong>
          <p>
            Automated resume parsing, AI recommendations, and match scores are
            not implemented. Review the original resume and use the status
            actions to record your decision.
          </p>
        </div>
      </div>

      {error && (
        <div className="form-alert form-alert-error" role="alert">
          {error}
        </div>
      )}
      {success && (
        <div className="form-alert form-alert-success" role="status">
          {success}
        </div>
      )}

      <div className="panel">
        <div className="recruitment-list-header">
          <div>
            <h2>Review queue</h2>
            <p>{queuedApplications.length} applications awaiting a decision</p>
          </div>
          <Link to="/applications" state={{ from: '/screening' }} className="text-link">
            All applications <ArrowRight size={15} />
          </Link>
        </div>
        {loading ? (
          <div className="empty-state">
            <span className="loading-spinner" />
            <p>Loading applications...</p>
          </div>
        ) : error ? (
          <div className="empty-state">
            <h3>Screening queue unavailable</h3>
            <p>Resolve the workspace query error above and refresh to try again.</p>
          </div>
        ) : (
          <RecruitmentApplicationList
            applications={queuedApplications}
            onStatusChange={handleStatusChange}
            onDecision={handleDecision}
            actionsFor={actionsFor}
            emptyTitle="Screening queue is clear"
            emptyDescription="New applications will appear here when candidates apply to your jobs."
          />
        )}
      </div>

      <div className="panel">
        <div className="recruitment-list-header">
          <div>
            <h2>Decision history</h2>
            <p>Recent recruiter decisions recorded for this workspace.</p>
          </div>
        </div>
        {decisionHistoryError ? (
          <div className="empty-state">
            <p>
              Decision history could not be loaded: {decisionHistoryError}
              {' '}Apply migration 202610260006 if it has not been run.
            </p>
          </div>
        ) : decisionEvents.length === 0 ? (
          <div className="empty-state"><p>No recruiter decisions recorded yet.</p></div>
        ) : (
          <div className="decision-event-list">
            {decisionEvents.map((event) => {
              const application = applications.find(
                (record) => record.id === event.application_id,
              )
              return (
                <article className="decision-event-row" key={event.id}>
                  <div>
                    <strong>{application?.candidates?.full_name ?? 'Candidate'}</strong>
                    <span>{application?.jobs?.title ?? 'Job'} · {event.decision.replace(/_/g, ' ')}</span>
                    {event.note && <span>{event.note}</span>}
                  </div>
                  <time dateTime={event.created_at}>{new Date(event.created_at).toLocaleString()}</time>
                </article>
              )
            })}
          </div>
        )}
      </div>
    </section>
  )
}
