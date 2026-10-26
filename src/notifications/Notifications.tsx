import { Bell } from 'lucide-react'
import { Link } from 'react-router-dom'

export default function Notifications() {
  return (
    <div className="notifications-page">
      <header className="page-header">
        <div>
          <p className="eyebrow">WORKSPACE</p>
          <h1>Notifications</h1>
          <p className="page-description">
            Keep up with updates from your hiring workspace.
          </p>
        </div>
      </header>

      <section className="dashboard-panel">
        <div className="empty-state">
          <span className="empty-state-icon">
            <Bell size={22} />
          </span>
          <h3>No notifications yet</h3>
          <p>
            Notifications are not enabled yet. You can continue managing current
            activity from your workspace overview.
          </p>
          <div className="empty-state-action">
            <Link className="button button-secondary" to="/dashboard">
              Back to overview
            </Link>
          </div>
        </div>
      </section>
    </div>
  )
}
