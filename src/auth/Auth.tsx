
import { useState, type FormEvent } from 'react'
import { Link, useLocation, useNavigate } from 'react-router-dom'
import {
  ArrowRight,
  Eye,
  EyeOff,
  ShieldCheck,
  Sparkles,
} from 'lucide-react'

import { supabase } from '../lib/supabase'

type AuthMode = 'login' | 'register' | 'forgot' | 'reset'

function getMode(pathname: string): AuthMode {
  if (pathname === '/register') return 'register'
  if (pathname === '/forgot-password') return 'forgot'
  if (pathname === '/reset-password') return 'reset'
  return 'login'
}

export default function Auth() {
  const location = useLocation()
  const navigate = useNavigate()
  const mode = getMode(location.pathname)

  const [fullName, setFullName] = useState('')
  const [workspaceName, setWorkspaceName] = useState('')
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [showPassword, setShowPassword] = useState(false)
  const [loading, setLoading] = useState(false)
  const [message, setMessage] = useState('')
  const [errorMessage, setErrorMessage] = useState('')

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setMessage('')
    setErrorMessage('')

    if (!supabase) {
      setErrorMessage(
        'Authentication is not configured yet. Complete the Supabase setup first.',
      )
      return
    }

    setLoading(true)

    try {
      if (mode === 'login') {
        const { error } = await supabase.auth.signInWithPassword({
          email: email.trim(),
          password,
        })

        if (error) throw error

        const destination =
          (location.state as { from?: { pathname?: string } } | null)?.from
            ?.pathname ?? '/dashboard'

        navigate(destination, { replace: true })
      }

      if (mode === 'register') {
        if (password.length < 8) {
          throw new Error('Use a password with at least 8 characters.')
        }

        const { data, error } = await supabase.auth.signUp({
          email: email.trim(),
          password,
          options: {
            data: {
              full_name: fullName.trim(),
              workspace_name: workspaceName.trim(),
            },
          },
        })

        if (error) throw error

        if (data.session) {
          navigate('/dashboard', { replace: true })
        } else {
          setMessage(
            'Account created. Check your email to confirm your address before signing in.',
          )
        }
      }

      if (mode === 'forgot') {
        const { error } = await supabase.auth.resetPasswordForEmail(
          email.trim(),
          {
            redirectTo: `${window.location.origin}/reset-password`,
          },
        )

        if (error) throw error

        setMessage(
          'If an account exists for this email, password recovery instructions will be sent.',
        )
      }

      if (mode === 'reset') {
        if (password.length < 8) {
          throw new Error('Use a password with at least 8 characters.')
        }

        const { error } = await supabase.auth.updateUser({ password })

        if (error) throw error

        setMessage('Password updated successfully. You can now sign in.')
        navigate('/login', { replace: true })
      }
    } catch (error) {
      setErrorMessage(
        error instanceof Error
          ? error.message
          : 'Something went wrong. Please try again.',
      )
    } finally {
      setLoading(false)
    }
  }

  const titles: Record<AuthMode, string> = {
    login: 'Welcome back',
    register: 'Build your workspace',
    forgot: 'Reset your password',
    reset: 'Create a new password',
  }

  const descriptions: Record<AuthMode, string> = {
    login: 'Sign in to continue building your team.',
    register: 'Set up your recruitment workspace in minutes.',
    forgot: 'Enter your email and we’ll send recovery instructions.',
    reset: 'Choose a strong password for your account.',
  }

  return (
    <main className="auth-page">
      <section className="auth-visual">
        <Link to="/login" className="auth-brand">
          <span className="brand-mark">P</span>
          <span>ProofHire</span>
        </Link>

        <div className="auth-visual-content">
          <div className="auth-eyebrow">
            <Sparkles size={15} />
            RECRUITMENT, REIMAGINED
          </div>

          <h1>
            Find the right people.
            <br />
            Build the right future.
          </h1>

          <p>
            One thoughtful workspace for job applications, candidate
            management and a better hiring process.
          </p>

          <div className="auth-benefit">
            <span className="auth-benefit-icon">
              <ShieldCheck size={19} />
            </span>
            <div>
              <strong>Your team, in one place</strong>
              <span>Organized workflows and secure candidate records.</span>
            </div>
          </div>
        </div>

        <p className="auth-visual-footer">
          Built for teams that hire with purpose.
        </p>
      </section>

      <section className="auth-panel">
        <div className="auth-form-wrap">
          <div className="auth-mobile-brand">
            <span className="brand-mark">P</span>
            <strong>ProofHire</strong>
          </div>

          <div className="auth-heading">
            <span className="auth-form-eyebrow">
              {mode === 'register' ? 'GET STARTED' : 'YOUR WORKSPACE'}
            </span>
            <h2>{titles[mode]}</h2>
            <p>{descriptions[mode]}</p>
          </div>

          <form className="auth-form" onSubmit={handleSubmit}>
            {mode === 'register' && (
              <>
                <label className="field-label" htmlFor="fullName">
                  Full name
                </label>
                <input
                  id="fullName"
                  className="form-input"
                  value={fullName}
                  onChange={(event) => setFullName(event.target.value)}
                  autoComplete="name"
                  placeholder="Your full name"
                  minLength={2}
                  maxLength={120}
                  required
                />

                <label className="field-label" htmlFor="workspaceName">
                  Company or workspace name
                </label>
                <input
                  id="workspaceName"
                  className="form-input"
                  value={workspaceName}
                  onChange={(event) => setWorkspaceName(event.target.value)}
                  placeholder="e.g. Acme Talent Team"
                  minLength={2}
                  maxLength={120}
                  required
                />
              </>
            )}

            {mode !== 'reset' && (
              <>
                <label className="field-label" htmlFor="email">
                  Work email
                </label>
                <input
                  id="email"
                  className="form-input"
                  type="email"
                  value={email}
                  onChange={(event) => setEmail(event.target.value)}
                  autoComplete="email"
                  placeholder="you@company.com"
                  maxLength={254}
                  required
                />
              </>
            )}

            {mode !== 'forgot' && (
              <>
                <div className="field-label-row">
                  <label className="field-label" htmlFor="password">
                    {mode === 'reset' ? 'New password' : 'Password'}
                  </label>

                  {mode === 'login' && (
                    <Link to="/forgot-password" className="auth-inline-link">
                      Forgot password?
                    </Link>
                  )}
                </div>

                <div className="password-field">
                  <input
                    id="password"
                    className="form-input"
                    type={showPassword ? 'text' : 'password'}
                    value={password}
                    onChange={(event) => setPassword(event.target.value)}
                    autoComplete={
                      mode === 'login' ? 'current-password' : 'new-password'
                    }
                    placeholder={
                      mode === 'login'
                        ? 'Enter your password'
                        : 'At least 8 characters'
                    }
                    minLength={8}
                    maxLength={128}
                    required
                  />
                  <button
                    type="button"
                    className="password-toggle"
                    onClick={() => setShowPassword((current) => !current)}
                    aria-label={showPassword ? 'Hide password' : 'Show password'}
                  >
                    {showPassword ? <EyeOff size={18} /> : <Eye size={18} />}
                  </button>
                </div>
              </>
            )}

            {errorMessage && (
              <div className="form-alert form-alert-error" role="alert">
                {errorMessage}
              </div>
            )}

            {message && (
              <div className="form-alert form-alert-success" role="status">
                {message}
              </div>
            )}

            <button
              className="button button-primary auth-submit"
              type="submit"
              disabled={loading}
            >
              {loading ? (
                'Please wait...'
              ) : (
                <>
                  {mode === 'login' && 'Sign in'}
                  {mode === 'register' && 'Create workspace'}
                  {mode === 'forgot' && 'Send recovery instructions'}
                  {mode === 'reset' && 'Update password'}
                  <ArrowRight size={17} />
                </>
              )}
            </button>
          </form>

          <div className="auth-switch">
            {mode === 'login' && (
              <>
                New to ProofHire? <Link to="/register">Create an account</Link>
              </>
            )}

            {mode === 'register' && (
              <>
                Already have an account? <Link to="/login">Sign in</Link>
              </>
            )}

            {mode === 'forgot' && (
              <>
                Remember your password? <Link to="/login">Back to sign in</Link>
              </>
            )}

            {mode === 'reset' && (
              <>
                Back to your account? <Link to="/login">Sign in</Link>
              </>
            )}
          </div>

          <p className="auth-legal">
            By continuing, you agree to use ProofHire responsibly and protect
            candidate information handled by your workspace.
          </p>
        </div>
      </section>
    </main>
  )
}
