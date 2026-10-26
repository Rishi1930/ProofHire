import { useEffect, useMemo, useState } from 'react'
import { ArrowLeft, Copy, ExternalLink, FileText, MapPin, X } from 'lucide-react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'

import Button from '../components/Button'
import ExportActions from '../components/ExportActions'
import Modal from '../components/Modal'
import StatusBadge from '../components/StatusBadge'
import RecruitmentApplicationList from '../recruitment/RecruitmentApplicationList'
import type {
  ApplicationDecisionEvent,
  ApplicationRecord,
  ApplicationStatus,
} from '../recruitment/applicationData'
import { getDecisionEvents, getResumeSignedUrl } from '../recruitment/applicationData'
import { getApplicationExportColumns } from '../recruitment/applicationData'
import { downloadCsv, downloadPdf, downloadXlsx } from '../lib/export'
import { supabase } from '../lib/supabase'
import {
  createApplicationReportRow,
  createApplicationReportRows,
  createRecruitmentWorkbookSheets,
  loadWorkspaceRecruitmentExportData,
} from '../recruitment/exportData'

type Job = {
  id: string
  workspace_id: string
  title: string
  department: string | null
  location: string | null
  employment_type: string
  workplace_type: string
  description: string | null
  required_skills: string[]
  preferred_skills: string[]
  minimum_experience: number | null
  status: 'draft' | 'open' | 'paused' | 'closed'
  created_at: string
}

type TabKey =
  | 'all'
  | 'review'
  | 'screening'
  | 'shortlisted'
  | 'interview'
  | 'hired'
  | 'rejected'
  | 'strong'
  | 'confirmation'
  | 'not-matched'

const tabs: { key: TabKey; label: string; configured?: boolean }[] = [
  { key: 'all', label: 'All applications' },
  { key: 'review', label: 'Needs screening' },
  { key: 'screening', label: 'In screening' },
  { key: 'shortlisted', label: 'Shortlisted' },
  { key: 'interview', label: 'Interviews' },
  { key: 'hired', label: 'Hired' },
  { key: 'rejected', label: 'Rejected' },
  { key: 'strong', label: 'Strong matches', configured: false },
  { key: 'confirmation', label: 'Needs confirmation', configured: false },
  { key: 'not-matched', label: 'Not matched', configured: false },
]

type Props = {
  job: Job
  applications: ApplicationRecord[]
  applicationsLoading: boolean
  applicationsError: string
  onStatusChange: (
    applicationId: string,
    status: ApplicationStatus,
  ) => Promise<void>
  onEdit: () => void
}

type CandidateInterview = {
  id: string
  round_number: number
  scheduled_at: string
  interview_status: string
  outcome: string
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(
    new Date(value),
  )
}

export default function JobHiringWorkspace({
  job,
  applications,
  applicationsLoading,
  applicationsError,
  onStatusChange,
  onEdit,
}: Props) {
  const location = useLocation()
  const [searchParams, setSearchParams] = useSearchParams()
  const navigationState = location.state as {
    from?: unknown
    jobsFilters?: { search?: string; sort?: string; statusFilter?: string }
    reportFilters?: {
      range?: string
      jobFilter?: string
      sourceFilter?: string
      stageFilter?: string
    }
  } | null
  const returnTo =
    typeof navigationState?.from === 'string' &&
    navigationState.from.startsWith('/') &&
    !navigationState.from.startsWith('//')
      ? navigationState.from
      : '/jobs'
  const [tab, setTab] = useState<TabKey>('all')
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState('newest')
  const [descriptionExpanded, setDescriptionExpanded] = useState(false)
  const [candidate, setCandidate] = useState<ApplicationRecord | null>(null)
  const [linkMessage, setLinkMessage] = useState('')
  const [decisionEvents, setDecisionEvents] = useState<ApplicationDecisionEvent[]>([])
  const [decisionEventsError, setDecisionEventsError] = useState('')
  const [candidateActionError, setCandidateActionError] = useState('')
  const [openingResume, setOpeningResume] = useState(false)
  const [shareOpen, setShareOpen] = useState(false)
  const [candidateDecisionEvents, setCandidateDecisionEvents] = useState<ApplicationDecisionEvent[]>([])
  const [candidateInterviews, setCandidateInterviews] = useState<CandidateInterview[]>([])
  const [candidateHistoryLoading, setCandidateHistoryLoading] = useState(false)
  const [candidateHistoryError, setCandidateHistoryError] = useState('')

  useEffect(() => {
    let active = true
    if (!applications.length) {
      setDecisionEvents([])
      setDecisionEventsError('')
      return
    }
    void getDecisionEvents(
      job.workspace_id,
      applications.map((application) => application.id),
    )
      .then((events) => {
        if (active) setDecisionEvents(events.slice(0, 10))
      })
      .catch((error: unknown) => {
        if (active) {
          setDecisionEvents([])
          setDecisionEventsError(
            error instanceof Error ? error.message : 'Decision history is unavailable.',
          )
        }
      })
    return () => {
      active = false
    }
  }, [applications, job.workspace_id])

  useEffect(() => {
    const applicationId = searchParams.get('application')
    if (!applicationId) {
      setCandidate(null)
      return
    }
    const selectedApplication = applications.find((item) => item.id === applicationId)
    if (selectedApplication) setCandidate(selectedApplication)
    else if (!applicationsLoading) setCandidate(null)
  }, [applications, applicationsLoading, searchParams])

  useEffect(() => {
    if (!candidate) {
      setCandidateDecisionEvents([])
      setCandidateInterviews([])
      setCandidateHistoryLoading(false)
      setCandidateHistoryError('')
      return
    }
    let active = true
    setCandidateHistoryLoading(true)
    setCandidateHistoryError('')
    Promise.all([
      getDecisionEvents(job.workspace_id, [candidate.id]),
      (async () => {
        if (!supabase) throw new Error('Supabase is not configured.')
        const records: CandidateInterview[] = []
        for (let start = 0; ; start += 1000) {
          const { data, error } = await supabase
            .from('interview_records')
            .select('id, round_number, scheduled_at, interview_status, outcome')
            .eq('workspace_id', job.workspace_id)
            .eq('application_id', candidate.id)
            .order('round_number', { ascending: true })
            .range(start, start + 999)
          if (error) throw error
          records.push(...((data ?? []) as CandidateInterview[]))
          if ((data ?? []).length < 1000) return records
        }
      })(),
    ])
      .then(([candidateDecisions, interviews]) => {
        if (!active) return
        setCandidateDecisionEvents(candidateDecisions)
        setCandidateInterviews(interviews)
      })
      .catch((error: unknown) => {
        if (!active) return
        setCandidateDecisionEvents([])
        setCandidateInterviews([])
        setCandidateHistoryError(
          error instanceof Error ? error.message : 'Recorded history is unavailable.',
        )
      })
      .finally(() => {
        if (active) setCandidateHistoryLoading(false)
      })
    return () => {
      active = false
    }
  }, [candidate, job.workspace_id])

  const filteredApplications = useMemo(() => {
    const query = search.trim().toLowerCase()
    const selected = applications.filter((application) => {
      const matchesSearch =
        (application.candidates?.full_name ?? '').toLowerCase().includes(query) ||
        (application.candidates?.email ?? '').toLowerCase().includes(query)
      const matchesTab =
        tab === 'all' ||
        (tab === 'review' && application.status === 'new') ||
        (tab === 'screening' && application.status === 'screening') ||
        (tab === 'shortlisted' && application.status === 'shortlisted') ||
        (tab === 'interview' && application.status === 'interview') ||
        (tab === 'hired' && application.status === 'hired') ||
        (tab === 'rejected' && application.status === 'rejected')
      return matchesSearch && matchesTab
    })

    return selected.sort((left, right) => {
      if (sort === 'name') {
        return (left.candidates?.full_name ?? '').localeCompare(
          right.candidates?.full_name ?? '',
        )
      }
      const leftDate = new Date(left.applied_at ?? left.created_at).getTime()
      const rightDate = new Date(right.applied_at ?? right.created_at).getTime()
      return sort === 'oldest' ? leftDate - rightDate : rightDate - leftDate
    })
  }, [applications, search, sort, tab])

  const counts: Record<TabKey, number | null> = {
    all: applications.length,
    review: applications.filter((item) => item.status === 'new').length,
    screening: applications.filter((item) => item.status === 'screening').length,
    shortlisted: applications.filter((item) => item.status === 'shortlisted').length,
    interview: applications.filter((item) => item.status === 'interview').length,
    hired: applications.filter((item) => item.status === 'hired').length,
    rejected: applications.filter((item) => item.status === 'rejected').length,
    strong: null,
    confirmation: null,
    'not-matched': null,
  }
  const latestDecisionByApplication = useMemo(() => {
    const map = new Map<string, string>()
    for (const event of [...decisionEvents].reverse()) {
      map.set(event.application_id, event.decision.replace(/_/g, ' '))
    }
    return map
  }, [decisionEvents])

  async function copyApplicationLink() {
    setLinkMessage('')
    try {
      await navigator.clipboard.writeText(
        `${window.location.origin}/apply/${job.id}`,
      )
      setLinkMessage('Public application link copied.')
    } catch {
      setLinkMessage('Could not copy the link. Copy it from the address bar: ' +
        `${window.location.origin}/apply/${job.id}`)
    }
  }

  async function openCandidateResume() {
    const resumePath =
      candidate?.resume_path ?? candidate?.candidates?.resume_path
    if (!resumePath) return
    const resumeWindow = window.open('about:blank', '_blank')
    if (!resumeWindow) {
      setCandidateActionError('Allow pop-ups to open the private resume.')
      return
    }
    resumeWindow.opener = null
    setCandidateActionError('')
    setOpeningResume(true)
    try {
      resumeWindow.location.href = await getResumeSignedUrl(resumePath)
    } catch {
      resumeWindow.close()
      setCandidateActionError('Resume access failed. Verify workspace storage permissions.')
    } finally {
      setOpeningResume(false)
    }
  }

  function exportJobApplications() {
    downloadCsv(
      `proofhire-${job.title}-applications`,
      getApplicationExportColumns(latestDecisionByApplication),
      applications,
    )
  }

  function openCandidateProfile(application: ApplicationRecord) {
    setCandidate(application)
    setSearchParams((current) => {
      const next = new URLSearchParams(current)
      next.set('application', application.id)
      return next
    })
  }

  function closeCandidateProfile() {
    setCandidate(null)
    setShareOpen(false)
    setSearchParams((current) => {
      const next = new URLSearchParams(current)
      next.delete('application')
      return next
    }, { replace: true })
  }

  async function copyInternalProfileLink() {
    if (!candidate) return
    const linkParams = new URLSearchParams(searchParams)
    linkParams.set('application', candidate.id)
    const link = `${window.location.origin}${location.pathname}?${linkParams.toString()}`
    await navigator.clipboard.writeText(link)
    setLinkMessage('Internal profile link copied. Recipients must sign in and have workspace access.')
    setShareOpen(false)
  }

  async function exportCandidateReviewPdf() {
    if (!candidate) throw new Error('Select a candidate profile first.')
    const data = await loadWorkspaceRecruitmentExportData(job.workspace_id, {
      includeDecisions: true,
      includeInterviews: true,
    })
    const review = createApplicationReportRow(
      data.applications.find((application) => application.id === candidate.id) ?? {
        id: candidate.id,
        workspace_id: candidate.workspace_id,
        candidate_id: candidate.candidate_id,
        job_id: candidate.job_id,
        status: candidate.status,
        source: candidate.source,
        applied_at: candidate.applied_at,
        created_at: candidate.created_at,
        resume_available: Boolean(
          candidate.resume_path || candidate.candidates?.resume_path,
        ),
      },
      data,
    )
    const interviewSummary = review.interviews.length
      ? review.interviews
          .map((interview) =>
            `Round ${interview.round_number}: ${interview.interview_status}; outcome ${interview.outcome}; scheduled ${new Date(interview.scheduled_at).toLocaleString()}`,
          )
          .join(' | ')
      : 'No interview record is available.'
    await downloadPdf({
      title: 'Candidate Review Summary',
      filters: [
        `Job: ${job.title} (${job.id})`,
        `Application: ${candidate.id}`,
      ],
      summary: [
        `Candidate: ${candidate.candidates?.full_name ?? 'Candidate'} (${candidate.candidate_id})`,
        `Email: ${candidate.candidates?.email ?? 'Not provided'}`,
        `Phone: ${candidate.candidates?.phone ?? 'Not provided'}`,
        `Application date: ${formatDate(candidate.applied_at ?? candidate.created_at)}`,
        `Source: ${candidate.source ?? 'Not recorded'}`,
        `Current application status: ${candidate.status}`,
        `Resume attached: ${Boolean(candidate.resume_path || candidate.candidates?.resume_path) ? 'Yes' : 'No'}`,
        `Latest recruiter decision: ${review.latestDecision?.decision ?? 'None recorded'}`,
        `Interview records: ${interviewSummary}`,
        `Required skills: ${job.required_skills.join(', ') || 'Not specified'}`,
        `Preferred skills: ${job.preferred_skills.join(', ') || 'Not specified'}`,
        `Minimum experience: ${job.minimum_experience === null ? 'Not specified' : `${job.minimum_experience} years`}`,
        'Screening assessment: Not available. Resume evidence, match scores, and AI assessment results are not persisted.',
        ...data.warnings,
      ],
      columns: [
        { header: 'Application ID', value: () => candidate.id },
        { header: 'Candidate ID', value: () => candidate.candidate_id },
        { header: 'Job ID', value: () => job.id },
        { header: 'Job title', value: () => job.title },
        { header: 'Application status', value: () => candidate.status },
        { header: 'Latest decision', value: () => review.latestDecision?.decision ?? 'None recorded' },
        { header: 'Interview rounds', value: () => review.interviews.length },
      ],
      rows: [candidate],
      filename: `proofhire-candidate-review-${candidate.id}`,
    })
  }

  async function exportJobReportPdf() {
    const data = await loadWorkspaceRecruitmentExportData(job.workspace_id, {
      includeDecisions: true,
      includeInterviews: true,
    })
    const jobApplications = data.applications.filter((application) => application.job_id === job.id)
    const statuses = ['new', 'screening', 'shortlisted', 'interview', 'rejected', 'hired']
    const summaries = [
      `Job ID: ${job.id}`,
      `Department: ${job.department ?? 'Not specified'}`,
      `Location: ${job.location ?? 'Not specified'}`,
      `Work mode: ${job.workplace_type}`,
      `Employment type: ${job.employment_type}`,
      `Status: ${job.status}`,
      `Created: ${formatDate(job.created_at)}`,
      'Published at: Not stored in the current jobs schema.',
      `Description: ${job.description || 'Not provided'}`,
      `Required skills: ${job.required_skills.join(', ') || 'Not specified'}`,
      `Preferred skills: ${job.preferred_skills.join(', ') || 'Not specified'}`,
      `Minimum experience: ${job.minimum_experience === null ? 'Not specified' : `${job.minimum_experience} years`}`,
      `Applications: ${jobApplications.length}`,
      ...statuses.map(
        (status) =>
          `${status[0].toUpperCase()}${status.slice(1)} applications: ${jobApplications.filter((application) => application.status === status).length}`,
      ),
      'Stage counts are a snapshot of each application’s current status, not historical transition counts.',
      'Screening assessment scores and evidence are not configured and are not inferred.',
      ...data.warnings,
    ]
    const reportRows = createApplicationReportRows(jobApplications, data).map((record) => {
      const { application } = record
      return {
        id: application.id,
        candidateId: application.candidate_id,
        name: record.candidate?.full_name,
        email: record.candidate?.email,
        phone: record.candidate?.phone,
        appliedAt: application.applied_at ?? application.created_at,
        source: application.source,
        status: application.status,
        recordedOutcome:
          application.status === 'hired' || application.status === 'rejected'
            ? application.status
            : '',
        resumeAvailable:
          application.resume_available ||
          Boolean(record.candidate?.resume_available),
        decision: record.latestDecision?.decision,
        interviewStatus: record.interviews.map((item) => item.interview_status).join('; '),
        interviewOutcome: record.interviews.map((item) => item.outcome).join('; '),
      }
    })
    await downloadPdf({
      title: `${job.title} - Job Recruitment Report`,
      filters: [`Job scope: ${job.title} (${job.id})`, `Applications: ${jobApplications.length}`],
      summary: summaries,
      columns: [
        { header: 'Application ID', value: (row) => row.id },
        { header: 'Candidate ID', value: (row) => row.candidateId },
        { header: 'Candidate name', value: (row) => row.name },
        { header: 'Email', value: (row) => row.email },
        { header: 'Phone', value: (row) => row.phone },
        { header: 'Resume attached', value: (row) => row.resumeAvailable },
        { header: 'Application date', value: (row) => row.appliedAt },
        { header: 'Source', value: (row) => row.source },
        { header: 'Application status', value: (row) => row.status },
        { header: 'Recorded outcome (status)', value: (row) => row.recordedOutcome },
        { header: 'Recruiter decision', value: (row) => row.decision },
        { header: 'Interview status', value: (row) => row.interviewStatus },
        { header: 'Interview outcome', value: (row) => row.interviewOutcome },
      ],
      rows: reportRows,
      filename: `proofhire-${job.title}-recruitment-report`,
    })
  }

  async function exportJobWorkbook() {
    const data = await loadWorkspaceRecruitmentExportData(job.workspace_id, {
      includeDecisions: true,
      includeInterviews: true,
    })
    await downloadXlsx(
      `proofhire-${job.title}-recruitment-workbook`,
      createRecruitmentWorkbookSheets(data, { jobId: job.id }),
    )
  }

  async function exportUniqueJobCandidates() {
    const data = await loadWorkspaceRecruitmentExportData(job.workspace_id)
    const jobApplications = data.applications.filter((application) => application.job_id === job.id)
    const candidateIds = new Set(jobApplications.map((application) => application.candidate_id))
    downloadCsv(
      `proofhire-${job.title}-unique-candidates`,
      [
        { header: 'Candidate ID', value: (candidate) => candidate.id },
        { header: 'Full name', value: (candidate) => candidate.full_name },
        { header: 'Email', value: (candidate) => candidate.email },
        { header: 'Phone', value: (candidate) => candidate.phone },
        { header: 'LinkedIn URL', value: (candidate) => candidate.linkedin_url },
      ],
      data.candidates.filter((candidateRecord) => candidateIds.has(candidateRecord.id)),
    )
  }

  const jobExportOptions = [
    { label: 'Complete Job Recruitment Report (PDF)', format: 'pdf' as const, onSelect: exportJobReportPdf, disabled: applicationsLoading || Boolean(applicationsError), reason: applicationsError || 'Job data is still loading.' },
    { label: 'Job and Applications Workbook (XLSX)', format: 'xlsx' as const, onSelect: exportJobWorkbook, disabled: applicationsLoading || Boolean(applicationsError), reason: applicationsError || 'Job data is still loading.' },
    { label: 'Applications List (CSV)', format: 'csv' as const, onSelect: exportJobApplications, disabled: applicationsLoading || Boolean(applicationsError), reason: applicationsError || 'Applications are still loading.' },
    { label: 'Unique Candidates for This Job (CSV)', format: 'csv' as const, onSelect: exportUniqueJobCandidates, disabled: applicationsLoading || Boolean(applicationsError), reason: applicationsError || 'Applications are still loading.' },
    { label: 'Screening Assessment Report (XLSX)', format: 'xlsx' as const, disabled: true, reason: 'No persisted screening assessments exist in the current schema.' },
  ]

  return (
    <section className="job-hiring-page">
      <header className="page-heading-row job-hiring-heading">
        <div className="page-heading">
          <Link
            to={returnTo}
            state={navigationState ?? undefined}
            className="text-link"
          >
            <ArrowLeft size={15} /> {returnTo.startsWith('/reports') ? 'Back to Reports & Insights' : 'Jobs &amp; Hiring'}
          </Link>
          <nav className="page-breadcrumbs" aria-label="Breadcrumb">
            {!returnTo.startsWith('/reports') && (
              <>
                <Link to="/dashboard">Overview</Link>
                <span>/</span>
              </>
            )}
            <Link to={returnTo} state={navigationState ?? undefined}>
              {returnTo.startsWith('/reports') ? 'Reports & Insights' : 'Jobs &amp; Hiring'}
            </Link>
            <span>/</span>
            <strong>{job.title}</strong>
          </nav>
          <span className="page-eyebrow">JOB RECRUITMENT WORKSPACE</span>
          <h1>{job.title}</h1>
          <p>Applications, candidate review, and hiring progress for this role.</p>
        </div>
        <div className="job-hiring-heading-actions">
          <Button variant="secondary" onClick={onEdit}>
            Edit job
          </Button>
          {job.status === 'open' && (
            <Button
              variant="secondary"
              icon={<Copy size={16} />}
              onClick={() => void copyApplicationLink()}
            >
              Copy application link
            </Button>
          )}
        </div>
      </header>
      {linkMessage && (
        <div className="form-alert form-alert-success" role="status">
          {linkMessage}
        </div>
      )}

      <div className="job-hiring-layout">
        <aside className="job-context-panel">
          <div className="job-context-heading">
            <div>
              <span className="page-eyebrow">JOB CONTEXT</span>
              <h2>{job.title}</h2>
            </div>
            <StatusBadge status={job.status} size="small" />
          </div>
          <div className="job-context-meta">
            {job.location && (
              <span><MapPin size={14} />{job.location}</span>
            )}
            <span>{job.workplace_type}</span>
            <span>{job.employment_type}</span>
            {job.department && <span>{job.department}</span>}
          </div>
          <div className="job-context-facts">
            <div><span>Applications</span><strong>{applications.length}</strong></div>
            <div><span>Created</span><strong>{formatDate(job.created_at)}</strong></div>
            {job.minimum_experience !== null && (
              <div>
                <span>Minimum experience</span>
                <strong>{job.minimum_experience} years</strong>
              </div>
            )}
          </div>
          {(job.required_skills.length > 0 || job.preferred_skills.length > 0) && (
            <div className="job-context-skills">
              {job.required_skills.length > 0 && (
                <div>
                  <h3>Required skills</h3>
                  <div className="job-context-tags">
                    {job.required_skills.map((skill) => (
                      <span className="job-skill-tag" key={`required-${skill}`}>{skill}</span>
                    ))}
                  </div>
                </div>
              )}
              {job.preferred_skills.length > 0 && (
                <div>
                  <h3>Preferred skills</h3>
                  <div className="job-context-tags">
                    {job.preferred_skills.map((skill) => (
                      <span className="job-skill-tag job-skill-tag-preferred" key={`preferred-${skill}`}>{skill}</span>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}
          <div className="job-context-description">
            <h3>Job description</h3>
            <p className={descriptionExpanded ? '' : 'job-description-collapsed'}>
              {job.description || 'No job description was provided.'}
            </p>
            {(job.description?.length ?? 0) > 260 && (
              <button
                type="button"
                className="text-link"
                onClick={() => setDescriptionExpanded((current) => !current)}
              >
                {descriptionExpanded ? 'Show less' : 'Read full description'}
              </button>
            )}
          </div>
          {job.status === 'open' && (
            <Link to={`/apply/${job.id}`} className="button button-secondary job-context-public-link">
              <ExternalLink size={15} /> Open public application
            </Link>
          )}
        </aside>

        <div className="job-hiring-main">
          <section className="job-hiring-kpis" aria-label="Job application metrics">
            {[
              ['Applications', applications.length],
              ['Needs screening', counts.review],
              ['In screening', counts.screening],
              ['Shortlisted', counts.shortlisted],
              ['Interview stage', counts.interview],
              ['Hired', counts.hired],
            ].map(([label, value]) => (
              <article className="metric-card" key={label}>
                <span>{label}</span>
                <strong>{value}</strong>
              </article>
            ))}
          </section>

          <div className="info-banner">
            <FileText size={18} />
            <div>
              <strong>Screening scores and confirmation queues are not configured</strong>
              <p>
                This workspace uses the application's current stage only.
                Resume parsing, match evidence, and separate screening recommendations
                require a screening backend and are not inferred from application status.
              </p>
            </div>
          </div>

          <div className="recruitment-export-toolbar">
            <p>Job-specific report and exports · {job.title} · private resume paths are excluded.</p>
            <ExportActions
              scope={`${job.title} · ${applications.length} applications`}
              disabled={applicationsLoading || Boolean(applicationsError)}
              options={jobExportOptions}
            />
          </div>
          <section className="panel job-applications-panel">
            {applicationsError && (
              <div className="form-alert form-alert-error" role="alert">
                Applications could not be loaded: {applicationsError}
              </div>
            )}
            <div className="job-application-toolbar">
              <div className="search-field">
                <input
                  value={search}
                  onChange={(event) => setSearch(event.target.value)}
                  placeholder="Search candidates"
                  aria-label="Search candidates for this job"
                />
              </div>
              <label className="job-sort-control">
                <span className="sr-only">Sort applications</span>
                <select
                  className="form-select"
                  value={sort}
                  onChange={(event) => setSort(event.target.value)}
                >
                  <option value="newest">Newest applications</option>
                  <option value="oldest">Oldest applications</option>
                  <option value="name">Candidate name</option>
                </select>
              </label>
            </div>
            <div className="job-application-tabs" role="tablist" aria-label="Filter job applications">
              {tabs.map((item) => (
                <button
                  type="button"
                  role="tab"
                  aria-selected={tab === item.key}
                  aria-label={`${item.label}${item.configured === false ? ', screening data unavailable' : `, ${counts[item.key] ?? 0} applications`}`}
                  className={`job-application-tab${tab === item.key ? ' active' : ''}${item.configured === false ? ' unavailable' : ''}`}
                  key={item.key}
                  onClick={() => setTab(item.key)}
                  title={item.configured === false ? 'No screening-result data is stored yet.' : undefined}
                >
                  {item.label}
                  <span>{item.configured === false ? '—' : counts[item.key]}</span>
                </button>
              ))}
            </div>
            {applicationsLoading ? (
              <div className="empty-state">
                <span className="loading-spinner" />
                <p>Loading job applications...</p>
              </div>
            ) : applicationsError ? (
              <div className="empty-state">
                <h3>Applications unavailable</h3>
                <p>Resolve the workspace query error above and refresh the page.</p>
              </div>
            ) : tab === 'strong' || tab === 'confirmation' || tab === 'not-matched' ? (
              <div className="empty-state">
                <h3>Screening data unavailable</h3>
                <p>
                  No screening results are stored for this job. Candidate matching
                  categories are deliberately not inferred from hiring status.
                </p>
              </div>
            ) : (
              <RecruitmentApplicationList
                applications={filteredApplications}
                onStatusChange={onStatusChange}
                onSelect={openCandidateProfile}
                emptyTitle={applications.length ? 'No matching applications' : 'No applications for this job yet'}
                emptyDescription={applications.length ? 'Try another tab or search term.' : 'Applications submitted for this role will appear here.'}
              />
            )}
          </section>
          <section className="panel">
            <header className="recruitment-list-header">
              <div>
                <h2>Recent recruiter decisions</h2>
                <p>Decision events are stored separately from the current application stage.</p>
              </div>
            </header>
            {decisionEventsError ? (
              <div className="empty-state">
                <p>
                  Decision history could not be loaded: {decisionEventsError}
                  {' '}Apply migration 202610260006 if it has not been run.
                </p>
              </div>
            ) : decisionEvents.length === 0 ? (
              <div className="empty-state">
                <p>No recruiter decisions have been recorded for this job.</p>
              </div>
            ) : (
              <div className="decision-event-list">
                {decisionEvents.map((event) => {
                  const record = applications.find(
                    (application) => application.id === event.application_id,
                  )
                  return (
                    <article className="decision-event-row" key={event.id}>
                      <div>
                        <strong>{record?.candidates?.full_name ?? 'Candidate'}</strong>
                        <span>{event.decision.replaceAll('_', ' ')}</span>
                      </div>
                      <time dateTime={event.created_at}>
                        {new Date(event.created_at).toLocaleString()}
                      </time>
                    </article>
                  )
                })}
              </div>
            )}
          </section>
        </div>
      </div>

      {candidate && (
        <div
          className="modal-backdrop candidate-report-backdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) closeCandidateProfile()
          }}
        >
          <section
            className="candidate-report-panel"
            role="dialog"
            aria-modal="true"
            aria-labelledby="candidate-report-title"
          >
            <header className="candidate-report-header">
              <div>
                <span className="page-eyebrow">APPLICATION REVIEW</span>
                  <button
                    type="button"
                    className="text-link candidate-back-link"
                    onClick={closeCandidateProfile}
                  >
                    <ArrowLeft size={14} /> Back to job applications
                  </button>
                  <h2 id="candidate-report-title">
                  {candidate.candidates?.full_name ?? 'Candidate'}
                </h2>
                <p>{job.title}</p>
                <nav className="page-breadcrumbs" aria-label="Breadcrumb">
                  <Link to={returnTo} state={navigationState ?? undefined}>
                    {returnTo.startsWith('/reports') ? 'Reports & Insights' : 'Jobs &amp; Hiring'}
                  </Link>
                  <span>/</span>
                  <button
                    type="button"
                    className="breadcrumb-button"
                    onClick={closeCandidateProfile}
                  >
                    {job.title}
                  </button>
                  <span>/</span>
                  <strong>{candidate.candidates?.full_name ?? 'Candidate'}</strong>
                </nav>
              </div>
              <button
                type="button"
                className="icon-button"
                aria-label="Back to job applications"
                onClick={closeCandidateProfile}
              >
                <X size={19} />
              </button>
            </header>
            <div className="candidate-report-content">
              <section className="candidate-report-section">
                <h3>Candidate profile</h3>
                <dl>
                  <div><dt>Email</dt><dd>{candidate.candidates?.email ?? 'Not provided'}</dd></div>
                  <div><dt>Phone</dt><dd>{candidate.candidates?.phone ?? 'Not provided'}</dd></div>
                  <div><dt>Application date</dt><dd>{formatDate(candidate.applied_at ?? candidate.created_at)}</dd></div>
                  <div><dt>Application source</dt><dd>{candidate.source ?? 'Not recorded'}</dd></div>
                  <div><dt>Current stage</dt><dd><StatusBadge status={candidate.status} size="small" /></dd></div>
                </dl>
                {candidate.candidates?.linkedin_url && (
                  <p>LinkedIn: {candidate.candidates.linkedin_url}</p>
                )}
                {candidate.candidates?.resume_path || candidate.resume_path ? (
                  <Button
                    variant="secondary"
                    loading={openingResume}
                    onClick={() => void openCandidateResume()}
                  >
                    Open private resume
                  </Button>
                ) : (
                  <p>No resume is attached to this application.</p>
                )}
                {candidateActionError && (
                  <p className="form-alert form-alert-error" role="alert">
                    {candidateActionError}
                  </p>
                )}
              </section>
              <section className="candidate-report-section">
                <h3>Job requirements</h3>
                {job.required_skills.length ? (
                  <p><strong>Required:</strong> {job.required_skills.join(', ')}</p>
                ) : <p>No required skills have been specified.</p>}
                {job.preferred_skills.length ? (
                  <p><strong>Preferred:</strong> {job.preferred_skills.join(', ')}</p>
                ) : <p>No preferred skills have been specified.</p>}
                <p><strong>Minimum experience:</strong> {job.minimum_experience === null ? 'Not specified' : `${job.minimum_experience} years`}</p>
              </section>
              <section className="candidate-report-section">
                <h3>Screening evidence</h3>
                <p>
                  Resume text extraction and screening evidence are not available.
                  No match percentage or skill assessment is generated.
                </p>
              </section>
              <section className="candidate-report-section">
                <h3>Recorded recruiter and interview history</h3>
                {candidateHistoryLoading ? (
                  <p>Loading recorded history…</p>
                ) : candidateHistoryError ? (
                  <p className="form-alert form-alert-error" role="alert">
                    Recorded history is unavailable: {candidateHistoryError}
                    {' '}Verify that migration 202610260006 has been applied.
                  </p>
                ) : (
                  <>
                    {candidateDecisionEvents.map((event) => (
                      <p key={event.id}>
                        Recruiter decision: <strong>{event.decision.replaceAll('_', ' ')}</strong>
                        {' · '}{new Date(event.created_at).toLocaleString()}
                      </p>
                    ))}
                    {candidateInterviews.map((interview) => (
                      <p key={interview.id}>
                        Interview round {interview.round_number}: {interview.interview_status}
                        {' · outcome: '}{interview.outcome}
                        {' · '}{new Date(interview.scheduled_at).toLocaleString()}
                      </p>
                    ))}
                    {!candidateDecisionEvents.length && !candidateInterviews.length && (
                      <p>No recruiter decision or interview outcome has been recorded.</p>
                    )}
                  </>
                )}
              </section>
              <section className="candidate-report-section">
                <h3>Recruiter action</h3>
                <Button
                  variant="secondary"
                  icon={<ExternalLink size={15} />}
                  onClick={() => setShareOpen(true)}
                >
                  Share profile
                </Button>
                <label className="field-label" htmlFor="candidate-stage-update">Application stage</label>
                <select
                  id="candidate-stage-update"
                  className="form-select"
                  value={candidate.status}
                  onChange={(event) => {
                    const status = event.target.value as ApplicationStatus
                    void onStatusChange(candidate.id, status).then(() => {
                      setCandidate({ ...candidate, status })
                    })
                  }}
                >
                  {['new', 'screening', 'shortlisted', 'interview', 'hired', 'rejected'].map((status) => (
                    <option key={status} value={status}>{status}</option>
                  ))}
                </select>
              </section>
            </div>
          </section>
        </div>
      )}
      {shareOpen && candidate && (
        <Modal
          open
          title="Share candidate profile"
          description="Internal links require sign-in and existing access to this workspace. External sharing is not enabled."
          size="small"
          onClose={() => setShareOpen(false)}
        >
          <div className="share-profile-preview">
            <strong>Profile preview</strong>
            <p>{candidate.candidates?.full_name ?? 'Candidate'} · {job.title}</p>
            <p>
              Includes application stage, application date, contact details visible
              to authorized workspace members, job requirements, and recorded
              recruiter/interview outcomes. No resume URL or resume content is included.
            </p>
            <p className="form-help">
              Screening scores and evidence are unavailable because no persisted
              assessment records exist.
            </p>
          </div>
          <div className="modal-actions share-profile-actions">
            <Button
              variant="secondary"
              icon={<Copy size={15} />}
              onClick={() => void copyInternalProfileLink().catch((error: unknown) => {
                setCandidateActionError(
                  error instanceof Error ? error.message : 'Could not copy the profile link.',
                )
              })}
            >
              Copy internal link
            </Button>
            <Button
              variant="secondary"
              icon={<FileText size={15} />}
              onClick={() => void exportCandidateReviewPdf().then(() => setShareOpen(false)).catch((error: unknown) => {
                setCandidateActionError(
                  error instanceof Error ? error.message : 'Could not export the candidate review.',
                )
              })}
            >
              Export review PDF
            </Button>
          </div>
          <div className="external-share-unavailable">
            <strong>External assessment link unavailable</strong>
            <p>
              Secure external sharing requires a revocable, expiring share-link
              record and server-side token validation. No public link has been created.
            </p>
          </div>
        </Modal>
      )}
    </section>
  )
}
