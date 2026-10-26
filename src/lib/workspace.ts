
import { supabase } from './supabase'

export type WorkspaceMembership = {
  workspace_id: string
  user_id: string
  role?: string
}

export type WorkspaceLookupResult = {
  workspaceId: string | null
  error: string | null
}

/**
 * Returns the workspace associated with the signed-in user.
 *
 * This helper relies on Supabase Row Level Security (RLS) to restrict
 * membership records to workspaces the current user can access.
 */
export async function getCurrentWorkspaceId(
  userId: string,
): Promise<WorkspaceLookupResult> {
  if (!supabase) {
    return {
      workspaceId: null,
      error: 'Supabase is not configured. Check your .env.local file.',
    }
  }

  if (!userId.trim()) {
    return {
      workspaceId: null,
      error: 'You must be signed in to access a workspace.',
    }
  }

  const { data, error } = await supabase
    .from('workspace_members')
    .select('workspace_id')
    .eq('user_id', userId)
    .limit(2)

  if (error) {
    return {
      workspaceId: null,
      error: error.message,
    }
  }

  if (!data || data.length === 0) {
    return {
      workspaceId: null,
      error: 'No workspace is associated with this account yet.',
    }
  }

  if (data.length > 1) {
    return {
      workspaceId: null,
      error:
        'This account belongs to multiple workspaces. Select an active workspace before continuing.',
    }
  }

  return {
    workspaceId: data[0].workspace_id,
    error: null,
  }
}

/**
 * Throws when a workspace lookup fails.
 * Useful for workflows that cannot proceed without a workspace.
 */
export async function requireCurrentWorkspaceId(
  userId: string,
): Promise<string> {
  const result = await getCurrentWorkspaceId(userId)

  if (!result.workspaceId) {
    throw new Error(result.error ?? 'Unable to determine the active workspace.')
  }

  return result.workspaceId
}
