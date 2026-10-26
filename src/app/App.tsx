
import { useState } from 'react'
import { NavLink, Outlet, useLocation, useNavigate } from 'react-router-dom'
import {
  Bell,
  CalendarDays,
  BriefcaseBusiness,
  ChartNoAxesColumnIncreasing,
  ChevronDown,
  ClipboardCheck,
  LayoutDashboard,
  LogOut,
  Settings,
  Users,
  BrainCircuit,
} from 'lucide-react'

import { useAuth } from '../auth/AuthContext'

const navigation = [
  {
    label: 'Workspace',
    items: [
      { label: 'Overview', path: '/dashboard', icon: LayoutDashboard },
      { label: 'Jobs & Hiring', path: '/jobs', icon: BriefcaseBusiness },
      { label: 'Resume Screening', path: '/screening', icon: ClipboardCheck },
      { label: 'Interviews', path: '/interviews', icon: CalendarDays },
      { label: 'Candidates', path: '/candidates', icon: Users },
      {
        label: 'Reports & Insights',
        path: '/reports',
        icon: ChartNoAxesColumnIncreasing,
      },
      { label: 'Settings', path: '/settings', icon: Settings },
    ],
  },
]

function getPageTitle(pathname: string) {
  if (pathname.startsWith('/jobs')) return 'Jobs & Hiring'
  if (pathname.startsWith('/applications')) return 'Applications'
  if (pathname.startsWith('/screening')) return 'Resume Screening'
  if (pathname.startsWith('/interviews')) return 'Interviews'
  if (pathname.startsWith('/reports')) return 'Reports & Insights'
  if (pathname.startsWith('/candidates')) return 'Candidates'
  if (pathname.startsWith('/dashboard')) return 'Overview'
  if (pathname.startsWith('/settings')) return 'Settings'
  if (pathname.startsWith('/notifications')) return 'Notifications'
  return 'Workspace'
}

export default function App() {
  const { user, signOut } = useAuth()
  const location = useLocation()
  const navigate = useNavigate()
  const [signOutError, setSignOutError] = useState('')
  const [signingOut, setSigningOut] = useState(false)

  const isPublicApplication = location.pathname.startsWith('/apply/')
  const isAuthPage = [
    '/login',
    '/register',
    '/forgot-password',
    '/reset-password',
  ].includes(location.pathname)

  if (isPublicApplication || isAuthPage) {
    return <Outlet />
  }

  async function handleSignOut() {
    setSignOutError('')
    setSigningOut(true)
    const { error } = await signOut()

    if (!error) {
      navigate('/login', { replace: true })
    } else {
      setSignOutError(error.message)
    }
    setSigningOut(false)
  }

  const pageTitle = getPageTitle(location.pathname)
  const userEmail = user?.email ?? 'Recruiter'
  const displayName =
    user?.user_metadata?.full_name?.trim() || userEmail.split('@')[0]
  const userInitial = displayName.charAt(0).toUpperCase()

  return (
    <div className="app-shell">
      <aside className="sidebar">
        <NavLink to="/dashboard" className="brand">
          <span className="brand-mark">P</span>
          <span className="brand-copy">
            <strong>ProofHire</strong>
            <small>Recruitment workspace</small>
          </span>
        </NavLink>

        <div className="workspace-switcher">
          <div className="workspace-avatar">W</div>
          <div className="workspace-copy">
            <strong>My workspace</strong>
            <small>Recruitment team</small>
          </div>
          <ChevronDown size={15} />
        </div>

        <nav className="sidebar-navigation" aria-label="Main navigation">
          {navigation.map((section) => (
            <div className="nav-section" key={section.label}>
              <p className="nav-section-label">{section.label}</p>

              {section.items.map((item) => {
                const Icon = item.icon

                return (
                  <NavLink
                    key={item.path}
                    to={item.path}
                    aria-label={item.label}
                    title={item.label}
                    className={({ isActive }) =>
                      `nav-link${isActive ? ' active' : ''}`
                    }
                  >
                    <Icon size={18} strokeWidth={1.8} />
                    <span>{item.label}</span>
                  </NavLink>
                )
              })}
            </div>
          ))}
        </nav>

        <div className="sidebar-bottom">
          <div className="nav-section">
            <p className="nav-section-label">Workspace tools</p>

            <div className="nav-link nav-link-disabled" aria-disabled="true">
              <BrainCircuit size={18} strokeWidth={1.8} />
              <span>AI insights</span>
              <span className="coming-soon">Later</span>
            </div>

          </div>

          <div className="sidebar-user">
            <div className="user-avatar">{userInitial}</div>
            <div className="sidebar-user-copy">
              <strong>{displayName}</strong>
              <small>{userEmail}</small>
            </div>

            <button
              type="button"
              className="icon-button"
              aria-label="Sign out"
              title="Sign out"
              onClick={() => void handleSignOut()}
              disabled={signingOut}
            >
              <LogOut size={17} />
            </button>
          </div>
        </div>
      </aside>

      <div className="main-area">
        <header className="topbar">
          <div className="breadcrumbs">
            <span>Workspace</span>
            <span className="breadcrumb-divider">/</span>
            <strong>{pageTitle}</strong>
          </div>

          <div className="topbar-actions">
            <span className="environment-label">
              <span className="status-dot" />
              Workspace
            </span>

            <button
              type="button"
              className="icon-button notification-button"
              aria-label="Notifications"
              title="Notifications"
              onClick={() => navigate('/notifications')}
            >
              <Bell size={19} />
            </button>
            <button
              type="button"
              className="icon-button topbar-logout"
              aria-label="Sign out"
              title="Sign out"
              onClick={() => void handleSignOut()}
              disabled={signingOut}
            >
              <LogOut size={17} />
            </button>

            <button
              type="button"
              className="topbar-profile"
              onClick={() => navigate('/settings')}
            >
              <span className="user-avatar small">{userInitial}</span>
              <span className="profile-label">Account</span>
              <ChevronDown size={14} />
            </button>
          </div>
          {signOutError && (
            <span className="topbar-error" role="alert">
              Could not sign out: {signOutError}
            </span>
          )}
        </header>

        <main className="page-content">
          <Outlet />
        </main>

        <footer className="app-footer">
          <span>ProofHire</span>
          <span>Recruitment, thoughtfully organized.</span>
        </footer>
      </div>
    </div>
  )
}
