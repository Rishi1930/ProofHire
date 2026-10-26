
import { useEffect, useMemo, useState, type FormEvent } from 'react'
import { Link, useLocation, useParams, useSearchParams } from 'react-router-dom'
import {
  ArrowLeft,
  ArrowRight,
  BriefcaseBusiness,
  MapPin,
  Plus,
  Search,
  Pencil,
  X,
  ExternalLink,
} from 'lucide-react'

import { supabase } from '../lib/supabase'
import { getCurrentWorkspaceId } from '../lib/workspace'
import { useWorkspaceApplications } from '../recruitment/useWorkspaceApplications'
import {
  getApplicationExportColumns,
  type ApplicationStatus,
} from '../recruitment/applicationData'
import JobHiringWorkspace from './JobHiringWorkspace'
import ExportActions from '../components/ExportActions'
import { downloadCsv, downloadXlsx } from '../lib/export'
import {
  createRecruitmentWorkbookSheets,
  loadWorkspaceRecruitmentExportData,
} from '../recruitment/exportData'

export type JobStatus = 'draft' | 'open' | 'paused' | 'closed'
export type WorkplaceType = 'on-site' | 'remote' | 'hybrid'

export type Job = {
  id: string
  workspace_id: string
  title: string
  department: string | null
  location: string | null
  employment_type: string
  workplace_type: WorkplaceType
  description: string | null
  required_skills: string[]
  preferred_skills: string[]
  minimum_experience: number | null
  status: JobStatus
  created_at: string
}

type JobForm = {
  title: string
  department: string
  location: string
  employment_type: string
  workplace_type: WorkplaceType
  description: string
  required_skills: string
  preferred_skills: string
  minimum_experience: string
  status: JobStatus
}

const emptyForm: JobForm = {
  title: '',
  department: '',
  location: '',
  employment_type: 'Full-time',
  workplace_type: 'on-site',
  description: '',
  required_skills: '',
  preferred_skills: '',
  minimum_experience: '',
  status: 'draft',
}

const statusLabels: Record<JobStatus, string> = {
  draft: 'Draft',
  open: 'Published',
  paused: 'Paused',
  closed: 'Closed',
}

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : 'Something went wrong.'
}

function parseSkills(value: string) {
  const seen = new Set<string>()

  return value
    .split(',')
    .map((skill) => skill.trim())
    .filter((skill) => {
      if (!skill) return false

      const normalized = skill.toLowerCase()
      if (seen.has(normalized)) return false

      seen.add(normalized)
      return true
    })
}

export default function Jobs() {
  const { jobId } = useParams()
  const location = useLocation()
  const navigationState = location.state as {
    from?: unknown
    jobsFilters?: {
      search?: string
      sort?: string
      statusFilter?: JobStatus | 'all'
    }
    reportFilters?: {
      range?: string
      jobFilter?: string
      sourceFilter?: string
      stageFilter?: string
    }
  } | null
  const [searchParams, setSearchParams] = useSearchParams()
  const {
    applications,
    workspaceId,
    loading: applicationsLoading,
    error: applicationsError,
    updateStatus: updateApplicationStatus,
  } = useWorkspaceApplications()
  const [jobs, setJobs] = useState<Job[]>([])
  const [search, setSearch] = useState(
    navigationState?.jobsFilters?.search ?? searchParams.get('q') ?? '',
  )
  const [sort, setSort] = useState(
    navigationState?.jobsFilters?.sort ?? searchParams.get('sort') ?? 'newest',
  )
  const [statusFilter, setStatusFilter] = useState(
    navigationState?.jobsFilters?.statusFilter ??
      searchParams.get('status') ??
      'all',
  )
  const [showForm, setShowForm] = useState(false)
  const [editingJob, setEditingJob] = useState<Job | null>(null)
  const [form, setForm] = useState<JobForm>(emptyForm)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [errorMessage, setErrorMessage] = useState('')
  const [successMessage, setSuccessMessage] = useState('')
  const [exportJobId, setExportJobId] = useState('')

  useEffect(() => {
    setSearch(searchParams.get('q') ?? '')
    setSort(searchParams.get('sort') ?? 'newest')
    setStatusFilter(searchParams.get('status') ?? 'all')
  }, [location.search, searchParams])

  async function loadJobs() {
    if (!supabase) {
      setErrorMessage('Configure Supabase before managing jobs.')
      setLoading(false)
      return
    }

    setLoading(true)
    setErrorMessage('')

    const { data: authData, error: authError } = await supabase.auth.getUser()
    if (authError) {
      setErrorMessage(authError.message)
      setJobs([])
      setLoading(false)
      return
    }
    if (!authData.user) {
      setErrorMessage('Sign in before viewing workspace jobs.')
      setJobs([])
      setLoading(false)
      return
    }

    const workspaceResult = await getCurrentWorkspaceId(authData.user.id)
    if (!workspaceResult.workspaceId) {
      setErrorMessage(
        workspaceResult.error ?? 'Unable to determine the active workspace.',
      )
      setJobs([])
      setLoading(false)
      return
    }

    try {
      const jobRows: Job[] = []
      const pageSize = 1000
      for (let start = 0; ; start += pageSize) {
        const { data, error } = await supabase
          .from('jobs')
          .select(
            'id, workspace_id, title, department, location, employment_type, workplace_type, description, required_skills, preferred_skills, minimum_experience, status, created_at',
          )
          .eq('workspace_id', workspaceResult.workspaceId)
          .order('created_at', { ascending: false })
          .range(start, start + pageSize - 1)
        if (error) throw error
        jobRows.push(...((data ?? []) as Job[]))
        if ((data ?? []).length < pageSize) break
      }
      setJobs(jobRows)
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
      setJobs([])
    }

    setLoading(false)
  }

  useEffect(() => {
    void loadJobs()
    if (searchParams.get('create') === 'true') openCreateForm()
  }, [])

  function openCreateForm() {
    setEditingJob(null)
    setForm(emptyForm)
    setErrorMessage('')
    setSuccessMessage('')
    setShowForm(true)
  }

  function openEditForm(job: Job) {
    setEditingJob(job)
    setForm({
      title: job.title,
      department: job.department ?? '',
      location: job.location ?? '',
      employment_type: job.employment_type,
      workplace_type: job.workplace_type,
      description: job.description ?? '',
      required_skills: (job.required_skills ?? []).join(', '),
      preferred_skills: (job.preferred_skills ?? []).join(', '),
      minimum_experience:
        job.minimum_experience === null
          ? ''
          : String(job.minimum_experience),
      status: job.status,
    })
    setErrorMessage('')
    setSuccessMessage('')
    setShowForm(true)
  }

  async function handleSave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!supabase) {
      setErrorMessage('Configure Supabase before saving jobs.')
      return
    }

    setErrorMessage('')
    setSuccessMessage('')

    const experienceValue = form.minimum_experience.trim()
    const minimumExperience =
      experienceValue === '' ? null : Number(experienceValue)

    if (
      experienceValue !== '' &&
      (!/^(?:\d+(?:\.\d*)?|\.\d+)$/.test(experienceValue) ||
        !Number.isFinite(minimumExperience) ||
        minimumExperience === null ||
        minimumExperience < 0)
    ) {
      setErrorMessage(
        'Minimum experience must be a valid number of years greater than or equal to 0.',
      )
      return
    }

    setSaving(true)
    const payload = {
      title: form.title.trim(),
      department: form.department.trim() || null,
      location: form.location.trim() || null,
      employment_type: form.employment_type,
      workplace_type: form.workplace_type,
      description: form.description.trim(),
      required_skills: parseSkills(form.required_skills),
      preferred_skills: parseSkills(form.preferred_skills),
      minimum_experience: minimumExperience,
      status: form.status,
    }

    try {
      if (editingJob) {
        const { data, error } = await supabase
          .from('jobs')
          .update(payload)
          .eq('id', editingJob.id)
          .eq('workspace_id', editingJob.workspace_id)
          .select('id')
          .maybeSingle()

        if (error) throw error
        if (!data) {
          throw new Error(
            'This job was not updated. It may have been removed or you may not have permission.',
          )
        }
      } else {
        const { data: authData, error: authError } =
          await supabase.auth.getUser()

        if (authError) throw authError
        if (!authData.user) {
          throw new Error('Sign in before creating a job.')
        }

        const workspaceResult = await getCurrentWorkspaceId(authData.user.id)
        if (!workspaceResult.workspaceId) {
          throw new Error(
            workspaceResult.error ??
              'No workspace was found for your account. Complete workspace setup first.',
          )
        }

        const { error } = await supabase.from('jobs').insert({
          ...payload,
          workspace_id: workspaceResult.workspaceId,
          created_by: authData.user.id,
        })

        if (error) throw error
      }

      setShowForm(false)
      setEditingJob(null)
      setForm(emptyForm)
      setSuccessMessage(
        editingJob ? 'Job updated successfully.' : 'Job created successfully.',
      )
      await loadJobs()
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
    } finally {
      setSaving(false)
    }
  }

  async function updateStatus(job: Job, status: JobStatus) {
    if (!supabase) return

    setErrorMessage('')
    setSuccessMessage('')

    const { data, error } = await supabase
      .from('jobs')
      .update({ status })
      .eq('id', job.id)
      .eq('workspace_id', job.workspace_id)
      .select('id')
      .maybeSingle()

    if (error) {
      setErrorMessage(error.message)
      return
    }

    if (!data) {
      setErrorMessage(
        'This job status was not updated. It may have been removed or you may not have permission.',
      )
      return
    }

    setSuccessMessage(`Job marked as ${statusLabels[status].toLowerCase()}.`)
    await loadJobs()
  }

  const filteredJobs = jobs.filter((job) => {
    const query = search.toLowerCase()
    const matchesSearch =
      job.title.toLowerCase().includes(query) ||
      (job.department ?? '').toLowerCase().includes(query) ||
      (job.location ?? '').toLowerCase().includes(query) ||
      job.required_skills.some((skill) => skill.toLowerCase().includes(query)) ||
      job.preferred_skills.some((skill) => skill.toLowerCase().includes(query))

    return (
      matchesSearch &&
      (statusFilter === 'all' || job.status === statusFilter)
    )
  }).sort((left, right) => {
    if (sort === 'title') return left.title.localeCompare(right.title)
    const leftDate = new Date(left.created_at).getTime()
    const rightDate = new Date(right.created_at).getTime()
    return sort === 'oldest' ? leftDate - rightDate : rightDate - leftDate
  })

  const applicationsByJob = useMemo(() => {
    const byJob = new Map<string, typeof applications>()
    for (const application of applications) {
      const records = byJob.get(application.job_id) ?? []
      records.push(application)
      byJob.set(application.job_id, records)
    }
    return byJob
  }, [applications])

  const selectedJob = jobs.find((job) => job.id === jobId)
  const listLocation = `${location.pathname}${location.search}`
  const routeParent =
    typeof navigationState?.from === 'string' &&
    navigationState.from.startsWith('/') &&
    !navigationState.from.startsWith('//')
      ? navigationState.from
      : '/jobs'
  const listState = {
    from: listLocation,
    jobsFilters: { search, sort, statusFilter },
  }

  function exportJobs(rows: Job[], scope: string) {
    const columns = [
      { header: 'Job ID', value: (job: Job) => job.id },
      { header: 'Title', value: (job: Job) => job.title },
      { header: 'Department', value: (job: Job) => job.department },
      { header: 'Location', value: (job: Job) => job.location },
      { header: 'Work mode', value: (job: Job) => job.workplace_type },
      { header: 'Employment type', value: (job: Job) => job.employment_type },
      { header: 'Status', value: (job: Job) => job.status },
      {
        header: 'Required skills',
        value: (job: Job) => (job.required_skills ?? []).join('; '),
      },
      {
        header: 'Preferred skills',
        value: (job: Job) => (job.preferred_skills ?? []).join('; '),
      },
      {
        header: 'Minimum experience (years)',
        value: (job: Job) => job.minimum_experience,
      },
      { header: 'Created at', value: (job: Job) => job.created_at },
      {
        header: 'Applications',
        value: (job: Job) => applicationsByJob.get(job.id)?.length ?? 0,
      },
    ]
    downloadCsv(`proofhire-jobs-${scope}`, columns, rows)
  }

  async function exportWorkspaceWorkbook() {
    if (!workspaceId) throw new Error('No active workspace is available.')
    const data = await loadWorkspaceRecruitmentExportData(workspaceId, {
      includeDecisions: true,
      includeInterviews: true,
    })
    await downloadXlsx(
      'proofhire-complete-recruitment-workbook',
      createRecruitmentWorkbookSheets(data),
    )
  }

  async function exportSelectedJobCandidates() {
    if (!workspaceId || !exportJobId) {
      throw new Error('Select a job before exporting its candidates.')
    }
    const data = await loadWorkspaceRecruitmentExportData(workspaceId)
    const jobApplications = data.applications.filter(
      (application) => application.job_id === exportJobId,
    )
    const candidateIds = new Set(jobApplications.map((application) => application.candidate_id))
    const counts = new Map<string, number>()
    for (const application of jobApplications) {
      counts.set(application.candidate_id, (counts.get(application.candidate_id) ?? 0) + 1)
    }
    downloadCsv(
      'proofhire-selected-job-candidates',
      [
        { header: 'Candidate ID', value: (candidate) => candidate.id },
        { header: 'Full name', value: (candidate) => candidate.full_name },
        { header: 'Email', value: (candidate) => candidate.email },
        { header: 'Phone', value: (candidate) => candidate.phone },
        { header: 'LinkedIn URL', value: (candidate) => candidate.linkedin_url },
        { header: 'Applications for selected job', value: (candidate) => counts.get(candidate.id) ?? 0 },
      ],
      data.candidates.filter((candidate) => candidateIds.has(candidate.id)),
    )
  }

  function exportSelectedJobApplications() {
    if (!exportJobId) throw new Error('Select a job before exporting applications.')
    const selectedJob = jobs.find((job) => job.id === exportJobId)
    if (!selectedJob) throw new Error('The selected job is not available in this workspace.')
    downloadCsv(
      `proofhire-${selectedJob.title}-applications`,
      getApplicationExportColumns(),
      applications.filter((application) => application.job_id === selectedJob.id),
    )
  }

  const jobExportOptions = [
    {
      label: 'Export All Jobs (CSV)',
      format: 'csv' as const,
      onSelect: () => exportJobs(jobs, 'all'),
      disabled: applicationsLoading || Boolean(applicationsError),
      reason: applicationsError || 'Application counts are still loading.',
    },
    {
      label: 'Export Filtered Jobs (CSV)',
      format: 'csv' as const,
      onSelect: () => exportJobs(filteredJobs, 'filtered'),
      disabled: applicationsLoading || Boolean(applicationsError),
      reason: applicationsError || 'Application counts are still loading.',
    },
    {
      label: 'Export All Applications (CSV)',
      format: 'csv' as const,
      onSelect: () =>
        downloadCsv(
          'proofhire-all-applications',
          getApplicationExportColumns(),
          applications,
        ),
      disabled: applicationsLoading || Boolean(applicationsError),
      reason: applicationsError || 'Applications are still loading.',
    },
    {
      label: 'Export Applications for Selected Job (CSV)',
      format: 'csv' as const,
      onSelect: exportSelectedJobApplications,
      disabled:
        !exportJobId ||
        applicationsLoading ||
        Boolean(applicationsError),
      reason: 'Select a job and wait for its applications to load.',
    },
    {
      label: 'Export Unique Candidates for Selected Job (CSV)',
      format: 'csv' as const,
      onSelect: exportSelectedJobCandidates,
      disabled: !exportJobId || !workspaceId,
      reason: 'Select a job to export its unique candidates.',
    },
    {
      label: 'Export Complete Recruitment Workbook (XLSX)',
      format: 'xlsx' as const,
      onSelect: exportWorkspaceWorkbook,
      disabled: !workspaceId,
      reason: 'The active workspace is not available.',
    },
  ]

  async function handleApplicationStatusChange(
    applicationId: string,
    status: ApplicationStatus,
  ) {
    await updateApplicationStatus(applicationId, status)
  }

  if (jobId) {
    if (loading) {
      return (
        <section className="page-stack">
          <Link to={routeParent} state={navigationState ?? undefined} className="text-link">
            <ArrowLeft size={15} />
            {routeParent.startsWith('/reports') ? 'Back to Reports & Insights' : 'Jobs &amp; Hiring'}
          </Link>
          <div className="empty-state">
            <span className="loading-spinner" />
            <p>Loading job workspace...</p>
          </div>
        </section>
      )
    }
    if (errorMessage || !selectedJob) {
      return (
        <section className="page-stack">
          <div className="form-alert form-alert-error" role="alert">
            {errorMessage || 'This job was not found in your workspace.'}
          </div>
          <Link to={routeParent} state={navigationState ?? undefined} className="text-link">
            <ArrowLeft size={15} />
            {routeParent.startsWith('/reports') ? 'Back to Reports & Insights' : 'Jobs &amp; Hiring'}
          </Link>
        </section>
      )
    }
    return (
      <>
        <JobHiringWorkspace
          job={selectedJob}
          applications={applications.filter(
            (application) => application.job_id === selectedJob.id,
          )}
          applicationsLoading={applicationsLoading}
          applicationsError={applicationsError}
          onStatusChange={handleApplicationStatusChange}
          onEdit={() => openEditForm(selectedJob)}
        />
        {showForm && renderJobForm()}
      </>
    )
  }

  return (
    <section className="page-stack">
      <div className="page-heading-row">
        <div className="page-heading">
          <span className="page-eyebrow">RECRUITMENT WORKSPACE</span>
          <h1>Jobs &amp; Hiring</h1>
          <p>Manage vacancies and review every application by job.</p>
        </div>
        <button
          type="button"
          className="button button-primary"
          onClick={openCreateForm}
        >
          <Plus size={17} />
          Create job
        </button>
      </div>

      {errorMessage && (
        <div className="form-alert form-alert-error" role="alert">
          {errorMessage}
        </div>
      )}
      {applicationsError && (
        <div className="form-alert form-alert-error" role="alert">
          Application metrics could not be loaded: {applicationsError}
        </div>
      )}
      {successMessage && (
        <div className="form-alert form-alert-success" role="status">
          {successMessage}
        </div>
      )}

      <div className="metric-grid">
        <div className="metric-card">
          <span>Total jobs</span>
          <strong>{jobs.length}</strong>
          <small>Across your workspace</small>
        </div>
        <div className="metric-card">
          <span>Published</span>
          <strong>{jobs.filter((job) => job.status === 'open').length}</strong>
          <small>Accepting applications</small>
        </div>
        <div className="metric-card">
          <span>Drafts</span>
          <strong>{jobs.filter((job) => job.status === 'draft').length}</strong>
          <small>Not yet published</small>
        </div>
        <div className="metric-card">
          <span>Paused or closed</span>
          <strong>
            {jobs.filter((job) => ['paused', 'closed'].includes(job.status)).length}
          </strong>
          <small>Not currently accepting</small>
        </div>
      </div>

      <div className="recruitment-export-toolbar">
        <label className="recruitment-export-job">
          <span>Job-specific export</span>
          <select
            className="form-select"
            value={exportJobId}
            onChange={(event) => setExportJobId(event.target.value)}
            aria-label="Select a job for job-specific exports"
          >
            <option value="">Select a job</option>
            {jobs.map((job) => (
              <option key={job.id} value={job.id}>{job.title}</option>
            ))}
          </select>
        </label>
        <ExportActions
          scope={`workspace · ${jobs.length} jobs · ${applications.length} applications`}
          disabled={loading || Boolean(errorMessage)}
          options={jobExportOptions}
        />
      </div>

      <div className="panel">
        <div className="panel-toolbar">
          <div className="search-field">
            <Search size={17} />
            <input
              value={search}
              onChange={(event) => {
                const value = event.target.value
                setSearch(value)
                setSearchParams((current) => {
                  const next = new URLSearchParams(current)
                  if (value) next.set('q', value)
                  else next.delete('q')
                  return next
                }, { replace: true })
              }}
              placeholder="Search job title, department or location"
              aria-label="Search jobs"
            />
          </div>
          <select
            className="form-select filter-select"
            value={statusFilter}
            onChange={(event) => {
              const value = event.target.value
              setStatusFilter(value)
              setSearchParams((current) => {
                const next = new URLSearchParams(current)
                if (value && value !== 'all') next.set('status', value)
                else next.delete('status')
                return next
              })
            }}
            aria-label="Filter jobs by status"
          >
            <option value="all">All statuses</option>
            <option value="draft">Draft</option>
            <option value="open">Published</option>
            <option value="paused">Paused</option>
            <option value="closed">Closed</option>
          </select>
          <select
            className="form-select filter-select"
            value={sort}
            onChange={(event) => {
              const value = event.target.value
              setSort(value)
              setSearchParams((current) => {
                const next = new URLSearchParams(current)
                if (value !== 'newest') next.set('sort', value)
                else next.delete('sort')
                return next
              })
            }}
            aria-label="Sort jobs"
          >
            <option value="newest">Newest jobs</option>
            <option value="oldest">Oldest jobs</option>
            <option value="title">Title A–Z</option>
          </select>
        </div>

        {loading ? (
          <div className="empty-state">
            <span className="loading-spinner" />
            <p>Loading jobs...</p>
          </div>
        ) : filteredJobs.length === 0 ? (
          <div className="empty-state">
            <span className="empty-state-icon">
              <BriefcaseBusiness size={23} />
            </span>
            <h3>{errorMessage ? 'Jobs unavailable' : jobs.length ? 'No matching jobs' : 'Create your first job'}</h3>
            <p>
              {errorMessage
                ? 'Resolve the workspace query error above, then refresh the page.'
                : jobs.length
                ? 'Try changing your search or status filter.'
                : 'Add a role to start receiving candidate applications.'}
            </p>
            {!jobs.length && !errorMessage && (
              <button
                type="button"
                className="button button-primary"
                onClick={openCreateForm}
              >
                <Plus size={16} />
                Create job
              </button>
            )}
          </div>
        ) : (
          <div className="jobs-list">
            {filteredJobs.map((job) => {
              const jobApplications = applicationsByJob.get(job.id) ?? []
              const latestApplication = jobApplications.reduce<
                string | null
              >((latest, application) => {
                const timestamp = application.applied_at ?? application.created_at
                return !latest || timestamp > latest ? timestamp : latest
              }, null)

              return (
              <article className="job-row" key={job.id}>
                <div className="job-icon">
                  <BriefcaseBusiness size={20} />
                </div>
                <div className="job-main">
                  <h3>
                    <Link
                      to={`/jobs/${job.id}/hiring`}
                      state={listState}
                    >
                      {job.title}
                    </Link>
                  </h3>
                  <div className="job-meta">
                    {job.department && <span>{job.department}</span>}
                    {job.location && (
                      <span>
                        <MapPin size={13} />
                        {job.location}
                      </span>
                    )}
                    <span>{job.employment_type}</span>
                    <span>{job.workplace_type}</span>
                  </div>
                  {(job.minimum_experience !== null ||
                    job.required_skills.length > 0 ||
                    job.preferred_skills.length > 0) && (
                    <div className="job-requirements">
                      {job.minimum_experience !== null && (
                        <span className="job-experience">
                          {job.minimum_experience}+
                          {job.minimum_experience === 1 ? ' year' : ' years'}{' '}
                          experience
                        </span>
                      )}
                      {job.required_skills.length > 0 && (
                        <span className="job-required-label">Required:</span>
                      )}
                      {job.required_skills.slice(0, 3).map((skill) => (
                        <span className="job-skill-tag" key={`required-${skill}`}>
                          {skill}
                        </span>
                      ))}
                      {job.required_skills.length > 3 && (
                        <span className="job-skill-more">
                          +{job.required_skills.length - 3} more required
                        </span>
                      )}
                      {job.preferred_skills.length > 0 && (
                        <span className="job-preferred-summary">
                          Preferred: {job.preferred_skills.slice(0, 2).join(', ')}
                          {job.preferred_skills.length > 2
                            ? ` +${job.preferred_skills.length - 2}`
                            : ''}
                        </span>
                      )}
                    </div>
                  )}
                  <span className={`status-badge status-${job.status}`}>
                    {statusLabels[job.status]}
                  </span>
                  <span className="job-list-date">
                    Created {new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(new Date(job.created_at))}
                    {latestApplication
                      ? ` · Latest application ${new Intl.DateTimeFormat(undefined, { dateStyle: 'medium' }).format(new Date(latestApplication))}`
                      : ''}
                  </span>
                  <div className="job-pipeline-summary" aria-label={`Application metrics for ${job.title}`}>
                    {[
                      ['Applications', jobApplications.length],
                      ['New', jobApplications.filter((item) => item.status === 'new').length],
                      ['Shortlisted', jobApplications.filter((item) => item.status === 'shortlisted').length],
                      ['Interviews', jobApplications.filter((item) => item.status === 'interview').length],
                      ['Hired', jobApplications.filter((item) => item.status === 'hired').length],
                    ].map(([label, count]) => (
                      <span key={label}><strong>{applicationsLoading ? '—' : count}</strong> {label}</span>
                    ))}
                  </div>
                  <Link
                    to={`/jobs/${job.id}/hiring`}
                    state={listState}
                    className="text-link"
                  >
                    Open hiring workspace <ArrowRight size={14} />
                  </Link>
                </div>
                <div className="job-actions">
                  {job.status === 'open' && (
                    <Link
                      className="icon-button"
                      to={`/apply/${job.id}`}
                      title="Open public application page"
                      aria-label={`Open application page for ${job.title}`}
                    >
                      <ExternalLink size={17} />
                    </Link>
                  )}
                  <button
                    type="button"
                    className="icon-button"
                    title="Edit job"
                    aria-label={`Edit ${job.title}`}
                    onClick={() => openEditForm(job)}
                  >
                    <Pencil size={17} />
                  </button>
                  <select
                    className="form-select job-status-select"
                    value={job.status}
                    onChange={(event) =>
                      void updateStatus(job, event.target.value as JobStatus)
                    }
                    aria-label={`Change status for ${job.title}`}
                  >
                    <option value="draft">Draft</option>
                    <option value="open">Published</option>
                    <option value="paused">Paused</option>
                    <option value="closed">Closed</option>
                  </select>
                </div>
              </article>
              )
            })}
          </div>
        )}
      </div>

      {showForm && renderJobForm()}
    </section>
  )

  function renderJobForm() {
    return showForm && (
        <div
          className="modal-backdrop"
          role="presentation"
          onMouseDown={(event) => {
            if (event.target === event.currentTarget) setShowForm(false)
          }}
        >
          <section
            className="modal-card modal-large"
            role="dialog"
            aria-modal="true"
            aria-labelledby="job-form-title"
          >
            <div className="modal-header">
              <div>
                <span className="page-eyebrow">JOB CONFIGURATION</span>
                <h2 id="job-form-title">
                  {editingJob ? 'Edit job' : 'Create a job'}
                </h2>
              </div>
              <button
                type="button"
                className="icon-button"
                onClick={() => setShowForm(false)}
                aria-label="Close job form"
              >
                <X size={19} />
              </button>
            </div>

            <form className="modal-form" onSubmit={handleSave}>
              <label className="field-label" htmlFor="job-title">
                Job title *
              </label>
              <input
                id="job-title"
                className="form-input"
                value={form.title}
                onChange={(event) =>
                  setForm({ ...form, title: event.target.value })
                }
                minLength={2}
                maxLength={160}
                required
              />

              <div className="form-grid-two">
                <div>
                  <label className="field-label" htmlFor="job-department">
                    Department
                  </label>
                  <input
                    id="job-department"
                    className="form-input"
                    value={form.department}
                    onChange={(event) =>
                      setForm({ ...form, department: event.target.value })
                    }
                    maxLength={120}
                  />
                </div>
                <div>
                  <label className="field-label" htmlFor="job-location">
                    Location
                  </label>
                  <input
                    id="job-location"
                    className="form-input"
                    value={form.location}
                    onChange={(event) =>
                      setForm({ ...form, location: event.target.value })
                    }
                    maxLength={160}
                    placeholder="e.g. Hyderabad"
                  />
                </div>
              </div>

              <div className="form-grid-two">
                <div>
                  <label className="field-label" htmlFor="employment-type">
                    Employment type
                  </label>
                  <select
                    id="employment-type"
                    className="form-select"
                    value={form.employment_type}
                    onChange={(event) =>
                      setForm({ ...form, employment_type: event.target.value })
                    }
                  >
                    <option>Full-time</option>
                    <option>Part-time</option>
                    <option>Contract</option>
                    <option>Internship</option>
                    <option>Temporary</option>
                  </select>
                </div>
                <div>
                  <label className="field-label" htmlFor="workplace-type">
                    Workplace type
                  </label>
                  <select
                    id="workplace-type"
                    className="form-select"
                    value={form.workplace_type}
                    onChange={(event) =>
                      setForm({
                        ...form,
                        workplace_type: event.target.value as WorkplaceType,
                      })
                    }
                  >
                    <option value="on-site">On-site</option>
                    <option value="remote">Remote</option>
                    <option value="hybrid">Hybrid</option>
                  </select>
                </div>
              </div>

              <label className="field-label" htmlFor="job-required-skills">
                Required Skills
              </label>
              <input
                id="job-required-skills"
                className="form-input"
                value={form.required_skills}
                onChange={(event) =>
                  setForm({ ...form, required_skills: event.target.value })
                }
                placeholder="e.g. React, TypeScript, Product design"
                maxLength={2000}
                aria-describedby="job-skills-help"
              />
              <label className="field-label" htmlFor="job-preferred-skills">
                Preferred Skills
              </label>
              <input
                id="job-preferred-skills"
                className="form-input"
                value={form.preferred_skills}
                onChange={(event) =>
                  setForm({ ...form, preferred_skills: event.target.value })
                }
                placeholder="e.g. Testing, AWS, Mentoring"
                maxLength={2000}
                aria-describedby="job-skills-help"
              />
              <p className="form-help" id="job-skills-help">
                Separate skills with commas. Extra spaces and duplicate skills
                are removed when saved.
              </p>
              <label className="field-label" htmlFor="job-minimum-experience">
                Minimum Experience (years)
              </label>
              <input
                id="job-minimum-experience"
                className="form-input"
                type="number"
                min="0"
                step="any"
                inputMode="decimal"
                value={form.minimum_experience}
                onChange={(event) =>
                  setForm({ ...form, minimum_experience: event.target.value })
                }
                placeholder="e.g. 1.5"
                aria-describedby="job-experience-help"
              />
              <p className="form-help" id="job-experience-help">
                Leave blank if there is no minimum experience requirement.
              </p>

              <label className="field-label" htmlFor="job-description">
                Job description *
              </label>
              <textarea
                id="job-description"
                className="form-textarea"
                value={form.description}
                onChange={(event) =>
                  setForm({ ...form, description: event.target.value })
                }
                rows={6}
                maxLength={20000}
                required
              />

              <label className="field-label" htmlFor="job-status">
                Publication status
              </label>
              <select
                id="job-status"
                className="form-select"
                value={form.status}
                onChange={(event) =>
                  setForm({ ...form, status: event.target.value as JobStatus })
                }
              >
                <option value="draft">Save as draft</option>
                <option value="open">Publish job</option>
                <option value="paused">Paused</option>
                <option value="closed">Closed</option>
              </select>

              <div className="modal-actions">
                <button
                  type="button"
                  className="button button-secondary"
                  onClick={() => setShowForm(false)}
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
                    : editingJob
                      ? 'Save changes'
                      : 'Create job'}
                </button>
              </div>
            </form>
          </section>
        </div>
      )
  }
}
