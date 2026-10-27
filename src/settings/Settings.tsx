import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import {
  ArrowRight,
  Building2,
  BrainCircuit,
  KeyRound,
  LogOut,
  ShieldAlert,
  Sparkles,
  UserRound,
} from 'lucide-react'

import { useAuth } from '../auth/AuthContext'
import { supabase } from '../lib/supabase'

type CompanyProfile = {
  name: string
  company_website: string
  company_industry: string
  company_size: string
  company_location: string
  company_phone: string
}

type DeletionRequest = {
  requested_at: string
  scheduled_for: string
  status: 'pending' | 'processing'
}

const emptyCompanyProfile: CompanyProfile = {
  name: '',
  company_website: '',
  company_industry: '',
  company_size: '',
  company_location: '',
  company_phone: '',
}

function getErrorMessage(error: unknown) {
  return error instanceof Error ? error.message : 'Something went wrong.'
}

function formatDate(value: string) {
  return new Intl.DateTimeFormat(undefined, {
    dateStyle: 'long',
    timeStyle: 'short',
  }).format(new Date(value))
}

export default function Settings() {
  const { user, signOut, refreshSession } = useAuth()
  const navigate = useNavigate()
  const [company, setCompany] = useState<CompanyProfile>(emptyCompanyProfile)
  const [recruiterName, setRecruiterName] = useState('')
  const [recruiterTitle, setRecruiterTitle] = useState('')
  const [recruiterPhone, setRecruiterPhone] = useState('')
  const [workspaceId, setWorkspaceId] = useState('')
  const [canManageCompany, setCanManageCompany] = useState(false)
  const [deletionRequest, setDeletionRequest] =
    useState<DeletionRequest | null>(null)
  const [loading, setLoading] = useState(true)
  const [savingCompany, setSavingCompany] = useState(false)
  const [savingRecruiter, setSavingRecruiter] = useState(false)
  const [requestingDeletion, setRequestingDeletion] = useState(false)
  const [signingOut, setSigningOut] = useState(false)
  const [errorMessage, setErrorMessage] = useState('')
  const [successMessage, setSuccessMessage] = useState('')

  useEffect(() => {
    let active = true

    async function loadSettings() {
      setLoading(true)
      setErrorMessage('')

      if (!user || !supabase) {
        setLoading(false)
        if (!supabase) setErrorMessage('Supabase is not configured.')
        return
      }

      setRecruiterName(user.user_metadata?.full_name?.trim() ?? '')
      setRecruiterTitle(user.user_metadata?.job_title?.trim() ?? '')
      setRecruiterPhone(user.user_metadata?.phone?.trim() ?? '')

      const { data: memberships, error: membershipError } = await supabase
        .from('workspace_members')
        .select('workspace_id, role')
        .eq('user_id', user.id)
        .limit(2)

      if (!active) return

      if (membershipError) {
        setErrorMessage(membershipError.message)
        setLoading(false)
        return
      }

      if (!memberships?.length) {
        setErrorMessage('No workspace is associated with this account.')
        setLoading(false)
        return
      }

      if (memberships.length > 1) {
        setErrorMessage(
          'This account belongs to multiple workspaces. Select an active workspace before changing company settings.',
        )
        setLoading(false)
        return
      }

      const membership = memberships[0]
      setWorkspaceId(membership.workspace_id)
      setCanManageCompany(
        membership.role === 'owner' || membership.role === 'admin',
      )

      const [workspaceResult, deletionResult] = await Promise.all([
        supabase
          .from('workspaces')
          .select(
            'name, company_website, company_industry, company_size, company_location, company_phone',
          )
          .eq('id', membership.workspace_id)
          .maybeSingle(),
        supabase
          .from('account_deletion_requests')
          .select('requested_at, scheduled_for, status')
          .maybeSingle(),
      ])

      if (!active) return

      const errors: string[] = []
      if (workspaceResult.error) {
        errors.push(workspaceResult.error.message)
      } else if (workspaceResult.data) {
        setCompany({
          name: workspaceResult.data.name ?? '',
          company_website: workspaceResult.data.company_website ?? '',
          company_industry: workspaceResult.data.company_industry ?? '',
          company_size: workspaceResult.data.company_size ?? '',
          company_location: workspaceResult.data.company_location ?? '',
          company_phone: workspaceResult.data.company_phone ?? '',
        })
      }

      if (deletionResult.error) {
        errors.push(deletionResult.error.message)
      } else if (deletionResult.data) {
        setDeletionRequest(
          deletionResult.data as DeletionRequest,
        )
      }

      if (errors.length) setErrorMessage(errors.join(' '))
      setLoading(false)
    }

    void loadSettings()
    return () => {
      active = false
    }
  }, [user])

  async function handleCompanySave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setErrorMessage('')
    setSuccessMessage('')

    if (!supabase || !workspaceId) {
      setErrorMessage('The workspace is not available. Please try again.')
      return
    }
    if (!canManageCompany) {
      setErrorMessage('Only workspace owners and admins can edit company details.')
      return
    }

    const companyName = company.name.trim()
    if (companyName.length < 2 || companyName.length > 120) {
      setErrorMessage('Company or workspace name must be 2 to 120 characters.')
      return
    }

    setSavingCompany(true)

    try {
      const { data, error } = await supabase
        .from('workspaces')
        .update({
          name: companyName,
          company_website: company.company_website.trim() || null,
          company_industry: company.company_industry.trim() || null,
          company_size: company.company_size || null,
          company_location: company.company_location.trim() || null,
          company_phone: company.company_phone.trim() || null,
        })
        .eq('id', workspaceId)
        .select('id')
        .maybeSingle()

      if (error) throw error
      if (!data) {
        throw new Error(
          'Company details were not saved. Check your workspace permissions and try again.',
        )
      }

      setCompany((current) => ({ ...current, name: companyName }))
      setSuccessMessage('Company details saved.')
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
    } finally {
      setSavingCompany(false)
    }
  }

  async function handleRecruiterSave(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setErrorMessage('')
    setSuccessMessage('')

    if (!supabase) {
      setErrorMessage('Authentication is not configured.')
      return
    }

    const name = recruiterName.trim()
    if (name.length < 2 || name.length > 120) {
      setErrorMessage('Enter a name between 2 and 120 characters.')
      return
    }

    setSavingRecruiter(true)

    try {
      const { error } = await supabase.auth.updateUser({
        data: {
          full_name: name,
          job_title: recruiterTitle.trim(),
          phone: recruiterPhone.trim(),
        },
      })

      if (error) throw error

      await refreshSession()
      setSuccessMessage('Recruiter details saved.')
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
    } finally {
      setSavingRecruiter(false)
    }
  }

  async function handleRequestDeletion() {
    if (!supabase || !user) {
      setErrorMessage('Sign in before requesting account deletion.')
      return
    }

    const confirmed = window.confirm(
      'Schedule this recruiter account for deletion? The account can be recovered for 15 days by signing in again. Shared workspace records will stay with the team; if this is the only workspace member, its data and uploaded resumes will also be deleted.',
    )
    if (!confirmed) return

    setErrorMessage('')
    setSuccessMessage('')
    setRequestingDeletion(true)

    try {
      const { data: scheduledFor, error } = await supabase.rpc(
        'request_account_deletion',
      )

      if (error) throw error

      const { error: signOutError } = await signOut()
      if (signOutError) {
        setDeletionRequest({
          requested_at: new Date().toISOString(),
          scheduled_for: scheduledFor,
          status: 'pending',
        })
        throw new Error(
          `Deletion is scheduled for ${formatDate(scheduledFor)}, but sign-out failed: ${signOutError.message}. You can cancel the request here.`,
        )
      }

      navigate('/login', { replace: true })
    } catch (error) {
      setErrorMessage(getErrorMessage(error))
    } finally {
      setRequestingDeletion(false)
    }
  }

  async function handleSignOut() {
    setErrorMessage('')
    setSigningOut(true)
    const { error } = await signOut()
    setSigningOut(false)

    if (error) {
      setErrorMessage(error.message)
      return
    }

    navigate('/login', { replace: true })
  }

  return (
    <div className="settings-page">
      <header className="page-header">
        <div>
          <p className="eyebrow">WORKSPACE & ACCOUNT</p>
          <h1>Settings</h1>
          <p className="page-description">
            Manage your company profile, recruiter details, and account access.
          </p>
        </div>
      </header>

      {errorMessage && (
        <div className="form-alert form-alert-error" role="alert">
          {errorMessage}
        </div>
      )}
      {successMessage && (
        <div className="form-alert form-alert-success" role="status">
          {successMessage}
        </div>
      )}

      {loading ? (
        <div className="dashboard-panel settings-panel settings-loading">
          <span className="loading-spinner" />
          <p>Loading your settings...</p>
        </div>
      ) : (
        <>
          <section className="dashboard-panel settings-panel">
            <div className="dashboard-panel-header">
              <div>
                <h2>Company details</h2>
                <p>Workspace information shared with your recruiting team.</p>
              </div>
              <Building2 size={19} className="settings-heading-icon" />
            </div>

            <form className="settings-form" onSubmit={handleCompanySave}>
              {!canManageCompany && (
                <p className="settings-notice">
                  Only workspace owners and admins can edit company details.
                </p>
              )}
              <div className="settings-form-grid">
                <div className="settings-field">
                  <label className="field-label" htmlFor="company-name">
                    Company or workspace name *
                  </label>
                  <input
                    id="company-name"
                    className="form-input"
                    value={company.name}
                    onChange={(event) =>
                      setCompany({ ...company, name: event.target.value })
                    }
                    minLength={2}
                    maxLength={120}
                    required
                    disabled={!canManageCompany}
                  />
                </div>
                <div className="settings-field">
                  <label className="field-label" htmlFor="company-website">
                    Company website
                  </label>
                  <input
                    id="company-website"
                    className="form-input"
                    type="url"
                    value={company.company_website}
                    onChange={(event) =>
                      setCompany({
                        ...company,
                        company_website: event.target.value,
                      })
                    }
                    placeholder="https://company.com"
                    maxLength={255}
                    disabled={!canManageCompany}
                  />
                </div>
                <div className="settings-field">
                  <label className="field-label" htmlFor="company-industry">
                    Industry
                  </label>
                  <input
                    id="company-industry"
                    className="form-input"
                    value={company.company_industry}
                    onChange={(event) =>
                      setCompany({
                        ...company,
                        company_industry: event.target.value,
                      })
                    }
                    placeholder="e.g. Software and technology"
                    maxLength={120}
                    disabled={!canManageCompany}
                  />
                </div>
                <div className="settings-field">
                  <label className="field-label" htmlFor="company-size">
                    Company size
                  </label>
                  <select
                    id="company-size"
                    className="form-select"
                    value={company.company_size}
                    onChange={(event) =>
                      setCompany({
                        ...company,
                        company_size: event.target.value,
                      })
                    }
                    disabled={!canManageCompany}
                  >
                    <option value="">Select company size</option>
                    <option value="1-10">1-10 employees</option>
                    <option value="11-50">11-50 employees</option>
                    <option value="51-200">51-200 employees</option>
                    <option value="201-500">201-500 employees</option>
                    <option value="501-1000">501-1,000 employees</option>
                    <option value="1001+">1,001+ employees</option>
                  </select>
                </div>
                <div className="settings-field">
                  <label className="field-label" htmlFor="company-location">
                    Company location
                  </label>
                  <input
                    id="company-location"
                    className="form-input"
                    value={company.company_location}
                    onChange={(event) =>
                      setCompany({
                        ...company,
                        company_location: event.target.value,
                      })
                    }
                    placeholder="City, country"
                    maxLength={160}
                    disabled={!canManageCompany}
                  />
                </div>
                <div className="settings-field">
                  <label className="field-label" htmlFor="company-phone">
                    Company phone
                  </label>
                  <input
                    id="company-phone"
                    className="form-input"
                    type="tel"
                    value={company.company_phone}
                    onChange={(event) =>
                      setCompany({
                        ...company,
                        company_phone: event.target.value,
                      })
                    }
                    autoComplete="tel"
                    maxLength={40}
                    disabled={!canManageCompany}
                  />
                </div>
              </div>
              {canManageCompany && (
                <div className="settings-form-actions">
                  <button
                    type="submit"
                    className="button button-primary"
                    disabled={savingCompany}
                  >
                    {savingCompany ? 'Saving...' : 'Save company details'}
                  </button>
                </div>
              )}
            </form>
          </section>

          <section className="dashboard-panel settings-panel">
            <div className="dashboard-panel-header">
              <div>
                <h2>Recruiter details</h2>
                <p>Your personal profile shown to your team.</p>
              </div>
              <UserRound size={19} className="settings-heading-icon" />
            </div>

            <form className="settings-form" onSubmit={handleRecruiterSave}>
              <div className="settings-form-grid">
                <div className="settings-field">
                  <label className="field-label" htmlFor="recruiter-name">
                    Full name *
                  </label>
                  <input
                    id="recruiter-name"
                    className="form-input"
                    value={recruiterName}
                    onChange={(event) => setRecruiterName(event.target.value)}
                    autoComplete="name"
                    minLength={2}
                    maxLength={120}
                    required
                  />
                </div>
                <div className="settings-field">
                  <label className="field-label" htmlFor="recruiter-email">
                    Account email
                  </label>
                  <input
                    id="recruiter-email"
                    className="form-input"
                    type="email"
                    value={user?.email ?? ''}
                    readOnly
                    aria-describedby="recruiter-email-help"
                  />
                  <small className="settings-field-help" id="recruiter-email-help">
                    Email changes are managed through account verification.
                  </small>
                </div>
                <div className="settings-field">
                  <label className="field-label" htmlFor="recruiter-title">
                    Job title
                  </label>
                  <input
                    id="recruiter-title"
                    className="form-input"
                    value={recruiterTitle}
                    onChange={(event) => setRecruiterTitle(event.target.value)}
                    placeholder="e.g. Talent Acquisition Partner"
                    maxLength={120}
                  />
                </div>
                <div className="settings-field">
                  <label className="field-label" htmlFor="recruiter-phone">
                    Phone number
                  </label>
                  <input
                    id="recruiter-phone"
                    className="form-input"
                    type="tel"
                    value={recruiterPhone}
                    onChange={(event) => setRecruiterPhone(event.target.value)}
                    autoComplete="tel"
                    maxLength={40}
                  />
                </div>
              </div>
              <div className="settings-form-actions">
                <button
                  type="submit"
                  className="button button-primary"
                  disabled={savingRecruiter}
                >
                  {savingRecruiter ? 'Saving...' : 'Save recruiter details'}
                </button>
              </div>
            </form>
          </section>

          <section className="dashboard-panel settings-panel">
            <div className="dashboard-panel-header">
              <div>
                <h2>AI screening</h2>
                <p>Planned tools for consistent, evidence-based hiring.</p>
              </div>
              <BrainCircuit size={19} className="settings-heading-icon" />
            </div>
            <div className="settings-feature-grid">
              <article className="settings-feature-card">
                <span className="settings-feature-icon">
                  <Sparkles size={17} />
                </span>
                <div>
                  <strong>AI resume shortlisting</strong>
                  <p>
                    Configure resume criteria, weighting, and shortlist
                    recommendations.
                  </p>
                </div>
                <span className="settings-coming-soon">Coming soon</span>
              </article>
              <article className="settings-feature-card">
                <span className="settings-feature-icon">
                  <BrainCircuit size={17} />
                </span>
                <div>
                  <strong>Interview screening</strong>
                  <p>
                    Set screening questions, evaluation criteria, and reviewer
                    guidance.
                  </p>
                </div>
                <span className="settings-coming-soon">Coming soon</span>
              </article>
            </div>
            <p className="settings-feature-note">
              These controls are a preview only. No automated screening or
              candidate scoring is active yet.
            </p>
          </section>

          <section className="dashboard-panel settings-panel">
            <div className="dashboard-panel-header">
              <div>
                <h2>Sign-in and security</h2>
                <p>Manage password access and end your current session.</p>
              </div>
              <KeyRound size={19} className="settings-heading-icon" />
            </div>

            <div className="settings-action-row">
              <span className="settings-action-icon">
                <KeyRound size={18} />
              </span>
              <span className="settings-action-copy">
                <strong>Password</strong>
                <small>Request a secure password reset link by email.</small>
              </span>
              <Link className="text-link" to="/forgot-password">
                Reset password
                <ArrowRight size={15} />
              </Link>
            </div>
            <div className="settings-action-row settings-signout-row">
              <span className="settings-action-icon">
                <LogOut size={18} />
              </span>
              <span className="settings-action-copy">
                <strong>Sign out</strong>
                <small>End your current ProofHire session.</small>
              </span>
              <button
                type="button"
                className="button button-secondary"
                onClick={() => void handleSignOut()}
                disabled={signingOut}
              >
                {signingOut ? 'Signing out...' : 'Sign out'}
              </button>
            </div>
          </section>

          <section className="dashboard-panel settings-panel settings-danger-panel">
            <div className="dashboard-panel-header">
              <div>
                <h2>Delete account</h2>
                <p>Schedule removal of this recruiter account.</p>
              </div>
              <ShieldAlert size={19} className="settings-danger-icon" />
            </div>

            {deletionRequest ? (
              <div className="settings-deletion-state">
                <div className="settings-danger-copy">
                  <strong>
                    {deletionRequest.status === 'processing'
                      ? 'Account deletion is being processed'
                      : 'Account deletion is scheduled'}
                  </strong>
                  <p>
                    {deletionRequest.status === 'pending'
                      ? `Your account is scheduled for deletion on ${formatDate(deletionRequest.scheduled_for)}. Cancellation is temporarily unavailable; contact support if you need help.`
                      : 'The grace period has ended. Deletion can no longer be canceled.'}
                  </p>
                </div>
              </div>
            ) : (
              <div className="settings-deletion-state">
                <div className="settings-danger-copy">
                  <strong>15-day recovery period</strong>
                  <p>
                    Your account remains scheduled for deletion for 15 days.
                    Cancellation is temporarily unavailable; contact support
                    if you need help. Team workspaces and recruiting records
                    are retained; if you are the only workspace member, that
                    workspace and its uploaded resumes are deleted too.
                  </p>
                </div>
                <button
                  type="button"
                  className="button button-danger"
                  onClick={() => void handleRequestDeletion()}
                  disabled={requestingDeletion}
                >
                  {requestingDeletion
                    ? 'Scheduling...'
                    : 'Schedule account deletion'}
                </button>
              </div>
            )}
          </section>
        </>
      )}
    </div>
  )
}
