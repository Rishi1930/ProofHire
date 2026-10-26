import { useMemo, useState } from 'react'
import { ChevronDown, Download } from 'lucide-react'

type Format = 'csv' | 'pdf' | 'xlsx'

export type ExportOption = {
  label: string
  format: Format
  onSelect?: () => void | Promise<void>
  disabled?: boolean
  reason?: string
  scope?: string
}

type Props = {
  scope: string
  disabled?: boolean
  options?: ExportOption[]
  onCsv?: () => void | Promise<void>
  onPdf?: () => void | Promise<void>
  onXlsx?: () => void | Promise<void>
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : 'The export could not be created.'
}

export default function ExportActions({
  scope,
  disabled = false,
  options,
  onCsv,
  onPdf,
  onXlsx,
}: Props) {
  const [exporting, setExporting] = useState<string | null>(null)
  const [message, setMessage] = useState('')
  const [failed, setFailed] = useState(false)
  const resolvedOptions = useMemo<ExportOption[]>(
    () =>
      options ??
      [
        ...(onCsv ? [{ label: 'Download CSV', format: 'csv' as const, onSelect: onCsv }] : []),
        ...(onXlsx ? [{ label: 'Download XLSX', format: 'xlsx' as const, onSelect: onXlsx }] : []),
        ...(onPdf ? [{ label: 'Download PDF', format: 'pdf' as const, onSelect: onPdf }] : []),
      ],
    [options, onCsv, onPdf, onXlsx],
  )

  async function runExport(option: ExportOption) {
    if (!option.onSelect || disabled || option.disabled) return
    const optionKey = `${option.format}-${option.label}`
    setExporting(optionKey)
    setMessage('')
    setFailed(false)
    try {
      await option.onSelect()
      setMessage(
        `${option.format.toUpperCase()} download started · ${option.scope ?? scope}`,
      )
    } catch (error) {
      setMessage(errorMessage(error))
      setFailed(true)
    } finally {
      setExporting(null)
    }
  }

  return (
    <div className="export-actions">
      <details className="export-menu">
        <summary
          className="button button-secondary export-menu-trigger"
          aria-label="Export recruitment data"
        >
          <Download size={15} />
          Export
          <ChevronDown size={14} />
        </summary>
        <div className="export-menu-popover" role="group" aria-label="Export formats">
          {resolvedOptions.map((option) => {
            const unavailable = disabled || Boolean(option.disabled)
            const unavailableReason = disabled
              ? 'Data is still loading or unavailable.'
              : option.reason
            return (
              <button
                type="button"
                className="export-menu-item"
                key={`${option.format}-${option.label}`}
                disabled={unavailable || exporting !== null}
                title={unavailable ? unavailableReason : undefined}
                onClick={(event) => {
                  const details = event.currentTarget.closest('details')
                  if (details) details.open = false
                  void runExport(option)
                }}
              >
                <span>{option.label}</span>
                <small>
                  {exporting === `${option.format}-${option.label}`
                    ? 'Preparing…'
                    : unavailable
                      ? unavailableReason ?? 'Unavailable'
                      : option.format.toUpperCase()}
                </small>
              </button>
            )
          })}
        </div>
      </details>
      <span className="export-scope">Scope: {scope}</span>
      {message ? (
        <span
          className={failed ? 'export-message export-message-error' : 'export-message'}
          role={failed ? 'alert' : 'status'}
        >
          {message}
        </span>
      ) : (
        <span className="export-helper">
          Only authorized workspace data is exported.
        </span>
      )}
    </div>
  )
}
