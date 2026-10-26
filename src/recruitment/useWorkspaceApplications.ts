import { useCallback, useEffect, useState } from 'react'

import { useAuth } from '../auth/AuthContext'
import { getCurrentWorkspaceId } from '../lib/workspace'
import {
  changeApplicationStatus,
  getWorkspaceApplications,
  recordRecruiterDecision,
  type ApplicationRecord,
  type ApplicationStatus,
  type RecruiterDecision,
} from './applicationData'

export function useWorkspaceApplications() {
  const { user } = useAuth()
  const [applications, setApplications] = useState<ApplicationRecord[]>([])
  const [workspaceId, setWorkspaceId] = useState('')
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const reload = useCallback(async () => {
    if (!user?.id) {
      setApplications([])
      setWorkspaceId('')
      setError('Sign in to view workspace applications.')
      setLoading(false)
      return
    }

    setLoading(true)
    setError('')
    try {
      const workspace = await getCurrentWorkspaceId(user.id)
      if (!workspace.workspaceId) {
        throw new Error(workspace.error ?? 'Unable to load your workspace.')
      }
      const records = await getWorkspaceApplications(workspace.workspaceId)
      setWorkspaceId(workspace.workspaceId)
      setApplications(records)
    } catch (caughtError) {
      setApplications([])
      setError(
        caughtError instanceof Error
          ? caughtError.message
          : 'Unable to load applications. Please try again.',
      )
    } finally {
      setLoading(false)
    }
  }, [user?.id])

  useEffect(() => {
    void reload()
  }, [reload])

  const updateStatus = useCallback(
    async (applicationId: string, status: ApplicationStatus) => {
      if (!workspaceId) {
        throw new Error('No active workspace is available.')
      }
      await changeApplicationStatus(workspaceId, applicationId, status)
      setApplications((current) =>
        current.map((application) =>
          application.id === applicationId
            ? { ...application, status }
            : application,
        ),
      )
    },
    [workspaceId],
  )

  const recordDecision = useCallback(
    async (applicationId: string, decision: RecruiterDecision) => {
      await recordRecruiterDecision(applicationId, decision)
      const nextStatus: Record<RecruiterDecision, ApplicationStatus> = {
        shortlist: 'shortlisted',
        reject: 'rejected',
        advance_to_interview: 'interview',
        return_to_screening: 'screening',
        mark_hired: 'hired',
      }
      setApplications((current) =>
        current.map((application) =>
          application.id === applicationId
            ? { ...application, status: nextStatus[decision] }
            : application,
        ),
      )
    },
    [],
  )

  return {
    applications,
    workspaceId,
    loading,
    error,
    reload,
    updateStatus,
    recordDecision,
  }
}
