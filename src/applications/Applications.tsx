
import { useEffect, useState } from 'react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'
import {
  ArrowLeft,
  FileUp,
  FileText,
  Search,
  Users,
  RefreshCw,
} from 'lucide-react'

import { supabase } from '../lib/supabase'
import Button from '../components/Button'
import ExportActions from '../components/ExportActions'
import RecruitmentApplicationList from '../recruitment/RecruitmentApplicationList'
import {
  applicationStatuses,
  getApplicationExportColumns,
  type ApplicationStatus,
} from '../recruitment/applicationData'
import { useWorkspaceApplications } from '../recruitment/useWorkspaceApplications'
import { downloadCsv, downloadXlsx } from '../lib/export'
import {
  createRecruitmentWorkbookSheets,
  loadWorkspaceRecruitmentExportData,
} from '../recruitment/exportData'

type JobOption = {
  id: string
  title: string
  status: string
}

function errorText(error: unknown) {
  return error instanceof Error ? error.message : 'Something went wrong.'
}

export default function Applications() {
  const location = useLocation()
  const [searchParams, setSearchParams] = useSearchParams()
  const {
    applications,
    workspaceId,
    loading: applicationsLoading,
    error: applicationsError,
    reload,
    updateStatus,
  } = useWorkspaceApplications()

  const [jobs, setJobs] = useState<JobOption[]>([])
  const [selectedJobId, setSelectedJobId] = useState(
    searchParams.get('job') ?? '',
  )
  const [selectedStatus, setSelectedStatus] = useState(
    searchParams.get('status') ?? '',
  )
  const [selectedSource, setSelectedSource] = useState(
    searchParams.get('source') ?? '',
  )
  const [selectedRange, setSelectedRange] = useState(() => {
    const value = searchParams.get('range') ?? ''
    return ['', '30', '90', '365'].includes(value) ? value : ''
  })
  const [rangeNow] = useState(() => new Date())
  const navigationState = location.state as {
    from?: unknown
    reportFilters?: {
      range?: string
      jobFilter?: string
      sourceFilter?: string
      stageFilter?: string
    }
  } | null
  const reportFilters = navigationState?.reportFilters
  const returnTo =
    typeof navigationState?.from === 'string' &&
    navigationState.from.startsWith('/') &&
    !navigationState.from.startsWith('//')
      ? navigationState.from
      : '/jobs'
  const returnLabel = returnTo.startsWith('/reports')
    ? 'Back to Reports & Insights'
    : returnTo.startsWith('/dashboard')
      ? 'Back to Overview'
      : returnTo.startsWith('/screening')
        ? 'Back to Resume Screening'
        : 'Back to Jobs & Hiring'
  const [search, setSearch] = useState(searchParams.get('q') ?? '')
  const [loading, setLoading] = useState(true)
  const [errorMessage, setErrorMessage] = useState('')
  const [successMessage, setSuccessMessage] = useState('')

  useEffect(() => {
    setSelectedJobId(searchParams.get('job') ?? '')
    setSelectedStatus(searchParams.get('status') ?? '')
    setSelectedSource(searchParams.get('source') ?? '')
    const range = searchParams.get('range') ?? ''
    setSelectedRange(['', '30', '90', '365'].includes(range) ? range : '')
    setSearch(searchParams.get('q') ?? '')
  }, [location.search, searchParams])

  useEffect(() => {
    if (workspaceId) void loadRecruiterJobs(workspaceId)
  }, [workspaceId])

  async function loadRecruiterJobs(activeWorkspaceId: string) {
    setLoading(true)
    setErrorMessage('')

    if (!supabase) {
      setErrorMessage('Configure Supabase to manage applications.')
      setLoading(false)
      return
    }

    try {
      const jobRows: JobOption[] = []
      const pageSize = 1000
      for (let start = 0; ; start += pageSize) {
        const { data, error } = await supabase
          .from('jobs')
          .select('id, title, status')
          .eq('workspace_id', activeWorkspaceId)
          .order('created_at', { ascending: false })
          .range(start, start + pageSize - 1)
        if (error) throw error
        const page = (data ?? []) as JobOption[]
        jobRows.push(...page)
        if (page.length < pageSize) break
      }
      setJobs(jobRows)
    } catch (error) {
      setErrorMessage(errorText(error))
      setJobs([])
    }

    setLoading(false)
  }

  const rangeDays = Number(selectedRange)
  const rangeStart =
    selectedRange && selectedRange !== 'all'
      ? new Date(rangeNow.getTime() - (rangeDays - 1) * 24 * 60 * 60 * 1000)
      : null
  if (rangeStart) rangeStart.setHours(0, 0, 0, 0)

  const visibleApplications = applications.filter((application) => {
    const query = search.trim().toLowerCase()
    const matchesSearch =
      (application.candidates?.full_name ?? '').toLowerCase().includes(query) ||
      (application.candidates?.email ?? '').toLowerCase().includes(query) ||
      (application.jobs?.title ?? '').toLowerCase().includes(query)
    const matchesJob = !selectedJobId || application.job_id === selectedJobId
    const matchesStatus =
      !selectedStatus || application.status === selectedStatus
    const matchesSource =
      !selectedSource ||
      (selectedSource === 'public'
        ? application.source === 'public'
        : application.source !== 'public')
    const matchesRange =
      !rangeStart ||
      new Date(application.applied_at ?? application.created_at) >= rangeStart

    return matchesSearch && matchesJob && matchesStatus && matchesSource && matchesRange
  })
  const activeApplicationFilters = [
    search.trim() ? `search "${search.trim()}"` : '',
    selectedJobId
      ? `job ${jobs.find((job) => job.id === selectedJobId)?.title ?? selectedJobId}`
      : '',
    selectedStatus ? `status ${selectedStatus}` : '',
    selectedSource
      ? selectedSource === 'public'
        ? 'public source'
        : 'non-public source'
      : '',
    selectedRange ? `last ${selectedRange === '365' ? '12 months' : `${selectedRange} days`}` : '',
  ].filter(Boolean)
  const filteredApplicationsScope =
    `filtered applications · ${visibleApplications.length} of ${applications.length}` +
    (activeApplicationFilters.length
      ? ` · ${activeApplicationFilters.join(', ')}`
      : '')

  async function exportApplicationsWorkbook(filtered: boolean) {
    if (!workspaceId) throw new Error('No active workspace is available.')
    const data = await loadWorkspaceRecruitmentExportData(workspaceId, {
      includeDecisions: true,
      includeInterviews: true,
    })
    await downloadXlsx(
      `proofhire-${filtered ? 'filtered' : 'workspace'}-recruitment-workbook`,
      createRecruitmentWorkbookSheets(
        data,
        filtered
          ? { applicationIds: new Set(visibleApplications.map((application) => application.id)) }
          : {},
      ),
    )
  }

  const applicationExportOptions = [
    {
      label: 'Export Filtered Applications (CSV)',
      format: 'csv' as const,
      onSelect: () =>
        downloadCsv(
          'proofhire-applications-filtered',
          getApplicationExportColumns(),
          visibleApplications,
        ),
      disabled: applicationsLoading || Boolean(applicationsError),
      reason: applicationsError || 'Applications are still loading.',
    },
    {
      label: 'Export All Workspace Applications (CSV)',
      format: 'csv' as const,
      onSelect: () =>
        downloadCsv(
          'proofhire-applications-all',
          getApplicationExportColumns(),
          applications,
        ),
      disabled: applicationsLoading || Boolean(applicationsError),
      reason: applicationsError || 'Applications are still loading.',
    },
    {
      label: 'Export Filtered Recruitment Workbook (XLSX)',
      format: 'xlsx' as const,
      onSelect: () => exportApplicationsWorkbook(true),
      disabled: applicationsLoading || Boolean(applicationsError) || !workspaceId,
      reason: applicationsError || 'Workspace data is still loading.',
    },
    {
      label: 'Export Complete Recruitment Workbook (XLSX)',
      format: 'xlsx' as const,
      onSelect: () => exportApplicationsWorkbook(false),
      disabled: applicationsLoading || Boolean(applicationsError) || !workspaceId,
      reason: applicationsError || 'Workspace data is still loading.',
    },
  ]

  async function handleStatusChange(
    applicationId: string,
    status: ApplicationStatus,
  ) {
    await updateStatus(applicationId, status)
    setSuccessMessage(`Application status updated to ${status}.`)
  }

  return (
    <section className="page-stack">
      <div className="page-heading-row">
        <div className="page-heading">
          <Link
            to={returnTo}
            state={
              returnTo.startsWith('/reports') && reportFilters
                ? { reportFilters }
                : undefined
            }
            className="text-link"
          >
            <ArrowLeft size={15} />
            {returnLabel}
          </Link>
          <span className="page-eyebrow">RECRUITMENT WORKSPACE</span>
          <h1>Applications</h1>
          <p>Review applications received for your published roles.</p>
        </div>
        <Link to="/candidates" className="button button-secondary">
          <Users size={17} />
          Candidate database
        </Link>
      </div>

      {(errorMessage || applicationsError) && (
        <div className="form-alert form-alert-error" role="alert">
          {errorMessage || applicationsError}
        </div>
      )}
      {successMessage && (
        <div className="form-alert form-alert-success" role="status">
          {successMessage}
        </div>
      )}

      <div className="recruitment-export-toolbar">
        <p>CSV and workbook exports exclude private resume paths and signed URLs.</p>
        <ExportActions
          scope={filteredApplicationsScope}
          disabled={applicationsLoading || Boolean(applicationsError)}
          options={applicationExportOptions}
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
              placeholder="Search candidate or job"
              aria-label="Search applications"
            />
          </div>

          <select
            className="form-select filter-select"
            value={selectedJobId}
            onChange={(event) => {
              const value = event.target.value
              setSelectedJobId(value)
              setSearchParams((current) => {
                const next = new URLSearchParams(current)
                if (value) next.set('job', value)
                else next.delete('job')
                return next
              })
            }}
            aria-label="Filter by job"
          >
            <option value="">All jobs</option>
            {jobs.map((job) => (
              <option key={job.id} value={job.id}>
                {job.title}
              </option>
            ))}
          </select>
          <select
            className="form-select filter-select"
            value={selectedStatus}
            onChange={(event) => {
              const value = event.target.value
              setSelectedStatus(value)
              setSearchParams((current) => {
                const next = new URLSearchParams(current)
                if (value) next.set('status', value)
                else next.delete('status')
                return next
              })
            }}
            aria-label="Filter by application status"
          >
            <option value="">All statuses</option>
            {applicationStatuses.map((status) => (
              <option key={status} value={status}>
                {status.charAt(0).toUpperCase() + status.slice(1)}
              </option>
            ))}
          </select>
          <select
            className="form-select filter-select"
            value={selectedSource}
            onChange={(event) => {
              const value = event.target.value
              setSelectedSource(value)
              setSearchParams((current) => {
                const next = new URLSearchParams(current)
                if (value) next.set('source', value)
                else next.delete('source')
                return next
              })
            }}
            aria-label="Filter by source"
          >
            <option value="">All sources</option>
            <option value="public">Public link</option>
            <option value="non-public">Non-public</option>
          </select>
          <select
            className="form-select filter-select"
            value={selectedRange}
            onChange={(event) => {
              const value = event.target.value
              setSelectedRange(value)
              setSearchParams((current) => {
                const next = new URLSearchParams(current)
                if (value) next.set('range', value)
                else next.delete('range')
                return next
              })
            }}
            aria-label="Filter by date range"
          >
            <option value="">All dates</option>
            <option value="30">Last 30 days</option>
            <option value="90">Last 90 days</option>
            <option value="365">Last 12 months</option>
          </select>
          <Button
            variant="secondary"
            icon={<RefreshCw size={16} />}
            onClick={() => void reload()}
            loading={applicationsLoading}
          >
            Refresh
          </Button>
        </div>

        {applicationsLoading || (loading && Boolean(workspaceId)) ? (
          <div className="empty-state">
            <span className="loading-spinner" />
            <p>Loading applications...</p>
          </div>
        ) : visibleApplications.length === 0 ? (
          <div className="empty-state">
            <span className="empty-state-icon">
              <FileText size={23} />
            </span>
            <h3>
              {applicationsError
                ? 'Applications unavailable'
                : applications.length
                  ? 'No matching applications'
                  : 'No applications yet'}
            </h3>
            <p>
              {applicationsError
                ? 'Resolve the workspace query error above and refresh to try again.'
                : applications.length
                  ? 'Try changing or clearing your filters.'
                  : 'Applications submitted through your public job links will appear here.'}
            </p>
            {applications.length ? (
              <button
                type="button"
                className="button button-secondary"
                onClick={() => {
                  setSelectedJobId('')
                  setSelectedStatus('')
                  setSelectedSource('')
                  setSelectedRange('')
                  setSearch('')
                  setSearchParams({})
                }}
              >
                Clear filters
              </button>
            ) : (
              <Link to="/jobs" className="button button-primary">
                <ArrowLeft size={16} />
                View jobs
              </Link>
            )}
          </div>
        ) : (
          <RecruitmentApplicationList
            applications={visibleApplications}
            onStatusChange={handleStatusChange}
          />
        )}
      </div>

      <div className="info-banner">
        <FileUp size={19} />
        <div>
          <strong>Private resume access and imports</strong>
          <p>
            Authorized workspace members can open resumes through short-lived,
            private links. Bulk CSV imports are not available yet.
          </p>
        </div>
      </div>
    </section>
  )
}
