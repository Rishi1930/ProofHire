import { supabase } from '../lib/supabase'
import type { ExportColumn } from '../lib/export'
import {
  applicationStatuses,
  updateApplicationStatus,
  type ApplicationStatus,
} from '../candidates/CandidateDatabase'

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
      value: (record) =>
        Boolean(
          record.resume_available ||
            record.resume_path ||
            record.candidates?.resume_path,
        ),
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

export async function getWorkspaceApplications(
  workspaceId: string,
): Promise<ApplicationRecord[]> {
  const client = requireSupabase()
  const records: ApplicationRecord[] = []
  const pageSize = 1000

  for (let start = 0; ; start += pageSize) {
    const { data, error } = await client
      .from('applications')
      .select(
        'id, workspace_id, candidate_id, job_id, status, source, applied_at, created_at, resume_path, candidates(full_name, email, phone, linkedin_url, resume_path), jobs(title, department)',
      )
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
  created_by: string
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
