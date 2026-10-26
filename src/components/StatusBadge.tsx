
type StatusBadgeProps = {
  status: string
  label?: string
  size?: 'small' | 'medium'
}

const STATUS_LABELS: Record<string, string> = {
  new: 'New',
  draft: 'Draft',
  open: 'Open',
  closed: 'Closed',
  paused: 'Paused',
  applied: 'Applied',
  screening: 'Screening',
  shortlisted: 'Shortlisted',
  interview: 'Interview',
  selected: 'Selected',
  rejected: 'Rejected',
  pending: 'Pending',
  completed: 'Completed',
  cancelled: 'Cancelled',
  active: 'Active',
  inactive: 'Inactive',
  invited: 'Invited',
}

const STATUS_CLASSES: Record<string, string> = {
  new: 'status-info',
  draft: 'status-neutral',
  open: 'status-success',
  closed: 'status-neutral',
  paused: 'status-warning',
  applied: 'status-info',
  screening: 'status-info',
  shortlisted: 'status-success',
  interview: 'status-purple',
  selected: 'status-success',
  rejected: 'status-danger',
  pending: 'status-warning',
  completed: 'status-success',
  cancelled: 'status-neutral',
  active: 'status-success',
  inactive: 'status-neutral',
  invited: 'status-purple',
}

function formatUnknownStatus(status: string): string {
  return status
    .replace(/[_-]+/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .replace(/\b\w/g, (character) => character.toUpperCase())
}

export default function StatusBadge({
  status,
  label,
  size = 'medium',
}: StatusBadgeProps) {
  const normalizedStatus = status.trim().toLowerCase()
  const statusClass = STATUS_CLASSES[normalizedStatus] ?? 'status-neutral'
  const displayLabel =
    label ?? STATUS_LABELS[normalizedStatus] ?? formatUnknownStatus(status)

  return (
    <span
      className={`status-badge ${statusClass} status-${size}`}
      title={displayLabel}
    >
      <span className="status-dot" aria-hidden="true" />
      {displayLabel || 'Unknown'}
    </span>
  )
}
