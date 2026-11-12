
import { useEffect, useRef, useState, type FormEvent } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ArrowLeft, BriefcaseBusiness, CheckCircle2, FileText, LoaderCircle, UploadCloud } from 'lucide-react'

import { supabase } from '../lib/supabase'
import { uploadPublicResume } from '../lib/resumeStorage'
import { getErrorMessage, isAllowedResumeFile } from '../lib/utils'
import BrandMark from '../components/BrandMark'
import {
  emptyResumeProfile,
  extractResumeText,
  parseResumeProfile,
  type ResumeExperience,
  type ResumeProfile,
} from './resumeParser'

type PublicJob = {
  id: string
  title: string
  workspace_id: string
  status: string
  required_skills: string[]
  preferred_skills: string[]
  minimum_experience: number | null
}

type SubmissionResult = {
  success: boolean
  duplicate: boolean
}

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
  const [resumeProfile, setResumeProfile] = useState<ResumeProfile>(emptyResumeProfile)
  const [skillsText, setSkillsText] = useState('')
  const [experienceYearsText, setExperienceYearsText] = useState('')
  const [experienceSummary, setExperienceSummary] = useState('')
  const [extractingResume, setExtractingResume] = useState(false)
  const extractionRequest = useRef(0)
  const resumeInputRef = useRef<HTMLInputElement | null>(null)
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
        .select('id, title, workspace_id, status, required_skills, preferred_skills, minimum_experience')
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
    const requestId = ++extractionRequest.current

    if (!file) {
      clearResumeDetails()
      setExtractingResume(false)
      return
    }

    if (!isAllowedResumeFile(file)) {
      clearResumeDetails()
      setExtractingResume(false)
      setFormError('Choose a PDF or DOCX resume.')
      return
    }

    if (!/\.(pdf|docx)$/i.test(file.name)) {
      clearResumeDetails()
      setExtractingResume(false)
      setFormError('Automatic resume extraction supports PDF and DOCX files.')
      return
    }

    setResume(file)
    setFullName('')
    setEmail('')
    setPhone('')
    setExtractingResume(false)
    setResumeProfile(emptyResumeProfile())
    setSkillsText('')
    setExperienceYearsText('')
    setExperienceSummary('')
    setExtractingResume(true)
    void (async () => {
      try {
        const text = await extractResumeText(file)
        if (requestId !== extractionRequest.current) return
        const profile = parseResumeProfile(
          text,
          [...(job?.required_skills ?? []), ...(job?.preferred_skills ?? [])],
        )
        setResumeProfile(profile)
        setFullName(profile.fullName)
        setEmail(profile.email)
        setPhone(profile.phone)
        setSkillsText(profile.skills.join(', '))
        setExperienceYearsText(
          profile.experienceYears === null ? '' : String(profile.experienceYears),
        )
        setExperienceSummary(profile.experienceSummary)
      } catch (error) {
        if (requestId === extractionRequest.current) {
          setFormError(getErrorMessage(error, 'Could not extract text from this resume.'))
          clearResumeDetails()
        }
      } finally {
        if (requestId === extractionRequest.current) setExtractingResume(false)
      }
    })()
  }

  function clearResumeDetails() {
    setResume(null)
    setResumeProfile(emptyResumeProfile())
    setFullName('')
    setEmail('')
    setPhone('')
    setSkillsText('')
    setExperienceYearsText('')
    setExperienceSummary('')
    if (resumeInputRef.current) resumeInputRef.current.value = ''
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

    if (!resume || extractingResume) {
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

    if (!phone.trim()) {
      setFormError('Enter a mobile number so the recruiting team can contact you.')
      return
    }

    if (!resumeProfile.education.trim()) {
      setFormError('Add your education details. They were not found in the resume.')
      return
    }

    const skills = skillsText.split(',').map((skill) => skill.trim()).filter(Boolean)
    if (skills.length === 0) {
      setFormError('Add your skills. They were not found in the resume.')
      return
    }

    const experienceYears = experienceYearsText.trim() === ''
      ? null
      : Number(experienceYearsText)
    if (
      job.minimum_experience !== null &&
      job.minimum_experience > 0 &&
      (experienceYears === null || !Number.isFinite(experienceYears))
    ) {
      setFormError(`Enter your years of experience for this job (minimum requirement: ${job.minimum_experience} years).`)
      return
    }
    if (experienceYears !== null && (!Number.isFinite(experienceYears) || experienceYears < 0 || experienceYears > 60)) {
      setFormError('Years of experience must be between 0 and 60.')
      return
    }

    const experiences = experienceYears !== null && experienceYears > 0
      ? (resumeProfile.experience.length ? resumeProfile.experience : [{ company: '', role: '' }])
      : resumeProfile.experience
    if (experienceYears !== null && experienceYears > 0 && experiences.some(
      (experience) => !experience.company.trim() || !experience.role.trim(),
    )) {
      setFormError('For work experience above 0 years, add the company and role.')
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
          p_resume_profile: {
            version: 1,
            education: resumeProfile.education.trim(),
            skills,
            experience_years: experienceYears,
            experience: experiences.map((experience) => ({
              company: experience.company.trim(),
              role: experience.role.trim(),
            })),
            experience_summary: experienceSummary.trim(),
            extraction_reviewed: true,
          },
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

  const experienceRows = resumeProfile.experience.length
    ? resumeProfile.experience
    : Number(experienceYearsText) > 0
      ? [{ company: '', role: '' }]
      : []

  function updateExperience(
    index: number,
    field: keyof ResumeExperience,
    value: string,
  ) {
    const current = resumeProfile.experience.length
      ? resumeProfile.experience
      : [{ company: '', role: '' }]
    const next = current.map((item, itemIndex) =>
      itemIndex === index ? { ...item, [field]: value } : item,
    )
    setResumeProfile({ ...resumeProfile, experience: next })
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
          <BrandMark className="public-application-brand-icon" />
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
                  : 'PDF or DOCX · Maximum 5 MB'}
              </span>
              <span className="resume-upload-action">
                {resume ? 'Choose a different file' : 'Browse files'}
              </span>
            </label>
            <input
              id="applicant-resume"
              ref={resumeInputRef}
              name="resume"
              type="file"
              accept=".pdf,.docx,application/pdf,application/vnd.openxmlformats-officedocument.wordprocessingml.document"
              onChange={(event) => handleResumeChange(event.target.files?.[0] ?? null)}
              disabled={submitting}
              required={!resume}
              className="visually-hidden-file-input"
            />
            {extractingResume && (
              <p className="application-confirmation-note" role="status">
                <LoaderCircle size={15} className="spin-icon" /> Extracting resume details in your browser...
              </p>
            )}
            {resume && !extractingResume && !formError && (
              <p className="application-confirmation-note" role="status">
                Resume text extracted. Please review and complete any missing or incorrect details below.
              </p>
            )}
            <p className="application-confirmation-note">
              Your resume is parsed locally in this browser before upload. Scanned/image-only PDFs need a text-based PDF or DOCX version.
            </p>
          </div>

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
            <label htmlFor="applicant-phone">Mobile number <span>*</span></label>
            <input
              id="applicant-phone"
              name="phone"
              type="tel"
              autoComplete="tel"
              value={phone}
              onChange={(event) => setPhone(event.target.value)}
              placeholder="Your contact number"
              maxLength={30}
              required
              disabled={submitting}
            />
          </div>

          <div className="form-field">
            <label htmlFor="applicant-education">Education <span>*</span></label>
            <textarea
              id="applicant-education"
              name="education"
              value={resumeProfile.education}
              onChange={(event) => setResumeProfile({ ...resumeProfile, education: event.target.value })}
              placeholder="Education was not found in your resume. Add your qualification and institution."
              rows={3}
              maxLength={4000}
              required
              disabled={submitting}
            />
          </div>

          <div className="form-field">
            <label htmlFor="applicant-skills">Skills <span>*</span></label>
            <input
              id="applicant-skills"
              name="skills"
              value={skillsText}
              onChange={(event) => setSkillsText(event.target.value)}
              placeholder="Enter skills separated by commas"
              maxLength={4000}
              required
              disabled={submitting}
            />
            <p className="application-confirmation-note">
              Required for this job: {job.required_skills?.join(', ') || 'None specified'}
              {job.preferred_skills?.length ? ` · Preferred: ${job.preferred_skills.join(', ')}` : ''}
            </p>
          </div>

          <div className="form-field">
            <label htmlFor="applicant-experience-years">
              Years of relevant experience
              {job.minimum_experience !== null && job.minimum_experience > 0 && <span> *</span>}
            </label>
            <input
              id="applicant-experience-years"
              name="experienceYears"
              type="number"
              min="0"
              max="60"
              step="0.5"
              value={experienceYearsText}
              onChange={(event) => setExperienceYearsText(event.target.value)}
              placeholder={job.minimum_experience && job.minimum_experience > 0 ? `Minimum ${job.minimum_experience} years` : 'Not specified'}
              required={job.minimum_experience !== null && job.minimum_experience > 0}
              disabled={submitting}
            />
            {job.minimum_experience !== null && job.minimum_experience > 0 && (
              <p className="application-confirmation-note">
                The recruiter set a minimum of {job.minimum_experience} years. Enter 0 if you have no relevant experience.
              </p>
            )}
          </div>

          {experienceRows.map((experience, index) => (
            <div className="form-field" key={`experience-${index}`}>
              <label>Experience {index + 1}{Number(experienceYearsText) > 0 && <span> *</span>}</label>
              <div className="resume-experience-row">
                <input
                  aria-label={`Company for experience ${index + 1}`}
                  name={`experienceCompany-${index}`}
                  value={experience.company}
                  onChange={(event) => updateExperience(index, 'company', event.target.value)}
                  placeholder="Company"
                  maxLength={180}
                  required={Number(experienceYearsText) > 0}
                  disabled={submitting}
                />
                <input
                  aria-label={`Role for experience ${index + 1}`}
                  name={`experienceRole-${index}`}
                  value={experience.role}
                  onChange={(event) => updateExperience(index, 'role', event.target.value)}
                  placeholder="Role / job title"
                  maxLength={180}
                  required={Number(experienceYearsText) > 0}
                  disabled={submitting}
                />
              </div>
              {index === experienceRows.length - 1 && (
                <button
                  type="button"
                  className="text-button"
                  onClick={() => setResumeProfile({
                    ...resumeProfile,
                    experience: [...(resumeProfile.experience.length ? resumeProfile.experience : [{ company: '', role: '' }]), { company: '', role: '' }],
                  })}
                  disabled={submitting}
                >
                  Add another role
                </button>
              )}
            </div>
          ))}

          {experienceSummary && (
            <div className="form-field">
              <label htmlFor="applicant-experience-summary">Resume work history (review)</label>
              <textarea
                id="applicant-experience-summary"
                name="experienceSummary"
                value={experienceSummary}
                onChange={(event) => setExperienceSummary(event.target.value)}
                rows={4}
                maxLength={6000}
                disabled={submitting}
              />
            </div>
          )}

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
