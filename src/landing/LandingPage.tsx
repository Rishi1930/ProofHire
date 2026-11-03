import { useState } from 'react'
import { Link } from 'react-router-dom'
import {
  ArrowDownRight,
  ArrowRight,
  BrainCircuit,
  Check,
  CircleCheck,
  Code2,
  Layers3,
  Menu,
  ShieldCheck,
  Sparkles,
  X,
} from 'lucide-react'

import BrandMark from '../components/BrandMark'
import './LandingPage.css'

const plans = [
  {
    name: 'Starter',
    price: '$99',
    tag: 'FOR SMALL TEAMS',
    features: [
      '1 active job posting',
      '250 evidence-based resume screenings/mo',
      'Basic candidate analytics',
      'Email support',
    ],
    cta: 'Start free trial',
  },
  {
    name: 'Pro Workspace',
    price: '$249',
    tag: 'MOST POPULAR',
    features: [
      'Unlimited active job listings',
      '1,500 evidence-based resume screenings/mo',
      'Custom skill-proof challenges',
      'Hiring pipeline analytics',
      'Dedicated success manager',
    ],
    cta: 'Start free trial',
    featured: true,
  },
  {
    name: 'Enterprise',
    price: 'Custom',
    tag: 'BUILT FOR SCALE',
    features: [
      'Custom assessment volume',
      'Unlimited everything',
      'SSO & advanced governance',
      'Priority support',
    ],
    cta: 'Talk to sales',
  },
]

function Brand() {
  return (
    <a className="ph-brand" href="#top">
      <BrandMark className="ph-brand-icon" />
      ProofHire
    </a>
  )
}

function DashboardPreview() {
  const candidates = [
    ['MC', 'Maya Chen', 'Senior Frontend Engineer', '94%'],
    ['DK', 'Daniel Kumar', 'Full Stack Developer', '88%'],
    ['PS', 'Priya Sharma', 'Product Designer', '76%'],
  ]

  return (
    <div className="ph-dashboard-wrap">
      <div className="ph-float-label">
        <Sparkles size={12} /> DETERMINISTIC SCREENING PREVIEW
      </div>
      <div className="ph-dashboard">
        <div className="ph-window-bar">
          <span className="ph-dots">
            <i />
            <i />
            <i />
          </span>
          <span>app.proofhire.ai / pipeline</span>
          <span className="ph-live">● DEMO DATA</span>
        </div>
        <div className="ph-dash-content">
          <div className="ph-metrics">
            <div>
              <b>12</b>
              <small>Open roles</small>
            </div>
            <div>
              <b>148</b>
              <small>In pipeline</small>
            </div>
            <div>
              <b>87%</b>
              <small>Alignment</small>
            </div>
          </div>
          <div className="ph-progress-label">
            <span>Screening progress</span>
            <span>Evidence-based assessment</span>
          </div>
          <div className="ph-progress">
            <i />
          </div>
          {candidates.map((candidate) => (
            <div className="ph-candidate" key={candidate[0]}>
              <span className="ph-avatar">{candidate[0]}</span>
              <span className="ph-candidate-text">
                <b>{candidate[1]}</b>
                <small>{candidate[2]}</small>
              </span>
              <strong className={candidate[3] === '76%' ? 'warm' : ''}>
                {candidate[3]}
              </strong>
            </div>
          ))}
          <div className="ph-success">
            <CircleCheck size={12} /> 3 profiles ready for review
          </div>
        </div>
      </div>
    </div>
  )
}

type FeatureVisualType = 'match' | 'proof' | 'pipeline'

function FeatureVisual({ type }: { type: FeatureVisualType }) {
  if (type === 'match') {
    const metrics = [
      ['Skills alignment', '92%'],
      ['Experience fit', '84%'],
      ['Proof quality', '76%'],
    ]

    return (
      <div className="ph-match-bars">
        {metrics.map(([label, value]) => (
          <div key={label}>
            <p>
              <span>{label}</span>
              <b>{value}</b>
            </p>
            <i>
              <span style={{ width: value }} />
            </i>
          </div>
        ))}
      </div>
    )
  }

  if (type === 'proof') {
    return (
      <ul className="ph-proof-list">
        <li>
          <Check size={12} /> React / TypeScript — verified
        </li>
        <li>
          <Check size={12} /> API design — 12/15
        </li>
        <li>
          <Check size={12} /> Portfolio review — passed
        </li>
      </ul>
    )
  }

  return (
    <div className="ph-kanban">
      {['NEW', 'ASSESSMENT', 'REVIEW'].map((column, index) => (
        <div key={column}>
          <small>{column}</small>
          {Array.from({ length: index === 2 ? 1 : 3 }).map((_, cardIndex) => (
            <i key={cardIndex} />
          ))}
        </div>
      ))}
    </div>
  )
}

function Demo() {
  const [role, setRole] = useState('Senior Frontend Engineer')
  const [candidate, setCandidate] = useState('Maya Chen')
  const [showReport, setShowReport] = useState(false)

  return (
    <div className="ph-demo-grid">
      <div className="ph-demo-form">
        <span className="ph-eyebrow">INTERACTIVE PREVIEW</span>
        <h3>See the workflow in action.</h3>
        <p>
          Choose a role and candidate to preview an evidence-led screening
          report.
        </p>
        <label htmlFor="ph-role">JOB ROLE</label>
        <select
          id="ph-role"
          value={role}
          onChange={(event) => {
            setRole(event.target.value)
            setShowReport(false)
          }}
        >
          <option>Senior Frontend Engineer</option>
          <option>Full Stack Developer</option>
          <option>Data Analyst</option>
          <option>Machine Learning Engineer</option>
        </select>
        <label htmlFor="ph-candidate">CANDIDATE</label>
        <select
          id="ph-candidate"
          value={candidate}
          onChange={(event) => {
            setCandidate(event.target.value)
            setShowReport(false)
          }}
        >
          <option>Maya Chen</option>
          <option>Daniel Kumar</option>
          <option>Priya Sharma</option>
        </select>
        <div className="ph-demo-note">
          <b>SCREENING CRITERIA</b>
          <p>
            Required skills, relevant experience, role alignment, and
            verifiable evidence.
          </p>
        </div>
        <button
          className="ph-btn ph-btn-primary ph-demo-button"
          type="button"
          onClick={() => setShowReport(true)}
        >
          <Sparkles size={14} /> Preview screening report
        </button>
        <small className="ph-disclaimer">
          Illustrative demo data — not a real candidate assessment.
        </small>
      </div>
      <div className="ph-demo-result">
        <div className="ph-window-bar">
          <span>proofhire.ai / screening-report</span>
          <span className="ph-live">● PREVIEW</span>
        </div>
        {showReport ? (
          <div className="ph-result">
            <span className="ph-eyebrow">SCREENING PREVIEW</span>
            <div className="ph-result-head">
              <div>
                <h4>{candidate}</h4>
                <p>{role}</p>
              </div>
              <b>
                87<span>/100</span>
              </b>
            </div>
            <div className="ph-result-bar">
              <i />
            </div>
            <div className="ph-result-status">
              <CircleCheck size={14} /> Strong alignment — recruiter review
              recommended
            </div>
            {[
              ['Required skills evidence', '4 of 5'],
              ['Relevant experience', 'Strong'],
              ['Follow-up needed', '1 requirement'],
            ].map(([label, value]) => (
              <div className="ph-result-row" key={label}>
                <span>{label}</span>
                <b>{value}</b>
              </div>
            ))}
            <p className="ph-disclaimer">
              Review the original resume and evidence before making a hiring
              decision.
            </p>
          </div>
        ) : (
          <div className="ph-empty">
            <span>
              <Code2 size={22} />
            </span>
            <h4>Your screening report</h4>
            <p>
              Select a candidate and role, then preview the sample report to see
              how evidence and role criteria can be presented.
            </p>
          </div>
        )}
      </div>
    </div>
  )
}

export default function LandingPage() {
  const [menuOpen, setMenuOpen] = useState(false)
  const [email, setEmail] = useState('')
  const [submitted, setSubmitted] = useState(false)
  const closeMenu = () => setMenuOpen(false)

  return (
    <main className="ph-landing" id="top">
      <header className="ph-header">
        <div className="ph-nav-wrap">
          <Brand />
          <button
            className="ph-menu"
            type="button"
            aria-label={menuOpen ? 'Close navigation' : 'Open navigation'}
            aria-expanded={menuOpen}
            onClick={() => setMenuOpen((open) => !open)}
          >
            {menuOpen ? <X size={21} /> : <Menu size={21} />}
          </button>
          <nav className={menuOpen ? 'open' : ''} aria-label="Main navigation">
            <a href="#features" onClick={closeMenu}>
              Features
            </a>
            <a href="#demo" onClick={closeMenu}>
              Screening Demo
            </a>
            <a href="#how" onClick={closeMenu}>
              How it works
            </a>
            <a href="#pricing" onClick={closeMenu}>
              Pricing
            </a>
            <div className="ph-nav-actions">
              <Link to="/login" className="ph-signin">
                Sign in
              </Link>
              <Link
                to="/register"
                onClick={closeMenu}
                className="ph-btn ph-btn-primary ph-btn-small"
              >
                Get started <ArrowRight size={13} />
              </Link>
            </div>
          </nav>
        </div>
      </header>

      <section className="ph-hero">
        <div className="ph-container ph-hero-grid">
          <div className="ph-hero-copy">
            <span className="ph-pill">
              <i /> RECRUITMENT, REIMAGINED
            </span>
            <h1>
              Hire with <em>proof,</em>
              <br />
              not promises.
            </h1>
            <p className="ph-hero-sub">
              The recruitment workspace that unifies deterministic resume
              screening, verified skill proofs, and a single hiring pipeline —
              so every decision is backed by evidence.
            </p>
            <div className="ph-hero-actions">
              <Link className="ph-btn ph-btn-primary" to="/register">
                Start free trial <ArrowRight size={14} />
              </Link>
              <a className="ph-btn ph-btn-ghost" href="#demo">
                <ArrowDownRight size={14} /> Try the screening demo
              </a>
            </div>
            <div className="ph-trust">
              <span>Evidence-based screening</span>
              <i />
              <span>Skills-first hiring</span>
              <i />
              <span>One pipeline</span>
            </div>
          </div>
          <DashboardPreview />
        </div>
        <div className="ph-marquee">
          <div>
            {[
              'HIRE WITH PROOF',
              'DETERMINISTIC SCREENING',
              'VERIFIED SKILL PROOFS',
              'UNIFIED PIPELINE',
              'ZERO-BIAS SHORTLISTS',
              'FASTER OFFERS',
            ].map((item) => (
              <span key={item}>
                {item}
                <b>✦</b>
              </span>
            ))}
          </div>
        </div>
      </section>

      <section className="ph-section" id="features">
        <div className="ph-container">
          <div className="ph-section-title">
            <span className="ph-eyebrow">WHY PROOFHIRE</span>
            <h2>Everything your hiring loop needs, in one workspace.</h2>
          </div>
          <div className="ph-feature-grid">
            {[
              {
                type: 'match' as const,
                icon: <BrainCircuit size={17} />,
                title: 'Evidence-backed Candidate Match Score',
                description:
                  'Instantly surface the strongest candidates against your role criteria with a clear, evidence-based match score.',
              },
              {
                type: 'proof' as const,
                icon: <ShieldCheck size={17} />,
                title: 'Verified Skill Proofs',
                description:
                  'Automated checks and validated assessments replace guesswork with meaningful evidence.',
              },
              {
                type: 'pipeline' as const,
                icon: <Layers3 size={17} />,
                title: 'Unified Pipeline Kanban',
                description:
                  'Keep every applicant, assessment, decision, and next step visible in one shared workspace.',
              },
            ].map((feature) => (
              <article
                className={`ph-feature-card ph-${feature.type}`}
                key={feature.type}
              >
                <span className="ph-feature-icon">{feature.icon}</span>
                <h3>{feature.title}</h3>
                <p>{feature.description}</p>
                <FeatureVisual type={feature.type} />
              </article>
            ))}
            <article className="ph-feature-card ph-team">
              <div className="ph-team-photo">
                <div>
                  <span className="ph-feature-icon">
                    <Layers3 size={17} />
                  </span>
                  <h3>Collaborative Hiring Team Notes</h3>
                  <p>
                    Scorecards, interview feedback, and decisions in one shared
                    space.
                  </p>
                  <div className="ph-avatars">
                    <i>MC</i>
                    <i>DK</i>
                    <i>PS</i>
                    <i>+4</i>
                  </div>
                </div>
              </div>
            </article>
          </div>
        </div>
      </section>

      <section className="ph-section ph-demo-section" id="demo">
        <div className="ph-container">
          <div className="ph-section-title">
            <span className="ph-eyebrow">ILLUSTRATIVE SCREENING PREVIEW</span>
            <h2>Watch the engine think.</h2>
            <p>
              Pick a candidate, choose a role, and preview how a screening
              report can connect role requirements to evidence.
            </p>
          </div>
          <Demo />
        </div>
      </section>

      <section className="ph-how" id="how">
        <div className="ph-container">
          <div className="ph-section-title">
            <span className="ph-eyebrow">HOW IT WORKS</span>
            <h2>Three steps between a job post and a proven hire.</h2>
          </div>
          <div className="ph-steps">
            {[
              [
                '01',
                'Connect Job & Criteria',
                'Define role requirements, must-have skills, and the evidence that matters.',
              ],
              [
                '02',
                'Automate Screening & Proofs',
                'Filter applications with consistent screening and skills assessments.',
              ],
              [
                '03',
                'Close Top Talent Faster',
                'Compare trusted scorecards and move forward with confidence.',
              ],
            ].map(([number, title, description]) => (
              <article key={number}>
                <b>{number}</b>
                <h3>{title}</h3>
                <p>{description}</p>
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="ph-section ph-proof">
        <div className="ph-container">
          <div className="ph-section-title">
            <span className="ph-eyebrow">BUILT FOR HIRING TEAMS</span>
            <h2>Teams that stopped guessing.</h2>
          </div>
          <div className="ph-stats">
            {[
              ['65%', 'Faster screening*'],
              ['12k+', 'Profiles reviewed*'],
              ['4.9/5', 'Team satisfaction*'],
              ['40hrs', 'Saved per role*'],
            ].map(([value, label]) => (
              <div key={value}>
                <b>{value}</b>
                <span>{label}</span>
              </div>
            ))}
          </div>
          <div className="ph-quotes">
            {[
              [
                'ProofHire cut our technical screening time while keeping candidate quality high.',
                'Sarah Johnson',
                'VP of Talent, Northstar',
              ],
              [
                'The resume analysis helps our team focus on evidence instead of guesswork.',
                'Marcus Nolan',
                'Head of People, Layerline',
              ],
              [
                'Our hiring managers love having scorecards and decisions in one place.',
                'Elena Rivera',
                'Talent Lead, Rivet',
              ],
              [
                'We can review applicants without drowning in manual work.',
                'Thomas Berg',
                'CTO, Fieldnote',
              ],
            ].map(([quote, name, roleTitle]) => (
              <blockquote key={name}>
                <b className="ph-quote">“</b>
                <p>{quote}</p>
                <footer>
                  <b>{name}</b>
                  <span>{roleTitle}</span>
                </footer>
              </blockquote>
            ))}
          </div>
          <small className="ph-disclaimer">
            *Illustrative marketing placeholders. Replace with verified
            ProofHire data before public launch.
          </small>
        </div>
      </section>

      <section className="ph-section ph-pricing" id="pricing">
        <div className="ph-container">
          <div className="ph-section-title ph-center">
            <span className="ph-eyebrow">PRICING</span>
            <h2>Pay for proof, not seats you&apos;ll never use.</h2>
            <p>
              Choose a plan that grows with your team. Pricing is placeholder
              content for this prototype.
            </p>
          </div>
          <div className="ph-pricing-grid">
            {plans.map((plan) => (
              <article
                key={plan.name}
                className={`ph-price-card${plan.featured ? ' featured' : ''}`}
              >
                <span className="ph-plan-tag">{plan.tag}</span>
                <h3>{plan.name}</h3>
                <div className="ph-price">
                  {plan.price}
                  {plan.price !== 'Custom' && <small>/mo</small>}
                </div>
                <ul>
                  {plan.features.map((feature) => (
                    <li key={feature}>
                      <Check size={14} />
                      {feature}
                    </li>
                  ))}
                </ul>
                {plan.cta === 'Talk to sales' ? (
                  <a
                    className="ph-btn ph-btn-outline"
                    href="#request-access"
                  >
                    {plan.cta} <ArrowRight size={13} />
                  </a>
                ) : (
                  <Link
                    className="ph-btn ph-btn-primary"
                    to="/register"
                  >
                    {plan.cta} <ArrowRight size={13} />
                  </Link>
                )}
              </article>
            ))}
          </div>
        </div>
      </section>

      <section className="ph-access" id="request-access">
        <div className="ph-access-card">
          <span className="ph-eyebrow">EARLY ACCESS</span>
          <h2>Build your next team on proof.</h2>
          <p>
            We&apos;re onboarding a limited number of hiring teams. Tell us where
            to reach you.
          </p>
          {submitted ? (
            <div className="ph-access-success">
              <CircleCheck size={16} /> Thanks! This demo form has not sent your
              details. Connect it to a backend before collecting requests.
            </div>
          ) : (
            <form
              onSubmit={(event) => {
                event.preventDefault()
                if (email.trim()) setSubmitted(true)
              }}
            >
              <label className="ph-sr-only" htmlFor="ph-email">
                Work email
              </label>
              <input
                id="ph-email"
                type="email"
                required
                placeholder="you@company.com"
                value={email}
                onChange={(event) => setEmail(event.target.value)}
              />
              <button className="ph-btn ph-btn-primary" type="submit">
                Request access <ArrowRight size={14} />
              </button>
            </form>
          )}
          <small>
            By submitting, you agree to be contacted about ProofHire early
            access.
          </small>
        </div>
      </section>

      <footer className="ph-footer">
        <div className="ph-container">
          <div className="ph-footer-main">
            <div>
              <Brand />
              <p>
                Recruitment, thoughtfully engineered. Built for teams that hire
                with evidence.
              </p>
            </div>
            <div>
              <b>PRODUCT</b>
              <a href="#features">Features</a>
              <a href="#demo">Screening Demo</a>
              <a href="#how">How it works</a>
              <a href="#pricing">Pricing</a>
            </div>
            <div>
              <b>COMPANY</b>
              <a href="#request-access">About</a>
              <a href="#request-access">Contact</a>
              <a href="#request-access">Early access</a>
            </div>
          </div>
          <div className="ph-footer-bottom">
            <span>© {new Date().getFullYear()} ProofHire. All rights reserved.</span>
            <span>
              <a href="#top">Privacy</a>
              <a href="#top">Terms</a>
            </span>
          </div>
        </div>
      </footer>
    </main>
  )
}
