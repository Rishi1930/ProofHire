import { supabase } from '../lib/supabase'

export type ExportJob = {
  id: string
  workspace_id: string
  title: string
  department: string | null
  location: string | null
  employment_type: string
  workplace_type: string
  description: string | null
  required_skills: string[] | null
  preferred_skills: string[] | null
  minimum_experience: number | null
  status: string
  created_at: string
}

export type ExportCandidate = {
  id: string
  workspace_id: string
  full_name: string
  email: string | null
  phone: string | null
  linkedin_url: string | null
  created_at: string
  resume_available: boolean
}

export type ExportApplication = {
  id: string
  workspace_id: string
  candidate_id: string
  job_id: string
  status: string
  source: string | null
  applied_at: string | null
  created_at: string
  resume_available: boolean
}

export type ExportDecision = {
  id: string
  workspace_id: string
  application_id: string
  decision: string
  created_at: string
}

export type ExportInterview = {
  id: string
  workspace_id: string
  application_id: string
  round_number: number
  scheduled_at: string
  interview_status: string
  outcome: string
  interviewer_name: string | null
  created_at: string
}

export type WorkspaceRecruitmentExportData = {
  jobs: ExportJob[]
  candidates: ExportCandidate[]
  applications: ExportApplication[]
  decisions: ExportDecision[]
  interviews: ExportInterview[]
  decisionsAvailable: boolean
  interviewsAvailable: boolean
  warnings: string[]
}

export type WorkbookSheet = {
  name: string
  headers: string[]
  rows: unknown[][]
  widths?: number[]
}

function requireSupabase() {
  if (!supabase) throw new Error('Supabase is not configured.')
  return supabase
}

function missingOptionalTable(error: { code?: string; message?: string }) {
  return (
    error.code === '42P01' ||
    error.code === 'PGRST205' ||
    error.message?.includes('Could not find the table')
  )
}

function appendVerifiedPage<T extends { id: string }>(
  destination: T[],
  page: T[],
  seenIds: Set<string>,
  count: number | null,
  expectedCount: number | null,
  start: number,
  pageSize: number,
  tableLabel: string,
) {
  if (count === null || (expectedCount !== null && count !== expectedCount)) {
    throw new Error(`The ${tableLabel} dataset changed during export. Retry the export.`)
  }
  const expectedPageLength = Math.min(pageSize, Math.max(0, count - start))
  if (page.length !== expectedPageLength) {
    throw new Error(`Could not retrieve all ${tableLabel} records. Retry the export.`)
  }
  if (page.some((record) => seenIds.has(record.id))) {
    throw new Error(`The ${tableLabel} dataset changed during export. Retry the export.`)
  }
  page.forEach((record) => seenIds.add(record.id))
  destination.push(...page)
  return count
}

export async function loadWorkspaceRecruitmentExportData(
  workspaceId: string,
  options: { includeDecisions?: boolean; includeInterviews?: boolean } = {},
): Promise<WorkspaceRecruitmentExportData> {
  const client = requireSupabase()
  const pageSize = 1000
  const jobs: ExportJob[] = []
  const candidates: ExportCandidate[] = []
  const applications: ExportApplication[] = []
  const jobIds = new Set<string>()
  const candidateIds = new Set<string>()
  const applicationIds = new Set<string>()

  let jobsCount: number | null = null
  for (let start = 0; ; start += pageSize) {
    const { data, error, count } = await client
      .from('jobs')
      .select(
        'id, workspace_id, title, department, location, employment_type, workplace_type, description, required_skills, preferred_skills, minimum_experience, status, created_at',
        { count: 'exact' },
      )
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .order('id', { ascending: true })
      .range(start, start + pageSize - 1)
    if (error) throw error
    const page = (data ?? []) as ExportJob[]
    jobsCount = appendVerifiedPage(
      jobs,
      page,
      jobIds,
      count,
      jobsCount,
      start,
      pageSize,
      'jobs',
    )
    if (jobs.length >= jobsCount) break
  }

  let candidatesCount: number | null = null
  for (let start = 0; ; start += pageSize) {
    const { data, error, count } = await client
      .from('candidates')
      .select(
        'id, workspace_id, full_name, email, phone, linkedin_url, created_at, resume_path',
        { count: 'exact' },
      )
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .order('id', { ascending: true })
      .range(start, start + pageSize - 1)
    if (error) throw error
    const page = (data ?? []).map((candidate) => {
      const { resume_path, ...safeCandidate } = candidate
      return {
        ...safeCandidate,
        resume_available: Boolean(resume_path),
      }
    }) as ExportCandidate[]
    candidatesCount = appendVerifiedPage(
      candidates,
      page,
      candidateIds,
      count,
      candidatesCount,
      start,
      pageSize,
      'candidates',
    )
    if (candidates.length >= candidatesCount) break
  }

  let applicationsCount: number | null = null
  for (let start = 0; ; start += pageSize) {
    const { data, error, count } = await client
      .from('applications')
      .select(
        'id, workspace_id, candidate_id, job_id, status, source, applied_at, created_at, resume_path',
        { count: 'exact' },
      )
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .order('id', { ascending: true })
      .range(start, start + pageSize - 1)
    if (error) throw error
    const page = (data ?? []).map((application) => {
      const { resume_path, ...safeApplication } = application
      return {
        ...safeApplication,
        resume_available: Boolean(resume_path),
      }
    }) as ExportApplication[]
    applicationsCount = appendVerifiedPage(
      applications,
      page,
      applicationIds,
      count,
      applicationsCount,
      start,
      pageSize,
      'applications',
    )
    if (applications.length >= applicationsCount) break
  }

  const warnings: string[] = []
  const decisions: ExportDecision[] = []
  let decisionsAvailable = false
  if (options.includeDecisions) {
    decisionsAvailable = true
    let decisionsCount: number | null = null
    const decisionIds = new Set<string>()
    for (let start = 0; ; start += pageSize) {
      const { data, error, count } = await client
        .from('application_decision_events')
        .select('id, workspace_id, application_id, decision, created_at', {
          count: 'exact',
        })
        .eq('workspace_id', workspaceId)
        .order('created_at', { ascending: false })
        .order('id', { ascending: true })
        .range(start, start + pageSize - 1)
      if (error) {
        if (missingOptionalTable(error)) {
          decisionsAvailable = false
          warnings.push(
            'Recruiter decision history is unavailable because its database migration is not present.',
          )
          break
        }
        throw error
      }
      const page = (data ?? []) as ExportDecision[]
      decisionsCount = appendVerifiedPage(
        decisions,
        page,
        decisionIds,
        count,
        decisionsCount,
        start,
        pageSize,
        'recruiter decisions',
      )
      if (decisions.length >= decisionsCount) break
    }
  }

  const interviews: ExportInterview[] = []
  let interviewsAvailable = false
  if (options.includeInterviews) {
    interviewsAvailable = true
    let interviewsCount: number | null = null
    const interviewIds = new Set<string>()
    for (let start = 0; ; start += pageSize) {
      const { data, error, count } = await client
        .from('interview_records')
        .select(
          'id, workspace_id, application_id, round_number, scheduled_at, interview_status, outcome, interviewer_name, created_at',
          { count: 'exact' },
        )
        .eq('workspace_id', workspaceId)
        .order('scheduled_at', { ascending: true })
        .order('id', { ascending: true })
        .range(start, start + pageSize - 1)
      if (error) {
        if (missingOptionalTable(error)) {
          interviewsAvailable = false
          warnings.push(
            'Interview records are unavailable because their database migration is not present.',
          )
          break
        }
        throw error
      }
      const page = (data ?? []) as ExportInterview[]
      interviewsCount = appendVerifiedPage(
        interviews,
        page,
        interviewIds,
        count,
        interviewsCount,
        start,
        pageSize,
        'interviews',
      )
      if (interviews.length >= interviewsCount) break
    }
  }

  return {
    jobs,
    candidates,
    applications,
    decisions,
    interviews,
    decisionsAvailable,
    interviewsAvailable,
    warnings,
  }
}

export function createRecruitmentWorkbookSheets(
  data: WorkspaceRecruitmentExportData,
  options: { jobId?: string; applicationIds?: Set<string> } = {},
): WorkbookSheet[] {
  const scopedApplications = data.applications.filter(
    (application) =>
      (!options.jobId || application.job_id === options.jobId) &&
      (!options.applicationIds || options.applicationIds.has(application.id)),
  )
  const scopedJobIds = new Set(scopedApplications.map((application) => application.job_id))
  const scopedJobs = options.jobId
    ? data.jobs.filter((job) => job.id === options.jobId)
    : options.applicationIds
      ? data.jobs.filter((job) => scopedJobIds.has(job.id))
      : data.jobs
  const applicationIds = new Set(scopedApplications.map((application) => application.id))
  const candidateIds = new Set(scopedApplications.map((application) => application.candidate_id))
  const jobById = new Map(data.jobs.map((job) => [job.id, job]))
  const candidateById = new Map(data.candidates.map((candidate) => [candidate.id, candidate]))
  const applicationById = new Map(scopedApplications.map((application) => [application.id, application]))
  const applicationCountByJob = new Map<string, number>()
  const applicationsByCandidate = new Map<string, ExportApplication[]>()
  for (const application of scopedApplications) {
    applicationCountByJob.set(
      application.job_id,
      (applicationCountByJob.get(application.job_id) ?? 0) + 1,
    )
    const candidateApplications = applicationsByCandidate.get(application.candidate_id) ?? []
    candidateApplications.push(application)
    applicationsByCandidate.set(application.candidate_id, candidateApplications)
  }

  const decisions = data.decisions
    .filter((decision) => applicationIds.has(decision.application_id))
    .sort((left, right) => right.created_at.localeCompare(left.created_at))
  const interviews = data.interviews
    .filter((interview) => applicationIds.has(interview.application_id))
    .sort((left, right) => left.scheduled_at.localeCompare(right.scheduled_at))
  const latestDecisionByApplication = new Map<string, ExportDecision>()
  for (const decision of decisions) {
    if (!latestDecisionByApplication.has(decision.application_id)) {
      latestDecisionByApplication.set(decision.application_id, decision)
    }
  }
  const interviewsByApplication = new Map<string, ExportInterview[]>()
  for (const interview of interviews) {
    const records = interviewsByApplication.get(interview.application_id) ?? []
    records.push(interview)
    interviewsByApplication.set(interview.application_id, records)
  }

  const statuses = ['new', 'screening', 'shortlisted', 'interview', 'hired', 'rejected']
  const summaryRows: unknown[][] = [
    ['Generated at', new Date()],
    ['Scope', options.jobId ? `Job ${options.jobId}` : 'All authorized workspace records'],
    ['Jobs', scopedJobs.length],
    ['Open jobs', scopedJobs.filter((job) => job.status === 'open').length],
    [
      'Unique candidates',
      options.jobId || options.applicationIds
        ? candidateIds.size
        : data.candidates.length,
    ],
    ['Applications', scopedApplications.length],
    ...statuses.map((status) => [
      `${status[0].toUpperCase()}${status.slice(1)} applications`,
      scopedApplications.filter((application) => application.status === status).length,
    ]),
    ['Recorded recruiter decisions', decisions.length],
    ['Recorded interview rounds', interviews.length],
    [
      'Screening assessments',
      'Not available; no persisted assessment schema or scores are configured.',
    ],
    ...data.warnings.map((warning) => ['Data availability note', warning]),
  ]

  const sheets: WorkbookSheet[] = [
    {
      name: 'Executive Summary',
      headers: ['Metric', 'Value'],
      rows: summaryRows,
      widths: [34, 70],
    },
    {
      name: 'Jobs',
      headers: [
        'Job ID',
        'Workspace ID',
        'Title',
        'Department',
        'Location',
        'Work mode',
        'Employment type',
        'Status',
        'Required skills',
        'Preferred skills',
        'Minimum experience (years)',
        'Description',
        'Created at',
        'Application count',
      ],
      rows: scopedJobs.map((job) => [
        job.id,
        job.workspace_id,
        job.title,
        job.department,
        job.location,
        job.workplace_type,
        job.employment_type,
        job.status,
        (job.required_skills ?? []).join('; '),
        (job.preferred_skills ?? []).join('; '),
        job.minimum_experience,
        job.description,
        new Date(job.created_at),
        applicationCountByJob.get(job.id) ?? 0,
      ]),
      widths: [38, 38, 32, 24, 24, 18, 20, 16, 36, 36, 24, 60, 24, 20],
    },
    {
      name: 'Applications',
      headers: [
        'Application ID',
        'Job ID',
        'Job title',
        'Candidate ID',
        'Candidate name',
        'Candidate email',
        'Candidate phone',
        'Resume attached',
        'Application date',
        'Source',
        'Current application status',
        'Latest recruiter decision',
        'Interview statuses',
        'Interview outcomes',
      ],
      rows: scopedApplications.map((application) => {
        const candidate = candidateById.get(application.candidate_id)
        const interviewRecords = interviewsByApplication.get(application.id) ?? []
        return [
          application.id,
          application.job_id,
          jobById.get(application.job_id)?.title,
          application.candidate_id,
          candidate?.full_name,
          candidate?.email,
          candidate?.phone,
          application.resume_available || candidate?.resume_available || false,
          new Date(application.applied_at ?? application.created_at),
          application.source,
          application.status,
          latestDecisionByApplication.get(application.id)?.decision,
          interviewRecords.map((interview) => interview.interview_status).join('; '),
          interviewRecords.map((interview) => interview.outcome).join('; '),
        ]
      }),
      widths: [38, 38, 32, 38, 30, 34, 22, 16, 24, 18, 28, 30, 28, 28],
    },
    {
      name: 'Candidates',
      headers: [
        'Candidate ID',
        'Workspace ID',
        'Full name',
        'Email',
        'Phone',
        'LinkedIn URL',
        'Resume attached',
        'Created at',
        'Application count',
        'Job titles',
        'Application statuses',
      ],
      rows: data.candidates
        .filter((candidate) =>
          options.jobId || options.applicationIds
            ? candidateIds.has(candidate.id)
            : true,
        )
        .map((candidate) => {
          const relatedApplications = applicationsByCandidate.get(candidate.id) ?? []
          return [
            candidate.id,
            candidate.workspace_id,
            candidate.full_name,
            candidate.email,
            candidate.phone,
            candidate.linkedin_url,
            candidate.resume_available,
            new Date(candidate.created_at),
            relatedApplications.length,
            [...new Set(relatedApplications.map((application) => jobById.get(application.job_id)?.title).filter(Boolean))].join('; '),
            relatedApplications.map((application) => `${jobById.get(application.job_id)?.title ?? application.job_id}: ${application.status}`).join('; '),
          ]
        }),
      widths: [38, 38, 30, 34, 22, 48, 16, 24, 20, 52, 64],
    },
  ]

  if (data.decisionsAvailable) {
    sheets.push({
      name: 'Recruiter Decisions',
      headers: ['Decision ID', 'Application ID', 'Job ID', 'Candidate ID', 'Decision', 'Recorded at'],
      rows: decisions.map((decision) => {
        const application = applicationById.get(decision.application_id)
        return [
          decision.id,
          decision.application_id,
          application?.job_id,
          application?.candidate_id,
          decision.decision,
          new Date(decision.created_at),
        ]
      }),
      widths: [38, 38, 38, 38, 30, 24],
    })
  }

  if (data.interviewsAvailable) {
    sheets.push({
      name: 'Interviews',
      headers: [
        'Interview ID',
        'Application ID',
        'Job ID',
        'Candidate ID',
        'Round',
        'Scheduled at',
        'Interview status',
        'Recorded outcome',
        'Interviewer',
      ],
      rows: interviews.map((interview) => {
        const application = applicationById.get(interview.application_id)
        return [
          interview.id,
          interview.application_id,
          application?.job_id,
          application?.candidate_id,
          interview.round_number,
          new Date(interview.scheduled_at),
          interview.interview_status,
          interview.outcome,
          interview.interviewer_name,
        ]
      }),
      widths: [38, 38, 38, 38, 12, 24, 22, 22, 30],
    })
  }

  sheets.push({
    name: 'Hiring Outcomes',
    headers: [
      'Application ID',
      'Job ID',
      'Job title',
      'Candidate ID',
      'Candidate name',
      'Current application status',
      'Recorded interview outcomes',
      'Latest recruiter decision',
    ],
    rows: scopedApplications
      .filter((application) => {
        const hasHiredInterview = (interviewsByApplication.get(application.id) ?? [])
          .some((interview) => interview.outcome === 'hired')
        return (
          application.status === 'hired' ||
          application.status === 'rejected' ||
          hasHiredInterview
        )
      })
      .map((application) => [
        application.id,
        application.job_id,
        jobById.get(application.job_id)?.title,
        application.candidate_id,
        candidateById.get(application.candidate_id)?.full_name,
        application.status,
        (interviewsByApplication.get(application.id) ?? [])
          .map((interview) => interview.outcome)
          .join('; '),
        latestDecisionByApplication.get(application.id)?.decision,
      ]),
    widths: [38, 38, 32, 38, 30, 28, 34, 30],
  })

  return sheets
}

export function createApplicationReportRow(
  application: ExportApplication,
  data: WorkspaceRecruitmentExportData,
) {
  return createApplicationReportRows([application], data)[0]
}

export function createApplicationReportRows(
  applications: ExportApplication[],
  data: WorkspaceRecruitmentExportData,
) {
  const jobById = new Map(data.jobs.map((job) => [job.id, job]))
  const candidateById = new Map(data.candidates.map((candidate) => [candidate.id, candidate]))
  const latestDecisionByApplication = new Map<string, ExportDecision>()
  for (const decision of [...data.decisions].sort(
    (left, right) => right.created_at.localeCompare(left.created_at),
  )) {
    if (!latestDecisionByApplication.has(decision.application_id)) {
      latestDecisionByApplication.set(decision.application_id, decision)
    }
  }
  const interviewsByApplication = new Map<string, ExportInterview[]>()
  for (const interview of data.interviews) {
    const records = interviewsByApplication.get(interview.application_id) ?? []
    records.push(interview)
    interviewsByApplication.set(interview.application_id, records)
  }
  return applications.map((application) => ({
    application,
    job: jobById.get(application.job_id),
    candidate: candidateById.get(application.candidate_id),
    latestDecision: latestDecisionByApplication.get(application.id),
    interviews: interviewsByApplication.get(application.id) ?? [],
  }))
}
