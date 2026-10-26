import { useEffect, useMemo, useState } from 'react'
import { ArrowRight, BarChart3, RefreshCw } from 'lucide-react'
import { Link, useLocation, useSearchParams } from 'react-router-dom'

import Button from '../components/Button'
import ExportActions from '../components/ExportActions'
import { useWorkspaceApplications } from './useWorkspaceApplications'
import { supabase } from '../lib/supabase'
import {
  getApplicationExportColumns,
  type ApplicationStatus,
} from './applicationData'
import { downloadCsv, downloadPdf, downloadXlsx } from '../lib/export'
import {
  createRecruitmentWorkbookSheets,
  loadWorkspaceRecruitmentExportData,
} from './exportData'

type ReportJob = {
  id: string
  title: string
  department: string | null
  status: string
}

const statuses: ApplicationStatus[] = [
  'new',
  'screening',
  'shortlisted',
  'interview',
  'hired',
  'rejected',
]

const labels: Record<ApplicationStatus, string> = {
  new: 'New',
  screening: 'Screening',
  shortlisted: 'Shortlisted',
  interview: 'Interview',
  hired: 'Hired',
  rejected: 'Rejected',
}

function applicationDate(appliedAt: string | null, createdAt: string) {
  return new Date(appliedAt ?? createdAt)
}

function getRangeStart(range: string, now: Date) {
  if (range === 'all') return null
  const days = Number(range)
  const start = new Date(now)
  start.setDate(start.getDate() - days + 1)
  start.setHours(0, 0, 0, 0)
  return start
}

function createTrend(
  records: ReturnType<typeof useWorkspaceApplications>['applications'],
  range: string,
  now: Date,
) {
  const intervalDays = range === '30' ? 1 : range === '90' ? 7 : 30
  const start = getRangeStart(range, now)
  const firstDate =
    start ??
    records.reduce<Date | null>((earliest, record) => {
      const date = applicationDate(record.applied_at, record.created_at)
      return !earliest || date < earliest ? date : earliest
    }, null)

  if (!firstDate || firstDate > now) return []
  const bucket = new Date(firstDate)
  bucket.setHours(0, 0, 0, 0)
  if (intervalDays === 30) bucket.setDate(1)
  else if (intervalDays === 7) {
    bucket.setDate(bucket.getDate() - ((bucket.getDay() + 6) % 7))
  }

  const buckets: { key: string; label: string; count: number }[] = []
  const cursor = new Date(bucket)
  while (cursor <= now) {
    const end = new Date(cursor)
    if (intervalDays === 30) end.setMonth(end.getMonth() + 1)
    else end.setDate(end.getDate() + intervalDays)
    const key =
      intervalDays === 1
        ? cursor.toISOString().slice(0, 10)
        : intervalDays === 7
          ? cursor.toISOString().slice(0, 10)
          : `${cursor.getFullYear()}-${String(cursor.getMonth() + 1).padStart(2, '0')}`
    buckets.push({
      key,
      label:
        intervalDays === 1
          ? new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(cursor)
          : intervalDays === 7
            ? new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(cursor)
            : new Intl.DateTimeFormat(undefined, { month: 'short', year: '2-digit' }).format(cursor),
      count: 0,
    })
    cursor.setTime(end.getTime())
  }

  for (const record of records) {
    const date = applicationDate(record.applied_at, record.created_at)
    const key =
      intervalDays === 1
        ? date.toISOString().slice(0, 10)
        : intervalDays === 7
          ? (() => {
              const monday = new Date(date)
              monday.setDate(monday.getDate() - ((monday.getDay() + 6) % 7))
              return monday.toISOString().slice(0, 10)
            })()
          : `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}`
    const matchingBucket = buckets.find((item) => item.key === key)
    if (matchingBucket) matchingBucket.count += 1
  }

  return buckets
}

export default function Reports() {
  const location = useLocation()
  const [searchParams, setSearchParams] = useSearchParams()
  const navigationState = location.state as {
    reportFilters?: {
      range?: string
      jobFilter?: string
      sourceFilter?: string
      stageFilter?: string
    }
  } | null
  const rememberedFilters = navigationState?.reportFilters
  const { applications, workspaceId, loading, error, reload } =
    useWorkspaceApplications()
  const [jobs, setJobs] = useState<ReportJob[]>([])
  const [jobsLoading, setJobsLoading] = useState(true)
  const [jobsError, setJobsError] = useState('')
  const [jobsRefreshKey, setJobsRefreshKey] = useState(0)
  const initialRange = searchParams.get('range')
  const validInitialRange =
    initialRange && ['30', '90', '365', 'all'].includes(initialRange)
      ? initialRange
      : rememberedFilters?.range ?? '90'
  const initialSource = searchParams.get('source')
  const initialStage = searchParams.get('status')
  const [range, setRange] = useState(validInitialRange)
  const [jobFilter, setJobFilter] = useState(
    searchParams.get('job') ?? rememberedFilters?.jobFilter ?? '',
  )
  const [sourceFilter, setSourceFilter] = useState(
    initialSource && ['public', 'non-public'].includes(initialSource)
      ? initialSource
      : rememberedFilters?.sourceFilter ?? '',
  )
  const [stageFilter, setStageFilter] = useState(
    initialStage && statuses.includes(initialStage as ApplicationStatus)
      ? initialStage
      : rememberedFilters?.stageFilter ?? '',
  )

  useEffect(() => {
    const nextRange = searchParams.get('range')
    setRange(
      nextRange && ['30', '90', '365', 'all'].includes(nextRange)
        ? nextRange
        : '90',
    )
    setJobFilter(searchParams.get('job') ?? '')
    const nextSource = searchParams.get('source')
    setSourceFilter(
      nextSource && ['public', 'non-public'].includes(nextSource)
        ? nextSource
        : '',
    )
    const nextStage = searchParams.get('status')
    setStageFilter(
      nextStage && statuses.includes(nextStage as ApplicationStatus)
        ? nextStage
        : '',
    )
  }, [location.search, searchParams])

  useEffect(() => {
    let active = true
    async function loadJobs() {
      if (!workspaceId || !supabase) {
        setJobs([])
        setJobsLoading(false)
        if (!supabase) setJobsError('Supabase is not configured.')
        return
      }
      setJobsLoading(true)
      setJobsError('')
      try {
        const rows: ReportJob[] = []
        const pageSize = 1000
        for (let start = 0; ; start += pageSize) {
          const { data, error: queryError } = await supabase
            .from('jobs')
            .select('id, title, department, status')
            .eq('workspace_id', workspaceId)
            .order('created_at', { ascending: false })
            .range(start, start + pageSize - 1)
          if (queryError) throw queryError
          rows.push(...((data ?? []) as ReportJob[]))
          if ((data ?? []).length < pageSize) break
        }
        if (active) setJobs(rows)
      } catch (caughtError) {
        if (active) {
          setJobs([])
          setJobsError(
            caughtError instanceof Error
              ? caughtError.message
              : 'Unable to load job reports.',
          )
        }
      } finally {
        if (active) setJobsLoading(false)
      }
    }
    void loadJobs()
    return () => {
      active = false
    }
  }, [jobsRefreshKey, workspaceId])

  const [now] = useState(() => new Date())
  const rangeStart = getRangeStart(range, now)
  const filteredApplications = useMemo(() => {
    return applications.filter((application) => {
      const applied = applicationDate(application.applied_at, application.created_at)
      return (
        (!rangeStart || applied >= rangeStart) &&
        (!jobFilter || application.job_id === jobFilter) &&
        (!sourceFilter ||
          (sourceFilter === 'public'
            ? application.source === 'public'
            : application.source !== 'public')) &&
        (!stageFilter || application.status === stageFilter)
      )
    })
  }, [applications, jobFilter, rangeStart, sourceFilter, stageFilter])

  const statusCounts = useMemo(
    () =>
      Object.fromEntries(
        statuses.map((status) => [
          status,
          filteredApplications.filter((application) => application.status === status).length,
        ]),
      ) as Record<ApplicationStatus, number>,
    [filteredApplications],
  )

  const visibleJobs = jobFilter ? jobs.filter((job) => job.id === jobFilter) : jobs
  const comparisonRows = useMemo(
    () =>
      visibleJobs
        .map((job) => {
          const records = filteredApplications.filter((application) => application.job_id === job.id)
          const recent = records.filter(
            (application) =>
              applicationDate(application.applied_at, application.created_at).getTime() >=
              now.getTime() - 7 * 24 * 60 * 60 * 1000,
          ).length
          return {
            ...job,
            applications: records.length,
            newCount: records.filter((record) => record.status === 'new').length,
            shortlisted: records.filter((record) => record.status === 'shortlisted').length,
            interviews: records.filter((record) => record.status === 'interview').length,
            hired: records.filter((record) => record.status === 'hired').length,
            recent,
          }
        })
        .sort((left, right) => right.applications - left.applications),
    [filteredApplications, jobs, jobFilter, now],
  )

  const trend = useMemo(
    () => createTrend(filteredApplications, range, now),
    [filteredApplications, range, now],
  )
  const trendMax = Math.max(1, ...trend.map((bucket) => bucket.count))
  const points = trend.map((bucket, index) => ({
    ...bucket,
    x: trend.length < 2 ? 50 : 4 + (index / (trend.length - 1)) * 92,
    y: 94 - (bucket.count / trendMax) * 82,
  }))
  const linePath = points
    .map((point, index) => `${index ? 'L' : 'M'} ${point.x} ${point.y}`)
    .join(' ')
  const areaPath = points.length
    ? `${linePath} L ${points[points.length - 1].x} 96 L ${points[0].x} 96 Z`
    : ''
  const outcomeTotal = statuses.reduce((total, status) => total + statusCounts[status], 0)
  let conicStart = 0
  const conicStops = statuses.map((status) => {
    const end = outcomeTotal
      ? conicStart + (statusCounts[status] / outcomeTotal) * 360
      : conicStart
    const stop = `${statusColors[status]} ${conicStart}deg ${end}deg`
    conicStart = end
    return stop
  })

  const pendingOlderThanWeek = filteredApplications.filter(
    (application) =>
      application.status === 'new' &&
      applicationDate(application.applied_at, application.created_at).getTime() <
        now.getTime() - 7 * 24 * 60 * 60 * 1000,
  ).length

  function applicationHref(status?: ApplicationStatus) {
    const parameters = new URLSearchParams()
    if (jobFilter) parameters.set('job', jobFilter)
    if (status || stageFilter) parameters.set('status', status ?? stageFilter)
    if (sourceFilter) parameters.set('source', sourceFilter)
    if (range !== 'all') parameters.set('range', range)
    const query = parameters.toString()
    return query ? `/applications?${query}` : '/applications'
  }

  function setReportFilter(key: string, value: string) {
    setSearchParams((current) => {
      const next = new URLSearchParams(current)
      if (value) next.set(key, value)
      else next.delete(key)
      return next
    })
  }

  const reportQuery = new URLSearchParams()
  if (range !== '90') reportQuery.set('range', range)
  if (jobFilter) reportQuery.set('job', jobFilter)
  if (sourceFilter) reportQuery.set('source', sourceFilter)
  if (stageFilter) reportQuery.set('status', stageFilter)
  const reportPath = reportQuery.toString()
    ? `/reports?${reportQuery.toString()}`
    : '/reports'

  const reportRangeLabel =
    range === 'all'
      ? 'all time'
      : `last ${range === '365' ? '12 months' : `${range} days`}`
  const reportFilterSummary = [
    `Date range: ${reportRangeLabel}`,
    `Job: ${visibleJobs.find((job) => job.id === jobFilter)?.title ?? 'All workspace jobs'}`,
    `Source: ${sourceFilter === 'public' ? 'Public applications' : sourceFilter ? 'Non-public applications' : 'All sources'}`,
    `Current stage: ${stageFilter ? labels[stageFilter as ApplicationStatus] : 'All stages'}`,
  ]
  const reportSummary = [
    `Jobs in the selected filter: ${visibleJobs.length}; ${visibleJobs.filter((job) => job.status === 'open').length} currently open.`,
    `Applications in selected filters: ${filteredApplications.length}.`,
    ...statuses.map((status) => `Current ${labels[status]} stage: ${statusCounts[status]}.`),
    `Applications received over time (${range === '30' ? 'daily' : range === '90' ? 'weekly' : 'monthly'} buckets): ${trend.map((bucket) => `${bucket.label}=${bucket.count}`).join(', ') || 'no applications in range'}.`,
    `Currently New for more than 7 days: ${pendingOlderThanWeek}.`,
    'Definitions: application volume counts matching records; stage counts are current-status snapshots, not historical transitions or conversion rates; dates use applied_at and fall back to created_at; the 7-day New rule is an operational threshold.',
  ]
  const reportBackState = {
    from: reportPath,
    reportFilters: { range, jobFilter, sourceFilter, stageFilter },
  }

  async function exportSupportingWorkbook() {
    if (!workspaceId) throw new Error('No active workspace is available.')
    const data = await loadWorkspaceRecruitmentExportData(workspaceId, {
      includeDecisions: true,
      includeInterviews: true,
    })
    await downloadXlsx(
      'proofhire-filtered-recruitment-report',
      createRecruitmentWorkbookSheets(data, {
        applicationIds: new Set(filteredApplications.map((application) => application.id)),
      }),
    )
  }

  const reportExportOptions = [
    {
      label: 'Export Current Report (PDF)',
      format: 'pdf' as const,
      onSelect: () =>
        downloadPdf({
          title: 'Recruitment Performance Report',
          filters: reportFilterSummary,
          summary: reportSummary,
          columns: getApplicationExportColumns(),
          rows: filteredApplications,
          filename: 'proofhire-recruitment-report',
        }),
    },
    {
      label: 'Export Supporting Data (CSV)',
      format: 'csv' as const,
      onSelect: () =>
        downloadCsv(
          'proofhire-recruitment-report-supporting-data',
          getApplicationExportColumns(),
          filteredApplications,
        ),
    },
    {
      label: 'Export Supporting Workbook (XLSX)',
      format: 'xlsx' as const,
      onSelect: exportSupportingWorkbook,
      disabled: !workspaceId,
      reason: 'The active workspace is not available.',
    },
  ]

  return (
    <section className="page-stack reports-page">
      <div className="page-heading-row">
        <div className="page-heading">
          <span className="page-eyebrow">WORKSPACE PERFORMANCE</span>
          <h1>Reports &amp; Insights</h1>
          <p>Live application and job reporting. Current-stage counts are not historical transitions.</p>
        </div>
        <Button
          variant="secondary"
          icon={<RefreshCw size={16} />}
          onClick={() => {
            void reload()
            setJobsRefreshKey((current) => current + 1)
          }}
          loading={loading || jobsLoading}
        >
          Refresh
        </Button>
      </div>

      {(error || jobsError) && (
        <div className="form-alert form-alert-error" role="alert">
          {error || jobsError}
        </div>
      )}

      <div className="reports-filters panel">
        <label>
          <span>Date range</span>
          <select className="form-select" value={range} onChange={(event) => {
            setRange(event.target.value)
            setReportFilter('range', event.target.value === '90' ? '' : event.target.value)
          }}>
            <option value="30">Last 30 days</option>
            <option value="90">Last 90 days</option>
            <option value="365">Last 12 months</option>
            <option value="all">All time</option>
          </select>
        </label>
        <label>
          <span>Job</span>
          <select className="form-select" value={jobFilter} onChange={(event) => {
            setJobFilter(event.target.value)
            setReportFilter('job', event.target.value)
          }}>
            <option value="">All workspace jobs</option>
            {jobs.map((job) => <option key={job.id} value={job.id}>{job.title}</option>)}
          </select>
        </label>
        <label>
          <span>Source</span>
          <select className="form-select" value={sourceFilter} onChange={(event) => {
            setSourceFilter(event.target.value)
            setReportFilter('source', event.target.value)
          }}>
            <option value="">All sources</option>
            <option value="public">Public applications</option>
            <option value="non-public">Non-public applications</option>
          </select>
        </label>
        <label>
          <span>Current stage</span>
          <select className="form-select" value={stageFilter} onChange={(event) => {
            setStageFilter(event.target.value)
            setReportFilter('status', event.target.value)
          }}>
            <option value="">All stages</option>
            {statuses.map((status) => <option key={status} value={status}>{labels[status]}</option>)}
          </select>
        </label>
        <small>
          Application window:{' '}
          {range === 'all'
            ? 'all time'
            : `last ${range === '365' ? '12 months' : `${range} days`}`}{' '}
          · based on applied_at, falling back to created_at.
        </small>
      </div>

      <div className="recruitment-export-toolbar">
        <p>Current report includes the selected date range, job, source, and stage filters.</p>
        <ExportActions
          scope={`${filteredApplications.length} filtered applications · ${reportRangeLabel} · ${reportFilterSummary.slice(1).join(' · ')}`}
          disabled={loading || jobsLoading || Boolean(error || jobsError)}
          options={reportExportOptions}
        />
      </div>

      <div className="metric-grid reports-kpi-grid">
        <Link
          to={jobFilter ? `/jobs/${jobFilter}/hiring` : '/jobs'}
          state={reportBackState}
          className="metric-card report-metric-link"
        >
          <span>{jobFilter ? 'Selected job' : 'Total jobs'}</span>
          <strong>{jobsLoading || jobsError ? '—' : jobFilter ? visibleJobs.length : jobs.length}</strong>
          <small>{jobsLoading || jobsError ? 'Data unavailable' : `${jobs.filter((job) => job.status === 'open' && (!jobFilter || job.id === jobFilter)).length} open`}</small>
        </Link>
        <Link to={applicationHref()} state={reportBackState} className="metric-card report-metric-link">
          <span>Applications received</span>
          <strong>{loading || error ? '—' : filteredApplications.length}</strong>
          <small>In selected filters</small>
        </Link>
        <Link to={applicationHref('new')} state={reportBackState} className="metric-card report-metric-link">
          <span>Awaiting screening</span>
          <strong>{loading || error ? '—' : statusCounts.new}</strong>
          <small>Currently in new stage</small>
        </Link>
        <Link to={applicationHref('shortlisted')} state={reportBackState} className="metric-card report-metric-link">
          <span>Shortlisted</span>
          <strong>{loading || error ? '—' : statusCounts.shortlisted}</strong>
          <small>Current application stage</small>
        </Link>
        <Link to={applicationHref('interview')} state={reportBackState} className="metric-card report-metric-link">
          <span>Interview stage</span>
          <strong>{loading || error ? '—' : statusCounts.interview}</strong>
          <small>Scheduling is not tracked</small>
        </Link>
        <Link to={applicationHref('hired')} state={reportBackState} className="metric-card report-metric-link">
          <span>Hired</span>
          <strong>{loading || error ? '—' : statusCounts.hired}</strong>
          <small>Current application stage</small>
        </Link>
      </div>

      <div className="reports-chart-grid">
        <article className="panel report-chart-panel">
          <header className="recruitment-list-header">
            <div>
              <h2>Applications received over time</h2>
              <p>Count of application records by {range === '30' ? 'day' : range === '90' ? 'week' : 'month'}.</p>
            </div>
          </header>
          {loading ? (
            <div className="empty-state"><span className="loading-spinner" /><p>Loading trend...</p></div>
          ) : trend.length === 0 ? (
            <div className="empty-state"><p>No applications in this date range.</p></div>
          ) : (
            <>
              <svg className="report-line-chart" viewBox="0 0 100 100" role="img" aria-label="Applications received over time">
                {[20, 45, 70, 95].map((y) => <line key={y} x1="4" x2="96" y1={y} y2={y} className="report-chart-gridline" />)}
                <path d={areaPath} className="report-chart-area" />
                <path d={linePath} className="report-chart-line" />
                {points.map((point) => (
                  <circle key={point.key} cx={point.x} cy={point.y} r="1.4" className="report-chart-point">
                    <title>{point.label}: {point.count} applications</title>
                  </circle>
                ))}
              </svg>
              <div className="report-chart-axis">
                <span>{trend[0].label}</span>
                <span>{trend[Math.floor(trend.length / 2)].label}</span>
                <span>{trend[trend.length - 1].label}</span>
              </div>
            </>
          )}
        </article>

        <article className="panel report-chart-panel">
          <header className="recruitment-list-header">
            <div>
              <h2>Current application outcomes</h2>
              <p>Distribution by each record's current status.</p>
            </div>
          </header>
          {loading ? (
            <div className="empty-state"><span className="loading-spinner" /><p>Loading outcomes...</p></div>
          ) : outcomeTotal === 0 ? (
            <div className="empty-state"><p>No applications match these filters.</p></div>
          ) : (
            <div className="report-outcome-chart">
              <div className="report-donut" style={{ background: `conic-gradient(${conicStops.join(', ')})` }}>
                <div><strong>{outcomeTotal}</strong><span>applications</span></div>
              </div>
              <div className="report-outcome-legend">
                {statuses.map((status) => (
                  <Link key={status} to={applicationHref(status)} state={reportBackState} className="report-outcome-item">
                    <span style={{ background: statusColors[status] }} />
                    {labels[status]} <strong>{statusCounts[status]}</strong>
                  </Link>
                ))}
              </div>
            </div>
          )}
        </article>
      </div>

      <article className="panel">
        <header className="recruitment-list-header">
          <div>
            <h2>Job performance comparison</h2>
            <p>Application volume uses selected filters; recent count is the last 7 days.</p>
          </div>
          {jobFilter && <Link to={`/jobs/${jobFilter}/hiring`} state={reportBackState} className="text-link">Open hiring workspace <ArrowRight size={15} /></Link>}
        </header>
        {jobsLoading || loading ? (
          <div className="empty-state"><span className="loading-spinner" /><p>Loading job comparisons...</p></div>
        ) : comparisonRows.length === 0 ? (
          <div className="empty-state"><p>No jobs found for the selected filters.</p></div>
        ) : (
          <div className="table-scroll">
            <table className="data-table report-jobs-table">
              <thead>
                <tr><th>Job</th><th>Applications</th><th>New</th><th>Shortlisted</th><th>Interview stage</th><th>Hired</th><th>Last 7 days</th></tr>
              </thead>
              <tbody>
                {comparisonRows.map((job) => (
                  <tr key={job.id}>
                    <td><Link to={`/jobs/${job.id}/hiring`}><strong>{job.title}</strong></Link><span className="table-secondary">{job.department || 'General'} · {job.status}</span></td>
                    <td>{job.applications}</td>
                    <td>{job.newCount}</td>
                    <td>{job.shortlisted}</td>
                    <td>{job.interviews}</td>
                    <td>{job.hired}</td>
                    <td>{job.recent}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </article>

      <div className="info-banner">
        <BarChart3 size={19} />
        <div>
          <strong>Data definitions and limitations</strong>
          <p>
            Funnel-like stage counts are a snapshot of each application's single current status, not historical transitions or conversion rates. Screening outcomes, match percentages, interview schedules, invitations, and feedback are not stored in the current schema. Aged review count uses an explicitly operational 7-day rule for applications currently marked New.
            {pendingOlderThanWeek > 0 && !loading ? ` ${pendingOlderThanWeek} currently-new applications are older than 7 days.` : ''}
          </p>
        </div>
      </div>
    </section>
  )
}

const statusColors: Record<ApplicationStatus, string> = {
  new: '#3478d4',
  screening: '#3eb6e8',
  shortlisted: '#18a56b',
  interview: '#e2ac18',
  hired: '#14a16b',
  rejected: '#e2535b',
}
