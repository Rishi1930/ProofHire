
export function getInitials(value?: string | null): string {
  const normalized = value?.trim()

  if (!normalized) return 'PH'

  const parts = normalized.split(/\s+/).filter(Boolean)

  if (parts.length === 1) {
    return parts[0].slice(0, 2).toUpperCase()
  }

  return `${parts[0][0]}${parts[parts.length - 1][0]}`.toUpperCase()
}

export function formatDate(
  value?: string | null,
  options?: Intl.DateTimeFormatOptions,
): string {
  if (!value) return '—'

  const date = new Date(value)

  if (Number.isNaN(date.getTime())) return '—'

  return new Intl.DateTimeFormat('en-IN', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    ...options,
  }).format(date)
}

export function formatDateTime(value?: string | null): string {
  if (!value) return '—'

  const date = new Date(value)

  if (Number.isNaN(date.getTime())) return '—'

  return new Intl.DateTimeFormat('en-IN', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  }).format(date)
}

export function normalizeEmail(value: string): string {
  return value.trim().toLowerCase()
}

export function normalizeSearch(value: string): string {
  return value.trim().toLowerCase().replace(/\s+/g, ' ')
}

export function getErrorMessage(
  error: unknown,
  fallback = 'Something went wrong. Please try again.',
): string {
  if (error instanceof Error && error.message.trim()) {
    return error.message
  }

  if (
    typeof error === 'object' &&
    error !== null &&
    'message' in error &&
    typeof error.message === 'string' &&
    error.message.trim()
  ) {
    return error.message
  }

  return fallback
}

export function formatCount(
  value: number,
  singular: string,
  plural = `${singular}s`,
): string {
  const safeValue = Number.isFinite(value) ? value : 0
  const label = safeValue === 1 ? singular : plural

  return `${safeValue.toLocaleString('en-IN')} ${label}`
}

export function getFileExtension(filename: string): string {
  const trimmed = filename.trim()
  const lastDot = trimmed.lastIndexOf('.')

  if (lastDot <= 0 || lastDot === trimmed.length - 1) {
    return ''
  }

  return trimmed.slice(lastDot + 1).toLowerCase()
}

export function isAllowedResumeFile(file: File): boolean {
  const allowedExtensions = new Set(['pdf', 'doc', 'docx'])
  const maximumSizeBytes = 5 * 1024 * 1024

  return (
    allowedExtensions.has(getFileExtension(file.name)) &&
    file.size > 0 &&
    file.size <= maximumSizeBytes
  )
}

export function createSafeFilename(filename: string): string {
  const extension = getFileExtension(filename)

  const baseName = filename
    .trim()
    .replace(/\.[^.]+$/, '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-zA-Z0-9_-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 80)

  const safeBaseName = baseName || 'resume'

  return extension ? `${safeBaseName}.${extension}` : safeBaseName
}
