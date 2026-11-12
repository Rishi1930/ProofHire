import { supabase } from '../lib/supabase'
import type { ExportColumn } from '../lib/export'
import {
  applicationStatuses,
  updateApplicationStatus,
  type ApplicationStatus,
} from '../candidates/CandidateDatabase'
import {
  createSafeFilename,
  getFileExtension,
  isAllowedResumeFile,
} from '../lib/utils'

const RESUME_BUCKET = 'candidate-resumes'
const RESUME_MIME_TYPES: Record<string, string> = {
  pdf: 'application/pdf',
  doc: 'application/msword',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
}

export type ApplicationRecord = {
  id: string
  workspace_id: string
  candidate_id: string
  job_id: string
  status: ApplicationStatus
  source: string | null
  applied_at: string | null
  created_at: string
  resume_path: string | null
  resume_profile?: {
    education?: string
    skills?: string[]
    experience_years?: number | null
    experience?: Array<{ company: string; role: string }>
    experience_summary?: string
  } | null
  resume_available?: boolean
  candidates: {
    full_name: string
    email: string | null
    phone: string | null
    linkedin_url: string | null
    resume_path: string | null
  } | null
  jobs: {
    title: string
    department: string | null
  } | null
}

export { applicationStatuses }
export type { ApplicationStatus }

export type RecruiterDecision =
  | 'shortlist'
  | 'reject'
  | 'advance_to_interview'
  | 'return_to_screening'
  | 'mark_hired'

export type ScreeningRequirementFinding = {
  requirement_key: string
  status:
    | 'supported'
    | 'partially_supported'
    | 'evidence_missing'
    | 'not_met'
    | 'unable_to_determine'
  explanation: string
  evidence: Array<{ excerpt: string; source: string }>
  confidence: 'high' | 'medium' | 'low'
}

export type ScreeningReport = {
  summary: string
  recommendation: 'strong_match' | 'review' | 'needs_more_information'
  confidence: 'high' | 'medium' | 'low'
  strengths: string[]
  potential_gaps: string[]
  missing_evidence: string[]
  follow_up_questions: string[]
  findings: ScreeningRequirementFinding[]
  evidence_coverage: number
  scoring_method: string
  category_scores?: Array<{
    category: string
    earned_weight: number
    available_weight: number
    score: number
  }>
  matched_requirements?: string[]
  partially_matched_requirements?: string[]
  unmatched_requirements?: string[]
  parsing_status?: string
  resume_format?: string
  resume_sha256?: string
  screened_at?: string
  engine_version?: string
  minimum_threshold?: number
  threshold_met?: boolean
}

export type ScreeningCriteria = {
  summary?: string
  experience_mandatory?: boolean
  clarifications?: string[]
  requirements: Array<{
    key: string
    name: string
    description: string
    priority: 'mandatory' | 'preferred'
    category: string
    weight?: number
  }>
}

export type ApplicationScreeningOverview = {
  application_id: string
  screening_status:
    | 'not_queued'
    | 'pending'
    | 'processing'
    | 'retry_wait'
    | 'waiting_configuration'
    | 'completed'
    | 'failed'
    | 'superseded'
  attempts: number
  failure_reason: string | null
  last_error_code: string | null
  assessment_id: string | null
  assessment_version: number | null
  match_score: number | null
  report: ScreeningReport | null
  criteria: ScreeningCriteria | null
  assessed_at: string | null
}

export function getApplicationExportColumns(
  decisions?: Map<string, string>,
): ExportColumn<ApplicationRecord>[] {
  const columns: ExportColumn<ApplicationRecord>[] = [
    { header: 'Application ID', value: (record) => record.id },
    { header: 'Candidate name', value: (record) => record.candidates?.full_name },
    { header: 'Candidate email', value: (record) => record.candidates?.email },
    { header: 'Candidate phone', value: (record) => record.candidates?.phone },
    { header: 'Job title', value: (record) => record.jobs?.title },
    {
      header: 'Application date',
      value: (record) => record.applied_at ?? record.created_at,
    },
    { header: 'Status', value: (record) => record.status },
    { header: 'Source', value: (record) => record.source },
    {
      header: 'Resume attached',
      value: (record) => Boolean(record.resume_available || record.resume_path),
    },
  ]
  if (decisions) {
    columns.push({
      header: 'Latest recruiter decision',
      value: (record) => decisions.get(record.id) ?? '',
    })
  }
  return columns
}

function requireSupabase() {
  if (!supabase) throw new Error('Supabase is not configured.')
  return supabase
}

export async function getApplicationScreeningOverview(
  workspaceId: string,
  applicationIds: string[],
): Promise<ApplicationScreeningOverview[]> {
  if (applicationIds.length === 0) return []
  const client = requireSupabase()
  const records: ApplicationScreeningOverview[] = []
  for (let start = 0; start < applicationIds.length; start += 100) {
    const { data, error } = await client.rpc('get_application_screening_overview', {
      target_workspace_id: workspaceId,
      target_application_ids: applicationIds.slice(start, start + 100),
    })
    if (error) throw error
    records.push(...((data ?? []) as unknown as ApplicationScreeningOverview[]))
  }
  return records
}

export async function requestApplicationScreening(
  applicationId: string,
): Promise<void> {
  const { error } = await requireSupabase().rpc(
    'request_application_screening',
    { target_application_id: applicationId },
  )
  if (error) throw error
}

export async function uploadResumeForJob(
  workspaceId: string,
  jobId: string,
  file: File,
): Promise<string> {
  if (!isAllowedResumeFile(file)) {
    throw new Error('Choose a non-empty PDF, DOC, or DOCX resume up to 5 MB.')
  }

  const extension = getFileExtension(file.name)
  const contentType = RESUME_MIME_TYPES[extension]
  if (!contentType) throw new Error('The selected resume format is unsupported.')

  const resumePath = `${workspaceId}/${jobId}/${crypto.randomUUID()}-${createSafeFilename(file.name)}`
  const { error } = await requireSupabase()
    .storage.from(RESUME_BUCKET)
    .upload(resumePath, file, { contentType, upsert: false })

  if (error) throw new Error(`Resume upload failed: ${error.message}`)
  return resumePath
}

export async function attachResumeToApplication(
  workspaceId: string,
  applicationId: string,
  jobId: string,
  resumePath: string,
): Promise<void> {
  const pathParts = resumePath.split('/')
  if (
    pathParts.length !== 3 ||
    pathParts[0] !== workspaceId ||
    pathParts[1] !== jobId ||
    !/^[0-9a-f-]{36}$/i.test(jobId) ||
    !/^[A-Za-z0-9_-]+\.(pdf|doc|docx)$/i.test(pathParts[2])
  ) {
    throw new Error('The uploaded resume is not scoped to this workspace and job.')
  }

  const { data, error } = await requireSupabase()
    .from('applications')
    .update({ resume_path: resumePath })
    .eq('id', applicationId)
    .eq('workspace_id', workspaceId)
    .eq('job_id', jobId)
    .is('resume_path', null)
    .select('id')
    .maybeSingle()

  if (error) throw error
  if (!data) {
    throw new Error(
      'This application already has a resume or is no longer available. Refresh before trying again.',
    )
  }
}

export async function getWorkspaceApplications(
  workspaceId: string,
): Promise<ApplicationRecord[]> {
  const client = requireSupabase()
  const records: ApplicationRecord[] = []
  const pageSize = 1000

  for (let start = 0; ; start += pageSize) {
    const { data, error } = await client
      .from('applications')
  .select(`
    id,
    workspace_id,
    candidate_id,
    job_id,
    status,
    source,
    applied_at,
    created_at,
    resume_path,
    resume_profile,
    candidates!applications_candidate_id_fkey(
      full_name,
      email,
      phone,
      linkedin_url,
      resume_path
    ),
    jobs!applications_job_id_fkey(
      title,
      department
    )
  `)
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .range(start, start + pageSize - 1)

    if (error) throw error
    const page = (data ?? []) as unknown as ApplicationRecord[]
    records.push(...page)
    if (page.length < pageSize) return records
  }
}

export type ApplicationDecisionEvent = {
  id: string
  application_id: string
  workspace_id: string
  decision: RecruiterDecision
  note: string | null
  created_by: string | null
  created_at: string
}

export async function getDecisionEvents(
  workspaceId: string,
  applicationIds?: string[],
): Promise<ApplicationDecisionEvent[]> {
  if (applicationIds && applicationIds.length === 0) return []
  const client = requireSupabase()
  if (!applicationIds) {
    const { data, error } = await client
      .from('application_decision_events')
      .select(
        'id, application_id, workspace_id, decision, note, created_by, created_at',
      )
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .limit(100)
    if (error) throw error
    return (data ?? []) as ApplicationDecisionEvent[]
  }

  const events: ApplicationDecisionEvent[] = []
  for (let start = 0; start < applicationIds.length; start += 100) {
    const applicationBatch = applicationIds.slice(start, start + 100)
    for (let pageStart = 0; ; pageStart += 1000) {
      const { data, error } = await client
        .from('application_decision_events')
        .select(
          'id, application_id, workspace_id, decision, note, created_by, created_at',
        )
        .eq('workspace_id', workspaceId)
        .in('application_id', applicationBatch)
        .order('created_at', { ascending: false })
        .range(pageStart, pageStart + 999)
      if (error) throw error
      const page = (data ?? []) as ApplicationDecisionEvent[]
      events.push(...page)
      if (page.length < 1000) break
    }
  }
  return events
    .sort((left, right) => right.created_at.localeCompare(left.created_at))
}

export async function changeApplicationStatus(
  workspaceId: string,
  applicationId: string,
  status: ApplicationStatus,
): Promise<void> {
  await updateApplicationStatus(workspaceId, applicationId, status)
}

export async function recordRecruiterDecision(
  applicationId: string,
  decision: RecruiterDecision,
  note?: string,
): Promise<void> {
  const { data, error } = await requireSupabase().rpc(
    'record_application_decision',
    {
      target_application_id: applicationId,
      target_decision: decision,
      target_note: note?.trim() || null,
    },
  )

  if (error) throw error
  if (!data) throw new Error('The recruiter decision was not recorded.')
}

export async function getResumeSignedUrl(
  resumePath: string,
): Promise<string> {
  const { data, error } = await requireSupabase()
    .storage.from('candidate-resumes')
    .createSignedUrl(resumePath, 60)

  if (error) throw error
  return data.signedUrl
}
