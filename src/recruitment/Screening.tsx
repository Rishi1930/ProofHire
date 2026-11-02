import { useCallback, useEffect, useMemo, useState } from 'react'
import { ArrowRight, BrainCircuit, FileUp, RefreshCw } from 'lucide-react'
import { Link } from 'react-router-dom'

import Button from '../components/Button'
import ExportActions from '../components/ExportActions'
import RecruitmentApplicationList from './RecruitmentApplicationList'
import {
  getApplicationScreeningOverview,
  getDecisionEvents,
  attachResumeToApplication,
  requestApplicationScreening,
  uploadResumeForJob,
  type ApplicationDecisionEvent,
  type ApplicationScreeningOverview,
  type ApplicationRecord,
} from './applicationData'
import { isAllowedResumeFile } from '../lib/utils'
import { useWorkspaceApplications } from './useWorkspaceApplications'
import { downloadCsv, downloadPdf, downloadXlsx } from '../lib/export'
import './Screening.css'

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
  const [screeningOverview, setScreeningOverview] = useState<ApplicationScreeningOverview[]>([])
  const [screeningError, setScreeningError] = useState('')
  const [screeningLoading, setScreeningLoading] = useState(false)
  const [screeningActionId, setScreeningActionId] = useState('')
  const [resumeUploadId, setResumeUploadId] = useState('')

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
  const applicationIds = useMemo(
    () => applications.map((application) => application.id),
    [applications],
  )
  const applicationKey = applicationIds.join(',')
  const reloadScreeningOverview = useCallback(async (showLoading = true) => {
    if (!workspaceId || applicationIds.length === 0) {
      setScreeningOverview([])
      setScreeningError('')
      setScreeningLoading(false)
      return
    }
    if (showLoading) setScreeningLoading(true)
    setScreeningError('')
    try {
      setScreeningOverview(
        await getApplicationScreeningOverview(workspaceId, applicationIds),
      )
    } catch (caughtError) {
      setScreeningOverview([])
      setScreeningError(
        caughtError instanceof Error
          ? caughtError.message
          : 'Screening assessments are unavailable.',
      )
    } finally {
      if (showLoading) setScreeningLoading(false)
    }
  }, [applicationKey, workspaceId])

  useEffect(() => {
    void reloadScreeningOverview()
  }, [reloadScreeningOverview])
  const hasProcessingAssessments = screeningOverview.some((overview) =>
    ['pending', 'retry_wait', 'processing'].includes(overview.screening_status),
  )
  useEffect(() => {
    if (!hasProcessingAssessments) return
    const intervalId = window.setInterval(() => {
      void reloadScreeningOverview(false)
    }, 5000)
    return () => window.clearInterval(intervalId)
  }, [hasProcessingAssessments, reloadScreeningOverview])
  const queuedApplications = useMemo(
    () =>
      applications.filter((application) =>
        ['new', 'screening', 'shortlisted'].includes(application.status) &&
        (!selectedJobId || application.job_id === selectedJobId),
      ),
    [applications, selectedJobId],
  )
  const screeningApplicationRows = useMemo(() => {
    const recordsByApplication = new Map(
      screeningOverview.map((record) => [record.application_id, record]),
    )
    return applications
      .filter((application) => !selectedJobId || application.job_id === selectedJobId)
      .map((application) => ({
        application,
        overview: recordsByApplication.get(application.id),
      }))
      .sort((left, right) => {
        const leftScore = left.overview?.match_score
        const rightScore = right.overview?.match_score
        if (leftScore == null && rightScore == null) return 0
        if (leftScore == null) return 1
        if (rightScore == null) return -1
        return rightScore - leftScore
      })
  }, [applications, screeningOverview, selectedJobId])
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
  const assessmentExportRows = screeningApplicationRows.map(({ application, overview }) => ({
    application_id: application.id,
    candidate_name: application.candidates?.full_name ?? 'Candidate',
    job_title: application.jobs?.title ?? 'Job',
    screening_status: overview?.screening_status ?? 'not_queued',
    match_score: overview?.match_score,
    recommendation: overview?.report?.recommendation ?? '',
    confidence: overview?.report?.confidence ?? '',
    evidence_coverage: overview?.report?.evidence_coverage ?? '',
    summary: overview?.report?.summary ?? '',
    findings: overview?.report?.findings ?? [],
    follow_up_questions: overview?.report?.follow_up_questions ?? [],
  }))
  const assessmentExportColumns = [
    { header: 'Application ID', value: (row: (typeof assessmentExportRows)[number]) => row.application_id },
    { header: 'Candidate', value: (row: (typeof assessmentExportRows)[number]) => row.candidate_name },
    { header: 'Job', value: (row: (typeof assessmentExportRows)[number]) => row.job_title },
    { header: 'Queue status', value: (row: (typeof assessmentExportRows)[number]) => row.screening_status },
    { header: 'Match score (%)', value: (row: (typeof assessmentExportRows)[number]) => row.match_score },
    { header: 'Recommendation', value: (row: (typeof assessmentExportRows)[number]) => row.recommendation },
    { header: 'Confidence', value: (row: (typeof assessmentExportRows)[number]) => row.confidence },
    { header: 'Evidence coverage (%)', value: (row: (typeof assessmentExportRows)[number]) => row.evidence_coverage },
    { header: 'Summary', value: (row: (typeof assessmentExportRows)[number]) => row.summary },
    { header: 'Requirement findings (JSON)', value: (row: (typeof assessmentExportRows)[number]) => JSON.stringify(row.findings) },
    { header: 'Follow-up questions (JSON)', value: (row: (typeof assessmentExportRows)[number]) => JSON.stringify(row.follow_up_questions) },
  ]
  const assessmentExportOptions = [
    {
      label: 'Export Results for This Job (CSV)',
      format: 'csv' as const,
      onSelect: () => downloadCsv(
        `proofhire-${screeningJobs.find((job) => job.id === selectedJobId)?.title ?? 'screening'}-assessments`,
        assessmentExportColumns,
        assessmentExportRows,
      ),
    },
    {
      label: 'Export Strong Recommendations (CSV)',
      format: 'csv' as const,
      onSelect: () => downloadCsv(
        `proofhire-${screeningJobs.find((job) => job.id === selectedJobId)?.title ?? 'screening'}-strong-recommendations`,
        assessmentExportColumns,
        assessmentExportRows.filter((row) => row.recommendation === 'strong_match'),
      ),
    },
    {
      label: 'Export Needs Recruiter Review (CSV)',
      format: 'csv' as const,
      onSelect: () => downloadCsv(
        `proofhire-${screeningJobs.find((job) => job.id === selectedJobId)?.title ?? 'screening'}-recruiter-review`,
        assessmentExportColumns,
        assessmentExportRows.filter((row) =>
          ['review', 'needs_more_information'].includes(row.recommendation),
        ),
      ),
    },
    {
      label: 'Export Not Matched (CSV)',
      format: 'csv' as const,
      disabled: true,
      reason: 'The model does not issue a reject/not-matched category; recruiters make all hiring decisions.',
    },
    {
      label: 'Export Assessment Report (PDF)',
      format: 'pdf' as const,
      onSelect: () => downloadPdf({
        title: 'Job-Specific Resume Assessment Report',
        filters: [`Job: ${screeningJobs.find((job) => job.id === selectedJobId)?.title ?? 'Selected job'}`],
        summary: [
          'AI assessments provide evidence for recruiter review and do not make hiring decisions.',
          'Missing resume evidence is not proof that a candidate lacks a skill.',
        ],
        columns: assessmentExportColumns,
        rows: assessmentExportRows,
        filename: `proofhire-screening-${selectedJobId}`,
      }),
    },
    {
      label: 'Export Assessment Workbook (XLSX)',
      format: 'xlsx' as const,
      onSelect: () => downloadXlsx(`proofhire-screening-${selectedJobId}`, [{
        name: 'Assessment Results',
        headers: assessmentExportColumns.map((column) => column.header),
        rows: assessmentExportRows.map((row) => assessmentExportColumns.map((column) => column.value(row))),
      }]),
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

  async function handleScreeningRequest(applicationId: string) {
    setScreeningActionId(applicationId)
    setScreeningError('')
    try {
      await requestApplicationScreening(applicationId)
      setSuccess('Screening job queued. The assessment will appear when processing completes.')
      await reloadScreeningOverview()
    } catch (caughtError) {
      setScreeningError(
        caughtError instanceof Error
          ? caughtError.message
          : 'Unable to queue resume screening.',
      )
    } finally {
      setScreeningActionId('')
    }
  }

  async function handleResumeUpload(application: ApplicationRecord, file: File | null) {
    if (!file) return
    setScreeningError('')
    if (!isAllowedResumeFile(file)) {
      setScreeningError('Choose a non-empty PDF, DOC, or DOCX resume up to 5 MB.')
      return
    }

    setResumeUploadId(application.id)
    try {
      const resumePath = await uploadResumeForJob(
        application.workspace_id,
        application.job_id,
        file,
      )
      await attachResumeToApplication(
        application.workspace_id,
        application.id,
        application.job_id,
        resumePath,
      )
      await requestApplicationScreening(application.id)
      setSuccess('Resume attached to this application. Screening has been queued.')
      await Promise.all([reload(), reloadScreeningOverview()])
    } catch (caughtError) {
      setScreeningError(
        caughtError instanceof Error
          ? caughtError.message
          : 'Unable to attach the resume to this application.',
      )
      await Promise.all([reload(), reloadScreeningOverview()])
    } finally {
      setResumeUploadId('')
    }
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
            void reloadScreeningOverview()
          }}
          loading={loading}
        >
          Refresh
        </Button>
      </div>

      <div className="recruitment-export-toolbar">
        <label className="recruitment-export-job">
          <span>Filter by job</span>
          <select
            className="form-select"
            value={selectedJobId}
            onChange={(event) => setSelectedJobId(event.target.value)}
            aria-label="Filter screening results by job"
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
          <strong>Evidence-based assistance, recruiter decides</strong>
          <p>
            Automated assessments are tied to the selected job and must be
            reviewed alongside the resume. Missing evidence is not proof that a
            candidate lacks a skill; AI recommendations never reject or
            shortlist anyone automatically.
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
      {screeningError && (
        <div className="form-alert form-alert-error" role="alert">
          Screening data or processing is unavailable: {screeningError}
          {' '}Confirm migration 202610290001 is applied locally and the screening worker is configured.
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
            <h2>Job-specific assessments</h2>
            <p>
              {screeningApplicationRows.length} applications
              {selectedJobId ? ' for the selected job' : ' in this workspace'}.
              Rankings are based only on evidence the system could assess.
            </p>
          </div>
          <Button
            variant="secondary"
            icon={<RefreshCw size={16} />}
            onClick={() => void reloadScreeningOverview()}
            loading={screeningLoading}
          >
            Refresh assessments
          </Button>
        </div>
        {screeningLoading ? (
          <div className="empty-state" aria-live="polite">
            <span className="loading-spinner" />
            <p>Loading persisted assessment results...</p>
          </div>
        ) : screeningError ? (
          <div className="empty-state">
            <h3>Assessment data unavailable</h3>
            <p>Apply the screening migration locally, then refresh this page.</p>
          </div>
        ) : screeningApplicationRows.length === 0 ? (
          <div className="empty-state">
            <h3>No applications to assess</h3>
            <p>Applications with resumes will be queued when the screening migration is enabled.</p>
          </div>
        ) : (
          <div className="screening-assessment-list">
            {screeningApplicationRows.map(({ application, overview }) => {
              const status = overview?.screening_status ?? 'not_queued'
              const hasResume = Boolean(application.resume_path)
              const statusLabel = hasResume
                ? status.replace(/_/g, ' ')
                : 'awaiting resume'
              const canQueue = hasResume && (
                status === 'not_queued' || status === 'failed' || status === 'superseded'
              )
              const report = overview?.report
              const requirements = new Map(
                (overview?.criteria?.requirements ?? []).map((requirement) => [
                  requirement.key,
                  requirement,
                ]),
              )
              return (
                <article className="screening-assessment-card" key={application.id}>
                  <div className="screening-assessment-heading">
                    <div>
                      <h3>{application.candidates?.full_name ?? 'Candidate'}</h3>
                      <p>{application.jobs?.title ?? 'Job'} · {statusLabel}</p>
                    </div>
                    <div className="screening-score">
                      <strong>
                        {overview?.match_score == null
                          ? 'Not scored'
                          : `${Math.round(overview.match_score)}%`}
                      </strong>
                      {overview?.assessment_version != null && (
                        <span>Assessment v{overview.assessment_version}</span>
                      )}
                    </div>
                  </div>
                  {report && (
                    <div className="screening-report">
                      <p>{report.summary}</p>
                      <div className="screening-report-meta">
                        <span>Recommendation: {report.recommendation.replace(/_/g, ' ')}</span>
                        <span>Confidence: {report.confidence}</span>
                        <span>Evidence coverage: {Math.round(report.evidence_coverage)}%</span>
                        <span>Assessed: {overview?.assessed_at ? new Date(overview.assessed_at).toLocaleString() : '—'}</span>
                      </div>
                      {report.strengths.length > 0 && (
                        <>
                          <strong>Evidence-backed strengths</strong>
                          <ul>{report.strengths.map((item) => <li key={item}>{item}</li>)}</ul>
                        </>
                      )}
                      {report.potential_gaps.length > 0 && (
                        <>
                          <strong>Potential gaps for recruiter review</strong>
                          <ul>{report.potential_gaps.map((item) => <li key={item}>{item}</li>)}</ul>
                        </>
                      )}
                      <details>
                        <summary>Review requirement findings and evidence</summary>
                        <p>{report.scoring_method}</p>
                        {overview?.criteria && (
                          <>
                            <p>{overview.criteria.summary}</p>
                            <p>
                              Professional experience treated as mandatory:{' '}
                              {overview.criteria.experience_mandatory ? 'Yes' : 'No'}.
                            </p>
                            {overview.criteria.clarifications.length > 0 && (
                              <>
                                <strong>Job criteria to clarify</strong>
                                <ul>{overview.criteria.clarifications.map((item) => <li key={item}>{item}</li>)}</ul>
                              </>
                            )}
                          </>
                        )}
                        {report.findings.length === 0 ? (
                          <p>No score was produced because job requirements need recruiter clarification.</p>
                        ) : (
                          <ul className="screening-finding-list">
                            {report.findings.map((finding) => (
                              <li key={finding.requirement_key}>
                                <strong>
                                  {requirements.get(finding.requirement_key)?.name ?? finding.requirement_key.replace(/_/g, ' ')}
                                  {' '}({requirements.get(finding.requirement_key)?.priority ?? 'requirement'}):{' '}
                                  {finding.status.replace(/_/g, ' ')}
                                </strong>
                                <p>{finding.explanation}</p>
                                {finding.evidence.map((evidence, index) => (
                                  <blockquote key={`${finding.requirement_key}-${index}`}>
                                    “{evidence.excerpt}” <cite>{evidence.source}</cite>
                                  </blockquote>
                                ))}
                              </li>
                            ))}
                          </ul>
                        )}
                        {report.missing_evidence.length > 0 && (
                          <>
                            <strong>Not demonstrated in submitted evidence</strong>
                            <ul>{report.missing_evidence.map((item) => <li key={item}>{item}</li>)}</ul>
                          </>
                        )}
                        {report.follow_up_questions.length > 0 && (
                          <>
                            <strong>Suggested recruiter follow-up</strong>
                            <ul>{report.follow_up_questions.map((item) => <li key={item}>{item}</li>)}</ul>
                          </>
                        )}
                      </details>
                    </div>
                  )}
                  {overview?.failure_reason && (
                    <p className="screening-failure">
                      {overview.failure_reason}
                      {overview.last_error_code && ` (${overview.last_error_code})`}
                    </p>
                  )}
                  {!hasResume && (
                    <div className="screening-resume-upload">
                      <p>
                        No resume is attached to this application, so it cannot
                        be screened. Existing candidate records without a stored
                        resume cannot be recovered automatically.
                      </p>
                      <label className="screening-resume-upload-label">
                        <FileUp size={15} />
                        {resumeUploadId === application.id
                          ? 'Uploading resume...'
                          : 'Attach resume to this application'}
                        <input
                          type="file"
                          accept=".pdf,.doc,.docx,application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                          disabled={resumeUploadId !== ''}
                          onChange={(event) => {
                            const file = event.target.files?.[0] ?? null
                            void handleResumeUpload(application, file)
                            event.target.value = ''
                          }}
                        />
                      </label>
                    </div>
                  )}
                  {!report && status === 'waiting_configuration' && (
                    <p>Assessment is waiting for server-side Gemini configuration.</p>
                  )}
                  {!report && ['pending', 'retry_wait', 'processing'].includes(status) && (
                    <p>Resume assessment is {status.replace(/_/g, ' ')}. This page will refresh its status automatically.</p>
                  )}
                  {canQueue && (
                    <Button
                      variant="secondary"
                      loading={screeningActionId === application.id}
                      disabled={screeningActionId !== ''}
                      onClick={() => void handleScreeningRequest(application.id)}
                    >
                      {status === 'failed' ? 'Retry assessment' : 'Queue assessment'}
                    </Button>
                  )}
                </article>
              )
            })}
          </div>
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
