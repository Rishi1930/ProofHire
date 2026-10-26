import { useState } from 'react'
import { ExternalLink, FileText, UserRound } from 'lucide-react'

import StatusBadge from '../components/StatusBadge'
import {
  applicationStatuses,
  getResumeSignedUrl,
  type ApplicationRecord,
  type ApplicationStatus,
  type RecruiterDecision,
} from './applicationData'

export type ApplicationAction = {
  label: string
  status: ApplicationStatus
  decision?: RecruiterDecision
  variant?: 'primary' | 'secondary' | 'danger'
}

type Props = {
  applications: ApplicationRecord[]
  onStatusChange?: (
    applicationId: string,
    status: ApplicationStatus,
  ) => Promise<void>
  onDecision?: (
    applicationId: string,
    decision: RecruiterDecision,
  ) => Promise<void>
  actionsFor?: (application: ApplicationRecord) => ApplicationAction[]
  onSelect?: (application: ApplicationRecord) => void
  emptyTitle?: string
  emptyDescription?: string
}

function formatDate(value: string | null, fallback: string) {
  const date = value ? new Date(value) : new Date(fallback)
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'medium',
  }).format(date)
}

export default function RecruitmentApplicationList({
  applications,
  onStatusChange,
  onDecision,
  actionsFor,
  onSelect,
  emptyTitle = 'No applications found',
  emptyDescription = 'Applications in this workspace will appear here.',
}: Props) {
  const [resumeLoadingId, setResumeLoadingId] = useState('')
  const [statusLoadingId, setStatusLoadingId] = useState('')
  const [actionError, setActionError] = useState('')

  async function openResume(application: ApplicationRecord) {
    const resumePath =
      application.resume_path ?? application.candidates?.resume_path
    if (!resumePath) return

    const resumeWindow = window.open('about:blank', '_blank')
    if (!resumeWindow) {
      setActionError('Allow pop-ups to open the private resume securely.')
      return
    }
    resumeWindow.opener = null
    setActionError('')
    setResumeLoadingId(application.id)
    try {
      const url = await getResumeSignedUrl(resumePath)
      resumeWindow.location.href = url
    } catch {
      resumeWindow.close()
      setActionError(
        'The resume could not be opened. Verify private storage access for your workspace.',
      )
    } finally {
      setResumeLoadingId('')
    }
  }

  async function updateStatus(
    application: ApplicationRecord,
    status: ApplicationStatus,
    decision?: RecruiterDecision,
  ) {
    if (!onStatusChange && !onDecision) return
    if (
      (decision === 'reject' || (!decision && status === 'rejected')) &&
      !window.confirm(
        `Reject ${application.candidates?.full_name ?? 'this candidate'} for ${application.jobs?.title ?? 'this job'}?`,
      )
    ) {
      return
    }
    setActionError('')
    setStatusLoadingId(application.id)
    try {
      if (decision && onDecision) {
        await onDecision(application.id, decision)
      } else if (onStatusChange) {
        await onStatusChange(application.id, status)
      }
    } catch (caughtError) {
      setActionError(
        caughtError instanceof Error
          ? caughtError.message
          : 'The application status could not be updated.',
      )
    } finally {
      setStatusLoadingId('')
    }
  }

  if (applications.length === 0) {
    return (
      <div className="empty-state">
        <span className="empty-state-icon">
          <FileText size={23} />
        </span>
        <h3>{emptyTitle}</h3>
        <p>{emptyDescription}</p>
      </div>
    )
  }

  return (
    <div className="recruitment-record-list">
      {actionError && (
        <div className="form-alert form-alert-error" role="alert">
          {actionError}
        </div>
      )}
      {applications.map((application) => {
        const resumeAvailable = Boolean(
          application.resume_path ?? application.candidates?.resume_path,
        )
        const actions = actionsFor?.(application) ?? []

        return (
          <article className="recruitment-record" key={application.id}>
            <div className="recruitment-record-main">
              <span className="recruitment-record-avatar">
                <UserRound size={19} />
              </span>
              <div className="recruitment-record-person">
                {onSelect ? (
                  <button
                    type="button"
                    className="recruitment-candidate-link"
                    onClick={() => onSelect(application)}
                  >
                    {application.candidates?.full_name ?? 'Candidate'}
                  </button>
                ) : (
                  <strong>{application.candidates?.full_name ?? 'Candidate'}</strong>
                )}
                <span>{application.candidates?.email ?? 'No email provided'}</span>
                {application.candidates?.phone && (
                  <span>{application.candidates.phone}</span>
                )}
              </div>
            </div>

            <div className="recruitment-record-job">
              <strong>{application.jobs?.title ?? 'Job unavailable'}</strong>
              <span>
                {application.jobs?.department || 'General'} · Applied{' '}
                {formatDate(application.applied_at, application.created_at)}
              </span>
            </div>

            <div className="recruitment-record-meta">
              <StatusBadge status={application.status} size="small" />
              <span className="status-badge status-neutral status-small">
                {application.source === 'public'
                  ? 'Public link'
                  : application.source || 'Manual'}
              </span>
            </div>

            <div className="recruitment-record-actions">
              {resumeAvailable ? (
                <button
                  type="button"
                  className="button button-secondary button-small"
                  disabled={resumeLoadingId === application.id}
                  onClick={() => void openResume(application)}
                >
                  <ExternalLink size={15} />
                  {resumeLoadingId === application.id
                    ? 'Opening...'
                    : 'View resume'}
                </button>
              ) : (
                <span className="recruitment-resume-missing">No resume</span>
              )}
              {actions.map((action) => (
                <button
                  type="button"
                  key={`${action.status}-${action.label}`}
                  className={`button button-${action.variant ?? 'secondary'} button-small`}
                  aria-label={`${action.label} ${application.candidates?.full_name ?? 'candidate'} for ${application.jobs?.title ?? 'job'}`}
                  disabled={statusLoadingId === application.id}
                  onClick={() =>
                    void updateStatus(application, action.status, action.decision)
                  }
                >
                  {statusLoadingId === application.id
                    ? 'Saving...'
                    : action.label}
                </button>
              ))}
              {onStatusChange && !actionsFor && (
                <label className="recruitment-status-control">
                  <span className="sr-only">Update application status</span>
                  <select
                    className="form-select"
                    value={application.status}
                    disabled={statusLoadingId === application.id}
                    onChange={(event) =>
                      void updateStatus(application, event.target.value as ApplicationStatus)
                    }
                  >
                    {applicationStatuses.map((status) => (
                      <option key={status} value={status}>
                        {status.charAt(0).toUpperCase() + status.slice(1)}
                      </option>
                    ))}
                  </select>
                </label>
              )}
            </div>
          </article>
        )
      })}
    </div>
  )
}
