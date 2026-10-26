import { supabase } from '../lib/supabase'

export type ApplicationStatus =
  | 'new'
  | 'screening'
  | 'shortlisted'
  | 'rejected'
  | 'interview'
  | 'hired'

export type Candidate = {
  id: string
  workspace_id: string
  full_name: string
  email: string | null
  phone: string | null
  linkedin_url: string | null
  created_by: string | null
  created_at: string
  updated_at: string
}

export type CandidateApplication = {
  id: string
  workspace_id: string
  candidate_id: string
  job_id: string
  status: ApplicationStatus
  created_at: string
  jobs: { title: string } | null
}

export type CandidateWithApplications = Candidate & {
  applications: CandidateApplication[]
}

export type CandidateFormValues = {
  full_name: string
  email: string
  phone: string
  linkedin_url: string
}

export const applicationStatuses: ApplicationStatus[] = [
  'new',
  'screening',
  'shortlisted',
  'rejected',
  'interview',
  'hired',
]

export function validateCandidate(values: CandidateFormValues) {
  const fullName = values.full_name.trim()
  const email = values.email.trim()
  const phone = values.phone.trim()
  const linkedinUrl = values.linkedin_url.trim()

  if (fullName.length < 2 || fullName.length > 180) {
    throw new Error('Full name must be between 2 and 180 characters.')
  }

  if (email && (email.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email))) {
    throw new Error('Enter a valid email address or leave it blank.')
  }

  if (phone.length > 40) {
    throw new Error('Phone number must be 40 characters or fewer.')
  }

  if (linkedinUrl) {
    try {
      const parsedUrl = new URL(linkedinUrl)
      if (
        parsedUrl.protocol !== 'https:' ||
        !['linkedin.com', 'www.linkedin.com'].includes(parsedUrl.hostname)
      ) {
        throw new Error()
      }
    } catch {
      throw new Error('Enter a valid LinkedIn profile URL starting with https://.')
    }
  }

  return {
    full_name: fullName,
    email: email.toLowerCase() || null,
    phone: phone || null,
    linkedin_url: linkedinUrl || null,
  }
}

function requireSupabase() {
  if (!supabase) {
    throw new Error('Supabase is not configured.')
  }

  return supabase
}

export async function getCandidates(
  workspaceId: string,
): Promise<CandidateWithApplications[]> {
  const client = requireSupabase()
  const pageSize = 1000
  const candidates: Candidate[] = []
  const applications: CandidateApplication[] = []

  for (let start = 0; ; start += pageSize) {
    const { data, error } = await client
      .from('candidates')
      .select(
        'id, workspace_id, full_name, email, phone, linkedin_url, created_by, created_at, updated_at',
      )
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .range(start, start + pageSize - 1)
    if (error) throw error
    const page = (data ?? []) as Candidate[]
    candidates.push(...page)
    if (page.length < pageSize) break
  }

  for (let start = 0; ; start += pageSize) {
    const { data, error } = await client
      .from('applications')
      .select(
        'id, workspace_id, candidate_id, job_id, status, created_at, jobs(title)',
      )
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .range(start, start + pageSize - 1)
    if (error) throw error
    const page = (data ?? []) as unknown as CandidateApplication[]
    applications.push(...page)
    if (page.length < pageSize) break
  }

  const applicationsByCandidate = new Map<string, CandidateApplication[]>()
  for (const application of applications) {
    const current = applicationsByCandidate.get(application.candidate_id) ?? []
    current.push(
      application as unknown as CandidateApplication,
    )
    applicationsByCandidate.set(application.candidate_id, current)
  }

  return candidates.map((candidate) => ({
    ...candidate,
    applications: applicationsByCandidate.get(candidate.id) ?? [],
  })) as CandidateWithApplications[]
}

export async function saveCandidate(
  workspaceId: string,
  userId: string,
  values: CandidateFormValues,
  candidateId?: string,
): Promise<void> {
  const client = requireSupabase()
  const candidateValues = validateCandidate(values)

  if (candidateId) {
    const { data, error } = await client
      .from('candidates')
      .update(candidateValues)
      .eq('id', candidateId)
      .eq('workspace_id', workspaceId)
      .select('id')
      .maybeSingle()

    if (error) throw error
    if (!data) {
      throw new Error(
        'Candidate was not updated. Check workspace access and try again.',
      )
    }
    return
  }

  const { error } = await client.from('candidates').insert({
    ...candidateValues,
    workspace_id: workspaceId,
    created_by: userId,
  })

  if (error) throw error
}

export async function deleteCandidate(
  workspaceId: string,
  candidateId: string,
): Promise<void> {
  const client = requireSupabase()
  const { data, error } = await client
    .from('candidates')
    .delete()
    .eq('id', candidateId)
    .eq('workspace_id', workspaceId)
    .select('id')
    .maybeSingle()

  if (error) throw error
  if (!data) {
    throw new Error(
      'Candidate was not deleted. You may not have permission to delete candidates in this workspace.',
    )
  }
}

export async function createCandidateApplication(
  workspaceId: string,
  candidateId: string,
  jobId: string,
): Promise<void> {
  const client = requireSupabase()

  const [{ data: candidate, error: candidateError }, { data: job, error: jobError }] =
    await Promise.all([
      client
        .from('candidates')
        .select('id')
        .eq('id', candidateId)
        .eq('workspace_id', workspaceId)
        .maybeSingle(),
      client
        .from('jobs')
        .select('id')
        .eq('id', jobId)
        .eq('workspace_id', workspaceId)
        .maybeSingle(),
    ])

  if (candidateError) throw candidateError
  if (jobError) throw jobError
  if (!candidate) throw new Error('Candidate was not found in this workspace.')
  if (!job) throw new Error('Choose a job from this workspace.')

  const { data: existingApplication, error: lookupError } = await client
    .from('applications')
    .select('id')
    .eq('workspace_id', workspaceId)
    .eq('candidate_id', candidateId)
    .eq('job_id', jobId)
    .maybeSingle()

  if (lookupError) throw lookupError
  if (existingApplication) {
    throw new Error('This candidate already has an application for that job.')
  }

  const { error } = await client.from('applications').insert({
    workspace_id: workspaceId,
    candidate_id: candidateId,
    job_id: jobId,
    status: 'new' satisfies ApplicationStatus,
  })

  if (error?.code === '23505') {
    throw new Error('This candidate already has an application for that job.')
  }
  if (error) throw error
}

export async function updateApplicationStatus(
  workspaceId: string,
  applicationId: string,
  status: ApplicationStatus,
): Promise<void> {
  const client = requireSupabase()

  const { data, error } = await client
    .from('applications')
    .update({ status })
    .eq('workspace_id', workspaceId)
    .eq('id', applicationId)
    .select('id')
    .maybeSingle()

  if (error) throw error
  if (!data) {
    throw new Error(
      'Application status was not updated. Check your workspace permissions and try again.',
    )
  }
}
