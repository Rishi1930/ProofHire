import { useCallback, useEffect, useMemo, useState, type FormEvent } from 'react'
import { Clipboard, Plus, RefreshCw, Send, Trash2 } from 'lucide-react'

import Button from '../components/Button'
import { useAuth } from '../auth/AuthContext'
import { supabase } from '../lib/supabase'
import { useWorkspaceApplications } from '../recruitment/useWorkspaceApplications'
import { createAptitudeInvitation, requestEmailDeliveryAction } from './api'

type TestRecord = {
  id: string
  title: string
  description: string | null
}

type VersionRecord = {
  id: string
  test_id: string
  version_number: number
  version_title: string
  version_description: string | null
  version_status: 'draft' | 'published'
  time_limit_seconds: number
  max_attempts: number
  passing_score: number | null
  published_at: string | null
}

type QuestionRecord = {
  id: string
  display_order: number
  question_type: 'single_choice' | 'multiple_choice' | 'short_text'
  prompt: string
  points: number
  category: string
  difficulty: 'beginner' | 'medium' | 'advanced' | 'expert'
  job_roles: string[]
  competencies: string[]
  options: Array<{ id: string; option_text: string }>
}

type InvitationRecord = {
  id: string
  application_id: string
  test_version_id: string
  candidate_email: string
  status: string
  email_status: string
  email_error_code: string | null
  max_attempts: number
  expires_at: string
  created_at: string
}

type AttemptRecord = {
  id: string
  invitation_id: string
  attempt_number: number
  status: string
  score: number | null
  result: { passed?: boolean | null } | null
  submitted_at: string | null
}

type DeliveryRecord = {
  id: string
  application_id: string
  aptitude_invitation_id: string | null
  email_type: string
  recipient_email: string
  status: string
  last_error_code: string | null
  created_at: string
}

type AssessmentReviewRecord = {
  id: string
  application_id: string
  attempt_id: string
  review_status: 'pending' | 'cleared' | 'overridden'
  reason: string
}

type WorkflowFailureRecord = {
  id: string
  application_id: string
  failure_code: string
  created_at: string
}

const questionTypes = [
  { value: 'single_choice', label: 'Single choice' },
  { value: 'multiple_choice', label: 'Multiple choice' },
  { value: 'short_text', label: 'Short text' },
] as const

function getErrorMessage(error: unknown, fallback: string) {
  return error instanceof Error ? error.message : fallback
}

function parseAnswerLines(value: string) {
  return value
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean)
}

function parseTags(value: string) {
  return [...new Set(parseAnswerLines(value).map((tag) => tag.toLowerCase()))]
}

export default function Aptitude() {
  const { user } = useAuth()
  const {
    applications,
    workspaceId,
    loading: applicationsLoading,
    error: applicationsError,
  } = useWorkspaceApplications()
  const [tests, setTests] = useState<TestRecord[]>([])
  const [versions, setVersions] = useState<VersionRecord[]>([])
  const [questions, setQuestions] = useState<QuestionRecord[]>([])
  const [invitations, setInvitations] = useState<InvitationRecord[]>([])
  const [attempts, setAttempts] = useState<AttemptRecord[]>([])
  const [deliveryJobs, setDeliveryJobs] = useState<DeliveryRecord[]>([])
  const [assessmentReviews, setAssessmentReviews] = useState<AssessmentReviewRecord[]>([])
  const [workflowFailures, setWorkflowFailures] = useState<WorkflowFailureRecord[]>([])
  const [selectedTestId, setSelectedTestId] = useState('')
  const [selectedVersionId, setSelectedVersionId] = useState('')
  const [selectedApplicationId, setSelectedApplicationId] = useState('')
  const [testTitle, setTestTitle] = useState('')
  const [testDescription, setTestDescription] = useState('')
  const [timeLimitMinutes, setTimeLimitMinutes] = useState('30')
  const [maxAttempts, setMaxAttempts] = useState('1')
  const [passingScore, setPassingScore] = useState('70')
  const [questionType, setQuestionType] =
    useState<QuestionRecord['question_type']>('single_choice')
  const [questionPrompt, setQuestionPrompt] = useState('')
  const [questionPoints, setQuestionPoints] = useState('1')
  const [questionCategory, setQuestionCategory] = useState('general')
  const [questionRoles, setQuestionRoles] = useState('general')
  const [questionCompetencies, setQuestionCompetencies] = useState('')
  const [questionDifficulty, setQuestionDifficulty] =
    useState<QuestionRecord['difficulty']>('medium')
  const [optionsText, setOptionsText] = useState('')
  const [answerText, setAnswerText] = useState('')
  const [inviteURL, setInviteURL] = useState('')
  const [inviteRecipient, setInviteRecipient] = useState('')
  const [jobRole, setJobRole] = useState('general')
  const [jobCompetencies, setJobCompetencies] = useState('')
  const [jobCategories, setJobCategories] = useState('')
  const [questionCount, setQuestionCount] = useState('')
  const [difficultyCounts, setDifficultyCounts] = useState({
    beginner: '0',
    medium: '0',
    advanced: '0',
    expert: '0',
  })
  const [error, setError] = useState('')
  const [success, setSuccess] = useState('')
  const [busy, setBusy] = useState(false)

  const selectedTest = tests.find((test) => test.id === selectedTestId)
  const selectedVersion = versions.find(
    (version) => version.id === selectedVersionId,
  )
  const draftVersion = selectedVersion?.version_status === 'draft'
  const eligibleApplications = applications.filter(
    (application) => application.candidates?.email,
  )
  const applicationById = useMemo(
    () => new Map(applications.map((application) => [application.id, application])),
    [applications],
  )
  const versionById = useMemo(
    () => new Map(versions.map((version) => [version.id, version])),
    [versions],
  )
  const attemptsByInvitation = useMemo(() => {
    const grouped = new Map<string, AttemptRecord[]>()
    for (const attempt of attempts) {
      grouped.set(attempt.invitation_id, [
        ...(grouped.get(attempt.invitation_id) ?? []),
        attempt,
      ])
    }
    return grouped
  }, [attempts])
  const reviewByAttempt = useMemo(
    () => new Map(assessmentReviews.map((review) => [review.attempt_id, review])),
    [assessmentReviews],
  )

  const loadTests = useCallback(async () => {
    if (!supabase || !workspaceId) {
      setTests([])
      return
    }
    const { data, error: queryError } = await supabase
      .from('aptitude_tests')
      .select('id, title, description')
      .eq('workspace_id', workspaceId)
      .order('updated_at', { ascending: false })
    if (queryError) throw queryError
    const records = (data ?? []) as TestRecord[]
    setTests(records)
    if (!records.some((test) => test.id === selectedTestId)) {
      setSelectedTestId(records[0]?.id ?? '')
    }
  }, [selectedTestId, workspaceId])

  const loadInvitations = useCallback(async () => {
    if (!supabase || !workspaceId) {
      setInvitations([])
      setAttempts([])
      setDeliveryJobs([])
      setAssessmentReviews([])
      setWorkflowFailures([])
      return
    }
    const { data, error: invitationError } = await supabase
      .from('aptitude_invitations')
      .select(
        'id, application_id, test_version_id, candidate_email, status, email_status, email_error_code, max_attempts, expires_at, created_at',
      )
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .limit(200)
    if (invitationError) throw invitationError
    const records = (data ?? []) as InvitationRecord[]
    setInvitations(records)
    const { data: deliveryData, error: deliveryError } = await supabase
      .from('email_delivery_jobs')
      .select('id, application_id, aptitude_invitation_id, email_type, recipient_email, status, last_error_code, created_at')
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .limit(200)
    if (deliveryError) throw deliveryError
    setDeliveryJobs((deliveryData ?? []) as DeliveryRecord[])
    const { data: reviewData, error: reviewError } = await supabase
      .from('application_assessment_reviews')
      .select('id, application_id, attempt_id, review_status, reason')
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .limit(200)
    if (reviewError) throw reviewError
    setAssessmentReviews((reviewData ?? []) as AssessmentReviewRecord[])
    const { data: failureData, error: failureError } = await supabase
      .from('application_workflow_failures')
      .select('id, application_id, failure_code, created_at')
      .eq('workspace_id', workspaceId)
      .order('created_at', { ascending: false })
      .limit(100)
    if (failureError) throw failureError
    setWorkflowFailures((failureData ?? []) as WorkflowFailureRecord[])
    if (records.length === 0) {
      setAttempts([])
      return
    }
    const { data: attemptData, error: attemptError } = await supabase
      .from('aptitude_attempts')
      .select(
        'id, invitation_id, attempt_number, status, score, result, submitted_at',
      )
      .eq('workspace_id', workspaceId)
      .in(
        'invitation_id',
        records.map((record) => record.id),
      )
      .order('attempt_number', { ascending: true })
    if (attemptError) throw attemptError
    setAttempts((attemptData ?? []) as AttemptRecord[])
  }, [workspaceId])

  const loadVersions = useCallback(async () => {
    if (!supabase || !workspaceId || !selectedTestId) {
      setVersions([])
      setSelectedVersionId('')
      return
    }
    const { data, error: queryError } = await supabase
      .from('aptitude_test_versions')
      .select(
        'id, test_id, version_number, version_title, version_description, version_status, time_limit_seconds, max_attempts, passing_score, published_at',
      )
      .eq('workspace_id', workspaceId)
      .eq('test_id', selectedTestId)
      .order('version_number', { ascending: false })
    if (queryError) throw queryError
    const records = (data ?? []) as VersionRecord[]
    setVersions(records)
    if (!records.some((version) => version.id === selectedVersionId)) {
      const selected =
        records.find((version) => version.version_status === 'draft') ??
        records[0]
      setSelectedVersionId(selected?.id ?? '')
    }
  }, [selectedTestId, selectedVersionId, workspaceId])

  const loadQuestions = useCallback(async () => {
    if (!supabase || !workspaceId || !selectedVersionId) {
      setQuestions([])
      return
    }
    const { data, error: questionError } = await supabase
      .from('aptitude_questions')
      .select('id, display_order, question_type, prompt, points, category, difficulty, job_roles, competencies')
      .eq('workspace_id', workspaceId)
      .eq('test_version_id', selectedVersionId)
      .order('display_order', { ascending: true })
    if (questionError) throw questionError
    const records = (data ?? []) as Omit<QuestionRecord, 'options'>[]
    if (records.length === 0) {
      setQuestions([])
      return
    }
    const { data: optionData, error: optionError } = await supabase
      .from('aptitude_question_options')
      .select('id, question_id, option_text, display_order')
      .eq('workspace_id', workspaceId)
      .in(
        'question_id',
        records.map((question) => question.id),
      )
      .order('display_order', { ascending: true })
    if (optionError) throw optionError
    const optionRows = optionData ?? []
    setQuestions(
      records.map((question) => ({
        ...question,
        options: optionRows
          .filter((option) => option.question_id === question.id)
          .map((option) => ({
            id: option.id,
            option_text: option.option_text,
          })),
      })),
    )
  }, [selectedVersionId, workspaceId])

  const reload = useCallback(async () => {
    setError('')
    try {
      await Promise.all([loadTests(), loadInvitations()])
    } catch (caughtError) {
      setError(getErrorMessage(caughtError, 'Aptitude data could not be loaded.'))
    }
  }, [loadInvitations, loadTests])

  useEffect(() => {
    void reload()
  }, [reload])

  useEffect(() => {
    void loadVersions().catch((caughtError: unknown) => {
      setVersions([])
      setError(getErrorMessage(caughtError, 'Test versions could not be loaded.'))
    })
  }, [loadVersions])

  useEffect(() => {
    void loadQuestions().catch((caughtError: unknown) => {
      setQuestions([])
      setError(getErrorMessage(caughtError, 'Test questions could not be loaded.'))
    })
  }, [loadQuestions])

  async function createTest(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!supabase || !workspaceId || !user?.id) return
    setBusy(true)
    setError('')
    setSuccess('')
    try {
      const { data: test, error: testError } = await supabase
        .from('aptitude_tests')
        .insert({
          workspace_id: workspaceId,
          title: testTitle.trim(),
          description: testDescription.trim() || null,
          created_by: user.id,
        })
        .select('id')
        .single()
      if (testError) throw testError
      const { data: version, error: versionError } = await supabase
        .from('aptitude_test_versions')
        .insert({
          workspace_id: workspaceId,
          test_id: test.id,
          version_number: 1,
          version_title: 'Version 1',
          version_description: testDescription.trim() || null,
          version_status: 'draft',
          time_limit_seconds: Number(timeLimitMinutes) * 60,
          max_attempts: Number(maxAttempts),
          passing_score: passingScore === '' ? null : Number(passingScore),
          created_by: user.id,
        })
        .select('id')
        .single()
      if (versionError) throw versionError
      setTestTitle('')
      setTestDescription('')
      setSelectedTestId(test.id)
      setSelectedVersionId(version.id)
      setSuccess('Draft aptitude test created.')
      await loadTests()
    } catch (caughtError) {
      setError(getErrorMessage(caughtError, 'The aptitude test could not be created.'))
    } finally {
      setBusy(false)
    }
  }

  async function createDraftVersion() {
    if (!supabase || !workspaceId || !user?.id || !selectedTestId) return
    setBusy(true)
    setError('')
    setSuccess('')
    try {
      const nextNumber =
        Math.max(0, ...versions.map((version) => version.version_number)) + 1
      const previous = versions[0]
      const { data, error: insertError } = await supabase
        .from('aptitude_test_versions')
        .insert({
          workspace_id: workspaceId,
          test_id: selectedTestId,
          version_number: nextNumber,
          version_title: `Version ${nextNumber}`,
          version_description: previous?.version_description ?? null,
          version_status: 'draft',
          time_limit_seconds: previous?.time_limit_seconds ?? 1800,
          max_attempts: previous?.max_attempts ?? 1,
          passing_score: previous?.passing_score ?? 70,
          created_by: user.id,
        })
        .select('id')
        .single()
      if (insertError) throw insertError
      setSelectedVersionId(data.id)
      setSuccess(`Draft version ${nextNumber} created.`)
    } catch (caughtError) {
      setError(getErrorMessage(caughtError, 'A draft version could not be created.'))
    } finally {
      setBusy(false)
    }
  }

  async function addQuestion(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!supabase || !workspaceId || !selectedVersion || !draftVersion) return
    const lines = parseAnswerLines(optionsText)
    let correctOptionIndexes: number[] = []
    let optionTexts: string[] = []
    let answerKey: { option_ids: string[] } | { accepted_answers: string[] }

    if (questionType === 'short_text') {
      const acceptedAnswers = parseAnswerLines(answerText)
      if (acceptedAnswers.length === 0) {
        setError('Add at least one accepted answer for this short-text question.')
        return
      }
      answerKey = { accepted_answers: acceptedAnswers }
    } else {
      optionTexts = lines.map((line) => {
        const correct = line.startsWith('*')
        if (correct) correctOptionIndexes.push(optionTexts.length)
        return line.replace(/^\*\s*/, '')
      })
      if (
        optionTexts.length < 2 ||
        optionTexts.some((option) => option.trim() === '') ||
        correctOptionIndexes.length === 0 ||
        (questionType === 'single_choice' && correctOptionIndexes.length !== 1)
      ) {
        setError(
          'Add at least two options and mark the correct option(s) with * at the start of each line.',
        )
        return
      }
      answerKey = { option_ids: [] }
    }

    const roles = parseTags(questionRoles)
    const competencies = parseTags(questionCompetencies)
    if (roles.length === 0 || roles.length > 20 || competencies.length > 50) {
      setError('Add between 1 and 20 job roles and no more than 50 competencies.')
      return
    }

    setBusy(true)
    setError('')
    setSuccess('')
    let insertedQuestionId = ''
    try {
      const { data: question, error: questionError } = await supabase
        .from('aptitude_questions')
        .insert({
          workspace_id: workspaceId,
          test_version_id: selectedVersion.id,
          display_order:
            Math.max(0, ...questions.map((record) => record.display_order)) + 1,
          question_type: questionType,
          prompt: questionPrompt.trim(),
          points: Number(questionPoints),
          category: questionCategory.trim().toLowerCase(),
          difficulty: questionDifficulty,
          job_roles: roles,
          competencies,
          is_active: true,
          approval_status: 'approved',
        })
        .select('id')
        .single()
      if (questionError) throw questionError
      insertedQuestionId = question.id

      if (questionType !== 'short_text') {
        const { error: optionsError } = await supabase
          .from('aptitude_question_options')
          .insert(
            optionTexts.map((option, index) => ({
              workspace_id: workspaceId,
              question_id: question.id,
              display_order: index + 1,
              option_text: option,
            })),
          )
        if (optionsError) throw optionsError
        const { data: options, error: optionQueryError } = await supabase
          .from('aptitude_question_options')
          .select('id, display_order')
          .eq('workspace_id', workspaceId)
          .eq('question_id', question.id)
          .order('display_order', { ascending: true })
        if (optionQueryError) throw optionQueryError
        if ((options ?? []).length !== optionTexts.length) {
          throw new Error('Question options could not be verified before saving the answer key.')
        }
        answerKey = {
          option_ids: correctOptionIndexes.map((index) => {
            const option = options?.find((item) => item.display_order === index + 1)
            if (!option) throw new Error('A correct option could not be verified.')
            return option.id
          }),
        }
      }

      const { error: keyError } = await supabase.rpc(
        'save_aptitude_answer_key',
        {
          target_question_id: question.id,
          target_answer_key: answerKey,
        },
      )
      if (keyError) throw keyError
      setQuestionPrompt('')
      setOptionsText('')
      setAnswerText('')
      setQuestionCategory('general')
      setQuestionRoles('general')
      setQuestionCompetencies('')
      setQuestionDifficulty('medium')
      setSuccess('Question and private answer key saved.')
      await loadQuestions()
    } catch (caughtError) {
      if (insertedQuestionId) {
        const { error: cleanupError } = await supabase
          .from('aptitude_questions')
          .delete()
          .eq('workspace_id', workspaceId)
          .eq('id', insertedQuestionId)
        if (cleanupError) {
          setError(
            `${getErrorMessage(caughtError, 'Question could not be saved.')} Draft question cleanup also failed; remove it before publishing.`,
          )
        } else {
          setError(getErrorMessage(caughtError, 'Question could not be saved.'))
        }
      } else {
        setError(getErrorMessage(caughtError, 'Question could not be saved.'))
      }
    } finally {
      setBusy(false)
    }
  }

  async function removeQuestion(questionId: string) {
    if (!supabase || !workspaceId || !draftVersion) return
    setError('')
    const { error: deleteError } = await supabase
      .from('aptitude_questions')
      .delete()
      .eq('workspace_id', workspaceId)
      .eq('id', questionId)
    if (deleteError) {
      setError(getErrorMessage(deleteError, 'The question could not be removed.'))
      return
    }
    setSuccess('Question removed from the draft.')
    await loadQuestions()
  }

  async function publishVersion() {
    if (!supabase || !selectedVersion || !draftVersion) return
    setBusy(true)
    setError('')
    setSuccess('')
    try {
      const { error: publishError } = await supabase.rpc(
        'publish_aptitude_test_version',
        { target_version_id: selectedVersion.id },
      )
      if (publishError) throw publishError
      setSuccess('Test version published and locked for editing.')
      await loadVersions()
    } catch (caughtError) {
      setError(
        getErrorMessage(caughtError, 'The aptitude test version could not be published.'),
      )
    } finally {
      setBusy(false)
    }
  }

  async function sendInvitation(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!workspaceId || !selectedVersion || selectedVersion.version_status !== 'published') {
      setError('Select a published test version before inviting a candidate.')
      return
    }
    const application = applicationById.get(selectedApplicationId)
    if (!application) {
      setError('Select an application to invite.')
      return
    }
    const targetCount = questionCount.trim() ? Number(questionCount) : null
    const distribution = {
      beginner: Number(difficultyCounts.beginner),
      medium: Number(difficultyCounts.medium),
      advanced: Number(difficultyCounts.advanced),
      expert: Number(difficultyCounts.expert),
    }
    const distributionTotal = Object.values(distribution).reduce(
      (total, count) => total + count,
      0,
    )
    if (
      Object.values(distribution).some((count) => !Number.isInteger(count) || count < 0) ||
      (targetCount !== null &&
        (!Number.isInteger(targetCount) || targetCount < 1 || targetCount > 1000 ||
          distributionTotal !== targetCount)) ||
      (targetCount === null && distributionTotal !== 0)
    ) {
      setError('Set a question count and difficulty quotas that add up to that count, or leave all quotas at zero to use every matching question.')
      return
    }
    const normalizedRole = jobRole.trim().toLowerCase()
    if (!normalizedRole) {
      setError('Enter the job role used to select aptitude questions.')
      return
    }
    setBusy(true)
    setError('')
    setSuccess('')
    setInviteURL('')
    try {
      const { data: sessionData, error: sessionError } =
        await supabase?.auth.getSession() ?? { data: { session: null }, error: null }
      if (sessionError) throw sessionError
      if (!sessionData.session?.access_token) {
        throw new Error('Sign in again before creating a candidate invitation.')
      }
      if (!supabase) throw new Error('Aptitude services are unavailable.')
      const { error: configurationError } = await supabase
        .from('job_aptitude_assessments')
        .upsert(
          {
            workspace_id: workspaceId,
            job_id: application.job_id,
            test_version_id: selectedVersion.id,
            is_required: true,
            job_role: normalizedRole,
            competencies: parseTags(jobCompetencies),
            categories: parseTags(jobCategories),
            question_count: targetCount,
            difficulty_distribution: distribution,
            created_by: user?.id ?? null,
          },
          { onConflict: 'workspace_id,job_id,test_version_id' },
        )
      if (configurationError) throw configurationError
      const response = await createAptitudeInvitation(
        {
          workspace_id: workspaceId,
          application_id: application.id,
          test_version_id: selectedVersion.id,
          expires_at: new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString(),
          max_attempts: selectedVersion.max_attempts,
        },
        sessionData.session.access_token,
      )
      setInviteRecipient(response.invitation.candidate_email)
      setInviteURL(`${window.location.origin}/aptitude/${response.token}`)
      setSelectedApplicationId('')
      setSuccess('Invitation created. The assessment email is queued for delivery. Keep the link as a fallback.')
      await loadInvitations()
    } catch (caughtError) {
      setError(getErrorMessage(caughtError, 'The aptitude invitation could not be created.'))
    } finally {
      setBusy(false)
    }
  }

  async function publishOrReload() {
    setBusy(true)
    await publishVersion()
  }

  async function actOnEmailDelivery(
    job: DeliveryRecord,
    action: 'send' | 'retry' | 'resend',
  ) {
    if (!supabase || !workspaceId) {
      setError('Email delivery controls are unavailable.')
      return
    }
    setBusy(true)
    setError('')
    setSuccess('')
    try {
      const { data: sessionData, error: sessionError } =
        await supabase.auth.getSession()
      if (sessionError) throw sessionError
      const accessToken = sessionData.session?.access_token
      if (!accessToken) {
        throw new Error('Sign in again before managing email delivery.')
      }
      await requestEmailDeliveryAction(
        job.id,
        { workspace_id: workspaceId, action, request_id: crypto.randomUUID() },
        accessToken,
      )
      setSuccess(
        action === 'resend'
          ? 'A resend was queued.'
          : action === 'retry'
            ? 'The email retry was queued.'
            : 'The email was returned to the delivery queue.',
      )
      await loadInvitations()
    } catch (caughtError) {
      setError(getErrorMessage(caughtError, 'The email delivery action failed.'))
    } finally {
      setBusy(false)
    }
  }

  async function resolveAssessmentReview(
    review: AssessmentReviewRecord,
    resolution: 'cleared' | 'overridden',
  ) {
    if (!supabase || !workspaceId) return
    setBusy(true)
    setError('')
    setSuccess('')
    try {
      const { error: resolveError } = await supabase.rpc(
        'resolve_application_assessment_review',
        {
          target_workspace_id: workspaceId,
          target_review_id: review.id,
          target_resolution: resolution,
        },
      )
      if (resolveError) throw resolveError
      setSuccess(
        resolution === 'overridden'
          ? 'The application was advanced to interview by recruiter override.'
          : 'The aptitude result was reviewed and cleared.',
      )
      await Promise.all([loadInvitations(), reload()])
    } catch (caughtError) {
      setError(getErrorMessage(caughtError, 'The aptitude review could not be updated.'))
    } finally {
      setBusy(false)
    }
  }

  async function grantAnotherAttempt(invitation: InvitationRecord) {
    if (!supabase || !workspaceId) return
    setBusy(true)
    setError('')
    setSuccess('')
    try {
      const { error: reinvitationError } = await supabase.rpc(
        'grant_aptitude_reinvitation',
        {
          target_workspace_id: workspaceId,
          target_invitation_id: invitation.id,
        },
      )
      if (reinvitationError) throw reinvitationError
      setSuccess('One additional attempt was authorized and a new invitation email was queued.')
      await loadInvitations()
    } catch (caughtError) {
      setError(getErrorMessage(caughtError, 'The additional attempt could not be authorized.'))
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="page-stack">
      <div className="page-heading-row">
        <div className="page-heading">
          <span className="page-eyebrow">RECRUITER WORKFLOW</span>
          <h1>Aptitude assessments</h1>
          <p>Author versioned tests, invite applicants, and review server-scored results.</p>
        </div>
        <Button
          variant="secondary"
          icon={<RefreshCw size={16} />}
          loading={applicationsLoading}
          onClick={() => void reload()}
        >
          Refresh
        </Button>
      </div>

      {(error || applicationsError) && (
        <div className="form-alert form-alert-error" role="alert">
          {error || applicationsError}
          {error.includes('aptitude') && (
            <> Apply the required aptitude migrations through 202611030002_score_aptitude_timeouts.sql to your local/test database.</>
          )}
        </div>
      )}
      {success && <div className="form-alert form-alert-success" role="status">{success}</div>}

      <div className="info-banner">
        <Clipboard size={18} />
        <div>
          <strong>Answer keys stay private; invitations are delivered by the backend email worker</strong>
          <p>
            Candidate responses are scored by the backend. This workspace does not
            send email yet: copy the generated one-time link and deliver it using
            your approved channel. Test outcomes support recruiter review and do
            not automatically change an application stage.
          </p>
        </div>
      </div>

      <div className="panel aptitude-authoring">
        <h2>Create a test</h2>
        <form className="form-grid" onSubmit={(event) => void createTest(event)}>
          <label>
            Test title
            <input
              className="form-input"
              required
              maxLength={180}
              value={testTitle}
              onChange={(event) => setTestTitle(event.target.value)}
            />
          </label>
          <label>
            Description
            <textarea
              className="form-textarea"
              maxLength={5000}
              value={testDescription}
              onChange={(event) => setTestDescription(event.target.value)}
            />
          </label>
          <div className="aptitude-settings-grid">
            <label>
              Time limit (minutes)
              <input
                className="form-input"
                type="number"
                min="1"
                max="360"
                value={timeLimitMinutes}
                onChange={(event) => setTimeLimitMinutes(event.target.value)}
                required
              />
            </label>
            <label>
              Attempts allowed
              <input
                className="form-input"
                type="number"
                min="1"
                max="5"
                value={maxAttempts}
                onChange={(event) => setMaxAttempts(event.target.value)}
                required
              />
            </label>
            <label>
              Passing score (%; optional)
              <input
                className="form-input"
                type="number"
                min="0"
                max="100"
                value={passingScore}
                onChange={(event) => setPassingScore(event.target.value)}
              />
            </label>
          </div>
          <Button type="submit" icon={<Plus size={16} />} loading={busy}>
            Create draft test
          </Button>
        </form>
      </div>

      <div className="panel aptitude-authoring">
        <div className="recruitment-list-header">
          <div>
            <h2>Test builder</h2>
            <p>Add questions and private keys to a draft, then publish an immutable version.</p>
          </div>
          <div className="aptitude-builder-controls">
            <label>
              Test
              <select
                className="form-select"
                value={selectedTestId}
                onChange={(event) => setSelectedTestId(event.target.value)}
              >
                <option value="">Select a test</option>
                {tests.map((test) => <option key={test.id} value={test.id}>{test.title}</option>)}
              </select>
            </label>
            {versions.length > 0 && (
              <label>
                Version
                <select
                  className="form-select"
                  value={selectedVersionId}
                  onChange={(event) => setSelectedVersionId(event.target.value)}
                >
                  {versions.map((version) => (
                    <option key={version.id} value={version.id}>
                      {version.version_title} · {version.version_status}
                    </option>
                  ))}
                </select>
              </label>
            )}
          </div>
        </div>
        {!selectedTest ? (
          <div className="empty-state"><p>Create a test to begin authoring.</p></div>
        ) : (
          <>
            <div className="aptitude-version-summary">
              <div>
                <strong>{selectedTest.title}</strong>
                <span>
                  {selectedVersion
                    ? `${selectedVersion.version_title} · ${selectedVersion.version_status} · ${Math.round(selectedVersion.time_limit_seconds / 60)} min · ${selectedVersion.max_attempts} attempt(s)`
                    : 'No version exists yet'}
                </span>
              </div>
              {!draftVersion && (
                <Button
                  variant="secondary"
                  icon={<Plus size={15} />}
                  loading={busy}
                  onClick={() => void createDraftVersion()}
                >
                  New draft version
                </Button>
              )}
              {draftVersion && (
                <Button
                  loading={busy}
                  onClick={() => void publishOrReload()}
                  disabled={questions.length === 0}
                >
                  Publish version
                </Button>
              )}
            </div>
            {selectedVersion && draftVersion && (
              <form className="aptitude-question-form" onSubmit={(event) => void addQuestion(event)}>
                <h3>Add a question</h3>
                <label>
                  Question
                  <textarea
                    className="form-textarea"
                    required
                    maxLength={10000}
                    value={questionPrompt}
                    onChange={(event) => setQuestionPrompt(event.target.value)}
                  />
                </label>
                <div className="aptitude-settings-grid">
                  <label>
                    Category
                    <input
                      className="form-input"
                      required
                      maxLength={120}
                      value={questionCategory}
                      onChange={(event) => setQuestionCategory(event.target.value)}
                    />
                  </label>
                  <label>
                    Difficulty
                    <select
                      className="form-select"
                      value={questionDifficulty}
                      onChange={(event) =>
                        setQuestionDifficulty(
                          event.target.value as QuestionRecord['difficulty'],
                        )
                      }
                    >
                      <option value="beginner">Beginner</option>
                      <option value="medium">Medium</option>
                      <option value="advanced">Advanced</option>
                      <option value="expert">Expert</option>
                    </select>
                  </label>
                  <label>
                    Job roles (one per line; use "general" for shared questions)
                    <textarea
                      className="form-textarea"
                      required
                      value={questionRoles}
                      onChange={(event) => setQuestionRoles(event.target.value)}
                    />
                  </label>
                  <label>
                    Competencies (one per line; leave blank for any competency)
                    <textarea
                      className="form-textarea"
                      value={questionCompetencies}
                      onChange={(event) => setQuestionCompetencies(event.target.value)}
                    />
                  </label>
                  <label>
                    Type
                    <select
                      className="form-select"
                      value={questionType}
                      onChange={(event) => setQuestionType(event.target.value as QuestionRecord['question_type'])}
                    >
                      {questionTypes.map((type) => <option key={type.value} value={type.value}>{type.label}</option>)}
                    </select>
                  </label>
                  <label>
                    Points
                    <input
                      className="form-input"
                      type="number"
                      min="0.01"
                      max="9999"
                      step="0.01"
                      value={questionPoints}
                      onChange={(event) => setQuestionPoints(event.target.value)}
                      required
                    />
                  </label>
                </div>
                {questionType === 'short_text' ? (
                  <label>
                    Accepted answers (one per line; case-insensitive exact match)
                    <textarea
                      className="form-textarea"
                      required
                      value={answerText}
                      onChange={(event) => setAnswerText(event.target.value)}
                    />
                  </label>
                ) : (
                  <label>
                    Options (one per line; prefix each correct option with *)
                    <textarea
                      className="form-textarea"
                      required
                      placeholder={'*Correct answer\nOther answer'}
                      value={optionsText}
                      onChange={(event) => setOptionsText(event.target.value)}
                    />
                  </label>
                )}
                <Button type="submit" icon={<Plus size={16} />} loading={busy}>
                  Save question
                </Button>
              </form>
            )}
            <div className="aptitude-question-list">
              {questions.map((question) => (
                <article className="aptitude-question-card" key={question.id}>
                  <div>
                    <strong>{question.display_order}. {question.prompt}</strong>
                    <p>
                      {questionTypes.find((type) => type.value === question.question_type)?.label}
                      {' · '}{question.category}
                      {' · '}{question.difficulty}
                      {' · '}{question.job_roles.join(', ')}
                      {question.competencies.length > 0 &&
                        ` · ${question.competencies.join(', ')}`}
                      {' · '}{question.points} point(s)
                    </p>
                    {question.options.length > 0 && (
                      <ul>{question.options.map((option) => <li key={option.id}>{option.option_text}</li>)}</ul>
                    )}
                  </div>
                  {draftVersion && (
                    <Button
                      variant="danger"
                      icon={<Trash2 size={15} />}
                      onClick={() => void removeQuestion(question.id)}
                    >
                      Remove
                    </Button>
                  )}
                </article>
              ))}
              {selectedVersion && questions.length === 0 && (
                <p className="empty-state">Add at least one question before publishing.</p>
              )}
            </div>
          </>
        )}
      </div>

      <div className="panel aptitude-authoring">
        <h2>Invite a candidate</h2>
        <form className="aptitude-invite-form" onSubmit={(event) => void sendInvitation(event)}>
          <label>
            Published test
            <select
              className="form-select"
              value={selectedVersionId}
              onChange={(event) => setSelectedVersionId(event.target.value)}
              required
            >
              <option value="">Select a published version</option>
              {versions
                .filter((version) => version.version_status === 'published')
                .map((version) => (
                  <option key={version.id} value={version.id}>
                    {selectedTest?.title} · {version.version_title}
                  </option>
                ))}
            </select>
          </label>
          <label>
            Application
            <select
              className="form-select"
              value={selectedApplicationId}
              onChange={(event) => setSelectedApplicationId(event.target.value)}
              required
            >
              <option value="">Select an application</option>
              {eligibleApplications.map((application) => (
                <option key={application.id} value={application.id}>
                  {application.candidates?.full_name ?? 'Candidate'} · {application.jobs?.title ?? 'Job'}
                </option>
              ))}
            </select>
          </label>
          <div className="aptitude-settings-grid">
            <label>
              Job role
              <input
                className="form-input"
                required
                maxLength={120}
                value={jobRole}
                onChange={(event) => setJobRole(event.target.value)}
              />
            </label>
            <label>
              Competencies to match (one per line; optional)
              <textarea
                className="form-textarea"
                value={jobCompetencies}
                onChange={(event) => setJobCompetencies(event.target.value)}
              />
            </label>
            <label>
              Categories to include (one per line; optional)
              <textarea
                className="form-textarea"
                value={jobCategories}
                onChange={(event) => setJobCategories(event.target.value)}
              />
            </label>
            <label>
              Number of questions (optional)
              <input
                className="form-input"
                type="number"
                min="1"
                max="1000"
                value={questionCount}
                onChange={(event) => setQuestionCount(event.target.value)}
              />
            </label>
            {(Object.keys(difficultyCounts) as Array<keyof typeof difficultyCounts>).map((difficulty) => (
              <label key={difficulty}>
                {difficulty[0].toUpperCase() + difficulty.slice(1)} questions
                <input
                  className="form-input"
                  type="number"
                  min="0"
                  max="1000"
                  value={difficultyCounts[difficulty]}
                  onChange={(event) =>
                    setDifficultyCounts((current) => ({
                      ...current,
                      [difficulty]: event.target.value,
                    }))
                  }
                />
              </label>
            ))}
          </div>
          <Button
            type="submit"
            icon={<Send size={16} />}
            loading={busy}
            disabled={!versions.some((version) => version.id === selectedVersionId && version.version_status === 'published')}
          >
            Create invitation link
          </Button>
        </form>
        {inviteURL && (
          <div className="aptitude-invite-link">
            <strong>Fallback link for {inviteRecipient}</strong>
            <p>The backend has queued an invitation email. This one-time link is also available as a secure fallback.</p>
            <input className="form-input" readOnly value={inviteURL} aria-label="Candidate aptitude invitation link" />
            <Button
              variant="secondary"
              icon={<Clipboard size={15} />}
              onClick={() => {
                void navigator.clipboard.writeText(inviteURL).then(
                  () => setSuccess('Invitation link copied.'),
                  () => setError('Clipboard access was denied. Copy the link from the field above.'),
                )
              }}
            >
              Copy link
            </Button>
          </div>
        )}
      </div>

      <div className="panel aptitude-authoring">
        {workflowFailures.length > 0 && (
          <section aria-labelledby="aptitude-workflow-failures">
            <div className="recruitment-list-header">
              <div>
                <h2 id="aptitude-workflow-failures">Automated follow-up needs attention</h2>
                <p>A screening pass could not create its aptitude invitation. Review the published assessment configuration and question bank.</p>
              </div>
            </div>
            <div className="aptitude-results-list">
              {workflowFailures.map((failure) => {
                const application = applicationById.get(failure.application_id)
                return (
                  <article className="aptitude-result-card" key={failure.id}>
                    <div>
                      <strong>{application?.candidates?.full_name ?? 'Candidate'}</strong>
                      <p>{application?.jobs?.title ?? 'Application'} · {failure.failure_code}</p>
                      <small>{new Date(failure.created_at).toLocaleString()}</small>
                    </div>
                  </article>
                )
              })}
            </div>
          </section>
        )}
        <div className="recruitment-list-header">
          <div>
            <h2>Email delivery</h2>
            <p>Track screening and assessment notices, then retry or resend without creating another invitation.</p>
          </div>
          <Button variant="secondary" onClick={() => void loadInvitations()}>
            Refresh delivery
          </Button>
        </div>
        {deliveryJobs.length === 0 ? (
          <div className="empty-state"><p>No email delivery records are available.</p></div>
        ) : (
          <div className="aptitude-results-list">
            {deliveryJobs.map((job) => {
              const application = applicationById.get(job.application_id)
              const action =
                job.status === 'queued'
                  ? 'send'
                  : job.status === 'retry_wait' ||
                      job.status === 'failed' ||
                      job.status === 'blocked_configuration'
                    ? 'retry'
                    : job.status === 'sent' || job.status === 'delivered'
                      ? 'resend'
                      : null
              return (
                <article className="aptitude-result-card" key={job.id}>
                  <div>
                    <strong>{application?.candidates?.full_name ?? job.recipient_email}</strong>
                    <p>
                      {job.email_type.replaceAll('_', ' ')} · {job.status}
                      {job.last_error_code ? ` · ${job.last_error_code}` : ''}
                    </p>
                    <small>{new Date(job.created_at).toLocaleString()}</small>
                  </div>
                  {action && (
                    <Button
                      variant="secondary"
                      icon={action === 'send' ? <Send size={15} /> : <RefreshCw size={15} />}
                      loading={busy}
                      onClick={() => void actOnEmailDelivery(job, action)}
                    >
                      {action === 'send'
                        ? 'Send now'
                        : action === 'retry'
                          ? 'Retry'
                          : 'Resend'}
                    </Button>
                  )}
                </article>
              )
            })}
          </div>
        )}
      </div>

      <div className="panel aptitude-authoring">
        <div className="recruitment-list-header">
          <div>
            <h2>Invitations and results</h2>
            <p>Scores are server-calculated; review them alongside the resume and interview evidence.</p>
          </div>
          <Button variant="secondary" onClick={() => void loadInvitations()}>Refresh results</Button>
        </div>
        {invitations.length === 0 ? (
          <div className="empty-state"><p>No aptitude invitations have been created.</p></div>
        ) : (
          <div className="aptitude-results-list">
            {invitations.map((invitation) => {
              const application = applicationById.get(invitation.application_id)
              const version = versionById.get(invitation.test_version_id)
              const invitationAttempts = attemptsByInvitation.get(invitation.id) ?? []
              const latestAttempt = invitationAttempts[invitationAttempts.length - 1]
              return (
                <article className="aptitude-result-card" key={invitation.id}>
                  <div>
                    <strong>{application?.candidates?.full_name ?? invitation.candidate_email}</strong>
                    <p>{application?.jobs?.title ?? version?.version_title ?? 'Aptitude test'} · {invitation.status}</p>
                    <p>
                      Delivery: {invitation.email_error_code === 'manual_delivery' ? 'manual link, not emailed' : invitation.email_status}
                      {' · '}Expires {new Date(invitation.expires_at).toLocaleString()}
                    </p>
                  </div>
                  <div>
                    {invitationAttempts.map((attempt) => {
                      const review = reviewByAttempt.get(attempt.id)
                      const recommendation =
                        attempt.result?.passed === true
                          ? 'Threshold met; application advances to interview.'
                          : attempt.result?.passed === false
                            ? 'Below threshold; recruiter review is pending.'
                            : ''
                      return (
                        <div key={attempt.id}>
                          <p>
                            Attempt {attempt.attempt_number}: {attempt.status}
                            {attempt.score != null ? ` · ${Number(attempt.score).toFixed(1)}%` : ''}
                            {attempt.result?.passed === true ? ' · Pass' : ''}
                            {attempt.result?.passed === false ? ' · Below threshold' : ''}
                            {recommendation && <> · {recommendation}</>}
                          </p>
                          {review?.review_status === 'pending' && (
                            <div className="aptitude-builder-controls">
                              <Button
                                variant="secondary"
                                loading={busy}
                                onClick={() => void resolveAssessmentReview(review, 'overridden')}
                              >
                                Advance to interview
                              </Button>
                              <Button
                                variant="secondary"
                                loading={busy}
                                onClick={() => void resolveAssessmentReview(review, 'cleared')}
                              >
                                Clear for review
                              </Button>
                            </div>
                          )}
                        </div>
                      )
                    })}
                    {latestAttempt?.result?.passed === false &&
                      version &&
                      invitation.max_attempts < version.max_attempts && (
                        <Button
                          variant="secondary"
                          loading={busy}
                          onClick={() => void grantAnotherAttempt(invitation)}
                        >
                          Allow one additional attempt
                        </Button>
                      )}
                    {invitationAttempts.length === 0 && <span>Awaiting candidate</span>}
                  </div>
                </article>
              )
            })}
          </div>
        )}
      </div>
    </section>
  )
}
