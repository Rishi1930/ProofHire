
import { useEffect, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ArrowLeft, BriefcaseBusiness, CheckCircle2, FileText, LoaderCircle, UploadCloud } from 'lucide-react'

import { supabase } from '../lib/supabase'
import { uploadPublicResume } from '../lib/resumeStorage'
import { getErrorMessage, isAllowedResumeFile } from '../lib/utils'

type PublicJob = {
  id: string
  title: string
  workspace_id: string
  status: string
}

type SubmissionResult = {
  success: boolean
  duplicate: boolean
}

const MAX_RESUME_SIZE = 5 * 1024 * 1024

export default function PublicApplication() {
  const { jobId } = useParams<{ jobId: string }>()

  const [job, setJob] = useState<PublicJob | null>(null)
  const [loadingJob, setLoadingJob] = useState(true)
  const [loadError, setLoadError] = useState('')
  const [fullName, setFullName] = useState('')
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [coverLetter, setCoverLetter] = useState('')
  const [resume, setResume] = useState<File | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [formError, setFormError] = useState('')
  const [submitted, setSubmitted] = useState(false)
  const [duplicate, setDuplicate] = useState(false)

  useEffect(() => {
    let active = true

    async function loadJob() {
      setLoadingJob(true)
      setLoadError('')

      if (!supabase) {
        setLoadError('The application portal is not configured yet.')
        setLoadingJob(false)
        return
      }

      if (!jobId) {
        setLoadError('This application link is invalid.')
        setLoadingJob(false)
        return
      }

      const { data, error } = await supabase
        .from('jobs')
        .select('id, title, workspace_id, status')
        .eq('id', jobId)
        .eq('status', 'open')
        .maybeSingle()

      if (!active) return

      if (error) {
        setLoadError('We could not load this role. Please try again later.')
      } else if (!data) {
        setLoadError('This role is no longer accepting applications.')
      } else {
        setJob(data as PublicJob)
      }

      setLoadingJob(false)
    }

    void loadJob()

    return () => {
      active = false
    }
  }, [jobId])

  function handleResumeChange(file: File | null) {
    setFormError('')

    if (!file) {
      setResume(null)
      return
    }

    if (!isAllowedResumeFile(file)) {
      setResume(null)
      setFormError('Choose a PDF, DOC, or DOCX resume.')
      return
    }

    if (file.size > MAX_RESUME_SIZE) {
      setResume(null)
      setFormError('Your resume must be 5 MB or smaller.')
      return
    }

    setResume(file)
  }

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    setFormError('')

    if (!supabase) {
      setFormError('The application portal is not configured yet.')
      return
    }

    if (!job || !jobId) {
      setFormError('This job is unavailable.')
      return
    }

    if (!resume) {
      setFormError('Please attach your resume before submitting.')
      return
    }

    if (fullName.trim().length < 2) {
      setFormError('Enter your full name.')
      return
    }

    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email.trim())) {
      setFormError('Enter a valid email address.')
      return
    }

    setSubmitting(true)

    try {
      const resumePath = await uploadPublicResume(
        resume,
        job.workspace_id,
        job.id,
      )

      const { data, error } = await supabase.rpc(
        'submit_public_application',
        {
          p_job_id: job.id,
          p_full_name: fullName.trim(),
          p_email: email.trim().toLowerCase(),
          p_phone: phone.trim() || null,
          p_cover_letter: coverLetter.trim() || null,
          p_resume_path: resumePath,
        },
      )

      if (error) {
        throw new Error(error.message)
      }

      const result = data as SubmissionResult | null

      if (!result?.success) {
        throw new Error('We could not confirm your application. Please try again.')
      }

      setDuplicate(Boolean(result.duplicate))
      setSubmitted(true)
    } catch (error) {
      setFormError(getErrorMessage(error, 'Something went wrong. Please try again.'))
    } finally {
      setSubmitting(false)
    }
  }

  if (loadingJob) {
    return (
      <main className="public-application-page">
        <div className="public-application-card public-application-message">
          <LoaderCircle className="loading-spinner" size={28} />
          <p>Loading application details...</p>
        </div>
      </main>
    )
  }

  if (loadError || !job) {
    return (
      <main className="public-application-page">
        <div className="public-application-card public-application-message">
          <BriefcaseBusiness size={32} />
          <h1>Application unavailable</h1>
          <p>{loadError || 'This role is not available.'}</p>
          <Link to="/login" className="button button-secondary">
            <ArrowLeft size={16} />
            Recruiter sign in
          </Link>
        </div>
      </main>
    )
  }

  if (submitted) {
    return (
      <main className="public-application-page">
        <section className="public-application-card public-application-message">
          <CheckCircle2 size={48} className="application-success-icon" />
          <h1>{duplicate ? 'Application already received' : 'Application submitted'}</h1>
          <p>
            {duplicate
              ? 'An application for this role already exists for your email address. If you need to update your details, contact the recruiting team.'
              : `Thank you, ${fullName.trim()}. Your application for ${job.title} has been received.`}
          </p>
          <p className="application-confirmation-note">
            You may close this page now.
          </p>
        </section>
      </main>
    )
  }

  return (
    <main className="public-application-page">
      <section className="public-application-card">
        <div className="public-application-brand">
          <span className="public-application-brand-icon">
            <BriefcaseBusiness size={21} />
          </span>
          <span>ProofHire</span>
        </div>

        <div className="public-application-heading">
          <p className="eyebrow">CAREER OPPORTUNITY</p>
          <h1>Apply for this role</h1>
          <p className="public-application-job-title">{job.title}</p>
          <p className="public-application-intro">
            Share your details and resume with the recruiting team.
          </p>
        </div>

        <form onSubmit={handleSubmit} className="public-application-form">
          <div className="form-field">
            <label htmlFor="applicant-name">Full name <span>*</span></label>
            <input
              id="applicant-name"
              name="fullName"
              autoComplete="name"
              value={fullName}
              onChange={(event) => setFullName(event.target.value)}
              placeholder="Enter your full name"
              maxLength={120}
              required
              disabled={submitting}
            />
          </div>

          <div className="form-field">
            <label htmlFor="applicant-email">Email address <span>*</span></label>
            <input
              id="applicant-email"
              name="email"
              type="email"
              autoComplete="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              placeholder="you@example.com"
              maxLength={254}
              required
              disabled={submitting}
            />
          </div>

          <div className="form-field">
            <label htmlFor="applicant-phone">Phone number</label>
            <input
              id="applicant-phone"
              name="phone"
              type="tel"
              autoComplete="tel"
              value={phone}
              onChange={(event) => setPhone(event.target.value)}
              placeholder="Your contact number"
              maxLength={30}
              disabled={submitting}
            />
          </div>

          <div className="form-field">
            <label htmlFor="applicant-cover-letter">Cover letter <span className="optional-label">Optional</span></label>
            <textarea
              id="applicant-cover-letter"
              name="coverLetter"
              value={coverLetter}
              onChange={(event) => setCoverLetter(event.target.value)}
              placeholder="Briefly tell us why you're a good fit..."
              rows={5}
              maxLength={5000}
              disabled={submitting}
            />
          </div>

          <div className="form-field">
            <label htmlFor="applicant-resume">Resume <span>*</span></label>
            <label
              htmlFor="applicant-resume"
              className="resume-upload-area"
            >
              <span className="resume-upload-icon">
                {resume ? <FileText size={25} /> : <UploadCloud size={25} />}
              </span>
              <strong>{resume ? resume.name : 'Upload your resume'}</strong>
              <span>
                {resume
                  ? `${(resume.size / 1024 / 1024).toFixed(2)} MB`
                  : 'PDF, DOC or DOCX · Maximum 5 MB'}
              </span>
              <span className="resume-upload-action">
                {resume ? 'Choose a different file' : 'Browse files'}
              </span>
            </label>
            <input
              id="applicant-resume"
              name="resume"
              type="file"
              accept=".pdf,.doc,.docx,application/pdf,application/msword,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
              onChange={(event) => handleResumeChange(event.target.files?.[0] ?? null)}
              disabled={submitting}
              required={!resume}
              className="visually-hidden-file-input"
            />
          </div>

          {formError && (
            <p className="form-error-message" role="alert">
              {formError}
            </p>
          )}

          <button
            type="submit"
            className="button button-primary public-application-submit"
            disabled={submitting}
          >
            {submitting ? (
              <>
                <LoaderCircle size={17} className="spin-icon" />
                Submitting application...
              </>
            ) : (
              'Submit application'
            )}
          </button>

          <p className="public-application-privacy">
            Your information will be shared with the recruiting team for this role.
          </p>
        </form>
      </section>
    </main>
  )
}
