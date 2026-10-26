import { useEffect, useMemo, useState, type FormEvent } from 'react'
import {
  BriefcaseBusiness,
  ExternalLink,
  Linkedin,
  Pencil,
  Plus,
  Search,
  Trash2,
  Users,
} from 'lucide-react'

import { useAuth } from '../auth/AuthContext'
import Modal from '../components/Modal'
import ExportActions from '../components/ExportActions'
import { supabase } from '../lib/supabase'
import { downloadCsv, downloadXlsx } from '../lib/export'
import {
  getApplicationExportColumns,
} from '../recruitment/applicationData'
import {
  createRecruitmentWorkbookSheets,
  loadWorkspaceRecruitmentExportData,
} from '../recruitment/exportData'
import {
  applicationStatuses,
  createCandidateApplication,
  deleteCandidate,
  getCandidates,
  saveCandidate,
  updateApplicationStatus,
  type ApplicationStatus,
  type CandidateFormValues,
  type CandidateWithApplications,
} from './CandidateDatabase'

type JobOption = {
  id: string
  title: string
}

type CandidateFormMode = 'create' | 'edit' | 'application'

const emptyCandidate: CandidateFormValues = {
  full_name: '',
  email: '',
  phone: '',
  linkedin_url: '',
}

const statusLabels: Record<ApplicationStatus, string> = {
  new: 'New',
  screening: 'Screening',
  shortlisted: 'Shortlisted',
  rejected: 'Rejected',
  interview: 'Interview',
  hired: 'Hired',
}

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : 'Something went wrong.'
}

function getCandidateSaveError(
  error: unknown,
  candidateValues: CandidateFormValues,
) {
  const errorRecord =
    typeof error === 'object' && error !== null
      ? (error as { code?: unknown; message?: unknown })
      : null
  const code = typeof errorRecord?.code === 'string' ? errorRecord.code : null
  const message =
    error instanceof Error
      ? error.message
      : typeof errorRecord?.message === 'string'
        ? errorRecord.message
        : 'Unknown candidate save error.'
  const sensitiveValues = [
    candidateValues.full_name,
    candidateValues.email,
    candidateValues.phone,
    candidateValues.linkedin_url,
  ].filter(Boolean)
  const safeMessage = sensitiveValues
    .sort((left, right) => right.length - left.length)
    .reduce(
      (safe, value) => safe.split(value).join('[redacted]'),
      message,
    )
    .replace(/Bearer\s+\S+/gi, 'Bearer [redacted]')

  let userMessage = 'Could not save the candidate. Please try again.'
  if (code === '23505') {
    userMessage = 'A candidate with this email already exists in this workspace.'
  } else if (code === '42501' || code === 'PGRST301') {
    userMessage =
      'You do not have permission to add candidates in this workspace.'
  } else if (!code && error instanceof Error) {
    userMessage = error.message
  }

  return {
    userMessage,
    diagnostic:
      import.meta.env.DEV
        ? `${code ? `Supabase error ${code}: ` : 'Candidate save error: '}${safeMessage}`
        : '',
  }
}

export default function Candidates() {
  const { user } = useAuth()
  const [candidates, setCandidates] = useState<CandidateWithApplications[]>([])
  const [jobs, setJobs] = useState<JobOption[]>([])
  const [workspaceId, setWorkspaceId] = useState('')
  const [canDeleteCandidates, setCanDeleteCandidates] = useState(false)
  const [search, setSearch] = useState('')
  const [jobFilter, setJobFilter] = useState('all')
  const [statusFilter, setStatusFilter] = useState('all')
  const [loading, setLoading] = useState(true)
  const [formMode, setFormMode] = useState<CandidateFormMode | null>(null)
  const [editingCandidate, setEditingCandidate] =
    useState<CandidateWithApplications | null>(null)
  const [form, setForm] = useState<CandidateFormValues>(emptyCandidate)
  const [applicationCandidate, setApplicationCandidate] =
    useState<CandidateWithApplications | null>(null)
  const [selectedJobId, setSelectedJobId] = useState('')
  const [saving, setSaving] = useState(false)
  const [errorMessage, setErrorMessage] = useState('')
  const [errorDetails, setErrorDetails] = useState('')
  const [successMessage, setSuccessMessage] = useState('')

  async function loadData() {
    if (!supabase || !user) {
      setErrorMessage('Sign in and configure Supabase to view candidates.')
      setLoading(false)
      return
    }

    setLoading(true)
    setErrorMessage('')

    try {
      const { data: memberships, error: membershipError } = await supabase
        .from('workspace_members')
        .select('workspace_id, role')
        .eq('user_id', user.id)
        .limit(2)

      if (membershipError) throw membershipError

      if (!memberships?.length) {
        setWorkspaceId('')
        setCandidates([])
        setJobs([])
        throw new Error('No workspace is linked to this account yet.')
      }

      if (memberships.length > 1) {
        setWorkspaceId('')
        setCandidates([])
        setJobs([])
        throw new Error(
          'This account belongs to multiple workspaces. Select an active workspace before continuing.',
        )
      }

      const membership = memberships[0]
      const currentWorkspaceId = membership.workspace_id
      setWorkspaceId(currentWorkspaceId)
      setCanDeleteCandidates(
        membership.role === 'owner' || membership.role === 'admin',
      )

      const [candidateRows, jobResult] = await Promise.all([
        getCandidates(currentWorkspaceId),
        supabase
          .from('jobs')
          .select('id, title')
          .eq('workspace_id', currentWorkspaceId)
          .order('created_at', { ascending: false }),
      ])

      if (jobResult.error) throw jobResult.error

      setCandidates(candidateRows)
      setJobs((jobResult.data ?? []) as JobOption[])
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
      setCandidates([])
      setJobs([])
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    void loadData()
  }, [user?.id])

  const filteredCandidates = useMemo(() => {
    const query = search.trim().toLowerCase()

    return candidates.filter((candidate) => {
      const matchesSearch =
        candidate.full_name.toLowerCase().includes(query) ||
        (candidate.email ?? '').toLowerCase().includes(query)
      const matchesApplicationFilters = candidate.applications.some(
        (application) =>
          (jobFilter === 'all' || application.job_id === jobFilter) &&
          (statusFilter === 'all' || application.status === statusFilter),
      )
      const matchesFilters =
        (jobFilter === 'all' && statusFilter === 'all') ||
        matchesApplicationFilters

      return matchesSearch && matchesFilters
    })
  }, [candidates, search, jobFilter, statusFilter])
  const activeCandidateFilters = [
    search.trim() ? `search "${search.trim()}"` : '',
    jobFilter !== 'all'
      ? `job ${jobs.find((job) => job.id === jobFilter)?.title ?? jobFilter}`
      : '',
    statusFilter !== 'all' ? `status ${statusFilter}` : '',
  ].filter(Boolean)
  const filteredCandidatesScope =
    `filtered candidates · ${filteredCandidates.length} of ${candidates.length}` +
    (activeCandidateFilters.length
      ? ` · ${activeCandidateFilters.join(', ')}`
      : '')

  function exportCandidates(
    rows: CandidateWithApplications[],
    filtered: boolean,
  ) {
    const exportRows = rows.map((candidate) => {
      const applications = filtered
        ? candidate.applications.filter(
            (application) =>
              (jobFilter === 'all' || application.job_id === jobFilter) &&
              (statusFilter === 'all' || application.status === statusFilter),
          )
        : candidate.applications
      return {
        ...candidate,
        application_count: applications.length,
        associated_jobs: applications
          .map((application) => application.jobs?.title)
          .filter(Boolean)
          .join(' | '),
        application_statuses: applications
          .map((application) => `${application.jobs?.title ?? 'Job'}: ${application.status}`)
          .join(' | '),
      }
    })
    downloadCsv(
      `proofhire-candidates-${filtered ? 'filtered' : 'all'}`,
      [
        { header: 'Candidate ID', value: (candidate) => candidate.id },
        { header: 'Full name', value: (candidate) => candidate.full_name },
        { header: 'Email', value: (candidate) => candidate.email },
        { header: 'Phone', value: (candidate) => candidate.phone },
        { header: 'LinkedIn URL', value: (candidate) => candidate.linkedin_url },
        { header: 'Created at', value: (candidate) => candidate.created_at },
        { header: 'Application count', value: (candidate) => candidate.application_count },
        { header: 'Associated jobs', value: (candidate) => candidate.associated_jobs },
        { header: 'Application statuses', value: (candidate) => candidate.application_statuses },
      ],
      exportRows,
    )
  }

  async function exportCandidateApplications(filtered: boolean) {
    if (!workspaceId) throw new Error('No active workspace is available.')
    const data = await loadWorkspaceRecruitmentExportData(workspaceId)
    const selectedCandidates = filtered ? filteredCandidates : candidates
    const candidateIds = new Set(selectedCandidates.map((candidate) => candidate.id))
    const rows = data.applications.filter((application) => {
      if (!candidateIds.has(application.candidate_id)) return false
      if (!filtered) return true
      return (
        (jobFilter === 'all' || application.job_id === jobFilter) &&
        (statusFilter === 'all' || application.status === statusFilter)
      )
    })
    downloadCsv(
      `proofhire-candidate-applications-${filtered ? 'filtered' : 'all'}`,
      getApplicationExportColumns(),
      rows.map((application) => {
        const candidate = data.candidates.find((item) => item.id === application.candidate_id)
        const job = data.jobs.find((item) => item.id === application.job_id)
        return {
          ...application,
          resume_path: null,
          resume_available:
            application.resume_available || Boolean(candidate?.resume_available),
          status: application.status as ApplicationStatus,
          candidates: candidate
            ? {
                full_name: candidate.full_name,
                email: candidate.email,
                phone: candidate.phone,
                linkedin_url: candidate.linkedin_url,
                resume_path: null,
              }
            : null,
          jobs: job ? { title: job.title, department: job.department } : null,
        }
      }),
    )
  }

  async function exportCandidateApplicationWorkbook() {
    if (!workspaceId) throw new Error('No active workspace is available.')
    const data = await loadWorkspaceRecruitmentExportData(workspaceId, {
      includeDecisions: true,
      includeInterviews: true,
    })
    await downloadXlsx(
      'proofhire-candidate-and-application-workbook',
      createRecruitmentWorkbookSheets(data),
    )
  }

  const candidateExportOptions = [
    {
      label: 'Export Unique Candidates (CSV)',
      format: 'csv' as const,
      onSelect: () => exportCandidates(candidates, false),
      disabled: loading,
      reason: 'Candidate data is still loading.',
      scope: `all workspace candidates · ${candidates.length}`,
    },
    {
      label: 'Export Filtered Candidates (CSV)',
      format: 'csv' as const,
      onSelect: () => exportCandidates(filteredCandidates, true),
      disabled: loading,
      reason: 'Candidate data is still loading.',
      scope: filteredCandidatesScope,
    },
    {
      label: 'Export Applications for Current Filters (CSV)',
      format: 'csv' as const,
      onSelect: () => exportCandidateApplications(true),
      disabled: loading || !workspaceId,
      reason: 'Workspace candidate data is unavailable.',
      scope: `applications matching candidate filters · ${filteredCandidates.length} candidates`,
    },
    {
      label: 'Export All Workspace Applications (CSV)',
      format: 'csv' as const,
      onSelect: () => exportCandidateApplications(false),
      disabled: loading || !workspaceId,
      reason: 'Workspace application data is unavailable.',
      scope: 'all authorized workspace applications',
    },
    {
      label: 'Export Candidate and Application Workbook (XLSX)',
      format: 'xlsx' as const,
      onSelect: exportCandidateApplicationWorkbook,
      disabled: loading || !workspaceId,
      reason: 'Candidate data is still loading or unavailable.',
      scope: 'complete authorized workspace recruitment workbook',
    },
  ]

  function openCreateForm() {
    setFormMode('create')
    setEditingCandidate(null)
    setForm(emptyCandidate)
    setErrorMessage('')
    setErrorDetails('')
    setSuccessMessage('')
  }

  function openEditForm(candidate: CandidateWithApplications) {
    setFormMode('edit')
    setEditingCandidate(candidate)
    setForm({
      full_name: candidate.full_name,
      email: candidate.email ?? '',
      phone: candidate.phone ?? '',
      linkedin_url: candidate.linkedin_url ?? '',
    })
    setErrorMessage('')
    setErrorDetails('')
    setSuccessMessage('')
  }

  async function handleCandidateSave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setErrorMessage('')
    setErrorDetails('')
    setSuccessMessage('')

    if (!user || !workspaceId) {
      setErrorMessage('Sign in and choose a workspace before saving.')
      return
    }

    const normalizedEmail = form.email.trim().toLowerCase()
    if (
      normalizedEmail &&
      candidates.some(
        (candidate) =>
          candidate.id !== editingCandidate?.id &&
          candidate.email?.trim().toLowerCase() === normalizedEmail,
      )
    ) {
      setErrorMessage(
        'A candidate with this email already exists in this workspace.',
      )
      return
    }

    setSaving(true)
    try {
      await saveCandidate(
        workspaceId,
        user.id,
        form,
        editingCandidate?.id,
      )
      setFormMode(null)
      setEditingCandidate(null)
      setForm(emptyCandidate)
      setSuccessMessage(
        editingCandidate
          ? 'Candidate details updated.'
          : 'Candidate added successfully.',
      )
      await loadData()
    } catch (error) {
      const saveError = getCandidateSaveError(error, form)
      setErrorMessage(saveError.userMessage)
      setErrorDetails(saveError.diagnostic)
    } finally {
      setSaving(false)
    }
  }

  function openApplicationForm(candidate: CandidateWithApplications) {
    setApplicationCandidate(candidate)
    setSelectedJobId('')
    setFormMode('application')
    setErrorMessage('')
    setSuccessMessage('')
  }

  async function handleApplicationCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setErrorMessage('')
    setSuccessMessage('')

    if (!applicationCandidate || !workspaceId || !selectedJobId) {
      setErrorMessage('Select a job in this workspace.')
      return
    }

    setSaving(true)
    try {
      await createCandidateApplication(
        workspaceId,
        applicationCandidate.id,
        selectedJobId,
      )
      setFormMode(null)
      setApplicationCandidate(null)
      setSuccessMessage('Application created successfully.')
      await loadData()
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
    } finally {
      setSaving(false)
    }
  }

  async function handleDelete(candidate: CandidateWithApplications) {
    const confirmed = window.confirm(
      `Delete ${candidate.full_name}? Their candidate profile and associated applications will be removed from this workspace.`,
    )
    if (!confirmed || !workspaceId) return

    setErrorMessage('')
    setSuccessMessage('')
    try {
      await deleteCandidate(workspaceId, candidate.id)
      setSuccessMessage(`${candidate.full_name} was deleted.`)
      await loadData()
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
    }
  }

  async function handleStatusChange(
    applicationId: string,
    status: ApplicationStatus,
  ) {
    if (!workspaceId) return

    setErrorMessage('')
    setSuccessMessage('')

    try {
      await updateApplicationStatus(workspaceId, applicationId, status)
      setSuccessMessage('Application status updated.')
      await loadData()
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
    }
  }

  const modalTitle =
    formMode === 'create'
      ? 'Add candidate'
      : formMode === 'edit'
        ? 'Edit candidate'
        : 'Create application'

  return (
    <section className="page-stack">
      <div className="page-heading-row">
        <div className="page-heading">
          <span className="page-eyebrow">TALENT DATABASE</span>
          <h1>Candidates</h1>
          <p>Manage candidate profiles and track applications across jobs.</p>
        </div>
        <button
          type="button"
          className="button button-primary"
          onClick={openCreateForm}
        >
          <Plus size={17} />
          Add candidate
        </button>
      </div>
      <div className="recruitment-export-toolbar">
        <p>Export authorized candidate and application data. Private resume paths are excluded.</p>
        <ExportActions
          scope={filteredCandidatesScope}
          disabled={loading || Boolean(errorMessage)}
          options={candidateExportOptions}
        />
      </div>

      {errorMessage && (
        <div className="form-alert form-alert-error" role="alert">
          {errorMessage}
          {import.meta.env.DEV && errorDetails && (
            <div className="form-help">{errorDetails}</div>
          )}
        </div>
      )}
      {successMessage && (
        <div className="form-alert form-alert-success" role="status">
          {successMessage}
        </div>
      )}

      <div className="metric-grid">
        <div className="metric-card">
          <span>Total candidates</span>
          <strong>{candidates.length}</strong>
          <small>In this workspace</small>
        </div>
        <div className="metric-card">
          <span>Applications</span>
          <strong>
            {candidates.reduce(
              (total, candidate) => total + candidate.applications.length,
              0,
            )}
          </strong>
          <small>Across all jobs</small>
        </div>
        <div className="metric-card">
          <span>Shortlisted</span>
          <strong>
            {candidates.reduce(
              (total, candidate) =>
                total +
                candidate.applications.filter(
                  (application) => application.status === 'shortlisted',
                ).length,
              0,
            )}
          </strong>
          <small>Applications shortlisted</small>
        </div>
        <div className="metric-card">
          <span>Hired</span>
          <strong>
            {candidates.reduce(
              (total, candidate) =>
                total +
                candidate.applications.filter(
                  (application) => application.status === 'hired',
                ).length,
              0,
            )}
          </strong>
          <small>Applications marked hired</small>
        </div>
      </div>

      <div className="panel">
        <div className="panel-toolbar candidates-toolbar">
          <div className="search-field">
            <Search size={17} />
            <input
              value={search}
              onChange={(event) => setSearch(event.target.value)}
              placeholder="Search name or email"
              aria-label="Search candidates by name or email"
            />
          </div>
          <select
            className="form-select filter-select"
            value={jobFilter}
            onChange={(event) => setJobFilter(event.target.value)}
            aria-label="Filter candidates by job"
          >
            <option value="all">All jobs</option>
            {jobs.map((job) => (
              <option key={job.id} value={job.id}>
                {job.title}
              </option>
            ))}
          </select>
          <select
            className="form-select filter-select"
            value={statusFilter}
            onChange={(event) => setStatusFilter(event.target.value)}
            aria-label="Filter candidates by application status"
          >
            <option value="all">All statuses</option>
            {applicationStatuses.map((status) => (
              <option key={status} value={status}>
                {statusLabels[status]}
              </option>
            ))}
          </select>
        </div>

        {loading ? (
          <div className="empty-state">
            <span className="loading-spinner" />
            <p>Loading candidates...</p>
          </div>
        ) : filteredCandidates.length === 0 ? (
          <div className="empty-state">
            <span className="empty-state-icon">
              <Users size={24} />
            </span>
            <h3>
              {candidates.length ? 'No matching candidates' : 'No candidates yet'}
            </h3>
            <p>
              {candidates.length
                ? 'Try changing the search or application filters.'
                : 'Add a candidate to build your workspace talent database.'}
            </p>
            {!candidates.length && (
              <button
                type="button"
                className="button button-primary"
                onClick={openCreateForm}
              >
                <Plus size={16} />
                Add candidate
              </button>
            )}
          </div>
        ) : (
          <div className="table-scroll">
            <table className="data-table candidate-management-table">
              <thead>
                <tr>
                  <th>Candidate</th>
                  <th>Contact</th>
                  <th>Applications</th>
                  <th>Actions</th>
                </tr>
              </thead>
              <tbody>
                {filteredCandidates.map((candidate) => {
                  const hasJobFilter = jobFilter !== 'all'
                  const visibleApplications = candidate.applications.filter(
                    (application) =>
                      (!hasJobFilter || application.job_id === jobFilter) &&
                      (statusFilter === 'all' ||
                        application.status === statusFilter),
                  )

                  return (
                    <tr key={candidate.id}>
                      <td>
                        <div className="candidate-table-person">
                          <span className="candidate-avatar">
                            {candidate.full_name.charAt(0).toUpperCase()}
                          </span>
                          <span>
                            <strong>{candidate.full_name}</strong>
                            <span className="table-secondary">
                              Added {new Date(candidate.created_at).toLocaleDateString()}
                            </span>
                          </span>
                        </div>
                      </td>
                      <td>
                        <div className="candidate-contact">
                          {candidate.email && <span>{candidate.email}</span>}
                          {candidate.phone && <span>{candidate.phone}</span>}
                          {candidate.linkedin_url && (
                            <a
                              href={candidate.linkedin_url}
                              target="_blank"
                              rel="noreferrer"
                              aria-label={`Open ${candidate.full_name}'s LinkedIn profile`}
                            >
                              <Linkedin size={14} />
                              LinkedIn
                              <ExternalLink size={12} />
                            </a>
                          )}
                          {!candidate.email &&
                            !candidate.phone &&
                            !candidate.linkedin_url && (
                              <span className="table-secondary">
                                No contact details
                              </span>
                            )}
                        </div>
                      </td>
                      <td>
                        <div className="candidate-applications">
                          {visibleApplications.length ? (
                            visibleApplications.map((application) => (
                              <div
                                className="candidate-application-item"
                                key={application.id}
                              >
                                <span className="candidate-application-job">
                                  <BriefcaseBusiness size={14} />
                                  {application.jobs?.title ?? 'Unknown job'}
                                </span>
                                <select
                                  className="form-select status-cell-select"
                                  value={application.status}
                                  onChange={(event) =>
                                    void handleStatusChange(
                                      application.id,
                                      event.target.value as ApplicationStatus,
                                    )
                                  }
                                  aria-label={`Update ${candidate.full_name}'s application status for ${application.jobs?.title ?? 'job'}`}
                                >
                                  {applicationStatuses.map((status) => (
                                    <option key={status} value={status}>
                                      {statusLabels[status]}
                                    </option>
                                  ))}
                                </select>
                              </div>
                            ))
                          ) : (
                            <span className="candidate-no-applications">
                              {candidate.applications.length
                                ? 'No applications match filters'
                                : 'No applications yet'}
                            </span>
                          )}
                        </div>
                      </td>
                      <td>
                        <div className="candidate-row-actions">
                          <button
                            type="button"
                            className="icon-button"
                            title="Create application"
                            aria-label={`Create application for ${candidate.full_name}`}
                            onClick={() => openApplicationForm(candidate)}
                            disabled={!jobs.length}
                          >
                            <Plus size={16} />
                          </button>
                          <button
                            type="button"
                            className="icon-button"
                            title="Edit candidate"
                            aria-label={`Edit ${candidate.full_name}`}
                            onClick={() => openEditForm(candidate)}
                          >
                            <Pencil size={16} />
                          </button>
                          {canDeleteCandidates && (
                            <button
                              type="button"
                              className="icon-button candidate-delete-button"
                              title="Delete candidate"
                              aria-label={`Delete ${candidate.full_name}`}
                              onClick={() => void handleDelete(candidate)}
                            >
                              <Trash2 size={16} />
                            </button>
                          )}
                        </div>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {formMode && (
        <Modal
          open
          title={modalTitle}
          description={
            formMode === 'application'
              ? `Select a job in this workspace for ${applicationCandidate?.full_name}.`
              : 'Candidate details are only available to authorized workspace members.'
          }
          size="medium"
          onClose={() => {
            if (saving) return
            setFormMode(null)
            setEditingCandidate(null)
            setApplicationCandidate(null)
          }}
        >
          {formMode === 'application' ? (
            <form className="modal-form" onSubmit={handleApplicationCreate}>
              <label className="field-label" htmlFor="candidate-job">
                Job *
              </label>
              <select
                id="candidate-job"
                className="form-select"
                value={selectedJobId}
                onChange={(event) => setSelectedJobId(event.target.value)}
                required
              >
                <option value="">Select a job</option>
                {jobs.map((job) => (
                  <option key={job.id} value={job.id}>
                    {job.title}
                  </option>
                ))}
              </select>
              <p className="form-help">
                The application starts with New status. Duplicate applications
                for the same candidate and job are prevented.
              </p>
              <div className="modal-actions">
                <button
                  type="button"
                  className="button button-secondary"
                  onClick={() => setFormMode(null)}
                  disabled={saving}
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  className="button button-primary"
                  disabled={saving || !jobs.length}
                >
                  {saving ? 'Creating...' : 'Create application'}
                </button>
              </div>
            </form>
          ) : (
            <form
              className="modal-form"
              onSubmit={(event) => void handleCandidateSave(event)}
            >
              <label className="field-label" htmlFor="candidate-name">
                Full name *
              </label>
              <input
                id="candidate-name"
                className="form-input"
                value={form.full_name}
                onChange={(event) =>
                  setForm({ ...form, full_name: event.target.value })
                }
                autoComplete="name"
                minLength={2}
                maxLength={180}
                required
              />

              <label className="field-label" htmlFor="candidate-email">
                Email
              </label>
              <input
                id="candidate-email"
                className="form-input"
                type="email"
                value={form.email}
                onChange={(event) =>
                  setForm({ ...form, email: event.target.value })
                }
                autoComplete="email"
                maxLength={320}
                placeholder="name@example.com"
              />

              <label className="field-label" htmlFor="candidate-phone">
                Phone
              </label>
              <input
                id="candidate-phone"
                className="form-input"
                type="tel"
                value={form.phone}
                onChange={(event) =>
                  setForm({ ...form, phone: event.target.value })
                }
                autoComplete="tel"
                maxLength={40}
              />

              <label className="field-label" htmlFor="candidate-linkedin">
                LinkedIn URL
              </label>
              <input
                id="candidate-linkedin"
                className="form-input"
                type="url"
                value={form.linkedin_url}
                onChange={(event) =>
                  setForm({ ...form, linkedin_url: event.target.value })
                }
                placeholder="https://www.linkedin.com/in/..."
                maxLength={500}
              />

              <p className="form-help">
                Email, phone, and LinkedIn URL are optional.
              </p>

              <div className="modal-actions">
                <button
                  type="button"
                  className="button button-secondary"
                  onClick={() => setFormMode(null)}
                  disabled={saving}
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  className="button button-primary"
                  disabled={saving}
                >
                  {saving
                    ? 'Saving...'
                    : formMode === 'edit'
                      ? 'Save changes'
                      : 'Add candidate'}
                </button>
              </div>
            </form>
          )}
        </Modal>
      )}
    </section>
  )
}
