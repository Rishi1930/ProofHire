import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

type WorkspaceMember = {
  user_id: string
  role: string
}

type StorageEntry = {
  name: string
  id: string | null
}

const storageBucket = 'candidate-resumes'

function isAuthorized(request: Request, expectedSecret: string) {
  const providedSecret = request.headers.get('x-cron-secret') ?? ''
  if (!providedSecret || providedSecret.length !== expectedSecret.length) {
    return false
  }

  let difference = 0
  for (let index = 0; index < expectedSecret.length; index += 1) {
    difference |=
      providedSecret.charCodeAt(index) ^ expectedSecret.charCodeAt(index)
  }

  return difference === 0
}

async function removeWorkspaceFiles(
  admin: ReturnType<typeof createClient>,
  workspaceId: string,
) {
  const bucket = admin.storage.from(storageBucket)

  async function collectFiles(prefix: string): Promise<string[]> {
    const files: string[] = []
    let offset = 0
    const pageSize = 100

    while (true) {
      const { data, error } = await bucket.list(prefix, {
        limit: pageSize,
        offset,
      })

      if (error) throw error

      const entries = (data ?? []) as StorageEntry[]
      for (const entry of entries) {
        const path = `${prefix}/${entry.name}`
        if (entry.id) {
          files.push(path)
        } else {
          files.push(...(await collectFiles(path)))
        }
      }

      if (entries.length < pageSize) break
      offset += pageSize
    }

    return files
  }

  const filePaths = await collectFiles(workspaceId)
  for (let index = 0; index < filePaths.length; index += 100) {
    const { error } = await bucket.remove(filePaths.slice(index, index + 100))
    if (error) throw error
  }
}

async function transferRecruiterRecords(
  admin: ReturnType<typeof createClient>,
  workspaceId: string,
  departingUserId: string,
  remainingMembers: WorkspaceMember[],
) {
  const rolePriority = ['owner', 'admin', 'recruiter', 'viewer']
  const replacement =
    rolePriority
      .map((role) => remainingMembers.find((member) => member.role === role))
      .find(Boolean) ?? remainingMembers[0]

  if (!replacement) {
    throw new Error('No remaining workspace member is available for transfer.')
  }

  const { data: workspace, error: workspaceError } = await admin
    .from('workspaces')
    .select('created_by')
    .eq('id', workspaceId)
    .maybeSingle()

  if (workspaceError) throw workspaceError

  if (workspace?.created_by === departingUserId) {
    const { error } = await admin
      .from('workspaces')
      .update({ created_by: replacement.user_id })
      .eq('id', workspaceId)

    if (error) throw error
  }

  if (!remainingMembers.some((member) => member.role === 'owner')) {
    const { error } = await admin
      .from('workspace_members')
      .update({ role: 'owner' })
      .eq('workspace_id', workspaceId)
      .eq('user_id', replacement.user_id)

    if (error) throw error
  }

  for (const table of ['jobs', 'candidates'] as const) {
    const { error } = await admin
      .from(table)
      .update({ created_by: replacement.user_id })
      .eq('workspace_id', workspaceId)
      .eq('created_by', departingUserId)

    if (error) throw error
  }
}

async function deleteRecruiterData(
  admin: ReturnType<typeof createClient>,
  userId: string,
) {
  const workspaceIds = new Set<string>()

  const [memberships, createdWorkspaces, createdJobs, createdCandidates] =
    await Promise.all([
      admin
        .from('workspace_members')
        .select('workspace_id')
        .eq('user_id', userId),
      admin.from('workspaces').select('id').eq('created_by', userId),
      admin.from('jobs').select('workspace_id').eq('created_by', userId),
      admin.from('candidates').select('workspace_id').eq('created_by', userId),
    ])

  for (const result of [
    memberships,
    createdWorkspaces,
    createdJobs,
    createdCandidates,
  ]) {
    if (result.error) throw result.error
  }

  for (const membership of memberships.data ?? []) {
    workspaceIds.add(membership.workspace_id)
  }
  for (const workspace of createdWorkspaces.data ?? []) {
    workspaceIds.add(workspace.id)
  }
  for (const job of createdJobs.data ?? []) {
    workspaceIds.add(job.workspace_id)
  }
  for (const candidate of createdCandidates.data ?? []) {
    workspaceIds.add(candidate.workspace_id)
  }

  for (const workspaceId of workspaceIds) {
    const { data: members, error: membersError } = await admin
      .from('workspace_members')
      .select('user_id, role')
      .eq('workspace_id', workspaceId)
      .neq('user_id', userId)

    if (membersError) throw membersError

    if (!members?.length) {
      await removeWorkspaceFiles(admin, workspaceId)
      const { error } = await admin
        .from('workspaces')
        .delete()
        .eq('id', workspaceId)

      if (error) throw error
      continue
    }

    await transferRecruiterRecords(
      admin,
      workspaceId,
      userId,
      members as WorkspaceMember[],
    )
  }

  const { error } = await admin.auth.admin.deleteUser(userId)
  if (error) throw error
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 })
  }

  const cronSecret = Deno.env.get('ACCOUNT_DELETION_CRON_SECRET')
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

  if (!cronSecret || !supabaseUrl || !serviceRoleKey) {
    console.error('Account deletion worker configuration is incomplete.')
    return Response.json({ error: 'Worker is not configured.' }, { status: 500 })
  }

  if (!isAuthorized(request, cronSecret)) {
    return Response.json({ error: 'Unauthorized.' }, { status: 401 })
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  const { data: dueRequests, error: claimError } = await admin.rpc(
    'claim_due_account_deletions',
  )

  if (claimError) {
    console.error('Unable to claim due account deletion requests.')
    return Response.json({ error: 'Unable to process deletion queue.' }, { status: 500 })
  }

  let deleted = 0
  let failed = 0

  for (const request of dueRequests ?? []) {
    try {
      await deleteRecruiterData(admin, request.user_id)
      deleted += 1
    } catch (error) {
      failed += 1
      console.error(
        'An account deletion could not be completed; it will be retried.',
        error,
      )
    }
  }

  return Response.json({ deleted, failed })
})
