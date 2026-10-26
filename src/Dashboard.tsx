
import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import {
  ArrowRight,
  BriefcaseBusiness,
  FileText,
  RefreshCw,
  Users,
  Plus,
  AlertCircle,
  CalendarDays,
  ClipboardCheck,
  ChartNoAxesColumnIncreasing,
} from 'lucide-react'

import { useAuth } from './auth/AuthContext'
import { supabase } from './lib/supabase'
import StatusBadge from './components/StatusBadge'
import Button from './components/Button'
import { getCurrentWorkspaceId } from './lib/workspace'

type DashboardJob = {
  id: string
  title: string
  department: string | null
  status: string
  created_at: string
}

type DashboardApplication = {
  id: string
  status: string
  applied_at: string | null
  created_at: string
  candidates: { full_name: string; email: string | null } | null
  jobs: { title: string } | null
}

type DashboardStats = {
  totalJobs: number
  openJobs: number
  totalApplications: number
  totalCandidates: number
  applicationStages: Record<ApplicationStage, number>
}

const APPLICATION_STAGES = [
  'new',
  'screening',
  'shortlisted',
  'interview',
  'rejected',
  'hired',
] as const

type ApplicationStage = (typeof APPLICATION_STAGES)[number]

const APPLICATION_STAGE_LABELS: Record<ApplicationStage, string> = {
  new: 'New',
  screening: 'Screening',
  shortlisted: 'Shortlisted',
  interview: 'Interview',
  rejected: 'Rejected',
  hired: 'Hired',
}

const EMPTY_STATS: DashboardStats = {
  totalJobs: 0,
  openJobs: 0,
  totalApplications: 0,
  totalCandidates: 0,
  applicationStages: {
    new: 0,
    screening: 0,
    shortlisted: 0,
    interview: 0,
    rejected: 0,
    hired: 0,
  },
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat('en-IN', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).format(new Date(value))
}

export default function Dashboard() {
  const { user } = useAuth()

  const [stats, setStats] = useState(EMPTY_STATS)
  const [recentJobs, setRecentJobs] = useState<DashboardJob[]>([])
  const [recentApplications, setRecentApplications] = useState<DashboardApplication[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const loadDashboard = useCallback(async () => {
    if (!user?.id) return

    if (!supabase) {
      setError('Supabase is not configured. Add your project credentials to .env.local.')
      setLoading(false)
      return
    }
    const client = supabase

    setLoading(true)
    setError('')

    try {
      const workspace = await getCurrentWorkspaceId(user.id)
      if (!workspace.workspaceId) {
        setStats(EMPTY_STATS)
        setRecentJobs([])
        setRecentApplications([])
        setError(workspace.error ?? 'Unable to load your workspace.')
        return
      }

      const workspaceId = workspace.workspaceId

      const [
        jobsResult,
        openJobsResult,
        applicationsResult,
        candidatesResult,
        recentJobsResult,
        recentApplicationsResult,
        applicationStageResults,
      ] = await Promise.all([
        client
          .from('jobs')
          .select('id', { count: 'exact', head: true })
          .eq('workspace_id', workspaceId),

        client
          .from('jobs')
          .select('id', { count: 'exact', head: true })
          .eq('workspace_id', workspaceId)
          .eq('status', 'open'),

        client
          .from('applications')
          .select('id', { count: 'exact', head: true })
          .eq('workspace_id', workspaceId),

        client
          .from('candidates')
          .select('id', { count: 'exact', head: true })
          .eq('workspace_id', workspaceId),

        client
          .from('jobs')
          .select('id, title, department, status, created_at')
          .eq('workspace_id', workspaceId)
          .order('created_at', { ascending: false })
          .limit(5),

        client
          .from('applications')
          .select(
            'id, status, applied_at, created_at, candidates(full_name, email), jobs(title)',
          )
          .eq('workspace_id', workspaceId)
          .order('applied_at', { ascending: false, nullsFirst: false })
          .order('created_at', { ascending: false })
          .limit(5),

        Promise.all(
          APPLICATION_STAGES.map((status) =>
            client
              .from('applications')
              .select('id', { count: 'exact', head: true })
              .eq('workspace_id', workspaceId)
              .eq('status', status),
          ),
        ),
      ])

      const results = [
        jobsResult,
        openJobsResult,
        applicationsResult,
        candidatesResult,
        recentJobsResult,
        recentApplicationsResult,
        ...applicationStageResults,
      ]

      const failedResult = results.find((result) => result.error)

      if (failedResult?.error) throw failedResult.error

      setStats({
        totalJobs: jobsResult.count ?? 0,
        openJobs: openJobsResult.count ?? 0,
        totalApplications: applicationsResult.count ?? 0,
        totalCandidates: candidatesResult.count ?? 0,
        applicationStages: Object.fromEntries(
          APPLICATION_STAGES.map((status, index) => [
            status,
            applicationStageResults[index].count ?? 0,
          ]),
        ) as Record<ApplicationStage, number>,
      })

      setRecentJobs((recentJobsResult.data ?? []) as DashboardJob[])
      setRecentApplications(
        (recentApplicationsResult.data ?? []) as unknown as DashboardApplication[],
      )
    } catch (caughtError) {
      setStats(EMPTY_STATS)
      setRecentJobs([])
      setRecentApplications([])
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : 'Unable to load dashboard data. Please try again.',
      )
    } finally {
      setLoading(false)
    }
  }, [user?.id])

  useEffect(() => {
    void loadDashboard()
  }, [loadDashboard])

  const firstName =
    user?.user_metadata?.full_name?.trim().split(/\s+/)[0] ||
    user?.email?.split('@')[0] ||
    'there'
  const pipelineTotal = APPLICATION_STAGES.reduce(
    (total, status) => total + stats.applicationStages[status],
    0,
  )

  return (
    <div className="dashboard-page">
      <header className="page-header dashboard-welcome">
        <div>
          <p className="eyebrow">WORKSPACE OVERVIEW</p>
          <h1>Welcome back, {firstName}</h1>
          <p className="page-description">
            Here's an overview of your recruitment activity.
          </p>
        </div>

        <div className="page-header-actions">
          <Button
            variant="secondary"
            icon={<RefreshCw size={16} />}
            onClick={() => void loadDashboard()}
            loading={loading}
          >
            Refresh
          </Button>

          <Link to="/jobs?create=true" className="button button-primary">
            <Plus size={17} />
            <span>Create job</span>
          </Link>
        </div>
      </header>

      {error && (
        <div className="dashboard-error" role="alert">
          <AlertCircle size={19} />
          <div>
            <strong>Dashboard needs attention</strong>
            <p>{error}</p>
          </div>
          <button
            type="button"
            className="icon-button"
            onClick={() => void loadDashboard()}
            aria-label="Retry loading dashboard"
          >
            <RefreshCw size={17} />
          </button>
        </div>
      )}

      <section className="overview-quick-actions" aria-label="Quick actions">
        <div>
          <span className="page-eyebrow">QUICK ACTIONS</span>
          <strong>Keep hiring moving</strong>
        </div>
        <Link to="/jobs?create=true" className="button button-primary">
          <Plus size={16} /> Create Job
        </Link>
        <Link to="/applications" state={{ from: '/dashboard' }} className="button button-secondary">
          <FileText size={16} /> Review Applications
        </Link>
        <Link to="/screening" className="button button-secondary">
          <ClipboardCheck size={16} /> Screening Queue
        </Link>
        <Link to="/interviews" className="button button-secondary">
          <CalendarDays size={16} /> Interviews
        </Link>
        <Link to="/reports" className="button button-secondary">
          <ChartNoAxesColumnIncreasing size={16} /> Reports
        </Link>
      </section>

      <section className="dashboard-stat-grid" aria-label="Recruitment metrics">
        <Link to="/jobs" className="dashboard-stat-card dashboard-stat-link">
          <div className="dashboard-stat-top">
            <span className="dashboard-stat-icon stat-icon-indigo">
              <BriefcaseBusiness size={20} />
            </span>
            <div className="dashboard-stat-title">
              <span className="dashboard-stat-label">All jobs</span>
              <span className="dashboard-stat-indicator indicator-indigo">
                Workspace
              </span>
            </div>
          </div>
          <p className="dashboard-stat-value">
            {loading || error ? '—' : stats.totalJobs}
          </p>
          <p className="dashboard-stat-footnote">
            {loading ? 'Loading records…' : error ? 'Data unavailable' : `${stats.openJobs} currently open`}
          </p>
        </Link>

        <Link to="/applications" state={{ from: '/dashboard' }} className="dashboard-stat-card dashboard-stat-link">
          <div className="dashboard-stat-top">
            <span className="dashboard-stat-icon stat-icon-blue">
              <FileText size={20} />
            </span>
            <div className="dashboard-stat-title">
              <span className="dashboard-stat-label">Applications</span>
              <span className="dashboard-stat-indicator indicator-blue">
                In pipeline
              </span>
            </div>
          </div>
          <p className="dashboard-stat-value">
            {loading || error ? '—' : stats.totalApplications}
          </p>
          <p className="dashboard-stat-footnote">Applications received</p>
        </Link>

        <Link to="/candidates" className="dashboard-stat-card dashboard-stat-link">
          <div className="dashboard-stat-top">
            <span className="dashboard-stat-icon stat-icon-violet">
              <Users size={20} />
            </span>
            <div className="dashboard-stat-title">
              <span className="dashboard-stat-label">Candidates</span>
              <span className="dashboard-stat-indicator indicator-violet">
                Talent
              </span>
            </div>
          </div>
          <p className="dashboard-stat-value">
            {loading || error ? '—' : stats.totalCandidates}
          </p>
          <p className="dashboard-stat-footnote">Candidate records in your workspace</p>
        </Link>

        <Link to="/jobs?status=open" className="dashboard-stat-card dashboard-stat-link">
          <div className="dashboard-stat-top">
            <span className="dashboard-stat-icon stat-icon-green">
              <BriefcaseBusiness size={20} />
            </span>
            <div className="dashboard-stat-title">
              <span className="dashboard-stat-label">Open positions</span>
              <span className="dashboard-stat-indicator indicator-green">
                Accepting
              </span>
            </div>
          </div>
          <p className="dashboard-stat-value">
            {loading || error ? '—' : stats.openJobs}
          </p>
          <p className="dashboard-stat-footnote">Jobs accepting applications</p>
        </Link>
      </section>

      <section
        className="dashboard-panel dashboard-pipeline"
        aria-labelledby="pipeline-title"
      >
        <div className="dashboard-panel-header">
          <div>
            <div className="dashboard-section-title">
              <span className="dashboard-section-icon stat-icon-blue">
                <Users size={17} />
              </span>
              <div>
                <h2 id="pipeline-title">Application pipeline</h2>
                <p>
                  {loading
                    ? 'Loading application stages…'
                    : error
                      ? 'Pipeline data unavailable'
                    : `${pipelineTotal} applications across your hiring stages`}
                </p>
              </div>
            </div>
          </div>
          <Link to="/applications" state={{ from: '/dashboard' }} className="text-link">
            Review pipeline <ArrowRight size={15} />
          </Link>
        </div>

        {loading ? (
          <div className="dashboard-pipeline-loading">
            <div className="skeleton-cell" />
          </div>
        ) : error ? (
          <div className="dashboard-pipeline-empty">
            <AlertCircle size={17} />
            <p>Pipeline data is unavailable until the workspace query succeeds.</p>
          </div>
        ) : pipelineTotal > 0 ? (
          <div className="dashboard-pipeline-content">
            <div
              className="pipeline-progress"
              role="img"
              aria-label={APPLICATION_STAGES.map(
                (status) =>
                  `${APPLICATION_STAGE_LABELS[status]}: ${stats.applicationStages[status]}`,
              ).join(', ')}
            >
              {APPLICATION_STAGES.map((status) => {
                const count = stats.applicationStages[status]
                if (count === 0) return null

                return (
                  <span
                    key={status}
                    className={`pipeline-progress-segment pipeline-${status}`}
                    style={{ flexGrow: count }}
                    title={`${APPLICATION_STAGE_LABELS[status]}: ${count}`}
                  />
                )
              })}
            </div>

            <div className="pipeline-stage-grid">
              {APPLICATION_STAGES.map((status) => (
                <Link
                  className="pipeline-stage"
                  key={status}
                  to={`/applications?status=${status}`}
                  state={{ from: '/dashboard' }}
                >
                  <span className={`pipeline-stage-dot pipeline-${status}`} />
                  <span className="pipeline-stage-label">
                    {APPLICATION_STAGE_LABELS[status]}
                  </span>
                  <strong>{stats.applicationStages[status]}</strong>
                </Link>
              ))}
            </div>
          </div>
        ) : (
          <div className="dashboard-pipeline-empty">
            <span className="pipeline-stage-dot pipeline-new" />
            <p>
              Applications will appear here as candidates move through your
              hiring stages.
            </p>
            <Link to="/jobs" className="text-link">
              View open jobs <ArrowRight size={15} />
            </Link>
          </div>
        )}
      </section>

      <section className="dashboard-main-grid">
        <article className="dashboard-panel">
          <div className="dashboard-panel-header">
            <div>
              <h2>Recent applications</h2>
              <p>Latest candidate submissions across your workspace.</p>
            </div>
            <Link to="/applications" state={{ from: '/dashboard' }} className="text-link">
              View all <ArrowRight size={15} />
            </Link>
          </div>

          {loading ? (
            <div className="dashboard-list-placeholder">
              <div className="skeleton-cell" />
              <div className="skeleton-cell" />
              <div className="skeleton-cell" />
            </div>
          ) : error ? (
            <div className="dashboard-empty-state">
              <AlertCircle size={25} />
              <h3>Applications unavailable</h3>
              <p>Refresh the dashboard to try loading them again.</p>
            </div>
          ) : recentApplications.length > 0 ? (
            <div className="recent-jobs-list">
              {recentApplications.map((application) => (
                <Link
                  to={`/applications?status=${application.status}`}
                  state={{ from: '/dashboard' }}
                  className="recent-job-row recent-application-row"
                  key={application.id}
                >
                  <div className="recent-job-icon">
                    <FileText size={18} />
                  </div>
                  <div className="recent-job-details">
                    <strong>
                      {application.candidates?.full_name ?? 'Candidate'}
                    </strong>
                    <span>
                      {application.jobs?.title ?? 'Job'} ·{' '}
                      {formatDate(application.applied_at ?? application.created_at)}
                    </span>
                  </div>
                  <StatusBadge status={application.status} size="small" />
                </Link>
              ))}
            </div>
          ) : (
            <div className="dashboard-empty-state">
              <FileText size={28} />
              <h3>No applications yet</h3>
              <p>Applications will appear here when candidates apply.</p>
              <Link to="/jobs" className="text-link">
                View jobs <ArrowRight size={15} />
              </Link>
            </div>
          )}
        </article>

        <article className="dashboard-panel">
          <div className="dashboard-panel-header">
            <div>
              <h2>Recent jobs</h2>
              <p>Your latest job postings and their status.</p>
            </div>
            <Link to="/jobs" className="text-link">
              View all <ArrowRight size={15} />
            </Link>
          </div>

          {loading ? (
            <div className="dashboard-list-placeholder">
              <div className="skeleton-cell" />
              <div className="skeleton-cell" />
              <div className="skeleton-cell" />
            </div>
          ) : error ? (
            <div className="dashboard-empty-state">
              <AlertCircle size={25} />
              <h3>Jobs unavailable</h3>
              <p>Refresh the dashboard to try loading them again.</p>
            </div>
          ) : recentJobs.length > 0 ? (
            <div className="recent-jobs-list">
              {recentJobs.map((job) => (
                <div className="recent-job-row" key={job.id}>
                  <div className="recent-job-icon">
                    <BriefcaseBusiness size={18} />
                  </div>

                  <div className="recent-job-details">
                    <strong>{job.title}</strong>
                    <span>
                      {job.department || 'General'} · {formatDate(job.created_at)}
                    </span>
                  </div>

                  <StatusBadge status={job.status} size="small" />
                </div>
              ))}
            </div>
          ) : (
            <div className="dashboard-empty-state">
              <BriefcaseBusiness size={28} />
              <h3>No jobs yet</h3>
              <p>Create your first job to start receiving applications.</p>
              <Link to="/jobs?create=true" className="text-link">
                Create your first job <ArrowRight size={15} />
              </Link>
            </div>
          )}
        </article>

      </section>
    </div>
  )
}
